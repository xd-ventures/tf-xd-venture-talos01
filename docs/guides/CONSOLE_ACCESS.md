# Console Access: iKVM, IPMI, and Serial Over LAN

Out-of-band console access for debugging a Talos bare metal server that is
unreachable over the network.

## When You Need This

- Server stuck in a boot loop (kernel panic, YAML parse error, config drive corruption)
- Tailscale not connecting (firewall misconfiguration, auth key expired)
- Public IP unreachable (network issue, firewall enabled)
- Need to see what's on screen before the Talos API is available

This project **relied heavily on iKVM console access** during initial cluster
bootstrapping and the [12-day config drive outage](../incidents/2026-02-config-drive-yaml-parse.md).
iKVM screenshots were the only way to diagnose boot failures on a headless server
where the Talos API never became available.

## Access Methods

| Method | Best For | Latency | Setup |
|--------|----------|---------|-------|
| [iKVM via MCP](#ikvm-via-mcp-recommended) | AI-assisted debugging, quick visual checks | ~5s | MCP server running |
| [iKVM via OVH Manager](#ikvm-via-ovh-manager) | Manual visual inspection | ~10s | Browser only |
| [Serial Over LAN (SOL)](#serial-over-lan-sol) | Text-based console, log capture | ~1s | SSH key registered |
| [Rescue Mode SSH](#rescue-mode) | Disk inspection, config drive repair | ~5min boot | OVH API access |

## iKVM via MCP (Recommended)

The [ovh-ikvm-mcp](https://github.com/xd-ventures/ovh-ikvm-mcp) server gives
MCP-capable AI assistants (Claude Code, Cursor, Windsurf) direct visual access
to the server's physical console. This was the primary debugging tool for this
project.

### How It Works

The MCP server authenticates with the OVH API, establishes a BMC (Baseboard
Management Controller) session, connects to the KVM WebSocket, captures JPEG
frames, and converts them to PNG images optimized for LLM vision analysis
(2x upscaling, brightness enhancement).

### Setup

**Prerequisites**: OVH API credentials with IPMI permissions.

**Option 1: Docker (recommended)**

```bash
docker run --rm \
  -e OVH_ENDPOINT=eu \
  -e OVH_APPLICATION_KEY=your-app-key \
  -e OVH_APPLICATION_SECRET=your-app-secret \
  -e OVH_CONSUMER_KEY=your-consumer-key \
  -p 3001:3001 \
  ghcr.io/xd-ventures/ovh-ikvm-mcp:latest
```

**Option 2: Local (requires Bun)**

```bash
git clone https://github.com/xd-ventures/ovh-ikvm-mcp.git ~/ovh-ikvm-mcp
cd ~/ovh-ikvm-mcp
bun install

export OVH_ENDPOINT="eu"
export OVH_APPLICATION_KEY="your-app-key"
export OVH_APPLICATION_SECRET="your-app-secret"
export OVH_CONSUMER_KEY="your-consumer-key"

bun start  # listens on http://localhost:3001/mcp
```

### Agent Configuration

This project's `.mcp.json` auto-registers the iKVM server:

```json
{
  "mcpServers": {
    "ikvm": {
      "type": "http",
      "url": "http://localhost:3001/mcp"
    }
  }
}
```

For other MCP clients, add the same URL to your agent's MCP configuration:
- **Claude Desktop**: `~/Library/Application Support/Claude/claude_desktop_config.json`
- **Cursor**: `.cursor/mcp.json`

### MCP Tools

**`list_servers`** — Lists all bare metal servers with iKVM access.

```
Returns: JSON array with server objects (id, name, provider, datacenter, IP)
```

**`get_screenshot(serverId)`** — Captures the server's console screen as a PNG.

```
Parameters:
  serverId (string) — Server identifier (e.g., from list_servers output)
  raw (boolean, default: false) — Return unprocessed image

Returns: Base64-encoded PNG image (optimized for LLM vision by default)
```

### Usage

With the MCP server running, ask your AI assistant:

> "List the servers and take a screenshot of the console"

The assistant will call `list_servers` to find the server ID, then
`get_screenshot` to capture the console. It can then read the screen content
(boot messages, error output, kernel panics) and help diagnose the issue.

### Debugging Workflow Example

This was the actual workflow used to diagnose the config drive YAML parse error:

1. `tofu apply` failed — server reinstalled but never became reachable
2. MCP `get_screenshot` captured the Talos boot screen
3. Console showed: `yaml: line 365: found character that cannot start any token`
4. This identified the root cause (OVH cleartext escape processing)
5. Led to rescue mode investigation and the base64 encoding fix

Without iKVM, this would have required filing an OVH support ticket and waiting
for manual intervention.

## iKVM via OVH Manager

If the MCP server is not available, access KVM through the OVH web console:

1. Go to [OVH Manager](https://www.ovh.com/manager/) → Bare Metal Cloud → Dedicated Servers
2. Select your server
3. Click **IPMI** tab
4. Click **From a Java applet (KVM)** or **From your browser (KVM)**
5. A console window opens showing the server's physical display

Or request access via the OVH API script:

```bash
./scripts/ovh-ipmi-access.sh
```

## Serial Over LAN (SOL)

SOL provides a text-based serial console over SSH. It's faster than iKVM
(no image rendering) and works well for capturing log output.

### Requesting SOL Access

```python
import ovh
client = ovh.Client()

service_name = "nsXXXXXXX.ip-XXX-XX-XX.eu"  # from: tofu output server_id

# Register your SSH key for SOL access
client.post(
    f'/dedicated/server/{service_name}/features/ipmi/access',
    type='serialOverLanSshKey',
    ttl=15,  # minutes
    sshKey=open(os.path.expanduser('~/.ssh/id_ed25519.pub')).read().strip(),
)

# Get the SOL SSH endpoint
access = client.get(
    f'/dedicated/server/{service_name}/features/ipmi/access',
    type='serialOverLanSshKey',
)
print(f"SSH command: {access['value']}")
```

### Connecting

```bash
ssh ipmi@<N>.sol-ssh.ipmi.ovh.net
```

The `<N>` and connection details are returned by the access API call above.

### Talos Console Output Over SOL

> **Important limitation**: Talos Linux does not display the Talos dashboard
> (interactive TUI) on the serial console by default. SOL shows kernel boot
> messages and the Talos log stream, but not the familiar Talos dashboard
> that appears on the VGA/iKVM console.
>
> This is a known upstream issue:
> [siderolabs/talos#10441](https://github.com/siderolabs/talos/issues/10441)

**What you CAN see over SOL:**
- Kernel boot messages (`dmesg` output)
- Talos service startup logs
- Error messages (kernel panics, config parse failures)
- Network interface initialization

**What you CANNOT see over SOL:**
- Talos dashboard (node status, services, IP addresses)
- Interactive TUI elements

#### Workaround for Talos Dashboard Over Serial

There is a [community workaround](https://github.com/siderolabs/talos/issues/10441#issuecomment-2689866836)
that redirects the Talos dashboard to the serial console using a privileged
DaemonSet. However, this approach has a critical limitation for emergency
access: **it requires deploying a privileged pod to the cluster**. If the
cluster is unreachable (which is typically why you need console access), you
cannot deploy the pod. This creates a catch-22 where the workaround is only
available when you don't need it.

For emergency debugging, use **iKVM** (which shows the full Talos dashboard)
or rely on the kernel/service logs visible over SOL.

### Enabling Serial Console Output

To ensure kernel messages appear on the serial console, add serial console
kernel arguments to your `terraform.tfvars`:

```hcl
extra_kernel_args = [
  "console=ttyS0,115200n8",  # Serial console (SOL)
  "console=tty0",             # Physical/iKVM console (keep both)
]
```

> **Note**: The last `console=` argument becomes the primary console for
> kernel output. Order matters — put `tty0` last if you want iKVM to be
> primary, or `ttyS0` last if SOL is primary.

## Rescue Mode

When you need to inspect disks or repair the config drive, boot into
OVH rescue mode:

```bash
./scripts/ovh-rescue-boot.sh
```

Then SSH in with the credentials shown in OVH Manager:

```bash
ssh root@<server-public-ip>
```

See [Disaster Recovery](../DISASTER_RECOVERY.md) for detailed rescue mode
procedures (disk inspection, config drive repair, etc.).

## Access Decision Tree

```
Server unreachable?
  │
  ├─ Need visual console? ──→ iKVM (MCP or OVH Manager)
  │   └─ See Talos dashboard, boot screen, kernel panics
  │
  ├─ Need text logs? ──→ SOL (serial console via SSH)
  │   └─ See kernel messages, service logs (no dashboard)
  │
  └─ Need disk access? ──→ Rescue Mode (SSH into Debian rescue)
      └─ Inspect/repair config drive, check partitions
```

## Related Documents

- [Disaster Recovery](../DISASTER_RECOVERY.md) — failure recovery procedures
- [Operations Runbook](../OPERATIONS_RUNBOOK.md) — routine operations
- [OVH BYOI Guide](OVH_BYOI_GUIDE.md) — installation specifics
- [RCA: Config Drive YAML Parse](../incidents/2026-02-config-drive-yaml-parse.md) — incident where iKVM was essential
