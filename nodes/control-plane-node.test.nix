# ═══════════════════════════════════════════════════════════════════════
#  control-plane-node — live VM test
#
#    check = boot(role ⊕ virtualisation) ⊨ assertions
#
#  This file is a NixOS *test module*. It never mentions `pkgs` and never
#  calls `runNixOSTest` itself: ../../flake.nix finds it by its `.test.nix`
#  suffix and hands it to `pkgs.testers.runNixOSTest` once per target
#  system. That indirection is what lets the test sit here, beside the
#  module it tests, instead of in a tests/ tree that mirrors this one.
#
#  What is under test is the *role*, not a machine. The node below imports
#  ./control-plane-node.nix directly and imports no board. Boards set
#  `nixpkgs.hostPlatform` and declare real disks; the test framework owns
#  both, so a board here would fight it rather than add coverage. A file
#  under nixosConfigurations/ is board ⊕ role, and the board half is what
#  the qcow2/repart images exist to exercise.
#
#  Scope — what a sandboxed VM can and cannot say:
#
#    can    every claim the module makes about a node *before* a cluster
#           exists: modules loaded, sysctls applied, swap gone, containerd
#           answering CRI, the rendered kubeadm document actually accepted
#           by kubeadm, firewall rules present in the running kernel.
#
#    cannot a running control plane. `kubeadm init` pulls apiserver and
#           etcd images from registry.k8s.io and the sandbox has no
#           network. The offline `init phase` calls below are the honest
#           boundary: they prove the configuration is valid and
#           self-contained, which is the part this flake owns.
#
#  In plain English: boot a real machine carrying the control-plane role
#  and check everything that does not require the internet.
# ═══════════════════════════════════════════════════════════════════════
{
  name = "control-plane-node";

  nodes.control =
    { config, ... }:
    {
      imports = [ ./control-plane-node.nix ];

      services.k8sCluster.controlPlane.enable = true;

      # Told, not guessed: kubeadm derives the API endpoint from the
      # default route when left to itself, and a test VM has none. This is
      # the address the framework put on eth1, so the certs kubeadm mints
      # below carry a SAN that matches the machine it is running on.
      services.k8sCluster.kubeadm.initConfiguration.localAPIEndpoint.advertiseAddress =
        config.networking.primaryIPAddress;

      # Stated so `primaryIPAddress` above is non-empty rather than
      # dependent on the framework's default node wiring.
      virtualisation.vlans = [ 1 ];
      virtualisation.cores = 2;
      virtualisation.memorySize = 2048;
      virtualisation.diskSize = 4096;
    };

  testScript =
    { nodes, ... }:
    let
      cfg = nodes.control.services.k8sCluster;
      inherit (cfg) package;
      inherit (cfg.kubeadm) configPath;
    in
    ''
      control.start()
      control.wait_for_unit("multi-user.target")

      with subtest("kernel prerequisites are live, not merely declared"):
          control.succeed("lsmod | grep -q '^br_netfilter'")
          control.succeed("lsmod | grep -q '^overlay'")
          # Read back from the kernel, not from /etc/sysctl.d: systemd-sysctl
          # only warns about a key the kernel does not have, so a misspelled
          # knob is silently a no-op unless something checks the live value.
          for knob in [
              "net.bridge.bridge-nf-call-iptables",
              "net.bridge.bridge-nf-call-ip6tables",
              "net.ipv4.ip_forward",
              "net.ipv6.conf.all.forwarding",
          ]:
              value = control.succeed(f"sysctl -n {knob}").strip()
              assert value == "1", f"{knob} is {value}, expected 1"

      with subtest("swap is off, which kubeadm preflight insists on"):
          assert control.succeed("swapon --show").strip() == "", "swap is active"

      with subtest("containerd is up and answering CRI calls"):
          control.wait_for_unit("containerd.service")
          control.wait_for_file("/run/containerd/containerd.sock")
          # Reaches containerd through /etc/crictl.yaml, so this covers the
          # client, the socket and the file that names it.
          control.succeed("crictl version")

      with subtest("the CNI bin dir is a real directory, seeded with plugins"):
          # A CNI DaemonSet cp's its binary here, so it cannot be a store
          # symlink; the tmpfiles rules make it writable and pre-populate the
          # plugins Flannel does not ship.
          control.succeed("test -d /opt/cni/bin")
          control.succeed("test -w /opt/cni/bin")
          control.succeed("test -x /opt/cni/bin/bridge")
          control.succeed("test -x /opt/cni/bin/loopback")

      with subtest("the kubelet unit is installed and runs the pinned binary"):
          control.succeed("systemctl cat kubelet.service >/dev/null")
          control.succeed("systemctl is-enabled kubelet.service")
          control.succeed(
              "systemctl show -p ExecStart --value kubelet.service"
              " | grep -q '${package}/bin/kubelet'"
          )
          control.succeed("kubelet --version")
          # The kubelet crash-loops until kubeadm writes config.yaml — that is
          # upstream's design, so the assertion is that it *tried*. "inactive"
          # would mean the unit was never pulled into the boot at all.
          state = control.succeed(
              "systemctl show -p ActiveState --value kubelet.service"
          ).strip()
          assert state != "inactive", f"kubelet never attempted to start (ActiveState={state})"

      with subtest("kubectl carries system-wide credentials"):
          # Via a login shell, because environment.variables lands in
          # /etc/set-environment and only a shell that sources it sees the var.
          kubeconfig = control.succeed("bash -lc 'echo $KUBECONFIG'").strip()
          assert (
              kubeconfig == "/etc/kubernetes/admin.conf"
          ), f"KUBECONFIG is {kubeconfig!r}, so kubectl would target localhost:8080"

      with subtest("the rendered kubeadm document is accepted by kubeadm"):
          control.succeed("test -f ${configPath}")
          # Cert generation is the first real consumer of the document and is
          # entirely offline, so it is the cheapest proof that the multi-doc
          # v1beta4 stream parses and its fields are ones kubeadm knows.
          control.succeed("kubeadm init phase certs all --config ${configPath}")
          control.succeed("test -f /etc/kubernetes/pki/ca.crt")
          control.succeed("test -f /etc/kubernetes/pki/etcd/ca.crt")

      with subtest("the control plane is pinned offline to its own binaries"):
          # Templating the static pods reaches dl.k8s.io unless
          # `kubernetesVersion` is pinned. Succeeding without network is
          # therefore the assertion: it proves the pin is doing its job, and
          # the grep proves it was pinned to *these* binaries.
          control.succeed("kubeadm init phase control-plane all --config ${configPath}")
          control.succeed(
              "grep -q 'kube-apiserver:v${package.version}'"
              " /etc/kubernetes/manifests/kube-apiserver.yaml"
          )

      with subtest("the shared CIDRs reach the components that must agree on them"):
          control.succeed(
              "grep -q -- '--service-cluster-ip-range=${cfg.serviceCIDR}'"
              " /etc/kubernetes/manifests/kube-apiserver.yaml"
          )
          control.succeed(
              "grep -q -- '--cluster-cidr=${cfg.podCIDR}'"
              " /etc/kubernetes/manifests/kube-controller-manager.yaml"
          )

      with subtest("the running firewall accepts the control-plane ports"):
          # The ports the role's own doc comment promises, read back out of the
          # live kernel rather than out of the config that put them there.
          rules = control.succeed("iptables-save")
          for port in [${toString cfg.controlPlane.apiServerPort}, 2379, 2380, 10257, 10259, 10250]:
              assert f"--dport {port} " in rules, f"tcp/{port} is not accepted"
    '';
}
