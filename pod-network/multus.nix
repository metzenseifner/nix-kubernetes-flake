# Multus: not a pod network, a way of having more than one.
#
#   multus = delegate(datapath) ⊕ extra interfaces
#
# This is why Multus is not in the `datapath` enum. It moves no packets of its
# own and allocates no pod addresses. What it does is sit in front of the real
# CNI as a meta-plugin: eth0 in the pod is delegated to whatever datapath is
# underneath, exactly as before, and any `NetworkAttachmentDefinition` the pod
# annotates itself with gets added alongside as net1, net2, and so on.
#
# So "Multus instead of Flannel" is not a configuration that exists. "Multus
# over Flannel" and "Multus over Calico" are, and both need a datapath set —
# which the assertion below enforces rather than leaving you to discover from
# pods that never get an address.
#
# Because it has no datapath, it opens no ports. Whatever the secondary
# networks need is theirs to declare; Multus itself only rewrites CNI config.
#
# Plain English: turn this on to give pods extra network interfaces, on top of
# whichever pod network you already chose.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.services.k8sCluster;
  multusCfg = cfg.podNetwork.multus;

  version = "v4.3.1";

  upstreamManifest = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/${version}/deployments/multus-daemonset.yml";
    hash = "sha256-vWGNI6lXcpBx7IHc73QP/AOlkWECE3r6YRTTGl0YeEM=";
  };

  # Upstream's manifest references `multus-cni:snapshot` — a floating tag that
  # is rebuilt from master. Pinning the file by hash while leaving that in
  # place would buy nothing: the YAML would be reproducible and the thing it
  # actually runs would not. Substituted to the release this module pins.
  manifest = pkgs.runCommand "multus-${version}.yaml" { preferLocalBuild = true; } ''
    substitute ${upstreamManifest} "$out" \
      --replace-fail \
        'ghcr.io/k8snetworkplumbingwg/multus-cni:snapshot' \
        'ghcr.io/k8snetworkplumbingwg/multus-cni:${version}'
  '';
in
{
  options.services.k8sCluster.podNetwork.multus = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Layer Multus over the selected datapath, so pods can hold more than one
        network interface.

        Requires {option}`services.k8sCluster.podNetwork.datapath` to be set:
        Multus delegates the pod's primary interface to that CNI and cannot
        stand in for it.
      '';
    };

    manifest = mkOption {
      type = types.path;
      default = manifest;
      defaultText = lib.literalExpression "the pinned upstream multus-daemonset.yml, with the image tag pinned to match";
      description = ''
        The manifest to apply. Override to vendor your own Multus
        installation — the thick plugin, a different delegate config — without
        patching this module.
      '';
    };
  };

  config = lib.mkIf multusCfg.enable {
    assertions = [
      {
        assertion = cfg.podNetwork.datapath != null;
        message = ''
          services.k8sCluster.podNetwork.multus.enable requires
          services.k8sCluster.podNetwork.datapath to name a CNI.

          Multus is a meta-plugin: it delegates a pod's primary interface to a
          real pod network and adds further interfaces beside it. With no
          datapath underneath there is nothing to delegate to, and pods would
          never get an address at all.
        '';
      }
    ];

    # mkAfter, so this lands after the datapath's own manifest no matter what
    # order the modules merge in. Multus reads the CNI config the datapath
    # wrote in order to build its delegate list; applied first, it has nothing
    # to find.
    services.k8sCluster.podNetwork.install.manifests = lib.mkAfter [ multusCfg.manifest ];
  };
}
