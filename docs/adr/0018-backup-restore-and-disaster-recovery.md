# ADR-0018: Backup, Restore, and Disaster Recovery

## Status
Accepted

## Date
2026-07-09

## Context

The cluster's historical answer to every failure was a full redeploy (ADR-0012): rebuild the node, re-bootstrap, redeploy workloads. ADR-0013 removed the *need* to reinstall for upgrades, but nothing yet protects the state a redeploy cannot recreate — etcd contents, persistent volume data on the ZFS pool, and the machine secrets/OpenTofu state that make node replacement possible without a full rebuild. The 2026-07-08 strategy review concluded that for a one-operator shop, a **tested restore is the cheapest real availability win** — ahead of any multi-node quorum ([ADR-0017](0017-multi-node-topology-fabric-and-endpoint.md), Proposed; #310).

Current exposure:

- **No automated etcd backups.** The ZFS mirror gives device-level redundancy on one host; it does not protect against etcd corruption, a destructive apply, or host loss.
- **Single-provider concentration.** Compute, OpenTofu state, and any backups stored on OVH sit under one account and one region cluster; an account compromise or a regional incident takes all three at once. (State-bucket versioning exists but lives in the same blast radius.)
- **"Rebuild from Git" is currently hollow twice over**: ArgoCD exists in the repo but is disabled (`argocd_enabled = false`), and even enabled it today installs only a sample application — there is no declarative root app-of-apps or repo-credential bootstrap.
- **Not everything that looks like config is in Git**: `terraform.tfvars`/`backend.tfvars` are gitignored (they exist only as CI secrets and the operator's local files), and the Tailscale tailnet ACL/tag/OAuth configuration is hand-managed in the admin console — none of it currently survives losing the operator's laptop plus the respective SaaS account.
- **etcd snapshots contain cluster secrets** — backups must be encrypted client-side before leaving the node.
- Verified tooling facts (fact-check, 2026-07-08): `siderolabs/talos-backup` is the official etcd-backup tool (CronJob → zstd → age encryption → S3) but self-describes as minimal/experimental; it requires `machine.features.kubernetesTalosAPIAccess` with role `os:etcd:backup` (a live-appliable config patch); snapshots taken via the Talos API carry the etcd integrity hash, so restores need no `--recover-skip-hash-check`. Restore is `talosctl bootstrap --recover-from=<snapshot>` (documented single-node and 3-node sequences).
- Storage facts: OpenEBS **zfs-localpv** provisions volumes from *already-existing* zpools (mandatory `poolname` StorageClass parameter) — a direct fit for the existing mirror pool, with dynamic PVC provisioning, snapshots, clones, and quotas; volumes are node-local. **Longhorn** replicates across *nodes* (on one worker every volume is replica-1 — zero durability gain over the ZFS mirror), requires extra system extensions + privileged PSS + kubelet mounts, and its own guidance plus etcd fsync data warn against synchronous replication over high-latency links.

## Considered Options

**etcd backup tooling:**

| Option | Encryption | Maintenance | Verdict |
|---|---|---|---|
| **siderolabs/talos-backup CronJob** | age (client-side) built in | Official Sidero tool; minimal surface | **Selected** — thin wrapper over the API snapshot; drills compensate for its "experimental" label |
| Custom CronJob: `talosctl etcd snapshot` + restic | restic client-side | DIY container + talosconfig handling in-cluster | Fallback if talos-backup misbehaves; more moving parts to own |
| Velero only | Server-side at best | Backs up API objects, not raw etcd | Rejected as the *primary* — no etcd-level restore; remains a candidate add-on for PV/object backups later |
| Keep the redeploy habit | n/a | none | Rejected — the habit is what this ADR ends |

**Backup locality:**

| Option | Blast radius | Verdict |
|---|---|---|
| **OVH bucket + off-provider replica (restic, client-side encrypted)** | Provider/account loss survivable | **Selected** |
| OVH-only (bucket in a second region) | One account still owns everything | Rejected |
| Off-provider only | Slower in-provider restores; single copy | Rejected |

**Interim StorageClass (single worker):**

| Option | Fit on one node with an existing ZFS mirror | Verdict |
|---|---|---|
| **OpenEBS zfs-localpv on the existing pool** | Purpose-built (`poolname`), dynamic PVCs + snapshots/quotas, zero new layers | **Selected** |
| Longhorn now | replica-1 on one worker = overhead without durability; extensions + privileged PSS; two redundancy layers stacked on ZFS | Rejected until the trigger below fires |
| local-path / hostPath | No snapshots, no quotas/capacity enforcement (plain hostPath additionally lacks dynamic provisioning) | Rejected |
| Mayastor | hugepages + NVMe-oF machinery for one node | Rejected at this scale |

## Decision

**Backups become the availability baseline: automated, encrypted, immutable where the platform allows, replicated off-provider, and rehearsed against every failure domain — including total provider loss. Storage stays on the existing ZFS pool behind a real CSI driver. Nothing here waits for multi-node.**

1. **etcd snapshots** (#316): `talos-backup` as a CronJob — snapshot → zstd → **age encryption** → a dedicated S3 bucket, cadence every 4–6 h. Enabled by the `kubernetesTalosAPIAccess` patch scoped to role `os:etcd:backup` and the backup namespace (live-appliable; it flows through talos-core's config-patch surface once the module lands, #322/#324). Two automated checks, because existence is not restorability: cluster-checks asserts a fresh snapshot object exists (age < 8 h), and a periodic job **decrypts the latest snapshot and verifies non-zero size and the embedded etcd integrity hash** — so a dead CronJob, a truncated object, or a rotated-away age key all surface within a day, not at the next drill.

2. **Off-provider replica** (#317): a scheduled restic (or rclone+age) job, client-side encrypted, running **at least daily**, replicating to a non-OVH target: **the latest N etcd snapshots** (the single highest-value artifact — without them, full provider loss loses every API object not in Git: issued certs, ServiceAccount tokens, controller keys, PVC bindings), OpenTofu state backups (state embeds the machine secrets — treat as secret material), an encrypted export of the Talos machine secrets, **`terraform.tfvars`/`backend.tfvars`** (gitignored — they exist nowhere else durable), ZFS snapshots of the data pool (`zfs send`, taken and replicated daily), **a git bundle of this repo** (removes GitHub from the critical recovery path), and an **export of the tailnet ACL policy** (hand-managed in the Tailscale console until ACL-as-code lands, #336 — at which point it moves to the "rebuilt from Git" column). Verified with `restic check` on schedule.

3. **Backup immutability and retention**: the same credential that writes backups must not be able to erase history — a destructive apply or a compromised key is an in-scope threat, and 7 days of retention is thinner than realistic corruption/ransomware dwell time. Both backup buckets get object-lock/WORM-style immutability where the platform supports it (verify per bucket empirically, as was done for state locking in #278); the backup-write credentials carry **no delete or lifecycle rights**; deletion happens only via lifecycle policy. Retention: primary etcd bucket ≥ 7 days rolling; the off-provider copy keeps a GFS-style schedule (dailies for 30 days, weeklies for 90) so slow corruption is survivable.

4. **Key custody — two independent locations, neither gated by the other**: the age identity and the restic password live in (a) the operator's password manager and (b) **offline media held outside both OVH and the password-manager vendor** (printed/hardware-token copy; optionally a Shamir split with a trusted second person, which also softens the DR bus factor). The off-provider copy may *contain* the age key as a convenience, but an encrypted copy is never counted as custody of the secret that decrypts it — losing the password manager must not orphan the backup estate. Rotation of either secret updates both custody locations in the same sitting.

5. **Restore runbook + drills against every failure domain** (#318): documented procedures for (a) single-node etcd restore (`talosctl bootstrap --recover-from`), (b) the 3-node recovery sequence (reset the others → bootstrap one from the snapshot → the rest rejoin) for the future topology, (c) ZFS dataset restore from `zfs send` streams, and (d) **full-loss recovery from the off-provider copy alone** — OVH account assumed gone: restore state + secrets + tfvars + git bundle, rebuild compute, restore etcd, reseed GitOps. Drills rotate through the paths quarterly, and **path (d) runs at least annually**; the first drill is path (a) and is labelled as such. Every drill files a redacted report (timings, gaps). **A backup that has not restored is a hypothesis.**
   **Drill secret handling** (a real production snapshot is the entire cluster secret estate): drills run in a production-side isolated scratch environment — explicitly **not** the ADR-0016 e2e project/tailnet (e2e must never see prod secrets, ADR-0016 decision 4); the restored scratch cluster never joins the production tailnet and never reuses production auth keys or node identity; the age key touches the scratch VM only in memory (piped in, never written to its disk); the VM is crypto-shredded on teardown; drill reports pass the same redaction discipline as cluster-checks output.

6. **GitOps recoverability** (#319): ArgoCD is re-enabled (`argocd_enabled = true` — tfvars, the CI tfvars secret, and the cluster-checks variable move together) and the bootstrap chain becomes **declarative end-to-end**: the root app-of-apps Application and its repo credentials are seeded by tofu/the module, never manually — today only a sample app exists, so "rebuilds from Git" is aspirational until #319 lands. Non-HA (single replica) until ≥ 2 schedulable nodes exist.

7. **Interim StorageClass** (#320): OpenEBS **zfs-localpv** pointed at the existing pool (`poolname` parameter, `allowedTopologies` restricted to the node carrying it), deployed via ArgoCD. The zfs-pool Job's nodeAffinity is retargeted from the control-plane role to an explicit node label, ready for the future CP/worker split. The storage cluster-check moves from hostPath assumptions to a PVC create/write/snapshot/delete round-trip.

8. **Longhorn trigger (deliberately narrow)**: Longhorn is adopted only when **≥ 2 workers share a same-provider/low-RTT storage fabric** — synchronous replica traffic over 15–30 ms inter-provider links fails its own fsync guidance and is additionally metered egress; a replica-1 Longhorn install is the overhead-without-durability anti-pattern the options table rejects and is not a sanctioned workaround. Until the trigger fires, zfs-localpv remains the answer for node-pinned volumes — noting plainly that it provides provisioning, snapshots, and quotas but **no cross-node availability or data mobility**; workloads needing those wait for the trigger. Network-attached storage (Longhorn/Ceph/iSCSI) is **never** placed under etcd's WAL.

9. **Recovery objectives, tiered by failure domain** (drills validate these or force this section to be amended):

   | Failure domain | RPO | RTO |
   |---|---|---|
   | Workload-level (etcd intact) | n/a (live state) | minutes, via GitOps |
   | Node loss, OVH available | etcd ≤ 6 h (primary bucket); PV ≤ 24 h (daily ZFS snapshot) | ≤ 1 h beyond the ~15–30 min OVH reinstall |
   | Full provider loss (off-provider copy only) | etcd ≤ 24 h (daily off-provider mirror); PV/state/secrets ≤ 24 h | ≤ 1 working day, targeting **hourly Public Cloud compute** for the rebuild (a fresh dedicated-server order can take days and is not the recovery path) |

10. **What is backed up vs rebuilt** (anything found in neither category during a drill is a finding): **backed up** — etcd snapshots, PV data (ZFS snapshots), machine secrets, OpenTofu state, `terraform.tfvars`/`backend.tfvars`, age/restic keys (custody per decision 4), the repo git bundle, the tailnet ACL export (until #336). **Rebuilt from Git** — machine config (module + the backed-up tfvars), all workloads and cluster add-ons (ArgoCD, once #319 makes the chain declarative), firewall/network policy. **Acknowledged dependencies that are neither**: the GitHub account itself (mitigated by the git bundle + operator's local clone; environment secrets are re-creatable from the backed-up tfvars/secrets inventory) and the Tailscale account (mitigated by the ACL export and documented tailnet reconstruction in the runbook).

11. **ADR-0004 relationship**: the ZFS mirror remains the device layer, but the *storage interface* moves to the consumer/GitOps layer (zfs-localpv via ArgoCD) — resolving the boundary question ADR-0016 (Context, goal 3) deferred to this ADR: storage is outside talos-core's scope, and module-side involvement ends at pool provisioning. ADR-0004 receives a **superseded-in-part** note via the reconciliation sweep (#340).

## Consequences

**Positive:**

- Availability improves where it is cheapest: a rehearsed restore bounds every failure mode that quorum would not (corruption, bad apply, account compromise, region loss) for a few €/mo of storage instead of ~€30+/mo of control-plane nodes.
- The single-provider blast radius is genuinely bounded: with etcd snapshots, tfvars, and a git bundle off-provider, a total OVH loss — or even OVH + GitHub simultaneously — degrades to a documented, drilled recovery path instead of "start over".
- Backup history survives a compromised writer credential or a destructive apply (immutability + delete-less credentials + GFS retention).
- Workload storage gains dynamic provisioning, snapshots, and quotas with zero new replication layers, and the GitOps recovery premise becomes real instead of aspirational.
- The future multi-node migration ([ADR-0017](0017-multi-node-topology-fabric-and-endpoint.md), Proposed) inherits a proven backup/restore substrate — its riskiest step (wiping the data-bearing node) becomes routine.

**Negative / accepted risks:**

- **Key custody is manual discipline.** Two independent locations close the single-point-of-failure, but keeping the offline copy current through rotations is a human process; a stale offline copy after a rotation silently reverts to single-custody. The rotation checklist in the runbook is the mitigation.
- **talos-backup maturity**: an officially minimal/experimental tool guards the most important data. Mitigations: the automated decrypt-and-verify check, drills exercising the real restore path, and the `talosctl etcd snapshot` + restic fallback documented in the runbook.
- **Drill cost and discipline**: quarterly drills cost little money but real operator attention, and the annual full-loss drill is a half-day exercise; skipping drills silently reverts this ADR to "hypothesis" status.
- **Secrets-bearing artifacts multiply**: etcd snapshots, state, machine secrets, and tfvars now exist in two storage systems plus drill environments; all copies are client-side encrypted and drills carry explicit handling rules, but the inventory of secret-bearing objects is larger than before.
- An off-provider account is one more thing to pay for, rotate, and monitor — and immutability support there must be verified, not assumed.

## References

- [siderolabs/talos-backup](https://github.com/siderolabs/talos-backup) (CronJob, age, S3, `os:etcd:backup` role); Talos disaster-recovery docs (`talosctl bootstrap --recover-from`, 3-node sequence)
- [OpenEBS zfs-localpv](https://github.com/openebs/zfs-localpv) (pre-existing zpool via `poolname`); [Longhorn Talos requirements](https://longhorn.io/docs/) (extensions, privileged PSS, kubelet mounts); etcd FAQ fsync guidance (WAL p99 < 10 ms — why network storage never sits under etcd)
- Strategy review and fact-check record, 2026-07-08/09
- Related ADRs: ADR-0004 (storage strategy; superseded in part by decision 11 via #340), ADR-0012 (the redeploy habit this ADR ends), ADR-0016 (module boundary; e2e isolation the drill rules must respect), [ADR-0017](0017-multi-node-topology-fabric-and-endpoint.md) (Proposed; #310)
- Tickets: #311 (this ADR), #316–#320 (implementation), #336 (ACL-as-code — moves the ACL from "backed up" to "rebuilt from Git"), #340 (reconciliation sweep)
