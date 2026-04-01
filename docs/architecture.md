# Architecture

## Overview

ASD Tunnel on Kubernetes uses a StatefulSet with embedded NATS clustering for cross-pod tunnel routing. Each pod runs an `asd-tunnel` instance that handles SSH connections (tunnel creation) and HTTP requests (tunnel access).

## Component Diagram

```
                     ┌─── Kubernetes Cluster ────────────────────────┐
                     │                                               │
SSH Client ──(30022)─┤  NodePort Service (SSH)                       │
  ssh -R app:80:...  │    → asd-tunnel StatefulSet (3 replicas)      │
                     │       pod-0 ←──NATS 6222──→ pod-1 ←→ pod-2   │
                     │                                               │
HTTP Client ─(30080)─┤  NodePort Service (HTTP)                      │
  curl app.tunnel.lo │    → asd-tunnel :8081 (HTTP muxer)            │
                     │      ↓ looks up host in local state or NATS   │
                     │      ↓ proxies via SSH channel to backend     │
                     │                                               │
                     │  [with-caddy overlay]                         │
HTTP Client ─(30443)─┤  Caddy sidecar (tls internal :8443)           │
                     │    → asd-tunnel :8081 (Host rewrite)          │
                     │    *.tunnel.localhost → *.tunnel.local         │
                     │                                               │
                     │  Validation Server (ClusterIP :8080)          │
                     │    echo/hash/payload endpoints for benchmarks │
                     │                                               │
                     │  Key Validator (ClusterIP :3000) [http-auth]  │
                     │    ED25519 SSH key validation endpoint        │
                     └───────────────────────────────────────────────┘
```

## Data Flow

### Tunnel Creation (SSH)

1. Client connects via SSH to any tunnel pod (NodePort 30022)
2. The pod registers the subdomain in its local tunnel state
3. If NATS is enabled, the registration is published to `tunnel.register.<subdomain>`
4. All pods in the cluster now know which pod owns the tunnel

### HTTP Request Routing

1. HTTP request arrives at any pod's HTTP muxer (port 8081)
2. The muxer extracts the `Host` header to determine the subdomain
3. **Local lookup**: If the tunnel is on this pod, proxy directly via the SSH channel
4. **NATS lookup**: If the tunnel is on another pod, query `tunnel.lookup.<subdomain>` via NATS
5. The owning pod responds with its pod IP
6. The requesting pod proxies the HTTP request to the owning pod

### NATS Subjects

| Subject | Purpose |
|---------|---------|
| `tunnel.register.<subdomain>` | Announce new tunnel registration |
| `tunnel.deregister.<subdomain>` | Announce tunnel teardown |
| `tunnel.lookup.<subdomain>` | Request-reply to find tunnel owner |
| `tunnel.heartbeat` | Periodic cluster health |

## StatefulSet Design

The StatefulSet provides:

- **Stable DNS names**: `asd-tunnel-{0,1,2}.asd-tunnel-nats.asd-tunnel-demo.svc.cluster.local`
- **Ordered startup**: NATS peers can reference each other by DNS before all pods are ready (NATS tolerates missing peers)
- **Rolling updates**: `maxUnavailable: 1` ensures at most one pod is down during upgrades

## Resource Allocation

| Container | CPU (req/limit) | Memory (req/limit) |
|-----------|----------------|-------------------|
| asd-tunnel | 5m / 200m | 16Mi / 188Mi |
| caddy (optional) | 5m / 100m | 12Mi / 64Mi |
| validation-server | 5m / 100m | 8Mi / 32Mi |
| key-validator | 5m / 100m | 16Mi / 64Mi |

## Networking

| Port | Service | Protocol | Purpose |
|------|---------|----------|---------|
| 30022 | NodePort | TCP/SSH | Tunnel creation |
| 30080 | NodePort | TCP/HTTP | Tunnel access (direct) |
| 30443 | NodePort | TCP/HTTPS | Tunnel access (via Caddy, tls internal) |
| 2222 | Pod | TCP/SSH | asd-tunnel SSH listener |
| 8081 | Pod | TCP/HTTP | asd-tunnel HTTP muxer |
| 4222 | Pod | TCP | NATS client connections |
| 6222 | Pod | TCP | NATS cluster peering |
| 8080 | ClusterIP | TCP/HTTP | Validation server |
| 3000 | ClusterIP | TCP/HTTP | Key validator |
