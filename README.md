# asd-tunnel-k8s

Reference deployment and validation suite for running [ASD Tunnel](https://github.com/asd-engineering/asd-tunnel) on Kubernetes.

Demonstrates a 3-node NATS-clustered tunnel server with SSH-based tunnel creation, HTTP request routing, optional Caddy TLS termination, two authentication modes, and enterprise security hardening.

### Security Posture

- Pods run as non-root (uid 65534) with read-only root filesystem
- All Linux capabilities dropped, seccomp profile enforced
- NetworkPolicy: default-deny with explicit allow rules
- Pod Security Standards: `restricted` profile enforced on namespace
- ServiceAccount tokens not auto-mounted
- Authentication enabled by default (overlays can disable for local dev)

## Quick Start

```bash
# 1. Initialize environment
asd env init

# 2. Create cluster + deploy (single replica, no auth)
asd run quickstart

# 3. Create a tunnel (in another terminal)
asd run tunnel

# 4. Test it (in another terminal)
curl --resolve "app.tunnel.local:30080:127.0.0.1" \
  http://app.tunnel.local:30080/echo

# 5. Run benchmarks
asd run bench
```

### Quick Start (3-node NATS cluster with file-auth)

```bash
asd env init
asd run quickstart-full     # 3 replicas, NATS clustering, SSH key auth
asd run tunnel-auth         # Tunnel with demo SSH key
asd run bench
```

### Using asd-tunnel Client (auto-reconnect)

```bash
asd run tunnel-client       # Built-in reconnection on network drops
```

Unlike plain SSH, `asd-tunnel connect` automatically reconnects when the connection drops. It combines the functionality of autossh and askpass into a single binary.

### Documentation Demo (Containerized Full-Stack Tunnel)

Serve this project's own documentation through the tunnel with HTTPS — a production-realistic demo using a containerized `asd-tunnel` client that connects to the K8s cluster. TLS is terminated by an in-cluster Caddy sidecar.

```
Browser (HTTPS)
  → NodePort 30443
    → Caddy sidecar (tls internal on 8443)
      → HTTP muxer (8081) → SSH channel
        → asd-tunnel client (container)
          → Python docs server (same container, port 8080)
```

**Prerequisites:** `asd-tunnel` binary installed (`asd init`), kind cluster running.

```bash
# 1. Initialize environment
asd env init

# 2. Create kind cluster + load images + deploy (if not already running)
asd run quickstart

# 3. Run docs demo (builds container, connects to K8s tunnel via SSH)
asd run docs

# 4. Open in browser (no /etc/hosts needed — .localhost resolves per RFC 6761)
#    https://docs.tunnel.localhost:30443
```

**Verify (in another terminal):**

```bash
# HTTPS through in-cluster Caddy sidecar
curl -sk https://docs.tunnel.localhost:30443/ | grep -o "docsify"

# HTTP through tunnel (direct, bypassing Caddy)
curl -sf -H "Host: docs.tunnel.local" http://127.0.0.1:30080/ | grep -o "docsify"

# Markdown loading through tunnel
curl -sf -H "Host: docs.tunnel.local" http://127.0.0.1:30080/README.md | head -1
```

Ctrl+C stops the Docker container. No `/etc/hosts` needed — `.localhost` resolves to 127.0.0.1 per RFC 6761.

## Architecture

```
SSH Client ──(30022)── NodePort ── StatefulSet (3 pods) ── NATS cluster
HTTP Client ─(30080)── NodePort ── HTTP muxer ── SSH channel ── backend
```

Each tunnel pod runs SSH (port 2222) and an HTTP muxer (port 8081). Pods discover each other via NATS over a headless service. When an HTTP request arrives for a tunnel on a different pod, NATS routes the lookup and the request is proxied cross-pod.

See [docs/architecture.md](docs/architecture.md) for the full component diagram and data flow.

## Available Commands

All commands are available via `asd run <task>` or `just <task>`.

### Cluster Lifecycle

| Command | Description |
|---------|-------------|
| `asd run quickstart` | Create kind cluster + deploy minimal overlay |
| `asd run quickstart-full` | Create kind cluster + deploy file-auth (3 replicas, NATS) |
| `asd run teardown` | Delete the kind cluster |
| `asd run status` | Show pods, services, and port reachability |

### Demo

| Command | Description |
|---------|-------------|
| `asd run docs` | Containerized docs demo: asd-tunnel client → K8s tunnel → in-cluster Caddy TLS |

### Build & Deploy

| Command | Description |
|---------|-------------|
| `asd run build` | Build validation-server and key-validator images |
| `asd run deploy` | Deploy the overlay specified by `$OVERLAY` env var |
| `asd run validate` | Verify all 7 Kustomize overlays build correctly |

### Tunnels

| Command | Description |
|---------|-------------|
| `asd run tunnel` | Create SSH tunnel to validation-server |
| `asd run tunnel-auth` | Create SSH tunnel with demo key (file-auth overlay) |
| `asd run tunnel-client` | Create tunnel with asd-tunnel client (auto-reconnect) |

### Benchmarks

| Command | Description |
|---------|-------------|
| `asd run bench` | Built-in benchmark: roundtrip + payload + concurrent |
| `asd run bench-roundtrip` | 100 UUID header echo requests |
| `asd run bench-payload` | 12MB + 25MB upload + 1MB download (SHA-256) |
| `asd run bench-concurrent` | 20 parallel requests, isolation check |
| `asd run bench-cross-pod` | NATS routing verification (requires 3 replicas) |
| `asd run bench-stress` | 100 concurrent tunnels, sustained load, zero-downtime assertion |

### Security Tests

| Command | Description |
|---------|-------------|
| `asd run bench-auth` | File-auth: valid/invalid/nokey/RSA/revoked key tests |
| `asd run bench-auth-http` | HTTP auth: approve/reject/fail-closed tests |
| `asd run bench-resilience` | Pod failure recovery via NATS re-routing |
| `asd run bench-resource-limits` | Resource pressure: 200 tunnels, recovery verification |

### Rolling Upgrades

| Command | Description |
|---------|-------------|
| `asd run rolling-upgrade` | Trigger rollout restart + verify tunnel survives |
| `asd run rolling-upgrade-full` | Full upgrade test with continuous monitoring |

## Deployment Modes

All modes use [Kustomize](https://kustomize.io/) overlays on a common base.

| Overlay | Replicas | Auth | Extras |
|---------|----------|------|--------|
| `minimal` | 1 | None | Simplest setup (auth disabled for local dev) |
| `file-auth` | 3 | SSH public keys | ConfigMap with `.pub` files |
| `http-auth` | 3 | HTTP validator | Key validation service |
| `with-caddy` | 3 | None | Caddy sidecar with TLS (HTTPS on 30443) |
| `with-caddy-noauth` | 3 | None | Caddy sidecar with TLS, auth disabled (docs demo) |
| `rolling-upgrade` | 3 | SSH public keys | PDB (minAvailable: 2) |
| `airgap` | 3 | SSH public keys | Internal registry + imagePullSecrets |

Deploy a specific overlay:

```bash
OVERLAY=file-auth asd run deploy
```

## Benchmarks

The benchmark suite validates correctness through the tunnel:

| Test | What it validates |
|------|-------------------|
| **roundtrip** | 100 requests with unique UUIDs echoed back |
| **payload** | 12MB + 25MB SHA-256 integrity verification |
| **concurrent** | 20 parallel requests, no cross-contamination |
| **cross-pod** | NATS routing: tunnel on pod-0 accessible from all pods |
| **stress** | 100 concurrent tunnels, sustained load, p50/p95/p99 latency, zero-downtime |
| **auth** | Valid/invalid/revoked key acceptance/rejection |
| **resilience** | Pod failure recovery via NATS re-routing |
| **resource-limits** | Memory pressure, OOM recovery, post-pressure health |

Results are written to `results.json`. See [docs/benchmarking.md](docs/benchmarking.md).

## Rolling Upgrades

Verify zero-downtime upgrades with continuous availability monitoring:

```bash
asd run quickstart-full               # 3 replicas with PDB
asd run tunnel-auth                   # Tunnel with demo key (separate terminal)
asd run rolling-upgrade               # Trigger restart + verify
```

See [docs/rolling-upgrade.md](docs/rolling-upgrade.md).

## Authentication

Two modes for controlling tunnel access:

- **File-based**: Mount `.pub` files via ConfigMap. Simple, no external dependencies. See [docs/authentication.md](docs/authentication.md#file-based-authentication).
- **HTTP-based**: Delegate to an HTTP validator service. Matches production pattern (Supabase API). See [docs/authentication.md](docs/authentication.md#http-based-authentication).

## Repository Structure

```
k8s/
  base/                    # StatefulSet, services, NetworkPolicy, ServiceAccount
  components/              # Reusable components (validation-server)
  overlays/                # Deployment configurations (7 overlays)
services/
  docs-server/             # Docsify SPA + Python server + asd-tunnel client (Alpine container)
  validation-server/       # Go echo server for benchmarks (~5MB image)
  key-validator/           # Node.js SSH key validator for http-auth
scripts/
  setup-cluster.sh         # Create kind cluster
  export-images.sh         # Export images for air-gapped deployment
  benchmark/               # Benchmark + security test suite
  rolling-upgrade/         # Upgrade testing
docs/                      # Architecture, auth, benchmarking, air-gap, production
```

## Prerequisites

- Docker
- [kind](https://kind.sigs.k8s.io/) (or minikube/k3s)
- kubectl
- SSH client
- [ASD CLI](https://github.com/asd-engineering/asd-cli) (`asd run` task runner)
- jq (for benchmark result parsing)
- [asd-tunnel](https://github.com/asd-engineering/asd-cli) (optional, for `asd run tunnel-client`)

## Image

The tunnel image is configured via `TUNNEL_IMAGE` in `tpl.env` (default: `ghcr.io/asd-engineering/asd-tunnel:latest`).

For kind clusters, `asd run quickstart` handles pulling, tagging, and loading the image automatically. The StatefulSet uses `asd-tunnel:k8s-demo` with `imagePullPolicy: IfNotPresent` so kind uses the pre-loaded image.

## Documentation

| Guide | Description |
|-------|-------------|
| [Architecture](docs/architecture.md) | Component diagram and data flow |
| [Authentication](docs/authentication.md) | File-auth and HTTP-auth setup |
| [Benchmarking](docs/benchmarking.md) | Test suite details and results |
| [Rolling Upgrades](docs/rolling-upgrade.md) | Zero-downtime upgrade procedure |
| [Air-Gap Deployment](docs/airgap-deployment.md) | Offline environment setup |
| [Production Deployment](docs/production-deployment.md) | Capacity planning, monitoring, DR |

## License

MIT
