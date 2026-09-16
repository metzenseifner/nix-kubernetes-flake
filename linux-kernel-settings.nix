# shared kernel prerequisites, opt-out-able.
{ config, lib, ... }:
let
  cfg = config.services.k8sCluster;
in
{
  options.services.k8sCluster.kernelPrereqs.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Load br_netfilter/overlay and set bridge + forwarding sysctls.";
  };

  config = lib.mkIf cfg.kernelPrereqs.enable {
    # br_netfilter must be loaded for the bridge-nf-call sysctls to exist/apply.
    boot.kernelModules = [
      "br_netfilter"
      "overlay"
    ];
    boot.kernel.sysctl = {
      "net.bridge.bridge-nf-call-iptables" = 1;
      "net.bridge.bridge-nf-call-ip6tables" = 1;

      # The two forwarding toggles are not spelled symmetrically. IPv4 has one
      # global switch; IPv6 has only per-interface `conf.<if>.forwarding`, of
      # which `all` is the pseudo-interface that fans out across the rest.
      # There is no `net.ipv6.ip_forward` — and systemd-sysctl only *warns*
      # about a key the kernel does not have, so writing one is a silent no-op
      # rather than a boot failure. ./nodes/*.test.nix reads these back out of
      # the running kernel for exactly that reason.
      "net.ipv4.ip_forward" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
    };
  };
}
