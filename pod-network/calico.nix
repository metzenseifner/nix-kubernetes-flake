# Calico: the datapath that actually enforces NetworkPolicy.
#
# This is the reason to reach past Flannel. Flannel does not reject
# `NetworkPolicy` objects, it ignores them — `kubectl apply` succeeds, the
# object is stored, and nothing enforces it. Calico ships a policy engine
# (Felix) alongside its datapath, so the same object starts dropping packets.
#
#   calico = datapath(encapsulation) ⊕ policy
#
# Encapsulation is an option because the two choices differ in how hard they
# are to firewall, not just in how they perform:
#
#   vxlan  UDP 4789 — an ordinary port a stateful firewall can reason about.
#          This is the default here for exactly that reason.
#
#   ipip   IP protocol 4. Not TCP, not UDP, and therefore not expressible in
#          `networking.firewall.allowedTCPPorts` or its UDP twin — it needs a
#          raw iptables rule, which this module adds via `extraCommands`. That
#          escape hatch is iptables-only, so a host that has switched on
#          `networking.nftables.enable` must open protocol 4 itself.
#          ./calico.test.nix builds an actual IPIP tunnel between two nodes
#          and pings through it, because a rule added this way is invisible to
#          anything that only reads options.
#
# Upstream's manifest ships `bird` + IPIP. The substitutions below move it to
# VXLAN when asked, which is the same edit Calico's own docs describe, and
# uncomment the pod CIDR in both cases.
#
# Plain English: Calico, with the pod CIDR wired to match kubeadm's, and a
# choice of how packets get wrapped between nodes.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.services.k8sCluster;
  calicoCfg = cfg.podNetwork.calico;
  selected = cfg.podNetwork.datapath == "calico";

  version = "v3.32.2";

  upstreamManifest = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/projectcalico/calico/${version}/manifests/calico.yaml";
    hash = "sha256-qMgooGqHximiguu8QkiVt386AwJRmT5B6kAKdDZ1uwI=";
  };

  # YAML anchors are written as double-quoted strings with explicit \n, never
  # as the lines of an indented string. An `''` string strips the common
  # leading whitespace off its lines, which silently reindents the anchor —
  # and a YAML anchor that has lost four spaces either fails to match or,
  # worse, matches the wrong block. escapeShellArg then hands each one to
  # `substitute` intact, newlines and all.
  substitutions =
    [
      # Upstream ships the pool CIDR commented out, falling back to Calico's
      # own 192.168.0.0/16 — which is not what kubeadm told the
      # controller-manager. Uncommenting it is the documented way to pin the
      # pool, and `--replace-fail` turns a future upstream reformat into a
      # build error rather than a cluster allocating pod IPs from a range
      # nothing routes.
      {
        from = "            # - name: CALICO_IPV4POOL_CIDR\n            #   value: \"192.168.0.0/16\"";
        to = "            - name: CALICO_IPV4POOL_CIDR\n              value: \"${cfg.podCIDR}\"";
      }
    ]
    ++ lib.optionals (calicoCfg.encapsulation == "vxlan") [
      # BGP carries routes for the IPIP datapath; a VXLAN-only install needs no
      # route distribution protocol at all, so upstream's own VXLAN
      # instructions turn the backend off rather than leaving bird idle.
      {
        from = "calico_backend: \"bird\"";
        to = "calico_backend: \"vxlan\"";
      }
      {
        from = "            - name: CALICO_IPV4POOL_IPIP\n              value: \"Always\"";
        to = "            - name: CALICO_IPV4POOL_IPIP\n              value: \"Never\"";
      }
      {
        from = "            - name: CALICO_IPV4POOL_VXLAN\n              value: \"Never\"";
        to = "            - name: CALICO_IPV4POOL_VXLAN\n              value: \"Always\"";
      }
    ];

  manifest =
    pkgs.runCommand "calico-${version}-${calicoCfg.encapsulation}.yaml" { preferLocalBuild = true; }
      ''
        substitute ${upstreamManifest} "$out" ${
          lib.concatMapStringsSep " " (
            s: "--replace-fail ${lib.escapeShellArg s.from} ${lib.escapeShellArg s.to}"
          ) substitutions
        }
      '';
in
{
  options.services.k8sCluster.podNetwork.calico = {
    encapsulation = mkOption {
      type = types.enum [
        "vxlan"
        "ipip"
      ];
      default = "vxlan";
      description = ''
        How Calico wraps pod traffic between nodes.

        `vxlan` rides UDP {option}`…calico.vxlanPort` and needs no BGP, which
        makes it the one a packet filter can express in ordinary terms.

        `ipip` is upstream's manifest default and uses IP protocol 4 plus BGP
        on {option}`…calico.bgpPort`. Protocol 4 is neither TCP nor UDP, so
        opening it needs the raw iptables rule this module adds — see the note
        at the top of ./calico.nix before using it on an nftables host.
      '';
    };

    vxlanPort = mkOption {
      type = types.port;
      default = 4789;
      description = ''
        UDP port for Calico's VXLAN datapath.

        Unlike Flannel, Calico uses the kernel's standard VXLAN port. The two
        therefore cannot be told apart by port alone on a host that has run
        both — worth knowing when reading a firewall.
      '';
    };

    bgpPort = mkOption {
      type = types.port;
      default = 179;
      description = "TCP port for BGP route distribution, used by the `ipip` datapath.";
    };

    manifest = mkOption {
      type = types.path;
      default = manifest;
      defaultText = lib.literalExpression "the pinned upstream calico.yaml, with podCIDR and encapsulation substituted";
      description = ''
        The manifest to apply. Override to vendor your own Calico
        installation — Typha, eBPF dataplane, a different IPAM — without
        patching this module.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open the ports this node's Calico datapath needs.";
    };
  };

  config = lib.mkIf selected (lib.mkMerge [
    {
      services.k8sCluster.podNetwork.install.manifests = [ calicoCfg.manifest ];
    }

    (lib.mkIf (calicoCfg.openFirewall && calicoCfg.encapsulation == "vxlan") {
      networking.firewall.allowedUDPPorts = [ calicoCfg.vxlanPort ];
    })

    (lib.mkIf (calicoCfg.openFirewall && calicoCfg.encapsulation == "ipip") {
      networking.firewall.allowedTCPPorts = [ calicoCfg.bgpPort ];

      # IPIP is IP protocol 4 — it has no port, so there is no
      # `allowedIPProtocols` for it to go in. `nixos-fw` is the iptables
      # backend's chain; on an nftables host this does nothing and protocol 4
      # has to be opened by hand.
      networking.firewall.extraCommands = ''
        iptables -A nixos-fw -p 4 -j nixos-fw-accept
      '';
    })
  ]);
}
