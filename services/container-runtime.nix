# CRI runtime, opt-out-able.
#
# Also owns crictl: the client and the /etc/crictl.yaml naming its socket are
# useless apart, so they ship together rather than crictl living with the
# operator CLIs under ../utilities.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.k8sCluster;
in
{
  options.services.k8sCluster.containerRuntime = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable the containerd Container Runtime Interface (CRI) backend.";
    };
    systemdCgroup = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enforce Systemd cgroup driver matching kubelet.";
    };
    extraSettings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Arbitrary additional containerd settings passed to virtualization.containerd.settings.";
      example = lib.literalExpression ''
        {
          plugins."io.containerd.grpc.v1.cri".sandbox_image = "registry.k8s.io/pause:3.9"
        }
      '';
    };
  };

  config = lib.mkIf cfg.containerRuntime.enable {
    boot.kernelModules = [ "overlay" ];
    virtualisation.containerd = {
      enable = true;
      settings = lib.recursiveUpdate {
        plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options = {
          SystemdCgroup = cfg.containerRuntime.systemdCgroup; # Match kubelet's cgroup driver
        };
      } cfg.containerRuntime.extraSettings;
    };
    environment.systemPackages = [ pkgs.cri-tools ];
    environment.etc."crictl.yaml".text = ''
      runtime-endpoint: unix:///run/containerd/containerd.sock
    '';
  };
}
