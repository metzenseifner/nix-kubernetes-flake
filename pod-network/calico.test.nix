# ═══════════════════════════════════════════════════════════════════════
#  calico — live per-datapath port test
#
#    check = ∀e ∈ {vxlan, ipip}.
#              boot(datapath=calico ⊕ e)² ⊨ reach(ports e) ∧ ¬reach(ports ē)
#
#  ../cross-node-reachability.test.nix pins itself to Flannel and says
#  why: 8472-vs-4789 is a property of *that* datapath, and the same
#  assertion inverts under Calico. This file is the other half of that
#  sentence — the same from-the-outside claim, made for the ports Calico
#  actually uses.
#
#  Why the machines here carry no role: what is under test is
#  ./calico.nix. A control-plane or worker role would add containerd, a
#  kubelet and a handful of its own ports to every machine without adding
#  a single assertion, and slow the boot down while it did. The smallest
#  unit that contains everything under test is this directory plus the
#  options it reads, so that is what boots.
#
#  Why four machines rather than four subtests: `encapsulation` is not a
#  runtime switch, it is a different packet filter baked at build time.
#  vxlan and ipip therefore cannot be two subtests over one pair — they
#  are two pairs, and every subtest below is a contrast between them.
#  That contrast is the point: "4789 is open" is nearly free to satisfy
#  by accident, while "4789 is open here and closed there" is only true
#  if the encapsulation option is actually driving the firewall.
#
#  The one that earns its keep is ipip. It is IP protocol 4 — neither TCP
#  nor UDP, so it cannot go in `networking.firewall.allowedTCPPorts` or
#  its UDP twin, and ./calico.nix reaches for `extraCommands` and a raw
#  iptables rule instead. That rule is invisible to anything that reads
#  options, and it silently does nothing on an nftables host. Nothing
#  short of a real IPIP tunnel with a real packet in it can tell you it
#  works.
#
#  In plain English: boot a pair of nodes per encapsulation and check
#  that Calico's ports are reachable, and that the ports belonging to the
#  other encapsulation — and to the datapath next door — are not.
# ═══════════════════════════════════════════════════════════════════════
let
  # Both pairs differ in exactly one option, which is what makes the
  # contrasts below mean something. Shared here rather than written out
  # four times so that "one option apart" stays true by construction.
  peer =
    encapsulation:
    { pkgs, ... }:
    {
      imports = [
        # ./calico.nix alone would not evaluate: `datapath`, the option
        # that selects it, is declared by ./default.nix.
        ./default.nix
        # Declares `podCIDR`, which ./calico.nix substitutes into its
        # manifest.
        ../shared-userspace-config
      ];

      services.k8sCluster.podNetwork.datapath = "calico";
      services.k8sCluster.podNetwork.calico.encapsulation = encapsulation;

      # ../utilities/kubeadm.nix is what puts socat on a real node, but no
      # role is imported here, so the probe's own tool is installed
      # directly rather than dragging kubeadm in for one binary.
      environment.systemPackages = [ pkgs.socat ];

      virtualisation.vlans = [ 1 ];
    };
