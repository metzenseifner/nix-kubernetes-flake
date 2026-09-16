# One-shot `kubeadm init`: the step that turns an installed control plane into
# a running one.
#
# Nothing else in this flake starts an API server. kubeadm generates the CA and
# the static pod manifests for apiserver/etcd/scheduler/controller-manager, and
# until it has run there is no listener on 6443 — the kubelet crash-loops, and
# kubectl reports a refused connection. On a real cluster that is a deliberate,
# operator-run step. On a throwaway node it is boilerplate, so this module makes
# it a unit you can switch on.
#
# Opt-in by design: `kubeadm init` writes a CA and cluster state, which is not
# something a module should do behind your back on a machine that might already
# be joined to something.
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
  options.services.k8sCluster.bootstrap = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Run `kubeadm init` once, on first boot of a control-plane node.

        Guarded by the existence of `/etc/kubernetes/admin.conf`, so it is a
        no-op on every subsequent boot. To start over, `kubeadm reset` and
        reboot.
      '';
    };

    skipPhases = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Phases passed to `kubeadm init --skip-phases`.";
      example = [ "addon/kube-proxy" ];
    };

    extraFlags = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Additional flags appended to the `kubeadm init` invocation.";
      example = [ "--upload-certs" ];
    };
  };

  config = lib.mkIf cfg.bootstrap.enable {
    assertions = [
      {
        assertion = cfg.kubeadm.enable;
        message = ''
          services.k8sCluster.bootstrap.enable requires services.k8sCluster.kubeadm.enable,
          which provides the kubeadm CLI and the configuration document at
          ${cfg.kubeadm.configPath}.
        '';
      }
    ];

    systemd.services.kubeadm-init = {
      description = "kubeadm init (one-shot control plane bootstrap)";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
      ]
      ++ lib.optional cfg.containerRuntime.enable "containerd.service";
      requires = lib.optional cfg.containerRuntime.enable "containerd.service";

      # kubeadm's preflight checks look for these on PATH, then it drives the
      # kubelet through systemctl once the manifests are in place.
      #
      # `cfg.package` is not optional here: preflight shells out to
      # `kubelet --version` to enforce the version skew policy, and a systemd
      # unit does not inherit the system profile's PATH. Without it kubeadm
      # aborts with "kubelet not found in system path".
      path = [
        cfg.package
        config.systemd.package
      ]
      ++ (with pkgs; [
        cri-tools
        conntrack-tools
        ethtool
        iproute2
        iptables
        socat
        util-linux
      ]);

      # `kubeadm init` refuses to run against an existing control plane, so the
      # admin kubeconfig it writes doubles as the "already bootstrapped" marker.
      unitConfig.ConditionPathExists = "!/etc/kubernetes/admin.conf";

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.concatStringsSep " " (
          [
            "${cfg.package}/bin/kubeadm"
            "init"
            "--config"
            cfg.kubeadm.configPath
          ]
          ++ lib.optional (
            cfg.bootstrap.skipPhases != [ ]
          ) "--skip-phases=${lib.concatStringsSep "," cfg.bootstrap.skipPhases}"
          ++ cfg.bootstrap.extraFlags
        );
        # Pulling control plane images on a cold node is slow; the default 90s
        # start timeout would kill the bootstrap partway through.
        TimeoutStartSec = "15min";
      };
    };
  };
}
