# ADR-0003: CNI Selection

## Status
Accepted

## Date
2026-02-08

## Context
Kubernetes requires a Container Network Interface (CNI) plugin. We need to select the appropriate CNI for our showcase cluster.

### Challenge
- Talos defaults to Flannel CNI
- nginx-ingress is deprecated (March 2026)
- Gateway API is the future of Kubernetes ingress
- Observability is important for a showcase cluster

### Considered Options

#### Option 1: Flannel (Default)
- Simple VXLAN-based overlay
- Minimal configuration
- Limited features
- No native Gateway API support
- **Rejected**: Limited observability, no Gateway API

#### Option 2: Calico
- Mature, feature-rich
- Supports Network Policies
- BGP routing capability
- No native Gateway API
- **Rejected**: More complex than needed, no Gateway API

#### Option 3: Cilium
- eBPF-based, high performance
- Hubble for observability (network flow visualization)
- Native Gateway API support
- Replaces kube-proxy
- Active development, modern architecture
- **Selected**

## Decision
Use Cilium CNI with Hubble observability and Gateway API enabled.

### Implementation
```hcl
# Disable Flannel and kube-proxy in machine config
cluster = {
  network.cni.name = "none"
  proxy.disabled = true
  inlineManifests = [
    { name = "gateway-api-crds", contents = "..." },
    { name = "cilium", contents = "..." }
  ]
}
```

### Cilium Configuration
```yaml
kubeProxyReplacement: true
k8sServiceHost: localhost
k8sServicePort: 7445  # KubePrism
hubble.enabled: true
hubble.relay.enabled: true
hubble.ui.enabled: true
gatewayAPI.enabled: true
bpf.hostLegacyRouting: true  # Required for Talos
```

### Routing Mode
- **Native routing** for single-node (no overlay needed)
- VXLAN/Geneve available for multi-node expansion

## Consequences

### Positive
- Network flow observability via Hubble
- Native Gateway API (replaces deprecated nginx-ingress)
- eBPF performance benefits
- Modern, actively developed
- Demonstrates expertise in cloud-native networking

### Negative
- More complex than Flannel
- Requires inline manifest for bootstrap
- Learning curve for operators

### Firewall Considerations
Cilium ports for firewall rules:
- TCP 4240: Health checks
- TCP 4244: Hubble Relay
- No overlay ports needed for native routing mode

## References
- [Cilium on Talos - Sidero Documentation](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium)
- [Gateway API Migration](https://kubernetes.io/blog/2023/10/31/gateway-api-ga/)
- [Hubble Documentation](https://docs.cilium.io/en/stable/gettingstarted/hubble/)
