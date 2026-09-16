# ═══════════════════════════════════════════════════════════════════════
#  weave — live per-datapath port test
#
#    check = boot(datapath=weave)² ⊨ reach(mesh) ∧ ¬reach(rest)
#
#  The sibling of ./calico.test.nix, for the same reason:
#  ../cross-node-reachability.test.nix pins itself to Flannel, so every
#  claim it makes about which overlay port is open is a claim about
#  Flannel and inverts under anything else. Weave's ports are asserted
#  here, from off the machine, which is where a packet filter can be
#  asked a question it might answer "no" to.
#
#  Weave is the one datapath in this flake whose ports are not a single
#  number, and its shape is easy to get wrong in a way no option-level
#  check would notice:
#
#    tcp/6783          mesh control — peer discovery and topology gossip
#    udp/6783          the sleeve datapath
#    udp/6784          the faster VXLAN datapath
#
#  6783 appearing under both protocols is upstream's design, not a
#  mistake in ./weave.nix, and it is exactly the overlap a firewall
#  written from memory collapses into "open 6783 and 6784 on both
#  protocols". That config satisfies every assertion about what *should*
#  be reachable, so the negative below — tcp/6784 must not answer — is
#  the one doing the real work here.
#
#  Why the machines carry no role, and why there are two of them: the
#  same argument as ./calico.test.nix. What is under test is ./weave.nix,
#  which a role would only bury under a kubelet and a containerd; and a
#  packet filter cannot be interrogated from the machine it protects.
#
#  In plain English: boot two nodes on the Weave datapath and check that
#  the mesh ports answer in both directions, on the protocols Weave
#  actually speaks and on no others.
# ═══════════════════════════════════════════════════════════════════════
let
  # A mesh has no client and no server, so the two machines are the same
  # machine twice. Written once to keep it that way — the bidirectional
  # assertion below is only interesting because neither side was special-
  # cased into being the listener.
  peer =
    { pkgs, ... }:
    {
      imports = [
        # ./weave.nix alone would not evaluate: `datapath`, the option that
        # selects it, is declared by ./default.nix.
        ./default.nix
        # Declares `podCIDR`, which ./weave.nix injects as IPALLOC_RANGE.
        ../shared-userspace-config
      ];

      services.k8sCluster.podNetwork.datapath = "weave";

      # ../utilities/kubeadm.nix is what puts socat on a real node, but no
      # role is imported here, so the probe's own tool is installed
      # directly rather than dragging kubeadm in for one binary.
      environment.systemPackages = [ pkgs.socat ];

      virtualisation.vlans = [ 1 ];
    };
