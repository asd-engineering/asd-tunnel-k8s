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

## High Availability

Every pod can serve any tunnel's HTTP requests — either directly (local) or via cross-pod proxy. This means the cluster acts as a built-in load balancer at the application layer.

### How Any Pod Serves Any Tunnel

```
                        ┌───────────────────────┐
                        │   curl myapp.tunnel.io │
                        └───────────┬───────────┘
                                    │
                         ┌──────────▼──────────┐
                         │   K8s Service        │
                         │   (NodePort :30080)  │
                         │   picks random pod   │
                         └──────────┬───────────┘
                                    │
               ┌────────────────────┼────────────────────┐
               ▼                    ▼                     ▼
          ┌─────────┐         ┌─────────┐           ┌─────────┐
          │  Pod-0  │         │  Pod-1  │           │  Pod-2  │
          │  :8081  │         │  :8081  │           │  :8081  │
          └────┬────┘         └────┬────┘           └────┬────┘
               │                   │                     │
        ┌──────┴──────┐     ┌──────┴──────┐       ┌──────┴──────┐
        │ HTTP Muxer  │     │ HTTP Muxer  │       │ HTTP Muxer  │
        │ Host lookup │     │ Host lookup │       │ Host lookup  │
        └──┬───────┬──┘     └─────────────┘       └─────────────┘
           │       │
      LOCAL?    NOT LOCAL?
        │          │
        ▼          ▼
   ┌────────┐  ┌──────────────────────────┐
   │ Direct │  │  NATS Registry Lookup    │
   │ proxy  │  │  cache → PodIP           │
   │ to SSH │  └───────────┬──────────────┘
   │channel │              │
   └───┬────┘         proxyToPod()
       │           (HTTP → PodIP:8081)
       ▼                   │
   ┌────────┐              ▼
   │Backend │          That pod handles
   │Service │          it as LOCAL
   └────────┘
```

The K8s Service has no knowledge of which pod owns which tunnel. All routing intelligence lives inside the pods via NATS pub/sub.

### Graceful Drain (Rolling Updates) — Zero Downtime

During rolling updates, pods shut down gracefully. The client reconnects to a surviving pod before the old pod is fully terminated.

```
t=0s   K8s sends SIGTERM to Pod-2
       │
       ├─ Pod-2 marks itself as "draining"
       ├─ Pod-2 closes SSH listener (:2222)
       └─ Readiness probe fails → K8s stops routing NEW traffic here

t=1s   Pod-2 publishes NATS "unregister" for all its tunnels
       └─ Pod-0 and Pod-1 remove Pod-2 entries from their cache

t=2s   Pod-2 sends SSH "disconnect" to all connected clients
       └─ Clients reconnect IMMEDIATELY (no 30s TCP timeout wait)

t=3s   Client reconnects → K8s routes to Pod-0 or Pod-1
       └─ Re-registers tunnel → NATS "register" published
       └─ All pods know the tunnel's new location

t=5s   Pod-2 fully shut down. No requests lost.
```

**Key design:** The server sends an explicit SSH disconnect message so the client reconnects instantly instead of waiting for TCP keepalive to detect the dead connection.

### Hard-Kill Recovery (Pod Crash / OOMKill)

When a pod dies unexpectedly (SIGKILL, OOM, node failure), there is no graceful shutdown — no unregister events are sent. The system self-heals through two parallel mechanisms:

```
t=0s   Pod-2 killed instantly (no cleanup)
       ├─ NATS cache on Pod-0/Pod-1 still says "Pod-2 owns myapp"  (STALE)
       └─ SSH client's TCP connection receives RST

CLIENT RECOVERY (restores the tunnel):

t=1s   Client detects disconnect → exponential backoff (~1s first attempt)
t=2s   Client reconnects to K8s Service → lands on Pod-0 or Pod-1
       └─ Re-registers tunnel on new pod → NATS "register" published

HTTP RECOVERY (serves requests during the gap):

t=3s   HTTP request arrives at Pod-1 for myapp.tunnel.io
       ├─ Pod-1 local lookup: NOT HERE
       ├─ Pod-1 NATS cache: "Pod-2 owns it" (stale!)
       ├─ Pod-1 proxyToPod(Pod-2) → TIMEOUT after 3 seconds
       │
       ├─ Pod-1 deletes stale cache entry
       ├─ Pod-1 broadcasts: "who has myapp?" (NATS request/reply)
       ├─ Pod-0 responds: "I have it now!"
       └─ Pod-1 retries proxyToPod(Pod-0) → SUCCESS
```

| Scenario | Downtime | Mechanism |
|----------|----------|-----------|
| Rolling update (graceful) | **0** | SSH disconnect → instant client reconnect |
| Pod crash (hard kill) | **~3-5s** (first request only) | NATS retry: timeout → fresh lookup → re-proxy |
| Node failure | **~3-5s** + client reconnect | Same as hard kill, plus client finds new pod |

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
