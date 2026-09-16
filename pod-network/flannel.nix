# Flannel: the pod network that makes a kubeadm node go Ready.
#
# A fresh kubeadm node reports NotReady with "container runtime network not
# ready: cni plugin not initialized", because vanilla Kubernetes ships no CNI —
# it is the one component the cluster cannot supply for itself. Flannel is the
# smallest thing that closes that gap: a DaemonSet that drops a CNI config into
# /etc/cni/net.d and runs a VXLAN overlay between nodes.
#
# The manifest is pinned by hash rather than fetched at boot, so what a node
# applies is fixed at build time and does not drift with an upstream release.
# The container images it references are still pulled from ghcr.io at runtime —
# that part is outside Nix's reach.
#
# Plain English: this applies Flannel's official YAML, with the pod CIDR
# rewritten to match whatever `services.k8sCluster.podCIDR` says.
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
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Participate in a Flannel pod network.

        Set this on *every* node in the cluster. It is the host-side half —
        opening the overlay port — and is deliberately separate from
        {option}`services.k8sCluster.podNetwork.flannel.install.enable`, which
        pushes the manifest cluster-wide from a single node. A worker that
        skips this still schedules pods, but traffic to pods on other nodes
        disappears into a dropped VXLAN packet.
      '';
    };

    install.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Apply the Flannel manifest to the cluster from this node.

        Enable on exactly one control-plane node: it is a cluster-wide write
        needing the admin credentials only a control plane has. Every other
        node receives Flannel through the DaemonSet.
      '';
    };

    manifest = mkOption {
      type = types.path;
      default = manifest;
      defaultText = lib.literalExpression "the pinned upstream kube-flannel.yml, with podCIDR substituted";
      description = ''
        The manifest to apply. Override to vendor your own Flannel
        configuration — a different backend, say — without patching this module.
      '';
    };

    kubeconfig = mkOption {
      type = types.str;
      default = "/etc/kubernetes/admin.conf";
      description = "Credentials used to apply the manifest.";
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
        pods on the same node talk fine and cross-node traffic silently blackholes.
      '';
    };

    apiReadyTimeout = mkOption {
      type = types.int;
      default = 300;
      description = ''
        Seconds to wait for the API server before giving up.

        On a reboot the bootstrap unit is skipped and the control plane returns
        as static pods, which the kubelet takes tens of seconds to bring up.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (flannelCfg.enable && flannelCfg.openFirewall) {
      networking.firewall.allowedUDPPorts = [ flannelCfg.vxlanPort ];
    })

    (lib.mkIf flannelCfg.install.enable {
      assertions = [
        {
          assertion = flannelCfg.enable;
          message = ''
            services.k8sCluster.podNetwork.flannel.install.enable requires
            services.k8sCluster.podNetwork.flannel.enable on the same node: the
            node applying the manifest also runs a Flannel pod and needs the
            overlay port open like any other.
          '';
        }
      ];

      systemd.services.flannel-cni = {
        description = "Apply the Flannel CNI manifest";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        # Ordering against a unit that does not exist is a no-op in systemd, so
        # this stays correct whether or not the bootstrap module is in play.
        after = [
          "network-online.target"
          "kubeadm-init.service"
        ];

        path = [ cfg.package ];

        environment.KUBECONFIG = flannelCfg.kubeconfig;

        # `kubectl apply` is idempotent, so running this every boot costs one
        # no-op round trip and repairs a cluster whose CNI was deleted by hand.
        script = ''
          deadline=$(( SECONDS + ${toString flannelCfg.apiReadyTimeout} ))
          until kubectl get --raw /readyz >/dev/null 2>&1; do
            if (( SECONDS >= deadline )); then
              echo "flannel-cni: API server not ready after ${toString flannelCfg.apiReadyTimeout}s" >&2
              exit 1
            fi
            sleep 2
          done

          kubectl apply -f ${flannelCfg.manifest}
        '';

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          TimeoutStartSec = toString (flannelCfg.apiReadyTimeout + 120);
        };
      };
    })
  ];
}
