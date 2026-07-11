# apps/

One ArgoCD `Application` manifest per cluster add-on. The app-of-apps root
(`../bootstrap/root-app.yaml`) syncs this directory recursively, so any
`Application` here is managed by ArgoCD automatically.

Current apps:
- `guestbook.yaml` — upstream example proving the GitOps loop (#319); retire
  once real add-ons are established.
- `zfs-localpv.yaml` — OpenEBS ZFS-LocalPV CSI over the existing pool (#320).
- `storage-classes.yaml` — StorageClass + VolumeSnapshotClass from
  `../manifests/storage/` (#320).

Conventions:
- One file per app, named after the app (e.g. `zfs-localpv.yaml`).
- Pin chart/image versions (Renovate-managed) — no floating tags.
- Scope each app to its own namespace with `CreateNamespace=true`.
