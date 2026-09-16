# CLI Utilities

Operator-facing commands: things a human types. One module per tool, each
owning both the binary and the configuration that tool cannot work without.

- `kubeadm.nix` — cluster lifecycle CLI + the rendered
  `/etc/kubernetes/kubeadm-config.yaml` it consumes
- `kubectl.nix` — API client + the `KUBECONFIG` pointing at kubeadm's `admin.conf`
- `etcdctl.nix` — opt-in break-glass access to the key-value store

Not here:

- **kubelet** is not a utility. It is a long-running node agent supervised by
  systemd, so it lives in `../services/kubelet.nix`.
- **crictl** ships with `../services/container-runtime.nix`, which also writes
  the `/etc/crictl.yaml` that tells it which socket to talk to. The tool and its
  configuration stay together.

All three Kubernetes binaries come from the same derivation, pinned once at
`services.k8sCluster.package` (see `../shared-userspace-config/kubernetes-distribution.nix`).
Splitting them into separate modules buys per-tool configuration ownership and
enable flags — not separate closures.
