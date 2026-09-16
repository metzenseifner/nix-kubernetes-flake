# # Control Plane Node Nixos Module {#module-k8s-control-plane-node}
#
# This top-level module may be consumed directly by a nixosConfiguration to make
# that configuration a Control Plane Node. A control plane has the following
# requirements:
# - kubelet service to start up the containers
# - container runtime service (with cri) for the various control plane processes
#
# - api service
# - etcd key-value store
# - scheduler service
# - controller service
# ## Open Ports {#module-k8s-control-plane-node-open-ports}
# - 2379
# - 2380 etcd client/peer comm
# - 10259
# - 10257 scheduler / controller-manager
# - 10250 kubelet
#
# This module is composition only: it decides *what a control plane is* by
# switching on capabilities the ../services and ../utilities modules implement.
# It declares no systemd units and installs no packages of its own.
{ config, lib, ... }:
let
  inherit (lib)
    mkIf
    mkMerge
    mkDefault
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
  options.services.k8sCluster.controlPlane = {
    enable = mkEnableOption "control-plane components on this node";
    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open control-plane TCP ports.";
    };
    apiServerPort = mkOption {
      type = types.port;
      default = 6443;
      description = "API server listen/reachable port.";
    };
  };

  config = mkIf cfg.controlPlane.enable (mkMerge [
    {
      # A control plane runs its own kubelet: the apiserver, scheduler,
      # controller-manager and etcd are static pods it supervises.
      services.k8sCluster.kubelet.enable = true;

      # Without this kubectl silently targets localhost:8080 and reports a
      # refused connection. admin.conf is what `kubeadm init` writes.
      services.k8sCluster.kubectl.defaultKubeconfig = mkDefault "/etc/kubernetes/admin.conf";
    }

    (mkIf cfg.controlPlane.openFirewall {
      # This list CONCATENATES with the worker's list when both roles are on.
      networking.firewall.allowedTCPPorts = [
        cfg.controlPlane.apiServerPort # overridable API port (default 6443)
        2379
        2380 # etcd client / peer
        10259
        10257 # scheduler / controller-manager
        10250 # kubelet (control-plane runs one too)
      ];
    })
  ]);
}
