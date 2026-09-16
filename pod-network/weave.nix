# Weave Net: mesh overlay, with a maintenance caveat worth reading first.
#
# Upstream `weaveworks/weave` is ARCHIVED. Weaveworks wound down in early 2024;
# the last release there is v2.8.1 from January 2021, and the repository is
# read-only. What this module pins instead is `rajch/weave`, a fork that is
# still receiving releases (v2.9.0, December 2024) and has moved its images to
# the iptables-nft backend, which is what a current NixOS host uses.
#
# That is a real dependency risk rather than a footnote: a fork maintained by
# one person is a thinner supply chain than Flannel's or Calico's. Weave is
# here because it was asked for and it is genuinely different — a full mesh
# with optional encryption, rather than a point-to-point overlay — but for
# anything long-lived, ./flannel.nix or ./calico.nix is the safer pick.
#
#   weave = mesh(control ⊕ data) ⊕ policy
#
# Unlike Flannel, Weave does enforce NetworkPolicy. Unlike Calico, it has no
# BGP and no choice of encapsulation: one mesh, two ports.
#
# Plain English: Weave Net from the maintained fork, with the pod CIDR
# injected, since upstream's manifest does not set one at all.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.services.k8sCluster;
  weaveCfg = cfg.podNetwork.weave;
  selected = cfg.podNetwork.datapath == "weave";

  version = "v2.9.0";

  upstreamManifest = pkgs.fetchurl {
    url = "https://github.com/rajch/weave/releases/download/${version}/weave-daemonset-k8s-1.11.yaml";
    hash = "sha256-KKJMjEX2TwnkCEKwhoCkOPfRgnTR6p5SywnWkWkHOak=";
  };

  # Weave's manifest carries no IPALLOC_RANGE at all — the hosted installer URL
  # used to append it as a query parameter, which is not something a pinned
  # file can do. So the env var is *inserted*, not substituted: without it
  # Weave allocates from its own 10.32.0.0/12 default and ignores whatever
  # kubeadm told the controller-manager.
  #
  # Anchored on CHECKPOINT_DISABLE, which appears exactly once in the file, and
  # inserted before it rather than appended, so the anchor stays a single line.
  #
  # Written as a double-quoted string with explicit \n, never as the lines of
  # an indented string: an `''` string strips the common leading whitespace off
  # its lines, which would quietly reindent the injected YAML and put the env
  # entry at the wrong nesting depth.
  substitutions = [
    {
      from = "                - name: CHECKPOINT_DISABLE";
      to =
        "                - name: IPALLOC_RANGE\n"
        + "                  value: \"${cfg.podCIDR}\"\n"
        + "                - name: CHECKPOINT_DISABLE";
    }
  ];

  manifest = pkgs.runCommand "weave-net-${version}.yaml" { preferLocalBuild = true; } ''
    substitute ${upstreamManifest} "$out" ${
      lib.concatMapStringsSep " " (
        s: "--replace-fail ${lib.escapeShellArg s.from} ${lib.escapeShellArg s.to}"
      ) substitutions
    }
  '';
in
{
  options.services.k8sCluster.podNetwork.weave = {
    manifest = mkOption {
      type = types.path;
      default = manifest;
      defaultText = lib.literalExpression "the pinned rajch/weave daemonset, with IPALLOC_RANGE injected";
      description = ''
        The manifest to apply. Override to vendor your own Weave
        installation — encryption via a password secret, a different peer
        discovery — without patching this module.
      '';
    };

    controlPort = mkOption {
      type = types.port;
      default = 6783;
      description = ''
        TCP port for mesh control traffic: peer discovery and topology gossip.

        Weave also uses the *same* number on UDP for one of its data ports,
        which is why {option}`…weave.dataPorts` overlaps it. That is upstream's
        design, not a mistake here.
      '';
    };

    dataPorts = mkOption {
      type = types.listOf types.port;
      default = [
        6783
        6784
      ];
      description = ''
        UDP ports carrying pod traffic: 6783 for the sleeve datapath and 6784
        for the faster VXLAN one. Weave picks between them per peer at runtime,
        so both have to be open or connectivity degrades to whichever it can
        still reach.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open the mesh control and data ports.";
    };
  };

  config = lib.mkIf selected (lib.mkMerge [
    {
      services.k8sCluster.podNetwork.install.manifests = [ weaveCfg.manifest ];
    }

    (lib.mkIf weaveCfg.openFirewall {
      networking.firewall.allowedTCPPorts = [ weaveCfg.controlPort ];
      networking.firewall.allowedUDPPorts = weaveCfg.dataPorts;
    })
  ]);
}
