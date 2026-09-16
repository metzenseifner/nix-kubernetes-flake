# The cluster-side half of installing a pod network: wait for the API, then
# apply whatever the selected datapath (and any attachment) contributed.
#
# This is the one piece genuinely shared across every CNI — "block until
# /readyz answers, then kubectl apply" is identical whether the manifest is
# Flannel's or Calico's — so it lives here once instead of three times. What is
# *not* shared stays with each plugin: the manifest itself, its ports, and how
# it wants the pod CIDR spelled. Those differ enough per plugin that folding
# them together would cost more than the duplication saves.
#
#   install = wait(readyz) ; ⨟ { apply m | m ∈ manifests }
#
# Order is significant and is carried by the list: a datapath appends normally,
# an attachment appends with `lib.mkAfter`, so Multus can never be applied
# before the CNI it delegates to exists.
{
  config,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.services.k8sCluster;
  installCfg = cfg.podNetwork.install;
in
{
  options.services.k8sCluster.podNetwork.install = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Apply the pod network's manifests to the cluster from this node.

        Enable on exactly one control-plane node: it is a cluster-wide write
        needing the admin credentials only a control plane has. Every other
        node receives the CNI through the DaemonSet this creates, and needs
        only {option}`services.k8sCluster.podNetwork.datapath`.
      '';
    };

    manifests = mkOption {
      type = types.listOf types.path;
      default = [ ];
      description = ''
        Manifests to apply, in order.

        Contributed by the selected datapath and by any attachment rather
        than written by hand — set
        {option}`services.k8sCluster.podNetwork.datapath` instead. Appending
        here is how you add a manifest that should land alongside the CNI;
        use `lib.mkAfter` if it has to come last.
      '';
    };

    kubeconfig = mkOption {
      type = types.str;
      default = "/etc/kubernetes/admin.conf";
      description = "Credentials used to apply the manifests.";
    };

    apiReadyTimeout = mkOption {
      type = types.int;
      default = 300;
      description = ''
        Seconds to wait for the API server before giving up.

        On a reboot the bootstrap unit is skipped and the control plane comes
        back as static pods, which the kubelet takes tens of seconds to bring
        up.
      '';
    };
  };

  config = lib.mkIf installCfg.enable {
    assertions = [
      {
        assertion = installCfg.manifests != [ ];
        message = ''
          services.k8sCluster.podNetwork.install.enable is set but no manifests
          were contributed. This normally means the selected datapath has no
          manifest of its own; check services.k8sCluster.podNetwork.datapath.
        '';
      }
    ];

    systemd.services.pod-network-cni = {
      description = "Apply the ${toString cfg.podNetwork.datapath} pod network manifests";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      # Ordering against a unit that does not exist is a no-op in systemd, so
      # this stays correct whether or not the bootstrap module is in play.
      after = [
        "network-online.target"
        "kubeadm-init.service"
      ];

      path = [ cfg.package ];

      environment.KUBECONFIG = installCfg.kubeconfig;

      # `kubectl apply` is idempotent, so running this every boot costs a
      # no-op round trip per manifest and repairs a cluster whose CNI was
      # deleted by hand.
      script = ''
        deadline=$(( SECONDS + ${toString installCfg.apiReadyTimeout} ))
        until kubectl get --raw /readyz >/dev/null 2>&1; do
          if (( SECONDS >= deadline )); then
            echo "pod-network-cni: API server not ready after ${toString installCfg.apiReadyTimeout}s" >&2
            exit 1
          fi
          sleep 2
        done

        ${lib.concatMapStringsSep "\n" (m: "kubectl apply -f ${m}") installCfg.manifests}
      '';

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = toString (installCfg.apiReadyTimeout + 120);
      };
    };
  };
}
