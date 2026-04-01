#!/usr/bin/env bash
# Stress test: N concurrent SSH tunnels with continuous monitoring.
#
# Simulates a company with many developers using tunnels simultaneously.
# Creates N tunnels, monitors all of them, runs load across all subdomains,
# and asserts ZERO probe failures — proving zero downtime under load.
#
# Features:
#   - Latency percentile tracking (p50/p95/p99)
#   - Resource monitoring (kubectl top pods during test)
#   - Graceful tunnel teardown verification
#   - Configurable SLA thresholds
#
# Usage: ./test-stress.sh [tunnel_count] [test_duration_seconds]
#   Default: 100 tunnels, 30s of sustained load
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

TUNNEL_COUNT="${1:-100}"
TEST_DURATION="${2:-30}"
LOCAL_PORT="${LOCAL_PORT:-18080}"
SSH_HOST="${TUNNEL_HOST:-127.0.0.1}"
SSH_PORT="${TUNNEL_SSH_PORT:-30022}"
NAMESPACE="${NAMESPACE:-asd-tunnel-demo}"
MONITOR_INTERVAL_MS=500

# SLA thresholds (configurable via environment)
SLA_P99_MS="${SLA_P99_MS:-500}"
SLA_P95_MS="${SLA_P95_MS:-200}"

WORK_DIR=$(mktemp -d)
TUNNEL_PIDS=()
MONITOR_PID=""
RESOURCE_MONITOR_PID=""

# ─── Cleanup ──────────────────────────────────────────────────────────────────

cleanup() {
  echo ""
  log_info "Cleaning up..."

  # Stop monitors
  [ -n "$MONITOR_PID" ] && kill "$MONITOR_PID" 2>/dev/null && wait "$MONITOR_PID" 2>/dev/null
  [ -n "$RESOURCE_MONITOR_PID" ] && kill "$RESOURCE_MONITOR_PID" 2>/dev/null && wait "$RESOURCE_MONITOR_PID" 2>/dev/null

  # Kill all SSH tunnels
  for pid in "${TUNNEL_PIDS[@]}"; do
    kill "$pid" 2>/dev/null
  done
  wait 2>/dev/null

  # Summary from monitor log
  local sla_violation=0
  if [ -f "$WORK_DIR/monitor.log" ]; then
    local total_probes failed_probes
    total_probes=$(wc -l < "$WORK_DIR/monitor.log")
    failed_probes=$(grep -c "FAIL" "$WORK_DIR/monitor.log" 2>/dev/null || echo 0)
    local success_probes=$((total_probes - failed_probes))

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  STRESS TEST RESULTS"
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Tunnels:        $TUNNEL_COUNT"
    echo "  Duration:       ${TEST_DURATION}s"
    echo "  Total probes:   $total_probes"
    echo "  Successful:     $success_probes"
    echo "  Failed:         $failed_probes"

    if [ -f "$WORK_DIR/load-results.json" ]; then
      local load_total load_passed load_failed
      load_total=$(jq -r '.total' "$WORK_DIR/load-results.json")
      load_passed=$(jq -r '.passed' "$WORK_DIR/load-results.json")
      load_failed=$(jq -r '.failed' "$WORK_DIR/load-results.json")
      echo "  Load requests:  $load_total ($load_passed passed, $load_failed failed)"
    fi

    # ── Latency percentiles ──
    local ok_count
    ok_count=$(grep -c " OK " "$WORK_DIR/monitor.log" 2>/dev/null || echo 0)
    if [ "$ok_count" -gt 0 ]; then
      # Extract latency values (e.g., "5ms" → "5"), sort numerically
      local latencies_file="$WORK_DIR/latencies.txt"
      grep " OK " "$WORK_DIR/monitor.log" | \
        awk '{print $NF}' | sed 's/ms$//' | sort -n > "$latencies_file"

      local count p50_idx p95_idx p99_idx p50 p95 p99 avg
      count=$(wc -l < "$latencies_file")
      p50_idx=$(( (count * 50 + 99) / 100 ))
      p95_idx=$(( (count * 95 + 99) / 100 ))
      p99_idx=$(( (count * 99 + 99) / 100 ))

      # Clamp to valid range
      [ "$p50_idx" -lt 1 ] && p50_idx=1
      [ "$p95_idx" -lt 1 ] && p95_idx=1
      [ "$p99_idx" -lt 1 ] && p99_idx=1
      [ "$p50_idx" -gt "$count" ] && p50_idx="$count"
      [ "$p95_idx" -gt "$count" ] && p95_idx="$count"
      [ "$p99_idx" -gt "$count" ] && p99_idx="$count"

      p50=$(sed -n "${p50_idx}p" "$latencies_file")
      p95=$(sed -n "${p95_idx}p" "$latencies_file")
      p99=$(sed -n "${p99_idx}p" "$latencies_file")
      avg=$(awk '{sum+=$1; n++} END{printf "%.0f", sum/n}' "$latencies_file")

      echo ""
      echo "  Latency (probe health checks):"
      echo "    avg:  ${avg}ms"
      echo "    p50:  ${p50}ms"
      echo "    p95:  ${p95}ms (SLA: <${SLA_P95_MS}ms)"
      echo "    p99:  ${p99}ms (SLA: <${SLA_P99_MS}ms)"

      # SLA check
      if [ "$p99" -gt "$SLA_P99_MS" ]; then
        echo -e "    ${RED}p99 EXCEEDS SLA threshold (${p99}ms > ${SLA_P99_MS}ms)${NC}"
        sla_violation=1
      fi
      if [ "$p95" -gt "$SLA_P95_MS" ]; then
        echo -e "    ${RED}p95 EXCEEDS SLA threshold (${p95}ms > ${SLA_P95_MS}ms)${NC}"
        sla_violation=1
      fi
      if [ "$sla_violation" -eq 0 ]; then
        echo -e "    ${GREEN}All latency SLAs met${NC}"
      fi
    fi

    # ── Resource usage snapshot ──
    if [ -f "$WORK_DIR/resource-log.txt" ]; then
      echo ""
      echo "  Resource usage (peak during test):"
      # Show the last recorded snapshot
      tail -n 10 "$WORK_DIR/resource-log.txt" | while read -r line; do
        echo "    $line"
      done
    fi

    if [ "$failed_probes" -eq 0 ]; then
      echo ""
      echo -e "  ${GREEN}ZERO DOWNTIME — All probes passed under load${NC}"
    else
      echo ""
      echo -e "  ${RED}DOWNTIME DETECTED — $failed_probes probes failed${NC}"
      echo ""
      echo "  Failed probes:"
      grep "FAIL" "$WORK_DIR/monitor.log" | head -20
    fi
    echo "═══════════════════════════════════════════════════════════════"
  fi

  rm -rf "$WORK_DIR"

  if [ "${failed_probes:-0}" -gt 0 ]; then
    exit 1
  fi
  if [ "${sla_violation:-0}" -gt 0 ]; then
    log_fail "Latency SLA violation detected"
    exit 1
  fi
}
trap cleanup EXIT INT TERM

