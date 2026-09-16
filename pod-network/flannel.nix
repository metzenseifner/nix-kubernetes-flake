# Flannel: the smallest datapath that makes a kubeadm node go Ready.
#
# A DaemonSet that drops a CNI config into /etc/cni/net.d and runs a VXLAN
# overlay between nodes. No network policy — Flannel ignores `NetworkPolicy`
# objects rather than rejecting them, so a cluster that relies on them is
# silently unprotected. Choose ../pod-network calico if that matters.
#
# The manifest is pinned by hash rather than fetched at boot, so what a node
# applies is fixed at build time and does not drift with an upstream release.
# The container images it references are still pulled from ghcr.io at runtime —
# that part is outside Nix's reach.
#
# Plain English: applies Flannel's official YAML, with the pod CIDR rewritten
# to match whatever `services.k8sCluster.podCIDR` says.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.services.k8sCluster;
  flannelCfg = cfg.podNetwork.flannel;
  selected = cfg.podNetwork.datapath == "flannel";

  version = "v0.28.9";

  upstreamManifest = pkgs.fetchurl {
    url = "https://github.com/flannel-io/flannel/releases/download/${version}/kube-flannel.yml";
    hash = "sha256-HAahWncQCcJjvbH1HJKK9G92Bv6WnzljZSFnk41Taqo=";
  };

  # Flannel's net-conf.json hardcodes a pod CIDR. It has to agree with what
  # kubeadm handed the controller-manager, or nodes get addresses from a range
  # the overlay does not route. `--replace-fail` turns a silent upstream rename
  # into a build error instead of a cluster that half-works.
  manifest = pkgs.runCommand "kube-flannel-${version}.yaml" { preferLocalBuild = true; } ''
    substitute ${upstreamManifest} "$out" \
      --replace-fail '"Network": "10.244.0.0/16"' '"Network": "${cfg.podCIDR}"'
  '';
in
{
  options.services.k8sCluster.podNetwork.flannel = {
    manifest = mkOption {
      type = types.path;
      default = manifest;
      defaultText = lib.literalExpression "the pinned upstream kube-flannel.yml, with podCIDR substituted";
      description = ''
        The manifest to apply. Override to vendor your own Flannel
        configuration — a different backend, say — without patching this module.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open the VXLAN port so nodes can reach each other's overlay.";
    };

    vxlanPort = mkOption {
      type = types.port;
      default = 8472;
      description = ''
        UDP port Flannel's default VXLAN backend uses.

        Note this is Flannel's own default, not the Linux kernel's 4789 — they
        differ, and a firewall opened for the wrong one produces a cluster where
        pods on the same node talk fine and cross-node traffic silently
        blackholes. ../cross-node-reachability.test.nix asserts both halves of
        that.
      '';
    };
  };

  config = lib.mkIf selected (lib.mkMerge [
    {
      services.k8sCluster.podNetwork.install.manifests = [ flannelCfg.manifest ];
    }

    (lib.mkIf flannelCfg.openFirewall {
      networking.firewall.allowedUDPPorts = [ flannelCfg.vxlanPort ];
    })
  ]);
}
