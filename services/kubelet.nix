# The kubelet: the node agent kubeadm drives.
#
# Division of labour: kubeadm owns this unit's *configuration* — during `init`
# and `join` it writes /var/lib/kubelet/config.yaml and
# /var/lib/kubelet/kubeadm-flags.env — while this module owns the *unit*. The
# two meet at the EnvironmentFile lines below, which carry a `-` prefix so the
# unit stays valid before kubeadm has ever run.
#
# Files referenced here and who creates them:
#   /etc/kubernetes/bootstrap-kubelet.conf  `kubeadm join`, removed after TLS bootstrap
#   /etc/kubernetes/kubelet.conf            written once the node holds a client cert
#   /var/lib/kubelet/config.yaml            kubeadm, from the cluster's KubeletConfiguration
#   /var/lib/kubelet/kubeadm-flags.env      kubeadm, per-node flags (cgroup driver, CRI socket)
#
# Plain English: this unit is expected to crash-loop on a fresh node until
# kubeadm has written those files. That is upstream's design, not a fault.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.services.k8sCluster;
in
{
  options.services.k8sCluster.kubelet = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Run the kubelet on this node.

        Set by the node role modules under ../nodes rather than directly: both
        the control-plane and worker roles switch it on, and a node carrying
        both roles must not conflict with itself.
      '';
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Extra flags appended to the kubelet command line, via the
        `KUBELET_EXTRA_ARGS` variable upstream's unit reserves for operators.
      '';
      example = [ "--node-ip=10.0.1.10" ];
    };
  };

  config = lib.mkIf cfg.kubelet.enable {
    systemd.services.kubelet = {
      description = "kubelet (kubeadm-managed)";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
      ]
      ++ lib.optional cfg.containerRuntime.enable "containerd.service";
      requires = lib.optional cfg.containerRuntime.enable "containerd.service";

      # The kubelet shells out to these for mounting volumes, probing links and
      # programming service rules. On NixOS nothing is in /usr/bin, so the unit
      # has to carry its own PATH.
      path = with pkgs; [
        util-linux # mount, umount, nsenter
        iproute2
        ethtool
        iptables
        conntrack-tools
        socat
        coreutils
        findutils
      ];

      # kubelet crash-loops until kubeadm writes its config; never rate-limit it away.
      unitConfig.StartLimitIntervalSec = 0;

      serviceConfig = {
        # Built with concatStringsSep, not a multi-line string: systemd ends a
        # directive at the newline, so an accidental line break silently drops
        # every argument after it.
        ExecStart = lib.concatStringsSep " " [
          "${cfg.package}/bin/kubelet"
          "$KUBELET_KUBECONFIG_ARGS"
          "$KUBELET_CONFIG_ARGS"
          "$KUBELET_KUBEADM_ARGS"
          "$KUBELET_EXTRA_ARGS"
        ];
        Environment = [
          (lib.concatStringsSep " " [
            "KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf"
            "--kubeconfig=/etc/kubernetes/kubelet.conf"
          ])
          "KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
        ]
        ++ lib.optional (
          cfg.kubelet.extraArgs != [ ]
        ) "KUBELET_EXTRA_ARGS=${lib.concatStringsSep " " cfg.kubelet.extraArgs}";
        EnvironmentFile = [
          "-/var/lib/kubelet/kubeadm-flags.env"
          "-/etc/default/kubelet"
        ];
        Restart = "always";
        RestartSec = "10s";
      };
    };

    # CNI DaemonSets cp their binaries here, so it must be a real writable
    # directory, seeded with the plugins the CNI itself does not ship.
    #
    # One line per path, not two: systemd-tmpfiles keys its item table by
    # path, so a `d` and a `C` for the same directory is a duplicate — it
    # keeps the first, logs "Duplicate line for path ..., ignoring", and
    # carries on. That left the directory created but empty, with nothing
    # failing to show for it. `C` creates the target itself, and seeds it
    # only when absent or empty, so it is also a no-op on a node whose CNI
    # DaemonSet has already dropped its own binaries in.
    systemd.tmpfiles.rules = [
      "C /opt/cni/bin 0755 root root - ${pkgs.cni-plugins}/bin"
    ];
    virtualisation.containerd.settings.plugins."io.containerd.grpc.v1.cri".cni.bin_dir =
      lib.mkIf cfg.containerRuntime.enable "/opt/cni/bin";
  };
}
