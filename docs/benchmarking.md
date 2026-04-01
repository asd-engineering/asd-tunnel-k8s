# Benchmarking

The benchmark suite validates tunnel correctness and reliability across several dimensions.

## Running

```bash
# All tests
./scripts/benchmark/run-all.sh app

# Individual tests
./scripts/benchmark/test-roundtrip.sh app
./scripts/benchmark/test-payload.sh app
./scripts/benchmark/test-concurrent.sh app
./scripts/benchmark/test-cross-pod.sh app
```

## Tests

### Roundtrip (`test-roundtrip.sh`)

Validates that HTTP headers pass through the tunnel without corruption.

- Sends 100 sequential requests with unique `X-Request-ID` UUIDs
- Verifies each response echoes the exact UUID in the JSON body
- Detects: header dropping, header rewriting, request misrouting

**Pass criteria**: All 100 UUIDs match.

### Payload Integrity (`test-payload.sh`)

Validates that large request/response bodies pass through the tunnel intact.

**Upload test**:
- Generates 12MB and 25MB random payloads
- Computes SHA-256 locally
- POSTs each payload through the tunnel to `/hash`
- Validates the server's computed SHA-256 matches

**Download test**:
- Requests a 1MB deterministic payload via `/payload/1048576`
- The server sends the payload with a pre-computed `X-Payload-SHA256` header
- Validates the downloaded data's hash matches

**Detects**: data corruption, truncation, buffering issues, chunked transfer encoding bugs.

### Concurrency (`test-concurrent.sh`)

Validates request isolation under parallel load.

- Launches 20 parallel `curl` processes
- Each sends a unique UUID via `X-Request-ID`
- Validates each response contains only its own UUID
- Detects: request cross-contamination, shared state leaks, connection pooling bugs

**Pass criteria**: All 20 responses contain the correct UUID.

### Cross-Pod (`test-cross-pod.sh`)

Validates NATS-based tunnel routing across StatefulSet pods.

- Requires a 3-replica deployment (file-auth or rolling-upgrade overlay)
- Tunnel is created via SSH (connects to one pod)
- `kubectl exec` into each pod and curls `localhost:8081` with the tunnel's `Host` header
- The pod that owns the tunnel serves directly; other pods route via NATS

**Pass criteria**: All 3 pods can serve the tunnel's traffic.

## Results

`run-all.sh` produces a `results.json` file:

```json
{
  "timestamp": "2026-04-01T12:00:00Z",
  "tests": [
    {"name": "roundtrip", "status": "pass", "details": {"total": 100, "passed": 100}},
    {"name": "payload", "status": "pass", "details": {"sizes": [{"mb": 12, "match": true}]}},
    {"name": "concurrent", "status": "pass", "details": {"concurrency": 20, "passed": 20}},
    {"name": "cross_pod", "status": "pass", "details": {"pods": 3, "accessible": 3}}
  ],
  "summary": {"total": 4, "passed": 4, "failed": 0}
}
```

## Configuration

Environment variables for customizing tests:

| Variable | Default | Description |
|----------|---------|-------------|
| `TUNNEL_DOMAIN` | `tunnel.local` | Tunnel domain for Host headers |
| `TUNNEL_HTTP_PORT` | `30080` | NodePort for HTTP access |
| `TUNNEL_SSH_PORT` | `30022` | NodePort for SSH |
| `TUNNEL_HOST` | `localhost` | Host to connect to |
| `NAMESPACE` | `asd-tunnel-demo` | Kubernetes namespace (cross-pod test) |

## Interpreting Failures

| Test | Failure | Likely Cause |
|------|---------|-------------|
| roundtrip | UUID mismatch | Proxy rewriting headers, or tunnel routing to wrong backend |
| payload | Hash mismatch | Data corruption in transit, chunked encoding issue |
| concurrent | Cross-contamination | Connection pooling bug, shared state leak |
| cross-pod | Pod unreachable | NATS not connected, or tunnel registered on wrong pod |
