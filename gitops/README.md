# GitOps (app-of-apps)

ArgoCD (`argocd_enabled = true`, #319) reconciles cluster add-ons from this
directory, so everything above etcd rebuilds from Git (ADR-0018).

## Layout

```
gitops/
├── bootstrap/
│   └── root-app.yaml     # the app-of-apps root Application (points at gitops/apps/)
└── apps/                 # one ArgoCD Application manifest per add-on (managed by root)
```

## How it works

`bootstrap/root-app.yaml` is a single ArgoCD `Application` that syncs the
`gitops/apps/` directory (`directory.recurse: true`). Every `Application`
manifest dropped into `gitops/apps/` is then managed by ArgoCD automatically —
adding an add-on is a PR, not a cluster operation.

## Bootstrap (one-time, after this skeleton is on `main`)

```bash
kubectl apply -f gitops/bootstrap/root-app.yaml
```

`root-app.yaml` targets `main`, so child apps appear once merged. ArgoCD reads
this **public** repo anonymously — no repository credentials are configured.

## Adding an app

Drop an ArgoCD `Application` manifest into `gitops/apps/` and open a PR. The
first real consumer is the storage layer (OpenEBS zfs-localpv, #320).

## Relationship to Terraform

Terraform installs ArgoCD itself (the Helm release) and can seed a bootstrap
app; ArgoCD then owns everything declared here. Keep infrastructure that must
exist *before* ArgoCD (the cluster, CNI, ArgoCD's own Helm release) in
Terraform; put workloads and add-ons here.
