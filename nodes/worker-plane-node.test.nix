# ═══════════════════════════════════════════════════════════════════════
#  worker-plane-node — live VM test
#
#    check = boot(role ⊕ virtualisation) ⊨ assertions
#
#  Same shape as ./control-plane-node.test.nix, and deliberately not
#  factored into a shared test library with it. A test that shares its
#  fixtures with the thing it is distinguishing itself from stops being
#  able to catch the two roles drifting into each other — the negative
#  assertions at the bottom of this file are exactly that check, and they
#  only mean something if this file stands alone.
#
#  What is *not* here, and why: `kubeadm join`. A worker joins a control
#  plane that does not exist in a single-node sandbox, and the rendered
#  kubeadm document is produced by the same module for both roles, so it
#  is exercised once — on the control plane, which actually consumes it.
#
#  In plain English: boot a real machine carrying the worker role and
#  check that it is a kubelet host with workload ports open and no
#  control-plane surface.
# ═══════════════════════════════════════════════════════════════════════
{
  name = "worker-plane-node";

  nodes.worker = {
    imports = [ ./worker-plane-node.nix ];

    services.k8sCluster.worker.enable = true;

    virtualisation.vlans = [ 1 ];
    virtualisation.cores = 2;
    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 4096;
  };

  testScript =
    { nodes, ... }:
    let
      cfg = nodes.worker.services.k8sCluster;
      inherit (cfg) package;
      inherit (cfg.worker) nodePortRange;
    in
    ''
      worker.start()
      worker.wait_for_unit("multi-user.target")

      with subtest("kernel prerequisites are live, not merely declared"):
          worker.succeed("lsmod | grep -q '^br_netfilter'")
          worker.succeed("lsmod | grep -q '^overlay'")
          # Read back from the kernel, not from /etc/sysctl.d: systemd-sysctl
          # only warns about a key the kernel does not have, so a misspelled
          # knob is silently a no-op unless something checks the live value.
          for knob in [
              "net.bridge.bridge-nf-call-iptables",
              "net.bridge.bridge-nf-call-ip6tables",
              "net.ipv4.ip_forward",
              "net.ipv6.conf.all.forwarding",
          ]:
              value = worker.succeed(f"sysctl -n {knob}").strip()
              assert value == "1", f"{knob} is {value}, expected 1"

      with subtest("swap is off, which kubeadm preflight insists on"):
          assert worker.succeed("swapon --show").strip() == "", "swap is active"

      with subtest("containerd is up and answering CRI calls"):
          worker.wait_for_unit("containerd.service")
          worker.wait_for_file("/run/containerd/containerd.sock")
          worker.succeed("crictl version")

      with subtest("the daemon loaded the cgroup driver and CNI dir we wired in"):
          # Read out of the file the *running* unit was started with, rather
          # than a path we assume: neither of these fails at boot. A cgroup
          # driver mismatch surfaces later as pods in a restart loop, and a
          # wrong cni bin_dir as nodes that never leave NotReady.
          execstart = worker.succeed(
              "systemctl show -p ExecStart --value containerd.service"
          )
          # NixOS renders the flag GNU-style as `--config=<path>`; lstrip keeps
          # this working if that ever becomes a separate argument instead.
          conf = execstart.split("--config")[1].lstrip("=").split()[0]
          loaded = worker.succeed(f"cat {conf}")
          assert "SystemdCgroup = true" in loaded, "containerd is not on the systemd cgroup driver"
          assert "/opt/cni/bin" in loaded, "the CRI plugin is not looking in /opt/cni/bin"

      with subtest("the CNI bin dir is a real directory, seeded with plugins"):
          worker.succeed("test -d /opt/cni/bin")
          worker.succeed("test -w /opt/cni/bin")
          worker.succeed("test -x /opt/cni/bin/bridge")
          worker.succeed("test -x /opt/cni/bin/loopback")

      with subtest("the kubelet unit is installed and runs the pinned binary"):
          worker.succeed("systemctl cat kubelet.service >/dev/null")
          worker.succeed("systemctl is-enabled kubelet.service")
          worker.succeed(
              "systemctl show -p ExecStart --value kubelet.service"
              " | grep -q '${package}/bin/kubelet'"
          )
          worker.succeed("kubelet --version")
          # Crash-looping until `kubeadm join` writes its config is upstream's
          # design, so the assertion is only that the unit was pulled into the
          # boot and tried.
          state = worker.succeed(
              "systemctl show -p ActiveState --value kubelet.service"
          ).strip()
          assert state != "inactive", f"kubelet never attempted to start (ActiveState={state})"

      with subtest("the running firewall accepts the workload ports"):
          rules = worker.succeed("iptables-save")
          for port in [10250, 10256]:
              assert f"--dport {port} " in rules, f"tcp/{port} is not accepted"
          nodeports = "${toString nodePortRange.from}:${toString nodePortRange.to}"
          assert f"--dport {nodeports} " in rules, f"NodePort range {nodeports} is not accepted"

      with subtest("a worker exposes no control-plane surface"):
          # The two roles compose onto one machine (see kubernetes-playground),
          # so what separates them has to be asserted, not assumed.
          rules = worker.succeed("iptables-save")
          for port in [6443, 2379, 2380, 10257, 10259]:
              assert (
                  f"--dport {port} " not in rules
              ), f"tcp/{port} is a control-plane port and must not be open on a worker"

          kubeconfig = worker.succeed("bash -lc 'echo $KUBECONFIG'").strip()
          assert (
              kubeconfig == ""
          ), f"a worker must not carry cluster-admin credentials, but KUBECONFIG is {kubeconfig!r}"

          worker.fail("test -e /etc/kubernetes/admin.conf")
    '';
}