in
{
  name = "calico";

  nodes = {
    "vxlan-a" = peer "vxlan";
    "vxlan-b" = peer "vxlan";
    "ipip-a" = peer "ipip";
    "ipip-b" = peer "ipip";
  };

  testScript =
    { nodes, ... }:
    let
      podNetwork = nodes."vxlan-a".services.k8sCluster.podNetwork;
      inherit (podNetwork.calico) vxlanPort bgpPort;
      # Read out of the option rather than written as 8472, so this stays
      # the port Flannel *would* have used even if ./flannel.nix moves it.
      # The option is declared whether or not Flannel is the selection.
      flannelPort = podNetwork.flannel.vxlanPort;
      ip = name: nodes.${name}.networking.primaryIPAddress;
    in
    ''
      start_all()
      for machine in machines:
          machine.wait_for_unit("multi-user.target")


      # The probe helpers below are close cousins of the ones in
      # ../cross-node-reachability.test.nix and are deliberately not shared
      # with them. A test that draws its fixtures from the same library as
      # the test it is contrasting itself against loses the ability to
      # catch the two drifting together, and the whole value of this file
      # is that it disagrees with that one about 4789.


      def park_tcp(machine, port):
          """Give the port something to answer with, so a probe against it is a
          question about the firewall rather than about what happens to be
          running. Nothing is listening on a node that was never bootstrapped,
          so without this every port would look shut and prove nothing."""
          machine.succeed(
              f"systemd-run --unit=probe-tcp-{port}"
              f" $(command -v socat) TCP-LISTEN:{port},fork,reuseaddr OPEN:/dev/null"
          )
          # Local check, against loopback, which the firewall trusts — so this
          # says the listener is up, not that the port is reachable.
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
          """A clock for the negative UDP cases, which otherwise have no event
          to wait for: absence of a datagram is only meaningful after enough
          time has passed for a present one to have arrived. ICMP echo is
          neither opened nor closed by ./calico.nix — `allowPing` is on by
          default and this module never touches it — so a completed echo is a
          neutral measure of "long enough": a datagram sent before it, over the
          same segment, has had at least that long to land."""
          source.succeed(f"ping -c 1 -W 5 {ip}")


      def tunnel_up(machine, local, remote, address):
          """Protocol 4 has no port, so nothing above it can probe it — socat
          speaks TCP and UDP and stops there. The only way to ask whether the
          raw rule in ./calico.nix admits IPIP is to put a real IPIP packet on
          the wire, which means building a real tunnel. `ip tunnel` auto-loads
          the ipip module; the ping that follows travels inside protocol 4.

          10.200.0.0/30 is chosen to miss both cluster CIDRs: the default
          serviceCIDR is 10.96.0.0/12, which reaches up through 10.111."""
          machine.succeed(
              f"ip tunnel add probe0 mode ipip local {local} remote {remote} ttl 64",
              f"ip addr add {address}/30 dev probe0",
              "ip link set probe0 up",
          )


      with subtest("the VXLAN port is open exactly where the encapsulation calls for it"):
          # ${toString vxlanPort} is the kernel's standard VXLAN port and Calico's
          # choice; ${toString flannelPort} is Flannel's. Opening the wrong one buys a
          # cluster where same-node pods talk fine and cross-node traffic
          # silently blackholes, which is the failure no single-node firewall
          # dump can see.
          for port in [${toString vxlanPort}, ${toString flannelPort}]:
              park_udp(vxlan_b, port)
              send_udp(vxlan_a, "${ip "vxlan-b"}", port)

          # The datagram that is supposed to land doubles as the clock: once it
          # has arrived, the blocked one has had at least as long to arrive too.
          vxlan_b.wait_until_succeeds("test -s /tmp/udp-${toString vxlanPort}", timeout=30)
          assert not udp_landed(
              vxlan_b, ${toString flannelPort}
          ), "udp/${toString flannelPort} belongs to Flannel and must stay shut under Calico"

          # The other half of the claim: an IPIP install has no VXLAN datapath,
          # so the same port is surface with nothing behind it.
          park_udp(ipip_b, ${toString vxlanPort})
          send_udp(ipip_a, "${ip "ipip-b"}", ${toString vxlanPort})
          round_trip(ipip_a, "${ip "ipip-b"}")
          assert not udp_landed(
              ipip_b, ${toString vxlanPort}
          ), "udp/${toString vxlanPort} is open on an IPIP install, which never uses it"

      with subtest("BGP is open exactly where the encapsulation needs it"):
          # Route distribution is what IPIP has instead of a VXLAN fabric; a
          # VXLAN-only install turns the backend off entirely, so tcp/${toString bgpPort}
          # there is a listening surface no component would ever answer on.
          for machine in [vxlan_b, ipip_b]:
              park_tcp(machine, ${toString bgpPort})

          assert can_reach_tcp(
              ipip_a, "${ip "ipip-b"}", ${toString bgpPort}
          ), "peers cannot exchange routes, so the IPIP datapath has nowhere to send packets"
          assert not can_reach_tcp(
              vxlan_a, "${ip "vxlan-b"}", ${toString bgpPort}
          ), "tcp/${toString bgpPort} is open on a VXLAN install, which runs no BGP"

      with subtest("protocol 4 crosses only where the raw iptables rule was added"):
          tunnel_up(ipip_a, "${ip "ipip-a"}", "${ip "ipip-b"}", "10.200.0.1")
          tunnel_up(ipip_b, "${ip "ipip-b"}", "${ip "ipip-a"}", "10.200.0.2")
          # The positive case first, and it is what keeps the negative below
          # honest: if IPIP tunnels did not work in this VM at all, this line
          # fails rather than the negative passing for the wrong reason.
          ipip_a.succeed("ping -c 1 -W 5 10.200.0.2")

          tunnel_up(vxlan_a, "${ip "vxlan-a"}", "${ip "vxlan-b"}", "10.200.0.1")
          tunnel_up(vxlan_b, "${ip "vxlan-b"}", "${ip "vxlan-a"}", "10.200.0.2")
          status, _ = vxlan_a.execute("ping -c 1 -W 5 10.200.0.2")
          assert (
              status != 0
          ), "a VXLAN install admits IP protocol 4, so the raw rule is not tracking encapsulation"
    '';
}
