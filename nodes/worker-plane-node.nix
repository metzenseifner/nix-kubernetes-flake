# worker behavior + its overridable knobs.
#
# Composition only, like its control-plane sibling: it turns on the kubelet and
# opens the ports a workload-carrying node needs, and leaves the implementing
# to ../services and ../utilities.
{ config, lib, ... }:
let
  inherit (lib)
    mkIf
    mkMerge
    mkEnableOption
    mkOption
    types
    ;
  cfg = config.services.k8sCluster;
in
{
  imports = [
    ../shared-userspace-config
    ../linux-kernel-settings.nix
    ../pod-network
    ../services
    ../utilities
  ];
  options.services.k8sCluster.worker = {
    enable = mkEnableOption "worker (kubelet) components on this node";
    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open worker/kubelet + NodePort range.";
    };
    nodePortRange = mkOption {
      type = types.submodule {
        options.from = mkOption {
          type = types.port;
          default = 30000;
        };
        options.to = mkOption {
          type = types.port;
          default = 32767;
        };
      };
      default = { };
      description = "Inclusive NodePort range to open.";
    };
  };

  config = mkIf cfg.worker.enable (mkMerge [
    {
      # Both roles may set this on a single-node cluster; `true = true` merges
      # cleanly, which a mkDefault/mkForce pair would not.
      services.k8sCluster.kubelet.enable = true;
    }

    (mkIf cfg.worker.openFirewall {
      networking.firewall.allowedTCPPorts = [
        10250
        10256 # kube-proxy healthz check
      ];
      networking.firewall.allowedTCPPortRanges = [ { inherit (cfg.worker.nodePortRange) from to; } ];
    })
  ]);
}
