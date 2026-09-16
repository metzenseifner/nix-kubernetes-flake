# etcdctl: break-glass access to the control plane's key-value store.
#
# Deliberately opt-in. With a stacked control plane, kubeadm runs etcd as a
# static pod from registry.k8s.io — the host never executes this package's
# server binary, so installing it by default only puts a second, unused etcd on
# PATH where it can be mistaken for the one actually holding cluster state.
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
  options.services.k8sCluster.etcdctl = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Install etcd's client tooling for inspecting cluster state directly.

        Only meaningful on a control-plane node. Talking to the stacked etcd
        needs the certificates kubeadm generated, e.g.

        ```
        etcdctl --endpoints=https://127.0.0.1:2379 \
          --cacert=/etc/kubernetes/pki/etcd/ca.crt \
          --cert=/etc/kubernetes/pki/etcd/server.crt \
          --key=/etc/kubernetes/pki/etcd/server.key member list
        ```
      '';
    };

    package = mkOption {
      type = types.package;
      default = pkgs.etcd;
      defaultText = lib.literalExpression "pkgs.etcd";
      description = ''
        Package providing `etcdctl`.

        Separate from {option}`services.k8sCluster.package` on purpose: etcd
        has its own release cadence and is not part of the Kubernetes version
        skew policy.
      '';
    };
  };

  config = lib.mkIf cfg.etcdctl.enable {
    environment.systemPackages = [ cfg.etcdctl.package ];
  };
}
