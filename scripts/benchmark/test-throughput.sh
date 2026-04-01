#!/usr/bin/env bash
# Throughput benchmark: data integrity at scale.
#
# Creates N tunnels, then sends M requests per tunnel — each request
# carries a binary payload verified via SHA-256. Proves the tunnel passes
# body bytes correctly under sustained parallel load.
#
# Usage:
#   ./test-throughput.sh [options]
#
# Options:
#   --tunnels N       Number of tunnels (default: 100)
#   --requests N      Requests per tunnel (default: 200)
#   --payload N       Payload size in KB (default: 250)
#   --workers N       Parallel worker count (default: 50)
#   --replicas N      Scale StatefulSet to N pods before test (default: keep current)
#   --memory SIZE     Set pod memory limit (e.g., 256Mi) before test (default: keep current)
#   --cpu SIZE        Set pod CPU limit (e.g., 500m, 1000m) before test (default: keep current)
#   --fresh           Restart pods before test (clears stale registrations)
#   --help            Show this help
#
# Examples:
#   ./test-throughput.sh --tunnels 100 --requests 200 --payload 10
#   ./test-throughput.sh --tunnels 1000 --requests 100 --payload 250 --workers 50
#   ./test-throughput.sh --tunnels 1000 --payload 500 --replicas 5 --memory 256Mi --cpu 1000m --fresh
#
# Environment variables (override defaults):
#   TUNNEL_HOST       SSH host (default: 127.0.0.1)
#   TUNNEL_SSH_PORT   SSH NodePort (default: 30022)
#   TUNNEL_HTTP_PORT  HTTP NodePort (default: 30080)
#   TUNNEL_DOMAIN     Tunnel domain (default: tunnel.local)
#   SSH_KEY           Path to SSH private key (default: auto-detect)
#   LOCAL_PORT        Backend port (default: 18080)
#   NAMESPACE         Kubernetes namespace (default: asd-tunnel-demo)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# ─── Parse arguments ──────────────────────────────────────────────────────────

TUNNEL_COUNT=100
REQUESTS_PER=200
PAYLOAD_KB=250
PARALLEL_WORKERS=50
REPLICAS=""
MEMORY=""
CPU=""
FRESH=false

while [ $# -gt 0 ]; do
  case "$1" in
    --tunnels)    TUNNEL_COUNT="$2"; shift 2 ;;
    --requests)   REQUESTS_PER="$2"; shift 2 ;;
    --payload)    PAYLOAD_KB="$2"; shift 2 ;;
    --workers)    PARALLEL_WORKERS="$2"; shift 2 ;;
    --replicas)   REPLICAS="$2"; shift 2 ;;
    --memory)     MEMORY="$2"; shift 2 ;;
    --cpu)        CPU="$2"; shift 2 ;;
    --fresh)      FRESH=true; shift ;;
    --help|-h)
      sed -n '2,/^set -/{ /^#/s/^# \?//p }' "$0"
      exit 0
      ;;
    # Legacy positional args support
    [0-9]*)
      if [ -z "${_pos1:-}" ]; then _pos1="$1"
      elif [ -z "${_pos2:-}" ]; then _pos2="$1"
      elif [ -z "${_pos3:-}" ]; then _pos3="$1"
      fi
      shift ;;
    *) log_fail "Unknown option: $1"; exit 1 ;;
  esac
done

# Support legacy positional: ./test-throughput.sh 100 200 10
[ -n "${_pos1:-}" ] && TUNNEL_COUNT="$_pos1"
[ -n "${_pos2:-}" ] && REQUESTS_PER="$_pos2"
[ -n "${_pos3:-}" ] && PAYLOAD_KB="$_pos3"

LOCAL_PORT="${LOCAL_PORT:-18080}"
SSH_HOST="${TUNNEL_HOST:-127.0.0.1}"
SSH_PORT="${TUNNEL_SSH_PORT:-30022}"
NAMESPACE="${NAMESPACE:-asd-tunnel-demo}"