in
{
  name = "weave";

  nodes = {
    "weave-a" = peer;
    "weave-b" = peer;
  };

  testScript =
    { nodes, ... }:
    let
      podNetwork = nodes."weave-a".services.k8sCluster.podNetwork;
      inherit (podNetwork.weave) controlPort dataPorts;

      # The data port that is *not* also the control port. "UDP only" is a
      # claim you can test on that one and nowhere else, because the other
      # number is supposed to answer on TCP.
      udpOnlyPort = builtins.head (builtins.filter (p: p != controlPort) dataPorts);
      dataPortList = builtins.concatStringsSep ", " (map toString dataPorts);

      # Read out of their own options, so these stay "the ports the
      # neighbouring datapaths would have used" even if either one moves.
      # Both options are declared whether or not that datapath is selected.
      flannelPort = podNetwork.flannel.vxlanPort;
      calicoPort = podNetwork.calico.vxlanPort;

      ip = name: nodes.${name}.networking.primaryIPAddress;
    in
    ''
      start_all()
      for machine in machines:
          machine.wait_for_unit("multi-user.target")


      # The probe helpers below are close cousins of the ones in
      # ../cross-node-reachability.test.nix and ./calico.test.nix, and are
      # deliberately not shared with them. A test that draws its fixtures
      # from the same library as the tests it contradicts loses the ability
      # to catch them drifting together, and the whole value of this file
      # is that it disagrees with both about which port carries pod traffic.


      def park_tcp(machine, port):
          """Give the port something to answer with, so a probe against it is a
          question about the firewall rather than about what happens to be
          running. Nothing listens on a node that was never bootstrapped, so
          without this every port would look shut and prove nothing."""
          machine.succeed(
              f"systemd-run --unit=probe-tcp-{port}"
              f" $(command -v socat) TCP-LISTEN:{port},fork,reuseaddr OPEN:/dev/null"
          )
          # A local check against loopback, which the firewall trusts — so this
          # says the listener came up, not that the port is reachable.
          machine.wait_for_open_port(port)


      def park_udp(machine, port):
          """UDP has no handshake to observe, so the receiving end has to leave
          evidence: each datagram that arrives is appended to a file."""
          machine.succeed(
              f"systemd-run --unit=probe-udp-{port}"
              f" $(command -v socat) -u UDP-RECVFROM:{port},fork"
              f" OPEN:/tmp/udp-{port},creat,append"
          )


      def can_reach_tcp(source, ip, port):
          """`networking.firewall.rejectPackets` is false by default, so a port
          that is not opened DROPs rather than refusing — the connect hangs
          instead of failing. connect-timeout is what turns that hang back into
          an answer within the lifetime of the test."""
          status, _ = source.execute(
              f"socat -T5 OPEN:/dev/null TCP:{ip}:{port},connect-timeout=5"
          )
          return status == 0


      def send_udp(source, ip, port):
          source.succeed(f"echo probe | socat -u - UDP-SENDTO:{ip}:{port}")


      def udp_landed(target, port):
          status, _ = target.execute(f"test -s /tmp/udp-{port}")
          return status == 0


      def round_trip(source, ip):
          """A clock for the negative UDP cases, which have no event to wait
          for: the absence of a datagram only means something once a present
          one would have arrived. ICMP echo is neither opened nor closed by
          ./weave.nix — `allowPing` is on by default and this module never
          touches it — so a completed echo is a neutral measure of "long
          enough": a datagram sent before it, over the same segment, has had at
          least that long to land."""
          source.succeed(f"ping -c 1 -W 5 {ip}")


      with subtest("mesh control traffic crosses in both directions"):
          # Weave is a full mesh rather than a hub: either peer dials the
          # other, so reachability has to hold symmetrically. Asserting one
          # direction would leave a one-sided firewall looking healthy.
          for machine in [weave_a, weave_b]:
              park_tcp(machine, ${toString controlPort})

          assert can_reach_tcp(
              weave_a, "${ip "weave-b"}", ${toString controlPort}
          ), "a peer cannot reach the mesh control port, so the two would never gossip"
          assert can_reach_tcp(
              weave_b, "${ip "weave-a"}", ${toString controlPort}
          ), "the mesh control port is one-way, which is not a mesh"

      with subtest("both data ports carry pod traffic"):
          # Weave chooses between the sleeve datapath and the faster VXLAN one
          # per peer, at runtime. Opening only one does not fail: connectivity
          # quietly degrades to whichever is still reachable, which reads as a
          # slow cluster rather than a broken one.
          for port in [${dataPortList}]:
              park_udp(weave_b, port)
              send_udp(weave_a, "${ip "weave-b"}", port)

          for port in [${dataPortList}]:
              weave_b.wait_until_succeeds(f"test -s /tmp/udp-{port}", timeout=30)

      with subtest("the mesh ports answer on the protocols Weave speaks, and no others"):
          # tcp/${toString controlPort} and udp/${toString controlPort} are both live above, which is
          # upstream's overlap and not a licence to open every mesh number on
          # every protocol. ${toString udpOnlyPort} is a data port, so it is UDP only.
          park_tcp(weave_b, ${toString udpOnlyPort})
          assert not can_reach_tcp(
              weave_a, "${ip "weave-b"}", ${toString udpOnlyPort}
          ), "tcp/${toString udpOnlyPort} is reachable, but ${toString udpOnlyPort} is a UDP data port"

      with subtest("no neighbouring datapath's overlay port is open"):
          # Flannel's ${toString flannelPort} and Calico's ${toString calicoPort}. Weave would answer on
          # neither, and a node with both open is a node whose `datapath`
          # setting is not the only thing choosing its firewall — which is the
          # failure the enum in ./default.nix exists to make impossible.
          for port in [${toString flannelPort}, ${toString calicoPort}]:
              park_udp(weave_b, port)
              send_udp(weave_a, "${ip "weave-b"}", port)

          round_trip(weave_a, "${ip "weave-b"}")
          for port in [${toString flannelPort}, ${toString calicoPort}]:
              assert not udp_landed(
                  weave_b, port
              ), f"udp/{port} belongs to another datapath and must stay shut under Weave"
    '';
}
