# The distribution pin: one derivation, every Kubernetes binary.
#
# kubeadm, kubectl and kubelet are three faces of a single upstream release, so
# they are pinned once here rather than once per tool module. Every module that
# needs a Kubernetes binary reads `cfg.package`; overriding this option moves
# the whole node at once and, when the nodes of a cluster share a pin, keeps
# them inside the supported version skew across a flake update.
#
# Plain English: this is the single knob that says "which Kubernetes".
{
  pkgs,
  lib,
  ...
}:
{
  options.services.k8sCluster.package = lib.mkOption {
    type = lib.types.package;
    default = pkgs.kubernetes;
    defaultText = lib.literalExpression "pkgs.kubernetes";
    description = ''
      Single source for kubeadm/kubelet/kubectl; pin to control version skew.

      `pkgs.kubernetes` is one derivation carrying every binary, so the tool
      modules under ../utilities and the unit modules under ../services all
      place *this same store path* on PATH. Listing it from several modules
      costs nothing — it deduplicates to one entry in the system profile.
    '';
  };
}
