# apps/

One ArgoCD `Application` manifest per cluster add-on. The app-of-apps root
(`../bootstrap/root-app.yaml`) syncs this directory recursively, so any
`Application` here is managed by ArgoCD automatically.

This directory is intentionally empty of apps for now (skeleton, #319). The
first consumer is the storage layer — OpenEBS zfs-localpv (#320).

Conventions:
- One file per app, named after the app (e.g. `zfs-localpv.yaml`).
- Pin chart/image versions (Renovate-managed) — no floating tags.
- Scope each app to its own namespace with `CreateNamespace=true`.