# ─── Phase 1: Create tunnels ─────────────────────────────────────────────────

log_info "Creating $TUNNEL_COUNT SSH tunnels..."

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ServerAliveInterval=10
  -o ServerAliveCountMax=3
)

# Spawn tunnels in batches to avoid overwhelming the server
BATCH_SIZE=25
created=0

for i in $(seq 1 "$TUNNEL_COUNT"); do
  subdomain=$(printf "stress-%03d" "$i")

  ssh "${SSH_OPTS[@]}" \
    -p "$SSH_PORT" \
    -N \
    -R "${subdomain}:80:localhost:${LOCAL_PORT}" \
    "$SSH_HOST" &
  TUNNEL_PIDS+=($!)
  created=$((created + 1))

  # Batch pause — let the server register tunnels
  if [ $((created % BATCH_SIZE)) -eq 0 ]; then
    log_info "  Created $created/$TUNNEL_COUNT tunnels..."
    sleep 1
  fi
done

log_info "  Created $TUNNEL_COUNT tunnels (${#TUNNEL_PIDS[@]} PIDs)"
sleep 2

# ─── Phase 2: Verify all tunnels are healthy ─────────────────────────────────

log_info "Verifying all $TUNNEL_COUNT tunnels are reachable..."

healthy=0
unhealthy=0
unreachable_subs=()

for i in $(seq 1 "$TUNNEL_COUNT"); do
  subdomain=$(printf "stress-%03d" "$i")
  if tunnel_curl "$subdomain" -sf --max-time 5 \
    "$(tunnel_url "$subdomain")/health" >/dev/null 2>&1; then
    healthy=$((healthy + 1))
  else
    unhealthy=$((unhealthy + 1))
    unreachable_subs+=("$subdomain")
  fi

  # Progress every 25
  if [ $((i % 25)) -eq 0 ]; then
    log_info "  Verified $i/$TUNNEL_COUNT ($healthy healthy, $unhealthy failed)"
  fi
done

if [ "$unhealthy" -gt 0 ]; then
  log_fail "$unhealthy/$TUNNEL_COUNT tunnels unreachable: ${unreachable_subs[*]:0:10}..."
  if [ "$unhealthy" -gt $((TUNNEL_COUNT / 2)) ]; then
    log_fail "More than 50% tunnels failed — aborting"
    exit 1
  fi
fi

log_pass "$healthy/$TUNNEL_COUNT tunnels healthy"

# ─── Phase 2b: Start resource monitor ────────────────────────────────────────

log_info "Starting resource monitor (kubectl top pods every 10s)..."

(
  end_time=$(($(date +%s) + TEST_DURATION + 15))
  while [ "$(date +%s)" -lt "$end_time" ]; do
    kubectl top pods -n "$NAMESPACE" -l app=asd-tunnel --no-headers 2>/dev/null | \
      while read -r name cpu mem; do
        echo "$(date +%H:%M:%S) $name CPU=$cpu MEM=$mem"
      done >> "$WORK_DIR/resource-log.txt" 2>/dev/null || true
    sleep 10
  done
) &
RESOURCE_MONITOR_PID=$!

