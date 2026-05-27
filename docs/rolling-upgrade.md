# Rolling Upgrades

The `rolling-upgrade` overlay demonstrates zero-downtime upgrades of the tunnel cluster.

## Overview

With 3 replicas, a PodDisruptionBudget (`minAvailable: 2`), and the StatefulSet's `maxUnavailable: 1` update strategy, Kubernetes upgrades one pod at a time while maintaining tunnel availability.

## How It Works

1. **PDB enforcement**: Kubernetes won't evict a pod if it would bring available replicas below 2
2. **Ordered rolling update**: Pods are updated in reverse ordinal order (pod-2, then pod-1, then pod-0)
3. **preStop hook**: Each pod sleeps 5 seconds before termination, allowing in-flight requests to complete
4. **Readiness probe**: New pods must pass TCP probe on port 2222 before receiving traffic
5. **NATS re-clustering**: Restarted pods rejoin the NATS cluster automatically via stable DNS

## Running the Test

### Prerequisites

- 3-replica deployment with a tunnel already established
- `jq` installed for results parsing

### Deploy and Create Tunnel

```bash
# Deploy the rolling-upgrade overlay
OVERLAY=rolling-upgrade asd run deploy

# Create a tunnel (in a separate terminal)
asd run tunnel-auth
```

### Run the Upgrade Test

```bash
./scripts/rolling-upgrade/run-upgrade.sh app
```

This will:
1. Verify the current deployment is healthy
2. Verify the tunnel is accessible
3. Start a background monitor (probing every 500ms)
4. Trigger `kubectl rollout restart`
5. Wait for rollout completion
6. Stop the monitor and analyze results

### Output

```
============================================
  Rolling Upgrade Report
============================================
  Total probes:      120
  Successful:        120
  Failed:            0
  Success rate:      100%
  Avg latency:       45ms
  Max latency:       230ms
  Zero downtime:     true
============================================
```

## Monitor Details

The `monitor.sh` script runs as a background process:

- Sends HTTP requests every 500ms to the tunnel endpoint
- Records timestamp, HTTP status code, and latency for each probe
- Writes a JSON log file for post-analysis

You can also run it standalone:

```bash
# Start monitoring
./scripts/rolling-upgrade/monitor.sh app monitor.log &
MONITOR_PID=$!

# ... perform operations ...

# Stop and view results
kill $MONITOR_PID
cat monitor.log | jq .
```

## Interpreting Results

| Metric | Good | Concerning |
|--------|------|-----------|
| Success rate | 100% | < 99% |
| Max gap | 0 probes | > 3 probes (1.5s gap) |
| Max latency | < 500ms | > 2000ms |

### Common Issues

**Some probes fail during restart**: The SSH tunnel may disconnect if the pod it connected to is restarted. Re-create the tunnel after the pod comes back, or connect to a pod that isn't being restarted.

**High latency spikes**: During NATS re-clustering, tunnel lookups may take slightly longer. This is transient and resolves once the cluster stabilizes.

**Tunnel completely drops**: If the tunnel was connected to a pod that gets restarted, the SSH connection closes. For true zero-downtime, establish tunnels to multiple pods or use the tunnel's reconnect logic.
