# Production Deployment Guide

This guide covers what's needed to move from this reference/demo deployment to a production tunnel infrastructure.

## What This Demo Provides vs. Production Requirements

| Capability | Demo Status | Production Requirement |
|-----------|-------------|----------------------|
| Functional tunneling | Included | Included |
| NATS cross-pod routing | Included | Included |
| File-based SSH auth | Included | Included (or HTTP auth) |
| HTTP-based SSH auth | Included | Included (integrate with your IdP) |
| SecurityContext (non-root, read-only) | Included | Included |
| NetworkPolicy (default-deny) | Included | Tighten to cluster CIDR ranges |
| Pod Security Standards (restricted) | Included | Included |
| Rolling upgrades (zero-downtime) | Included | Included |
| Air-gap image distribution | Included | Included |
| TLS termination | Demo (Caddy sidecar) | cert-manager + Ingress |
| Monitoring / Alerting | Not included | Prometheus + Grafana |
| SIEM / Audit logging | Not included | Organization-specific |
| Helm chart | Not included | Recommended for enterprise |
| HPA autoscaling | Not included | Cluster-specific |
| Multi-cluster | Not included | Architecture decision |

## Capacity Planning

### Resource Requirements Per Pod

| Component | CPU Request | CPU Limit | Memory Request | Memory Limit |
|-----------|-----------|-----------|---------------|-------------|
| asd-tunnel | 5m | 200m | 16Mi | 188Mi |
| validation-server | 5m | 100m | 8Mi | 32Mi |
| key-validator | 5m | 100m | 16Mi | 64Mi |
| caddy (sidecar) | 5m | 100m | 12Mi | 64Mi |

### Sizing Guidelines

Based on stress testing (100 concurrent tunnels per 3-pod cluster, ~415 req/s):

| Scale | Developers | Concurrent Tunnels | Recommended Replicas | Memory per Pod | Total Memory |
|-------|-----------|-------------------|---------------------|---------------|-------------|
| Small | 1-50 | ~50 | 3 | 188Mi | ~564Mi |
| Medium | 50-200 | ~200 | 5 | 256Mi | ~1.3Gi |
| Large | 200-500 | ~500 | 8 | 384Mi | ~3Gi |
| Enterprise | 500-2000 | ~2000 | 15 | 512Mi | ~7.5Gi |

**Key sizing factors:**

- Each SSH tunnel consumes ~1-2Mi of memory on the server
- NATS cluster overhead is ~20-30Mi per pod
- GOMEMLIMIT should be set to ~85% of the memory limit
- CPU is not typically the bottleneck; tunnels are I/O-bound

### Node Requirements

- **CPU**: 2 cores minimum per node, 4 recommended
- **Memory**: Tunnel pods are memory-bound. Plan for pod memory limit * replicas * 1.5 (headroom)
- **Network**: 1Gbps minimum. Tunnel throughput is bounded by network I/O
- **Disk**: Minimal — tunnel server is stateless. 10Gi per node for logs/tmp

### NATS Cluster Sizing

- Up to 10 replicas: single NATS cluster works well
- 10-30 replicas: consider NATS super-clusters or leaf nodes
- 30+ replicas: contact ASD Engineering for architecture guidance

## Monitoring Integration

### Recommended Stack

- **Prometheus** for metrics collection
- **Grafana** for dashboards
- **AlertManager** for incident notification

### Key Metrics to Monitor

| Metric | Source | Alert Threshold |
|--------|--------|----------------|
| Active tunnel count | Tunnel server logs (JSON) | > 80% of capacity |
| SSH connection errors | Tunnel server logs | > 5% error rate |
| Pod restart count | `kube_pod_container_status_restarts_total` | > 0 in 5 min |
| Memory usage | `container_memory_working_set_bytes` | > 85% of limit |
| NATS message latency | NATS server metrics | p99 > 100ms |
| HTTP muxer response time | Tunnel server logs | p99 > 500ms |
| Pod readiness | `kube_pod_status_ready` | Any pod not ready > 30s |

### Structured Logging

The tunnel server outputs JSON logs when `ASD_TUNNEL_LOG_JSON=true`:

```json
{"level":"info","msg":"tunnel created","subdomain":"app","remote_addr":"10.0.0.1:54321","time":"2025-01-01T00:00:00Z"}
{"level":"info","msg":"tunnel closed","subdomain":"app","duration":"3600s","time":"2025-01-01T01:00:00Z"}
```