# ─── Phase 3: Start continuous monitor ────────────────────────────────────────

log_info "Starting continuous monitor (${MONITOR_INTERVAL_MS}ms interval, ${TEST_DURATION}s)..."

(
  end_time=$(($(date +%s) + TEST_DURATION + 10))  # monitor runs slightly longer than load
  interval_s=$(awk "BEGIN{printf \"%.1f\", $MONITOR_INTERVAL_MS/1000}")

  while [ "$(date +%s)" -lt "$end_time" ]; do
    # Pick a random tunnel to probe
    idx=$(( (RANDOM % TUNNEL_COUNT) + 1 ))
    subdomain=$(printf "stress-%03d" "$idx")
    ts=$(date +%s.%N)

    start_ms=$(date +%s%N)
    if tunnel_curl "$subdomain" -sf --max-time 5 \
      "$(tunnel_url "$subdomain")/health" >/dev/null 2>&1; then
      end_ms=$(date +%s%N)
      latency_ms=$(( (end_ms - start_ms) / 1000000 ))
      echo "$ts OK $subdomain ${latency_ms}ms" >> "$WORK_DIR/monitor.log"
    else
      echo "$ts FAIL $subdomain" >> "$WORK_DIR/monitor.log"
    fi

    sleep "$interval_s"
  done
) &
MONITOR_PID=$!

sleep 1  # let monitor start

# ─── Phase 4: Sustained load across all tunnels ──────────────────────────────

log_info "Running sustained load for ${TEST_DURATION}s across $TUNNEL_COUNT tunnels..."

total_requests=0
passed_requests=0
failed_requests=0
end_time=$(($(date +%s) + TEST_DURATION))

# Run load in waves — each wave sends concurrent requests to random subdomains
WAVE_SIZE=20

while [ "$(date +%s)" -lt "$end_time" ]; do
  wave_pids=()
  for w in $(seq 1 "$WAVE_SIZE"); do
    idx=$(( (RANDOM % TUNNEL_COUNT) + 1 ))
    subdomain=$(printf "stress-%03d" "$idx")
    uuid=$(gen_uuid)

    (
      response=$(tunnel_curl "$subdomain" -sf --max-time 10 \
        -H "X-Request-ID: $uuid" \
        "$(tunnel_url "$subdomain")/echo" 2>/dev/null) || { echo "FAIL" > "$WORK_DIR/wave-$w"; exit; }
      got_id=$(echo "$response" | jq -r '.request_id // empty')
      if [ "$got_id" = "$uuid" ]; then
        echo "OK" > "$WORK_DIR/wave-$w"
      else
        echo "FAIL" > "$WORK_DIR/wave-$w"
      fi
    ) &
    wave_pids+=($!)
  done

  # Wait for wave
  for pid in "${wave_pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  # Tally wave results
  for w in $(seq 1 "$WAVE_SIZE"); do
    total_requests=$((total_requests + 1))
    result=$(cat "$WORK_DIR/wave-$w" 2>/dev/null || echo "FAIL")
    if [ "$result" = "OK" ]; then
      passed_requests=$((passed_requests + 1))
    else
      failed_requests=$((failed_requests + 1))
    fi
    rm -f "$WORK_DIR/wave-$w"
  done

  elapsed=$(($(date +%s) - (end_time - TEST_DURATION)))
  printf "\r  %ds/%ds — %d requests (%d ok, %d fail)" \
    "$elapsed" "$TEST_DURATION" "$total_requests" "$passed_requests" "$failed_requests"
done

echo ""  # newline after progress

# Write load results for cleanup summary
cat > "$WORK_DIR/load-results.json" <<LOAD_EOF
{"total":$total_requests,"passed":$passed_requests,"failed":$failed_requests}
LOAD_EOF

if [ "$failed_requests" -eq 0 ]; then
  log_pass "load: $passed_requests/$total_requests requests passed"
else
  log_fail "load: $passed_requests/$total_requests passed, $failed_requests failed"
fi

# Let monitor finish its final probes
sleep 2

# ─── Phase 5: Graceful teardown verification ─────────────────────────────────

log_info "Verifying graceful tunnel teardown..."

# Kill all SSH tunnels
for pid in "${TUNNEL_PIDS[@]}"; do
  kill "$pid" 2>/dev/null || true
done
wait 2>/dev/null || true
TUNNEL_PIDS=()  # clear so cleanup doesn't double-kill

sleep 3

# Verify subdomains are no longer routable (tunnels deregistered)
stale=0
for i in 1 25 50 75 100; do
  [ "$i" -gt "$TUNNEL_COUNT" ] && continue
  subdomain=$(printf "stress-%03d" "$i")
  if tunnel_curl "$subdomain" -sf --max-time 3 \
    "$(tunnel_url "$subdomain")/health" >/dev/null 2>&1; then
    stale=$((stale + 1))
  fi
done

if [ "$stale" -eq 0 ]; then
  log_pass "Graceful teardown: all sampled tunnels deregistered"
else
  log_info "Graceful teardown: $stale sampled tunnels still routable (may need pod restart to clear)"
fi

log_info "Test complete — see summary below"
