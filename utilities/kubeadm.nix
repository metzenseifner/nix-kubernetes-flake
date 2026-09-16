# kubeadm: the cluster lifecycle CLI, plus the config document it consumes.
#
# kubeadm reads a multi-document YAML stream, one document per API kind. This
# module renders that stream from typed options and installs it at the
# conventional path, so `kubeadm init --config /etc/kubernetes/kubeadm-config.yaml`
# is a copy-pasteable command rather than a store path you have to look up.
#
# Algebraically: kubeadmConfig = render ∘ (initConfiguration ⊕ clusterConfiguration),
# where ⊕ is document concatenation and the module's own defaults are the
# identity element the caller overrides.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.services.k8sCluster;

  yaml = pkgs.formats.yaml { };

  # `pkgs.formats.yaml.generate` emits exactly one document, but kubeadm wants a
  # stream. Concatenate the rendered documents with the `---` separator, keeping
  # each one individually type-checked on the way in.
  renderDocumentStream =
    name: documents:
    let
      files = map (yaml.generate "kubeadm-document.yaml") documents;
      appendCommands = lib.concatMapStringsSep ''

        printf -- '---\n' >> "$out"
      '' (file: ''cat ${file} >> "$out"'') files;
    in
    pkgs.runCommand name { preferLocalBuild = true; } ''
      : > "$out"
      ${appendCommands}
    '';

  # Defaults the caller may override field-by-field via the freeform options.
  clusterConfiguration = lib.recursiveUpdate {
    apiVersion = "kubeadm.k8s.io/v1beta4";
    kind = "ClusterConfiguration";
    # Pinning this stops kubeadm reaching out to dl.k8s.io during `init`, which
    # both removes a boot-time network dependency and guarantees the control
    # plane images match the binaries this node actually runs.
    kubernetesVersion = "v${cfg.package.version}";
    networking = {
      serviceSubnet = cfg.serviceCIDR;
      podSubnet = cfg.podCIDR;
    };
  } cfg.kubeadm.clusterConfiguration;

  initConfiguration = lib.recursiveUpdate {
    apiVersion = "kubeadm.k8s.io/v1beta4";
    kind = "InitConfiguration";
  } cfg.kubeadm.initConfiguration;

  # kubeadm's preflight checks look for these by name on PATH and abort if any
  # is missing. The kubelet unit carries its own copy in `path`, because a
  # systemd unit does not inherit the interactive login PATH — but an operator
  # running `kubeadm init`/`join` from a shell needs them here.
  preflightTools = with pkgs; [
    conntrack-tools # conntrack
    ebtables
    ethtool
    iproute2 # ip, tc
    iptables
    socat
    util-linux # mount, nsenter
  ];
in
{
  options.services.k8sCluster.kubeadm = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Install the kubeadm CLI and its configuration document.";
    };

    clusterConfiguration = mkOption {
      type = yaml.type;
      default = { };
      description = ''
        Fields merged into the generated `ClusterConfiguration` document.

        Merged recursively over this module's defaults, so you override only
        the leaves you care about and inherit the rest.
      '';
      example = lib.literalExpression ''
        {
          apiServer.extraArgs = [ { name = "enable-admission-plugins"; value = "NodeRestriction"; } ];
          etcd.local.dataDir = "/var/lib/etcd";
        }
      '';
    };

    initConfiguration = mkOption {
      type = yaml.type;
      default = { };
      description = ''
        Fields merged into the generated `InitConfiguration` document.

        This document describes *this node's* participation in `kubeadm init`
        (its advertise address, CRI socket, node name), as opposed to
        {option}`services.k8sCluster.kubeadm.clusterConfiguration`, which
        describes the cluster every node shares.
      '';
      example = lib.literalExpression ''
        { localAPIEndpoint.advertiseAddress = "10.0.1.10"; }
      '';
    };

    configPath = mkOption {
      type = types.str;
      default = "/etc/kubernetes/kubeadm-config.yaml";
      readOnly = true;
      description = "Where the rendered kubeadm configuration lands on the node.";
    };
  };

  config = lib.mkIf cfg.kubeadm.enable {
    environment.systemPackages = [ cfg.package ] ++ preflightTools;

    environment.etc."kubernetes/kubeadm-config.yaml".source =
      renderDocumentStream "kubeadm-config.yaml"
        [
          initConfiguration
          clusterConfiguration
        ];
  };
}
