# ADR-0015: Cilium Datapath Alignment — VXLAN Routing, kube-proxy Removal, Gateway API Deferral

## Status
Accepted

## Date
2026-07-08

## Context

[ADR-0003](0003-cni-selection.md) selected Cilium as the CNI — that decision
stands. Its *implementation details*, however, drifted from reality in three
independent ways (found by the 2026-07 repo review, #240; verified against
the live cluster):

1. **Routing mode.** ADR-0003 specified *native routing* ("no overlay ports
   needed"), and a talos.tf comment repeats the claim. The live cluster runs
   `routing-mode: tunnel, tunnel-protocol: vxlan` — the cilium-cli **default**,
   because `templates/cilium-install-job.yaml.tftpl` never sets a routing
   mode. firewall.tf accordingly opens UDP 8472, with a spoofable pod-CIDR
   source (#241).
2. **kube-proxy.** ADR-0003 specified `cluster.proxy.disabled = true`. The
   machine config never sets it: the kube-proxy DaemonSet has run for 110+
   days *alongside* Cilium's `kube-proxy-replacement: "true"` — a redundant
   double service-dataplane that Cilium guidance advises against
   (conflict-prone, muddies debugging).
3. **Gateway API.** The install job sets `gatewayAPI.enabled=true`, but the
   `gateway-api-crds` inline manifest ADR-0003 promised was never wired into
   talos.tf — **zero Gateway CRDs exist**, so the flag is silently inert and
   the README's "Gateway API" feature claim is hollow.

Additionally, ADR-0003's `bpf.hostLegacyRouting: true # Required for Talos`
is **disproven**: the flag is unset and the cluster has run fine for 110+
days.

Cluster context that shapes the decision:

- **Single node today**: same-node pod traffic never traverses the tunnel —
  routing mode is functionally irrelevant until multi-node.
- **Multi-node future** (ADR-0013 Phase 3): OVH eco-class dedicated servers,
  likely no vRack (no shared L2), possibly cross-DC, with node-to-node
  connectivity expected over Tailscale/WireGuard.
- Inline-manifest changes apply live via `talos_machine_configuration_apply`;
  a changed cilium-install Job manifest is re-created and re-run (the
  original was GC'd by `ttlSecondsAfterFinished`), and `cilium install`
  against an existing installation errors rather than reconfigures — a
  failed re-run also skips the cleanup Job, leaving the `cilium-install`
  cluster-admin ClusterRoleBinding behind (manual delete).
- Firewall (`NetworkRuleConfig`) changes are **staged for the next reboot**
  under `apply_mode = "auto"` — they never apply live.

## Considered Options

### Routing mode

1. **Align code to ADR-0003: switch to native routing.** Closes UDP 8472
   entirely. Rejected: an untested datapath flip that only takes effect at
   the next reinstall; on a single node it changes nothing functionally; and
   for the realistic multi-node future (no shared L2, Tailscale underlay)
   native routing requires route-distribution machinery (BGP or custom) we
   would have to build.
2. **Accept VXLAN and pin it explicitly** *(selected)*. On a single node the
   tunnel is idle; for multi-node over Tailscale, VXLAN is the *correct*
   choice — the overlay rides the encrypted WireGuard mesh (VTEP = Tailscale
   IP) and needs only UDP 8472 between node IPs, no underlay route
   distribution. The firewall concern (#241) is decoupled: the spoofable
   pod-CIDR source is provably dead code (VXLAN outer headers use node IPs,
   never pod IPs) and is removed without touching the datapath.

### kube-proxy

1. **Keep both dataplanes.** Rejected: indefinite double-programming of
   services is a footgun, not a safe baseline.
2. **Set `kubeProxyReplacement=false` to match reality.** Rejected: a
   downgrade that gives up the eBPF service path already in use.
3. **Disable kube-proxy** *(selected)*: `cluster.proxy.disabled = true` in
   the machine config plus an explicit `kubectl delete ds kube-proxy`
   (Talos's manifest controller is apply-only — it will not garbage-collect
   the already-bootstrapped DaemonSet). The real hazard is stale `KUBE-*`
   iptables chains after deletion (Talos has no shell to flush them) — **a
   reboot clears them**, so the change is bundled with the firewall fix's
   reboot window. Pre-check: `cilium-dbg service list` must show all
   ClusterIPs (including `kubernetes.default`) programmed by Cilium.
   Rollback: `proxy.disabled = false`, re-apply, reboot. Blast radius is
   in-cluster ClusterIP consumers only (no NodePort/LB exists; Tailscale-only
   access); node-level access (Talos API, KubePrism 7445) is unaffected.

### Gateway API

1. **Wire the missing CRDs manifest.** Rejected for now: no ingress exists
   (Cloudflare Tunnel is still planned); unused CRDs are maintenance surface.
2. **Remove the inert flag** *(selected)*: drop `gatewayAPI.enabled=true` and
   the README feature claim. This is not abandoning Gateway API — it stops
   advertising an unimplemented feature. Reintroduce properly (CRDs inline
   manifest + flag + a real GatewayClass) when public ingress lands.

## Decision

1. **VXLAN stays.** Pin `routingMode=tunnel` and `tunnelProtocol=vxlan`
   explicitly in the install job so a cilium-cli default change cannot
   silently flip the datapath at the next reinstall. Fix the talos.tf
   comment claiming native routing.
2. **Firewall**: remove the pod-CIDR source from the UDP 8472 rule
   (loopback stays — not internet-spoofable, preserves the cilium-health
   self-overlay path). Re-add node CIDRs when multi-node arrives. Resolves
   #241; takes effect at the next reboot.
3. **kube-proxy is removed**: `cluster.proxy.disabled = true` + DaemonSet
   deletion, bundled with the firewall change into **one planned reboot**
   (activates the rule and flushes stale iptables in a single window).
4. **Gateway API flag and README claim are removed** until ingress is
   actually implemented.
5. `bpf.hostLegacyRouting` stays **unset**; ADR-0003's "required for Talos"
   claim is recorded as incorrect. It remains a contingency lever if
   kube-proxy removal ever surfaces a host-netns service issue.

### Rollout staging (by blast radius)

- **Stage 1 — zero live impact**: this ADR; routing pins + Gateway API flag
  removal + comment/README fixes. Note: the template change re-runs the
  install Job, which is expected to fail harmlessly against the existing
  installation — verify the Cilium DaemonSet is not restarted, and clean up
  the leftover `cilium-install` ClusterRoleBinding if the cleanup Job
  skipped.
- **Stage 2 — one planned reboot**: firewall 8472 tightening + kube-proxy
  removal. Pre-check KPR service programming; post-reboot verify Tailscale
  access, CoreDNS resolution, and a pod reaching `kubernetes.default`.
  The firewall change only removes an allow (cannot cause lockout), so any
  post-reboot breakage attributes cleanly to kube-proxy → documented
  rollback.

## Consequences

**Positive:**

- Configuration and documentation match the running system; the datapath is
  pinned rather than riding a tool default
- #241's spoofable VXLAN ingress is closed with zero functional loss
- Single service dataplane (Cilium KPR) — less confusion, fewer moving parts
- A deliberate, recorded position for the multi-node future: VXLAN over the
  Tailscale mesh

**Negative / risks:**

- One planned reboot window (~minutes) for Stage 2 on a single-node cluster
- The install-Job re-run-on-change behavior remains awkward (errors
  harmlessly rather than reconciling); a future ticket may move Cilium
  lifecycle to a proper upgrade path
- Gateway API users following ADR-0003's original promise must wait for the
  ingress milestone

## References

- [ADR-0003](0003-cni-selection.md) — CNI selection (stands; implementation
  details superseded by this ADR)
- [ADR-0013](0013-upgrade-lifecycle-architecture.md) — Phase 1 live config
  application used by Stage 1
- #240 (this ADR's ticket), #241 (VXLAN firewall rule), #282 (public-log
  identifier exposure)
- Live-cluster verification 2026-07-08: `cilium-config` ConfigMap
  (`routing-mode: tunnel`, `tunnel-protocol: vxlan`,
  `kube-proxy-replacement: "true"`), kube-proxy DaemonSet age 110d, zero
  Gateway CRDs
- Infrastructure architect consultation 2026-07-08 (risk staging, stale
  iptables hazard, VXLAN-over-Tailscale rationale)
