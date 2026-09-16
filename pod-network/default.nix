# ═══════════════════════════════════════════════════════════════════════
#  Pod network — the one component a vanilla cluster cannot supply itself
#
#    podNetwork = datapath ⊕ attachments
#
#      datapath    ∈ { flannel, calico, weave } ∪ { null }
#      attachments ⊆ { multus }
#
#  A fresh kubeadm node reports NotReady with "container runtime network
#  not ready: cni plugin not initialized", because Kubernetes ships no
#  CNI — it is the one piece the cluster cannot supply for itself. So
#  picking one is mandatory, and picking *two* is incoherent: two
#  datapaths both claiming /etc/cni/net.d and both handing out pod
#  addresses is a cluster that half-works in ways that look like packet
#  loss. Hence an enum rather than a set of independent `enable` flags —
#  the dispatch is total and the illegal state cannot be written down.
#
#  Multus is deliberately *not* in that enum. It is a meta-plugin: it
#  moves no packets of its own, it lets a pod hold several interfaces and
#  delegates the primary one to whatever real CNI sits underneath.
#  Listing it beside Flannel would make "Multus over Calico" — the only
#  way Multus is ever actually run — impossible to express.
#
#  The split every datapath inherits, and why it is two options:
#
#    datapath   the host-side half. Every node in the cluster sets it.
#               Opens the ports that datapath needs, and nothing else.
#
#    install    the cluster-side half. Exactly one control-plane node
#               sets it, because applying a manifest is a cluster-wide
#               write that needs admin credentials. Every other node
#               receives the CNI through the DaemonSet it creates.
#
#  In plain English: say which pod network you want on every node, and
#  say "install it" on one of them.
# ═══════════════════════════════════════════════════════════════════════
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.services.k8sCluster;
in
{
  imports = [
    ./manifest-installer.nix

    # Datapaths. Each owns its own manifest, its own ports and its own
    # answer to "how does this one want the pod CIDR spelled" — which is
    # different enough per plugin that a shared abstraction would cost
    # more than the duplication saves.
    ./flannel.nix
    ./calico.nix
    ./weave.nix

    # Attachment: composes over a datapath rather than replacing one.
    ./multus.nix
  ];

  options.services.k8sCluster.podNetwork.datapath = mkOption {
    type = types.nullOr (types.enum [
      "flannel"
      "calico"
      "weave"
    ]);
    default = null;
    example = "calico";
    description = ''
      Which pod network carries traffic between nodes. Set this on *every*
      node in the cluster; it is the host-side half, and a node that skips
      it still schedules pods but drops everything bound for another node.

      `null` means this flake installs no CNI and the cluster stays
      NotReady until something else provides one.

      - `flannel` — VXLAN overlay, no network policy. The smallest thing
        that makes a node Ready, and what most quick-start guides assume.
      - `calico` — enforces `NetworkPolicy`, which Flannel ignores
        entirely. Defaults to a VXLAN datapath here; see
        {option}`services.k8sCluster.podNetwork.calico.encapsulation`.
      - `weave` — mesh overlay with encryption available. Upstream is
        archived; see ./weave.nix before choosing it.

      Not a place for Multus: that is
      {option}`services.k8sCluster.podNetwork.multus.enable`, which layers
      over whichever datapath is chosen here rather than replacing it.
    '';
  };

  config = {
    assertions = [
      {
        assertion = cfg.podNetwork.install.enable -> cfg.podNetwork.datapath != null;
        message = ''
          services.k8sCluster.podNetwork.install.enable is set but
          services.k8sCluster.podNetwork.datapath is null, so there is no
          manifest to apply. Name a datapath, or turn the install off.
        '';
      }
    ];
  };
}
