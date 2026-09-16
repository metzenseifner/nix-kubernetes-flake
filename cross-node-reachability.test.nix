# ═══════════════════════════════════════════════════════════════════════
#  cross-node-reachability — live two-node VM test
#
#    check = boot(control) ∥ boot(worker) ⊨ reach ∧ ¬reach
#
#  Placement: this file sits at the root of the kubernetes flake rather
#  than beside a module, because there is no single module it tests. The
#  contract it checks is a seam — what ./nodes/control-plane-node.nix
#  opens has to be what ./nodes/worker-plane-node.nix needs to dial, and
#  vice versa, with ./pod-network/flannel.nix owning the overlay port
#  between them. Colocation still holds, read as "next to the smallest
#  unit that contains everything under test"; here that unit is the flake.
#  The discovery walk in ./flake.nix finds `*.test.nix` at any depth, so
#  the name is what shows up as the check either way.
#
#  Why two nodes: ./nodes/*.test.nix can assert that a port is in the
#  running packet filter, which is a statement about one machine. It
#  cannot tell you a peer's packet gets through — that needs a peer. The
#  firewall rule and the reachability it is supposed to buy are different
#  claims, and only the second one is what a cluster actually depends on.
#
#  The awkward part, and the reason for the listeners below: on a cluster
#  that has never been bootstrapped nothing is listening. There is no
#  apiserver, and the kubelet crash-loops before it binds. A bare connect
#  would therefore fail on every port, open or not, and prove nothing. So
#  each port under test gets a parked listener first, which reduces the
#  probe to a question about the packet filter and nothing else.
#
#  In plain English: boot both roles on one network and check that each
#  can reach the other exactly where it is supposed to, and nowhere else.
# ═══════════════════════════════════════════════════════════════════════
{
  name = "cross-node-reachability";

  nodes.control = {
    imports = [ ./nodes/control-plane-node.nix ];

    services.k8sCluster.controlPlane.enable = true;
    # The host-side half of the overlay — opening the VXLAN port. Set on
    # every node, per the module's own guidance. `install.enable` stays
    # off: it is a cluster-wide write that blocks on an API server that
    # will never come up here.
    #
    # Pinned to flannel rather than left at the default, because the
    # overlay subtest below asserts on 8472-vs-4789 and those are a
    # property of *this* datapath: Calico's VXLAN mode uses 4789, so the
    # same assertion would invert under it.
    services.k8sCluster.podNetwork.datapath = "flannel";

    virtualisation.vlans = [ 1 ];
  };

  nodes.worker = {
    imports = [ ./nodes/worker-plane-node.nix ];

    services.k8sCluster.worker.enable = true;
    # Same datapath as the control plane, necessarily: the overlay is the
    # one thing both ends have to agree on.
    services.k8sCluster.podNetwork.datapath = "flannel";

    virtualisation.vlans = [ 1 ];
  };

  testScript =
    { nodes, ... }:
    let
      controlIP = nodes.control.networking.primaryIPAddress;
      workerIP = nodes.worker.networking.primaryIPAddress;
      apiPort = nodes.control.services.k8sCluster.controlPlane.apiServerPort;
      vxlanPort = nodes.control.services.k8sCluster.podNetwork.flannel.vxlanPort;
      inherit (nodes.worker.services.k8sCluster.worker) nodePortRange;
    in
    ''
      start_all()
      control.wait_for_unit("multi-user.target")
      worker.wait_for_unit("multi-user.target")


      def park_tcp(machine, port):
          """Give the port something to answer with, so a probe against it is a
          question about the firewall rather than about what happens to be
          running. socat is already on PATH: kubeadm's preflight checks require
          it, so ../utilities/kubeadm.nix installs it on every node."""
          # Resolved from PATH by the shell, not left to systemd-run: a unit's
          # ExecStart is an absolute path, and relying on systemd-run to find
          # the binary itself is the kind of thing that works until it doesn't.
          machine.succeed(
              f"systemd-run --unit=probe-tcp-{port}"
              f" $(command -v socat) TCP-LISTEN:{port},fork,reuseaddr OPEN:/dev/null"
          )
          machine.wait_for_open_port(port)


      def park_udp(machine, port):
          """UDP has no handshake to observe, so the receiving end has to leave
          evidence: each datagram that arrives is appended to a file."""
          machine.succeed(
              f"systemd-run --unit=probe-udp-{port}"
              f" $(command -v socat) -u UDP-RECVFROM:{port},fork"
              f" OPEN:/tmp/udp-{port},creat,append"
          )


      def can_reach(source, ip, port):
          """`networking.firewall.rejectPackets` is false by default, so a port
          that is not opened DROPs rather than refusing — the connect hangs
          instead of failing. connect-timeout is what turns that hang back into
          an answer within the lifetime of the test."""
          status, _ = source.execute(
              f"socat -T5 OPEN:/dev/null TCP:{ip}:{port},connect-timeout=5"
          )
          return status == 0


      with subtest("a worker reaches the control plane where it must"):
          for port in [${toString apiPort}, 10250]:
              park_tcp(control, port)

          assert can_reach(
              worker, "${controlIP}", ${toString apiPort}
          ), "a worker cannot reach the API server, so it could never join"
          assert can_reach(
              worker, "${controlIP}", 10250
          ), "the control plane's own kubelet is unreachable from the cluster"

      with subtest("the control plane reaches the worker where it must"):
          for port in [10250, 10256]:
              park_tcp(worker, port)

          # Without this the apiserver cannot serve `kubectl logs` or `exec`,
          # and the metrics pipeline has nothing to scrape.
          assert can_reach(
              control, "${workerIP}", 10250
          ), "the worker's kubelet API is unreachable from the control plane"
          assert can_reach(
              control, "${workerIP}", 10256
          ), "kube-proxy's healthz endpoint is unreachable"

      with subtest("the NodePort range is open across exactly its declared bounds"):
          # Both ends and both neighbors: an off-by-one at either edge is
          # invisible in the config but costs you a service that will not
          # answer, so the boundary is worth pinning from the outside.
          cases = [
              (${toString nodePortRange.from}, True),
              (${toString nodePortRange.to}, True),
              (${toString (nodePortRange.from - 1)}, False),
              (${toString (nodePortRange.to + 1)}, False),
          ]
          for port, _ in cases:
              park_tcp(worker, port)
          for port, expected in cases:
              actual = can_reach(control, "${workerIP}", port)
              assert actual == expected, (
                  f"NodePort boundary wrong at {port}:"
                  f" reachable={actual}, expected={expected}"
              )

      with subtest("a worker exposes no control-plane surface to its peers"):
          # The single-node test asserts these are absent from the worker's own
          # packet filter. This is the same claim made from off the machine,
          # which is where it actually matters.
          for port in [2379, 2380, ${toString apiPort}]:
              park_tcp(worker, port)
              assert not can_reach(
                  control, "${workerIP}", port
              ), f"tcp/{port} is a control-plane port and must not be reachable on a worker"

      with subtest("the overlay port is open, and the port Flannel avoids is not"):
          # 4789 is the kernel's VXLAN default; Flannel uses ${toString vxlanPort}. Opening
          # the wrong one yields a cluster where same-node pods talk fine and
          # cross-node traffic silently blackholes — which is precisely the
          # failure a single-node test cannot see.
          for port in [${toString vxlanPort}, 4789]:
              park_udp(control, port)
          for port in [${toString vxlanPort}, 4789]:
              worker.succeed(f"echo overlay | socat -u - UDP-SENDTO:${controlIP}:{port}")

          # The datagram that is supposed to land doubles as the clock: once it
          # has arrived, the blocked one has had at least as long to arrive too.
          control.wait_until_succeeds("test -s /tmp/udp-${toString vxlanPort}", timeout=30)
          control.fail("test -s /tmp/udp-4789")
    '';
}