PAYLOAD_BYTES=$((PAYLOAD_KB * 1024))
TOTAL_REQUESTS=$((TUNNEL_COUNT * REQUESTS_PER))

KEY_DIR="$(cd "$SCRIPT_DIR/../../k8s/overlays/file-auth/ssh-keys" && pwd)"
AUTH_KEY="${SSH_KEY:-$KEY_DIR/demo}"

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ServerAliveInterval=10
  -o ServerAliveCountMax=3
)

if [ -f "$AUTH_KEY" ]; then
  SSH_OPTS+=(-o IdentitiesOnly=yes -i "$AUTH_KEY")
  log_info "Using SSH key: $AUTH_KEY"
else
  log_info "No SSH key found — running without auth (minimal overlay only)"
fi

WORK_DIR=$(mktemp -d)
TUNNEL_PIDS=()
PF_PID=""

cleanup() {
  echo ""
  log_info "Cleaning up ${#TUNNEL_PIDS[@]} tunnels..."
  [ -n "${RESOURCE_MONITOR_PID:-}" ] && kill "$RESOURCE_MONITOR_PID" 2>/dev/null
  for pid in "${TUNNEL_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null
  wait 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

# ─── Pre-test cluster adjustments ─────────────────────────────────────────────

if [ -n "$REPLICAS" ]; then
  current=$(kubectl get statefulset asd-tunnel -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
  if [ "$current" != "$REPLICAS" ]; then
    log_info "Scaling StatefulSet from $current to $REPLICAS replicas..."
    kubectl scale statefulset asd-tunnel -n "$NAMESPACE" --replicas="$REPLICAS"
    kubectl rollout status statefulset/asd-tunnel -n "$NAMESPACE" --timeout=180s
    log_info "  Scaled to $REPLICAS replicas"
  fi
fi

# Build patches array (apply memory + cpu in a single patch to avoid double rollout)
PATCHES=""
if [ -n "$MEMORY" ]; then
  PATCHES="${PATCHES}{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources/limits/memory\",\"value\":\"$MEMORY\"},"
fi
if [ -n "$CPU" ]; then
  PATCHES="${PATCHES}{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources/limits/cpu\",\"value\":\"$CPU\"},"
fi
if [ -n "$PATCHES" ]; then
  PATCHES="[${PATCHES%,}]"  # strip trailing comma, wrap in array
  log_info "Patching resource limits: ${MEMORY:+memory=$MEMORY }${CPU:+cpu=$CPU}..."
  kubectl patch statefulset asd-tunnel -n "$NAMESPACE" --type='json' -p="$PATCHES"
  kubectl rollout status statefulset/asd-tunnel -n "$NAMESPACE" --timeout=180s
  log_info "  Resource limits updated"
  FRESH=false  # patch already triggers rollout
fi

if [ "$FRESH" = true ]; then
  log_info "Restarting pods (--fresh)..."
  kubectl rollout restart statefulset/asd-tunnel -n "$NAMESPACE"
  kubectl rollout status statefulset/asd-tunnel -n "$NAMESPACE" --timeout=180s
  log_info "  Pods restarted"
fi

# ─── Gather cluster info ──────────────────────────────────────────────────────

POD_COUNT=$(kubectl get statefulset asd-tunnel -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
POD_MEMORY=$(kubectl get statefulset asd-tunnel -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}')
POD_CPU=$(kubectl get statefulset asd-tunnel -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}')

# ─── Start local backend ─────────────────────────────────────────────────────
# kubectl port-forward can't handle 1000+ concurrent connections.
# Use a threaded Python HTTP server with the same /health and /hash endpoints.
if ! curl -sf -m 2 "http://localhost:${LOCAL_PORT}/health" >/dev/null 2>&1; then
  log_info "Starting local benchmark backend on port ${LOCAL_PORT}..."
  python3 "$SCRIPT_DIR/local-backend.py" "$LOCAL_PORT" &
  PF_PID=$!
  sleep 1
  if ! curl -sf -m 3 "http://localhost:${LOCAL_PORT}/health" >/dev/null 2>&1; then
    log_fail "Local backend failed to start"
    exit 1
  fi
  log_info "  Backend ready on localhost:${LOCAL_PORT}"
else
  log_info "Backend already reachable on localhost:${LOCAL_PORT}"
fi

echo "═══════════════════════════════════════════════════════════════"
echo "  THROUGHPUT BENCHMARK"
echo "═══════════════════════════════════════════════════════════════"
echo "  Cluster:    $POD_COUNT pods × ${POD_MEMORY} RAM, ${POD_CPU} CPU"
echo "  Tunnels:    $TUNNEL_COUNT"
echo "  Requests:   $REQUESTS_PER per tunnel ($TOTAL_REQUESTS total)"
echo "  Payload:    ${PAYLOAD_KB}KB per request (${PAYLOAD_BYTES} bytes)"
echo "  Workers:    $PARALLEL_WORKERS parallel"
echo "  Data:       $((TOTAL_REQUESTS * PAYLOAD_KB / 1024))MB total through tunnel"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# ─── Generate payload ────────────────────────────────────────────────────────

log_info "Generating ${PAYLOAD_KB}KB test payload..."
dd if=/dev/urandom of="$WORK_DIR/payload.bin" bs=1024 count="$PAYLOAD_KB" 2>/dev/null
EXPECTED_HASH=$(sha256sum "$WORK_DIR/payload.bin" | awk '{print $1}')
log_info "  Payload SHA-256: $EXPECTED_HASH"

# ─── Phase 1: Create tunnels ────────────────────────────────────────────────

log_info "Creating $TUNNEL_COUNT tunnels..."

BATCH_SIZE=25
created=0

for i in $(seq 1 "$TUNNEL_COUNT"); do
  subdomain=$(printf "tp-%03d" "$i")

  ssh "${SSH_OPTS[@]}" \
    -p "$SSH_PORT" \
    -N \
    -R "${subdomain}:80:localhost:${LOCAL_PORT}" \
    "$SSH_HOST" 2>/dev/null &
  TUNNEL_PIDS+=($!)
  created=$((created + 1))

  if [ $((created % BATCH_SIZE)) -eq 0 ]; then
    log_info "  $created/$TUNNEL_COUNT tunnels created..."
    sleep 2
  fi
done
sleep 3

# ─── Phase 2: Verify all tunnels are healthy ────────────────────────────────

log_info "Verifying all $TUNNEL_COUNT tunnels are reachable..."

healthy=0
unhealthy=0

for i in $(seq 1 "$TUNNEL_COUNT"); do
  subdomain=$(printf "tp-%03d" "$i")
  if tunnel_curl "$subdomain" -sf --max-time 5 \
    "$(tunnel_url "$subdomain")/health" >/dev/null 2>&1; then
    healthy=$((healthy + 1))
  else
    unhealthy=$((unhealthy + 1))
  fi

  if [ $((i % 25)) -eq 0 ]; then
    log_info "  Verified $i/$TUNNEL_COUNT ($healthy healthy, $unhealthy failed)"
  fi
done

log_info "  $healthy/$TUNNEL_COUNT tunnels healthy"
if [ "$unhealthy" -gt $((TUNNEL_COUNT / 2)) ]; then
  log_fail "More than 50% unhealthy ($unhealthy/$TUNNEL_COUNT) — aborting"
  exit 1
fi

# ─── Start resource monitor ──────────────────────────────────────────────────

RESOURCE_MONITOR_PID=""
log_info "Starting resource monitor..."

(
  while true; do
    ts=$(date +%s)
    # Pod resource usage
    kubectl top pods -n "$NAMESPACE" -l app=asd-tunnel --no-headers 2>/dev/null | \
      while read -r name cpu mem; do
        echo "$ts pod $name $cpu $mem"
      done >> "$WORK_DIR/resources.log" 2>/dev/null

    # Host-side: SSH process count and total RSS
    ssh_count=$(pgrep -c -f "ssh.*$SSH_PORT" 2>/dev/null || echo 0)
    ssh_rss=$(ps -C ssh -o rss= 2>/dev/null | awk '{sum+=$1} END{printf "%.0f", sum/1024}' 2>/dev/null || echo 0)
    # Host CPU load
    load=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "-")
    echo "$ts host ssh_procs=$ssh_count ssh_rss_mb=$ssh_rss load=$load" >> "$WORK_DIR/resources.log" 2>/dev/null

    sleep 10
  done
) &
RESOURCE_MONITOR_PID=$!

# ─── Phase 3: Throughput test ────────────────────────────────────────────────

log_info "Starting throughput test: $REQUESTS_PER requests × $TUNNEL_COUNT tunnels..."

START_TIME=$(date +%s%N)

# Track results per tunnel
uuid_pass=0
uuid_fail=0
hash_pass=0
hash_fail=0
request_errors=0
latencies_file="$WORK_DIR/latencies.txt"

for batch_start in $(seq 1 "$PARALLEL_WORKERS" "$TUNNEL_COUNT"); do
  batch_end=$((batch_start + PARALLEL_WORKERS - 1))
  [ "$batch_end" -gt "$TUNNEL_COUNT" ] && batch_end="$TUNNEL_COUNT"

  worker_pids=()
  for t in $(seq "$batch_start" "$batch_end"); do
    subdomain=$(printf "tp-%03d" "$t")
    result_file="$WORK_DIR/result-$t"

    (
      local_uuid_pass=0
      local_uuid_fail=0
      local_hash_pass=0
      local_hash_fail=0
      local_errors=0

      for r in $(seq 1 "$REQUESTS_PER"); do
        uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "req-$t-$r")

        req_start=$(date +%s%N)

        # POST payload with UUID header through tunnel
        response=$(tunnel_curl "$subdomain" -sf --max-time 15 \
          -X POST \
          -H "X-Request-ID: $uuid" \
          --data-binary "@$WORK_DIR/payload.bin" \
          "$(tunnel_url "$subdomain")/hash" 2>/dev/null) || {
          local_errors=$((local_errors + 1))
          continue
        }

        req_end=$(date +%s%N)
        latency_ms=$(( (req_end - req_start) / 1000000 ))
        echo "$latency_ms" >> "$WORK_DIR/lat-$t.txt"

        # Verify SHA-256 of payload
        got_hash=$(echo "$response" | jq -r '.sha256 // empty' 2>/dev/null)
        got_size=$(echo "$response" | jq -r '.size // 0' 2>/dev/null)

        if [ "$got_hash" = "$EXPECTED_HASH" ] && [ "$got_size" = "$PAYLOAD_BYTES" ]; then
          local_hash_pass=$((local_hash_pass + 1))
        else
          local_hash_fail=$((local_hash_fail + 1))
        fi

        local_uuid_pass=$((local_uuid_pass + 1))
      done

      echo "$local_uuid_pass $local_uuid_fail $local_hash_pass $local_hash_fail $local_errors" > "$result_file"
    ) &
    worker_pids+=($!)
  done

  for pid in "${worker_pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  printf "\r  Tunnels %d-%d/%d complete" "$batch_start" "$batch_end" "$TUNNEL_COUNT"
done
echo ""

END_TIME=$(date +%s%N)
DURATION_MS=$(( (END_TIME - START_TIME) / 1000000 ))
DURATION_S=$((DURATION_MS / 1000))

# ─── Phase 4: Tally results ─────────────────────────────────────────────────

for t in $(seq 1 "$TUNNEL_COUNT"); do
  if [ -f "$WORK_DIR/result-$t" ]; then
    read -r up uf hp hf err < "$WORK_DIR/result-$t"
    uuid_pass=$((uuid_pass + up))
    uuid_fail=$((uuid_fail + uf))
    hash_pass=$((hash_pass + hp))
    hash_fail=$((hash_fail + hf))
    request_errors=$((request_errors + err))
  else
    request_errors=$((request_errors + REQUESTS_PER))
  fi

  # Merge latency files
  [ -f "$WORK_DIR/lat-$t.txt" ] && cat "$WORK_DIR/lat-$t.txt" >> "$latencies_file" 2>/dev/null
done

total_completed=$((uuid_pass + uuid_fail))
total_data_mb=$((hash_pass * PAYLOAD_KB / 1024))
req_per_sec=0
if [ "$DURATION_MS" -gt 0 ]; then
  req_per_sec=$((total_completed * 1000 / DURATION_MS))
fi

# ─── Latency percentiles ────────────────────────────────────────────────────

p50="-" p95="-" p99="-" avg="-"
if [ -f "$latencies_file" ] && [ "$(wc -l < "$latencies_file")" -gt 0 ]; then
  sort -n "$latencies_file" > "$WORK_DIR/sorted-lat.txt"
  count=$(wc -l < "$WORK_DIR/sorted-lat.txt")
  p50_idx=$(( (count * 50 + 99) / 100 ))
  p95_idx=$(( (count * 95 + 99) / 100 ))
  p99_idx=$(( (count * 99 + 99) / 100 ))
  [ "$p50_idx" -lt 1 ] && p50_idx=1
  [ "$p95_idx" -lt 1 ] && p95_idx=1
  [ "$p99_idx" -lt 1 ] && p99_idx=1
  [ "$p50_idx" -gt "$count" ] && p50_idx="$count"
  [ "$p95_idx" -gt "$count" ] && p95_idx="$count"
  [ "$p99_idx" -gt "$count" ] && p99_idx="$count"

  p50=$(sed -n "${p50_idx}p" "$WORK_DIR/sorted-lat.txt")
  p95=$(sed -n "${p95_idx}p" "$WORK_DIR/sorted-lat.txt")
  p99=$(sed -n "${p99_idx}p" "$WORK_DIR/sorted-lat.txt")
  avg=$(awk '{sum+=$1; n++} END{printf "%.0f", sum/n}' "$WORK_DIR/sorted-lat.txt")
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

error_pct=0
[ "$TOTAL_REQUESTS" -gt 0 ] && error_pct=$((request_errors * 100 / TOTAL_REQUESTS))

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  THROUGHPUT BENCHMARK RESULTS"
echo "═══════════════════════════════════════════════════════════════"
echo "  Cluster:            $POD_COUNT pods × ${POD_MEMORY} RAM, ${POD_CPU} CPU"
echo "  Tunnels:            $TUNNEL_COUNT ($healthy healthy)"
echo "  Requests/tunnel:    $REQUESTS_PER"
echo "  Payload:            ${PAYLOAD_KB}KB per request"
echo "  Workers:            $PARALLEL_WORKERS parallel"
echo "  Duration:           ${DURATION_S}s (${DURATION_MS}ms)"
echo "  Throughput:         ${req_per_sec} req/s"
echo "  Data transferred:   ${total_data_mb}MB"
echo ""
echo "  Requests completed: $total_completed / $TOTAL_REQUESTS"
echo "  Request errors:     $request_errors ($error_pct%)"
echo "  SHA-256 verified:   $hash_pass / $total_completed"
echo "  SHA-256 mismatch:   $hash_fail"
echo ""
echo "  Latency:"
echo "    avg:  ${avg}ms"
echo "    p50:  ${p50}ms"
echo "    p95:  ${p95}ms"
echo "    p99:  ${p99}ms"

# ─── Bottleneck analysis ─────────────────────────────────────────────────────

# Stop resource monitor and analyze
[ -n "$RESOURCE_MONITOR_PID" ] && kill "$RESOURCE_MONITOR_PID" 2>/dev/null && wait "$RESOURCE_MONITOR_PID" 2>/dev/null
RESOURCE_MONITOR_PID=""

bottleneck="none"
bottleneck_details=""
pod_cpu_peak="" pod_mem_peak="" pod_mem_pct="" host_load_peak="" ssh_rss_peak=""

if [ -f "$WORK_DIR/resources.log" ]; then
  # Parse peak pod CPU (e.g., "200m" or "1500m")
  pod_cpu_peak=$(grep "^[0-9]* pod " "$WORK_DIR/resources.log" | awk '{print $4}' | sed 's/m$//' | sort -n | tail -1)
  # Parse peak pod memory (e.g., "150Mi")
  pod_mem_peak=$(grep "^[0-9]* pod " "$WORK_DIR/resources.log" | awk '{print $5}' | sed 's/Mi$//' | sort -n | tail -1)
  # Host load
  host_load_peak=$(grep "^[0-9]* host " "$WORK_DIR/resources.log" | sed 's/.*load=//' | sort -n | tail -1)
  # SSH RSS
  ssh_rss_peak=$(grep "^[0-9]* host " "$WORK_DIR/resources.log" | sed 's/.*ssh_rss_mb=//' | sed 's/ .*//' | sort -n | tail -1)

  # CPU limit in millicores
  cpu_limit_m=$(echo "$POD_CPU" | sed 's/m$//')
  # Memory limit in Mi
  mem_limit_mi=$(echo "$POD_MEMORY" | sed 's/Mi$//')

  # Determine bottleneck
  if [ -n "$pod_cpu_peak" ] && [ "$pod_cpu_peak" -ge "$((cpu_limit_m * 90 / 100))" ] 2>/dev/null; then
    bottleneck="pod-cpu"
    bottleneck_details="Pod CPU at ${pod_cpu_peak}m / ${cpu_limit_m}m (throttled)"
  fi

  if [ -n "$pod_mem_peak" ] && [ -n "$mem_limit_mi" ] && [ "$pod_mem_peak" -ge "$((mem_limit_mi * 85 / 100))" ] 2>/dev/null; then
    if [ "$bottleneck" = "none" ]; then
      bottleneck="pod-memory"
      bottleneck_details="Pod memory at ${pod_mem_peak}Mi / ${mem_limit_mi}Mi"
    fi
  fi

  if [ -n "$pod_mem_peak" ] && [ -n "$mem_limit_mi" ]; then
    pod_mem_pct=$((pod_mem_peak * 100 / mem_limit_mi))
  fi

  host_cpus=$(nproc 2>/dev/null || echo 1)
  if [ -n "$host_load_peak" ] && [ "${host_load_peak%.*}" -ge "$host_cpus" ] 2>/dev/null; then
    if [ "$bottleneck" = "none" ]; then
      bottleneck="host-cpu"
      bottleneck_details="Host load ${host_load_peak} >= ${host_cpus} cores (client saturated)"
    fi
  fi

  # If errors >10% and no resource bottleneck found, it's likely SSH channel/network
  if [ "$bottleneck" = "none" ] && [ "$error_pct" -gt 10 ]; then
    bottleneck="ssh-channel"
    bottleneck_details="SSH channels saturated — ${TUNNEL_COUNT} tunnels × ${PAYLOAD_KB}KB through single NodePort"
  fi
fi

echo ""
echo "  Resources (peak during test):"
[ -n "$pod_cpu_peak" ] && echo "    Pod CPU:    ${pod_cpu_peak}m / ${POD_CPU} limit"
[ -n "$pod_mem_peak" ] && echo "    Pod memory: ${pod_mem_peak}Mi / ${POD_MEMORY} limit (${pod_mem_pct:-?}%)"
[ -n "$host_load_peak" ] && echo "    Host load:  ${host_load_peak} ($(nproc 2>/dev/null || echo '?') cores)"
[ -n "$ssh_rss_peak" ] && echo "    SSH RSS:    ${ssh_rss_peak}MB (${TUNNEL_COUNT} connections)"

if [ "$bottleneck" != "none" ]; then
  echo ""
  echo -e "  ${YELLOW}Bottleneck: $bottleneck_details${NC}"
else
  echo ""
  echo "  No bottleneck detected"
fi

if [ "$hash_fail" -eq 0 ] && [ "$request_errors" -eq 0 ]; then
  echo ""
  echo -e "  ${GREEN}ALL DATA VERIFIED — Zero corruption, zero errors${NC}"
elif [ "$hash_fail" -eq 0 ]; then
  echo ""
  echo -e "  ${YELLOW}DATA INTACT — Zero corruption, but $request_errors request errors ($error_pct%)${NC}"
else
  echo ""
  echo -e "  ${RED}DATA CORRUPTION — $hash_fail SHA-256 mismatches detected${NC}"
fi
echo "═══════════════════════════════════════════════════════════════"

# ─── Save result to local/runs.json ──────────────────────────────────────────

RUNS_DIR="$SCRIPT_DIR/../../local"
RUNS_FILE="$RUNS_DIR/runs.json"
mkdir -p "$RUNS_DIR"

# Build JSON result
run_json=$(cat <<RUNJSON
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "cluster": {
    "pods": $POD_COUNT,
    "memory": "$POD_MEMORY",
    "cpu": "$POD_CPU"
  },
  "config": {
    "tunnels": $TUNNEL_COUNT,
    "requests_per_tunnel": $REQUESTS_PER,
    "payload_kb": $PAYLOAD_KB,
    "workers": $PARALLEL_WORKERS
  },
  "results": {
    "tunnels_healthy": $healthy,
    "requests_completed": $total_completed,
    "requests_total": $TOTAL_REQUESTS,
    "request_errors": $request_errors,
    "error_pct": $error_pct,
    "sha256_verified": $hash_pass,
    "sha256_mismatch": $hash_fail,
    "data_transferred_mb": $total_data_mb,
    "duration_ms": $DURATION_MS,
    "throughput_rps": $req_per_sec
  },
  "latency": {
    "avg_ms": $([ "$avg" = "-" ] && echo "null" || echo "$avg"),
    "p50_ms": $([ "$p50" = "-" ] && echo "null" || echo "$p50"),
    "p95_ms": $([ "$p95" = "-" ] && echo "null" || echo "$p95"),
    "p99_ms": $([ "$p99" = "-" ] && echo "null" || echo "$p99")
  },
  "resources": {
    "pod_cpu_peak_m": $([ -n "$pod_cpu_peak" ] && echo "$pod_cpu_peak" || echo "null"),
    "pod_mem_peak_mi": $([ -n "$pod_mem_peak" ] && echo "$pod_mem_peak" || echo "null"),
    "pod_mem_pct": $([ -n "$pod_mem_pct" ] && echo "$pod_mem_pct" || echo "null"),
    "host_load_peak": $([ -n "$host_load_peak" ] && echo "$host_load_peak" || echo "null"),
    "ssh_rss_mb": $([ -n "$ssh_rss_peak" ] && echo "$ssh_rss_peak" || echo "null"),
    "bottleneck": "$bottleneck",
    "bottleneck_detail": "$bottleneck_details"
  }
}
RUNJSON
)

# Append to runs array (create if missing)
if [ -f "$RUNS_FILE" ]; then
  # Append to existing array
  jq --argjson run "$run_json" '. += [$run]' "$RUNS_FILE" > "$RUNS_FILE.tmp" && mv "$RUNS_FILE.tmp" "$RUNS_FILE"
else
  echo "[$run_json]" | jq '.' > "$RUNS_FILE"
fi

log_info "Result saved to $RUNS_FILE ($(jq length "$RUNS_FILE") runs total)"

# Exit non-zero on any hash failure
[ "$hash_fail" -gt 0 ] && exit 1
exit 0
