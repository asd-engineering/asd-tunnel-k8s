# asd-tunnel-k8s

Reference deployment and validation suite for running [ASD Tunnel](https://github.com/asd-engineering/asd-tunnel) on Kubernetes.

Demonstrates a 3-node NATS-clustered tunnel server with SSH-based tunnel creation, HTTP request routing, optional Caddy TLS termination, two authentication modes, and enterprise security hardening.

## Prerequisites

The only tool you need installed manually is **[Docker](https://docs.docker.com/get-docker/)** — it requires OS-specific installation (Docker Desktop on macOS/Windows, package manager on Linux).

Everything else (ASD CLI, kind, kubectl, jq, ssh, curl) is **checked and auto-installed** by the setup script.

**Optional:** [asd-tunnel](https://github.com/asd-engineering/asd-tunnel) binary — only needed for `asd run tunnel-client` (auto-reconnect) and the docs demo.

## Quick Start

The fastest way to get a tunnel running locally. This creates a single-replica cluster without authentication — ideal for a first look.

**Step 0 — Clone the repository:**

```bash
git clone https://github.com/asd-engineering/asd-tunnel-k8s.git
cd asd-tunnel-k8s
```

**Step 1 — Check and install prerequisites:**

```bash
./setup              # check + install missing tools
./setup --dry-run    # only show what's present and what's missing
```

This checks all required tools, installs what's missing (kind, kubectl, jq), and tells you if Docker or ASD CLI need manual installation.

**Step 2 — Initialize and deploy:**

```bash
asd env init              # set up environment variables
asd run quickstart        # create kind cluster + deploy
```

Wait for the output to show all pods as `Running`.

**Step 3 — Create a tunnel (open a second terminal):**

```bash
asd run tunnel
```

Keep this terminal open — the tunnel must stay active.

**Step 4 — Test it (open a third terminal):**

```bash
curl -s --resolve "app.tunnel.local:30080:127.0.0.1" \
  http://app.tunnel.local:30080/echo | jq .
```

**Expected output** — a formatted JSON response with your request metadata:

```json
{
  "headers": {
    "Accept": "*/*",
    "Accept-Encoding": "gzip",
    "User-Agent": "curl/8.5.0",
    "X-Forwarded-For": "10.244.0.1",
    "X-Forwarded-Host": "app.tunnel.local:30080",
    "X-Forwarded-Port": "30080",
    "X-Forwarded-Proto": "http",
    "X-Forwarded-Server": "asd-tunnel-0",
    "X-Real-Ip": "10.244.0.1"
  },
  "host": "app.tunnel.local:30080",
  "method": "GET",
  "path": "/echo",
  "remote_addr": "127.0.0.1:47654",
  "request_id": "",
  "timestamp": "2026-05-27T16:08:46Z"
}
```

If you see this, the tunnel is working.

**Step 5 — Run benchmarks (same terminal):**

```bash
asd run bench
```

### Quick Start: Full Cluster (3 replicas, NATS, SSH key auth)

Once you're comfortable with the basic setup, try the production-like deployment:

```bash
asd run quickstart-full     # 3 replicas, NATS clustering, SSH key auth
asd run tunnel-auth         # Tunnel with demo SSH key (auto-generated)
asd run bench
```

### Cleanup

```bash
asd run teardown            # Deletes the kind cluster
```

## Deploy Variants

One-shot commands for the most useful overlays. Each composite task creates the cluster, builds images, generates keys if needed, and deploys the right overlay. After it finishes, run the matching tunnel command in a second terminal.

| Variant | Command | Tunnel | Access |
|---------|---------|--------|--------|
| HTTPS + SSH auth (recommended) | `asd run quickstart-https` | `asd run tunnel-auth` | `https://app.tunnel.localhost:30443` |
| HTTPS without auth | `asd run quickstart-https-noauth` | `asd run tunnel` | `https://app.tunnel.localhost:30443` |
| HTTP-based auth | `asd run quickstart-http-auth` | `asd run tunnel-auth` | `http://app.tunnel.local:30080` |

**Example — full HTTPS + auth demo:**

```bash
asd run quickstart-https           # cluster + key + HTTPS overlay
asd run tunnel-auth                # open tunnel (keep open)
# In another terminal:
curl -sk --resolve "app.tunnel.localhost:30443:127.0.0.1" \
  https://app.tunnel.localhost:30443/echo | jq .
```

### Other deployments

**Rolling upgrade test:**

```bash
asd run quickstart-full                       # cluster + demo key (file-auth)
OVERLAY=rolling-upgrade asd run deploy        # switch to PDB-enabled overlay
asd run tunnel-auth                           # tunnel (keep open in 2nd terminal)
asd run rolling-upgrade-full                  # trigger restart + verify zero-downtime
```

**Air-gapped deployment:**

See [docs/airgap-deployment.md](docs/airgap-deployment.md) — requires image export and registry setup.

**Deploy any overlay manually:**

```bash
OVERLAY=<overlay-name> asd run deploy         # see Deployment Modes table below
```

### Next Steps

- [Authentication modes](docs/authentication.md) — file-based and HTTP-based auth
- [Benchmarking](docs/benchmarking.md) — understanding the test suite
- [Rolling upgrades](docs/rolling-upgrade.md) — zero-downtime upgrade verification
- [Architecture](docs/architecture.md) — component design and data flow

## Architecture

```
SSH Client ──(30022)── NodePort ── StatefulSet (3 pods) ── NATS cluster
HTTP Client ─(30080)── NodePort ── HTTP muxer ── SSH channel ── backend
```

Each tunnel pod runs SSH (port 2222) and an HTTP muxer (port 8081). Pods discover each other via NATS over a headless service. When an HTTP request arrives for a tunnel on a different pod, NATS routes the lookup and the request is proxied cross-pod.

**Every pod can serve any tunnel** — the cluster provides built-in load balancing at the application layer. Rolling updates have zero downtime; pod crashes self-heal in ~3-5 seconds via NATS retry.

See [docs/architecture.md](docs/architecture.md) for the full component diagram, data flow, and high-availability design.

## Deployment Modes

All modes use [Kustomize](https://kustomize.io/) overlays on a common base. Choose the overlay that matches your use case:

| Overlay | Replicas | Auth | TLS | Use case |
|---------|----------|------|-----|----------|
| `minimal` | 1 | None | No | First look, local development |
| `file-auth` | 3 | SSH public keys | No | Team environments, test with real auth |
| `http-auth` | 3 | HTTP validator | No | Production pattern (API-based auth) |
| `with-caddy` | 3 | BYO keys¹ | Yes (Caddy) | Template — bring your own keys |
| `with-caddy-noauth` | 3 | None | Yes (Caddy) | HTTPS demo without auth |
| `with-caddy-file-auth` | 3 | SSH public keys | Yes (Caddy) | **HTTPS + auth demo (recommended)** |
| `rolling-upgrade` | 3 | SSH public keys | No | Zero-downtime upgrade testing (PDB) |
| `airgap` | 3 | SSH public keys | No | Offline/air-gapped environments |

¹ `with-caddy` enables authentication but mounts no public keys — used as a building block. For an out-of-the-box HTTPS+auth deployment, use `with-caddy-file-auth`.

See [Deploy Variants](#deploy-variants) above for ready-to-run snippets.

## Documentation

| Guide | Description |
|-------|-------------|
| [Architecture](docs/architecture.md) | Component diagram and data flow |
| [Authentication](docs/authentication.md) | File-auth and HTTP-auth setup |
| [Benchmarking](docs/benchmarking.md) | Test suite details and results |
| [Rolling Upgrades](docs/rolling-upgrade.md) | Zero-downtime upgrade procedure |
| [Air-Gap Deployment](docs/airgap-deployment.md) | Offline environment setup |
| [Production Deployment](docs/production-deployment.md) | Capacity planning, monitoring, DR |

## Available Commands

All commands are available via `asd run <task>`. A subset is also available via `just <task>` — see the Justfile for what's supported.

### Cluster Lifecycle

| Command | Description |
|---------|-------------|
| `asd run quickstart` | Create kind cluster + deploy minimal overlay |
| `asd run quickstart-full` | Create kind cluster + deploy file-auth (3 replicas, NATS) |
| `asd run teardown` | Delete the kind cluster |
| `asd run status` | Show pods, services, and port reachability |

### Tunnels

| Command | Description |
|---------|-------------|
| `asd run tunnel` | Create SSH tunnel to validation-server |
| `asd run tunnel-auth` | Create SSH tunnel with demo key (file-auth overlay) |
| `asd run tunnel-client` | Create tunnel with asd-tunnel client (auto-reconnect) |

### Build & Deploy

| Command | Description |
|---------|-------------|
| `asd run build` | Build validation-server and key-validator images |
| `asd run deploy` | Deploy the overlay specified by `$OVERLAY` env var |
| `asd run validate` | Verify all 8 Kustomize overlays build correctly |

### Benchmarks & Tests

| Command | Description |
|---------|-------------|
| `asd run bench` | Built-in benchmark: roundtrip + payload + concurrent |
| `asd run bench-roundtrip` | 100 UUID header echo requests |
| `asd run bench-payload` | 12MB + 25MB upload + 1MB download (SHA-256) |
| `asd run bench-concurrent` | 20 parallel requests, isolation check |
| `asd run bench-cross-pod` | NATS routing verification (requires 3 replicas) |
| `asd run bench-stress` | 100 concurrent tunnels, sustained load, zero-downtime assertion |
| `asd run bench-auth` | File-auth: valid/invalid/nokey/RSA/revoked key tests |
| `asd run bench-auth-http` | HTTP auth: approve/reject/fail-closed tests |
| `asd run bench-resilience` | Pod failure recovery via NATS re-routing |
| `asd run bench-resource-limits` | Resource pressure: 200 tunnels, recovery verification |

### Rolling Upgrades

| Command | Description |
|---------|-------------|
| `asd run rolling-upgrade` | Trigger rollout restart + verify tunnel survives |
| `asd run rolling-upgrade-full` | Full upgrade test with continuous monitoring |

## Demos

### Documentation Demo (Full-Stack HTTPS Tunnel)

Serve this project's own documentation through the tunnel with HTTPS — a production-realistic demo using a containerized `asd-tunnel` client. TLS is terminated by an in-cluster Caddy sidecar.

**Requires:** `asd-tunnel` binary installed (`asd init`), kind cluster running.

```bash
asd env init
asd run quickstart          # if not already running
asd run docs                # builds container, connects via SSH
# Open: https://docs.tunnel.localhost:30443
```

No `/etc/hosts` needed — `.localhost` resolves to 127.0.0.1 per [RFC 6761](https://www.rfc-editor.org/rfc/rfc6761). Press Ctrl+C to stop.

### Using asd-tunnel Client (auto-reconnect)

Unlike plain SSH, `asd-tunnel connect` automatically reconnects when the connection drops. It combines the functionality of autossh and askpass into a single binary.

```bash
asd run tunnel-client
```

## Troubleshooting

### `asd run quickstart` fails

- **Docker not running?** Start Docker Desktop or the Docker daemon.
- **Port conflict on 30022/30080?** Another service may be using these ports. Check with `lsof -i :30022`.
- **Kind cluster already exists?** Run `asd run teardown` first, then retry.

### Tunnel doesn't connect

- **Pods not ready?** Check with `asd run status` — all pods should show `Running`.
- **SSH connection refused?** The NodePort may not be ready yet. Wait 10 seconds and retry.

### `curl` returns no response

- **Tunnel still open?** The SSH tunnel (terminal 2) must stay open while testing.
- **Wrong host header?** The `--resolve` flag in the curl command maps the domain to localhost. Make sure it matches exactly.

### Benchmarks fail

- **Tunnel not active?** Benchmarks require an active tunnel. Run `asd run tunnel` first.
- **Partial failures?** Check `asd run status` to verify cluster health.

## Security Posture

- Pods run as non-root (uid 65534) with read-only root filesystem
- All Linux capabilities dropped, seccomp profile enforced
- NetworkPolicy: default-deny with explicit allow rules
- Pod Security Standards: `restricted` profile enforced on namespace
- ServiceAccount tokens not auto-mounted
- Authentication enabled by default (overlays can disable for local dev)

## Repository Structure

```
setup                      # Preflight wrapper — runs scripts/preflight.sh
k8s/
  base/                    # StatefulSet, services, NetworkPolicy, ServiceAccount
  components/              # Reusable components (validation-server)
  overlays/                # Deployment configurations (8 overlays)
services/
  docs-server/             # Docsify SPA + Python server + asd-tunnel client (Alpine container)
  validation-server/       # Go echo server for benchmarks (~5MB image)
  key-validator/           # Node.js SSH key validator for http-auth
scripts/
  preflight.sh             # Check + install prerequisites (kind, kubectl, jq)
  setup-cluster.sh         # Create kind cluster with port mappings
  generate-demo-key.sh     # Generate demo SSH keypair + update ConfigMap
  export-images.sh         # Export images for air-gapped deployment
  test-drain.sh            # Zero-downtime graceful drain test
  test-hardkill-recovery.sh # NATS retry recovery test
  benchmark/               # Benchmark + security test suite
  rolling-upgrade/         # Upgrade testing
docs/                      # Architecture, auth, benchmarking, air-gap, production
```

## Image

The tunnel image is configured via `TUNNEL_IMAGE` in `tpl.env` (default: `ghcr.io/asd-engineering/asd-tunnel:latest`).

For kind clusters, `asd run quickstart` handles pulling, tagging, and loading the image automatically. The StatefulSet uses `asd-tunnel:k8s-demo` with `imagePullPolicy: IfNotPresent` so kind uses the pre-loaded image.

## License

MIT
