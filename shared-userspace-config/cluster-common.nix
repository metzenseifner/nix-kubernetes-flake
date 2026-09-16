# cross-cutting options + caller escape hatches.
#
# What lives here is what more than one consumer needs to agree on: the two
# cluster CIDRs are read by kubeadm (to write ClusterConfiguration) and by
# whichever CNI you layer on top, so neither of them may own the values.
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
  options.services.k8sCluster = {
    disableSwap = mkOption {
      type = types.bool;
      default = true;
      description = "By default, kubeadm init preflight checks fail when swap is enabled.";
    };
    serviceCIDR = mkOption {
      type = types.str;
      default = "10.96.0.0/12";
      description = "Service network CIDR.";
    };
    podCIDR = mkOption {
      type = types.str;
      default = "10.244.0.0/16";
      description = ''
        Pod network CIDR.

        Must match whatever the CNI you install is configured for. The default
        is Flannel's expected range, which is also what most quick-start
        manifests assume.
      '';
    };
    extraOpenTCPPorts = mkOption {
      type = types.listOf types.port;
      default = [ ];
      description = "Extra TCP ports to open.";
    };
    extraOpenUDPPorts = mkOption {
      type = types.listOf types.port;
      default = [ ];
      description = "Extra UDP ports to open.";
    };
  };

  config = {
    networking.firewall.allowedTCPPorts = cfg.extraOpenTCPPorts;
    networking.firewall.allowedUDPPorts = cfg.extraOpenUDPPorts;
    swapDevices = lib.mkIf cfg.disableSwap (lib.mkForce [ ]);
    zramSwap.enable = lib.mkIf cfg.disableSwap (lib.mkForce false);
  };
}