Forward these to your SIEM/log aggregation platform for:
- Audit trail (who created which tunnel, when)
- Security monitoring (unusual connection patterns)
- Capacity trending (tunnel creation/deletion rates)

## TLS Configuration

### Demo: Caddy Sidecar (Included)

The `with-caddy` overlay adds Caddy as a sidecar with `tls internal` for automatic TLS termination. Accessible at `https://*.tunnel.localhost:30443` — no `/etc/hosts` needed. Suitable for testing but not production (uses Caddy's self-signed internal CA).

### Production: cert-manager + Ingress

```yaml
# 1. Install cert-manager
# 2. Create a ClusterIssuer (e.g., Let's Encrypt or internal CA)
# 3. Create an Ingress resource:

apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: asd-tunnel
  namespace: asd-tunnel-demo
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  tls:
    - hosts:
        - "*.tunnel.company.com"
      secretName: tunnel-tls
  rules:
    - host: "*.tunnel.company.com"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: asd-tunnel-http
                port:
                  number: 8081
```

### Internal mTLS (NATS)

For encrypted inter-pod NATS traffic:

```yaml
env:
  - name: ASD_TUNNEL_NATS_TLS_CERT
    value: /etc/nats/tls/tls.crt
  - name: ASD_TUNNEL_NATS_TLS_KEY
    value: /etc/nats/tls/tls.key
  - name: ASD_TUNNEL_NATS_TLS_CA
    value: /etc/nats/tls/ca.crt
```

Generate certificates with cert-manager Certificate resources.

## Disaster Recovery

### Pod Failure

**Automatic recovery**: StatefulSet controller recreates deleted pods. NATS re-routes tunnel traffic to surviving pods.

**Manual intervention needed if**: All pods are down simultaneously (check persistent storage, node health, resource quotas).

```bash
# Check pod status
kubectl get pods -n asd-tunnel-demo -o wide

# Check events for error details
kubectl get events -n asd-tunnel-demo --sort-by='.lastTimestamp'

# Force recreate all pods
kubectl rollout restart statefulset/asd-tunnel -n asd-tunnel-demo
```

### NATS Split-Brain

If NATS cluster loses quorum (e.g., 2 of 3 pods isolated):

```bash
# Check NATS cluster health from inside a pod
kubectl exec -n asd-tunnel-demo asd-tunnel-0 -- \
  wget -qO- http://localhost:8222/routez 2>/dev/null || echo "NATS monitoring not enabled"

# Force restart to re-form cluster
kubectl rollout restart statefulset/asd-tunnel -n asd-tunnel-demo
kubectl rollout status statefulset/asd-tunnel -n asd-tunnel-demo --timeout=180s
```

### Full Cluster Recovery

```bash
# 1. Verify namespace exists
kubectl get ns asd-tunnel-demo

# 2. Re-apply manifests
kubectl apply -k k8s/overlays/<your-overlay>

# 3. Wait for rollout
kubectl rollout status statefulset/asd-tunnel -n asd-tunnel-demo --timeout=300s

# 4. Verify health
kubectl get pods -n asd-tunnel-demo
# All pods should be Running and Ready
```

### Backup & Restore

The tunnel server is **stateless** — there is nothing to back up except:

1. **SSH public keys** (in ConfigMap `tunnel-pubkeys` for file-auth)
2. **Kubernetes manifests** (in Git)
3. **Custom configuration** (environment variables in overlay patches)

All state is reconstructed from Git manifests. Tunnels are ephemeral — clients reconnect automatically.

## Security Hardening Checklist

- [x] Pods run as non-root (uid 65534)
- [x] Read-only root filesystem
- [x] All capabilities dropped
- [x] Seccomp profile: RuntimeDefault
- [x] ServiceAccount tokens not mounted
- [x] NetworkPolicy: default-deny with explicit allows
- [x] Pod Security Standards: restricted
- [x] Authentication enabled by default
- [x] Private SSH key not in Git
- [ ] TLS on all external traffic (requires cert-manager)
- [ ] NATS TLS between pods (requires cert-manager)
- [ ] Image digest pinning (set in kustomization.yaml)
- [ ] Image signing verification (cosign/notation)
- [ ] Rate limiting on SSH connections (not yet supported in tunnel server)
- [ ] Audit log forwarding to SIEM
- [ ] Secret rotation procedures for SSH keys
