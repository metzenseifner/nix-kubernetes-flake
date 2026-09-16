# kubectl: the API client, and the one piece of state it cannot guess.
#
# kubectl with no kubeconfig does not fail loudly — it silently falls back to
# http://localhost:8080, the long-removed insecure API port, and reports
# "connection to the server localhost:8080 was refused". Pointing KUBECONFIG at
# the credentials kubeadm wrote is therefore part of installing the tool, not a
# separate concern.
{
  config,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.services.k8sCluster;
in
{
  options.services.k8sCluster.kubectl = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Install the kubectl CLI.";
    };

    defaultKubeconfig = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Value for the system-wide `KUBECONFIG` environment variable, or `null`
        to leave it unset and let kubectl use `~/.kube/config`.

        The node role modules set this: a control plane points it at the
        `admin.conf` that `kubeadm init` writes. Note the file is mode 0600 and
        owned by root, so only root picks up working credentials from it; other
        users still need their own `~/.kube/config`.
      '';
      example = "/etc/kubernetes/admin.conf";
    };
  };

  config = lib.mkIf cfg.kubectl.enable {
    environment.systemPackages = [ cfg.package ];

    environment.variables.KUBECONFIG = lib.mkIf (
      cfg.kubectl.defaultKubeconfig != null
    ) cfg.kubectl.defaultKubeconfig;
  };
}
