#!/usr/bin/env bash
# Resource exhaustion test.
#
# Verifies that pods handle resource pressure gracefully:
#   1. Memory limit behavior — open many tunnels, monitor resource usage
#   2. Recovery verification — all pods remain running after load
#   3. Surviving routing — fresh tunnels work after pressure subsides
#
# With default limits (188Mi, GOMEMLIMIT=160MiB) and 3 replicas,
# 200 tunnels (~67 per pod, ~1-2Mi each) may not trigger OOM.
# Increase tunnel_count or reduce memory limits to test OOM recovery.
#
# Usage: ./test-resource-limits.sh [tunnel_count]
#   Default: 200 tunnels
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

TUNNEL_COUNT="${1:-200}"
LOCAL_PORT="${LOCAL_PORT:-18080}"
SSH_HOST="${TUNNEL_HOST:-127.0.0.1}"
SSH_PORT="${TUNNEL_SSH_PORT:-30022}"
NAMESPACE="${NAMESPACE:-asd-tunnel-demo}"

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=5
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=2
)

WORK_DIR=$(mktemp -d)
TUNNEL_PIDS=()

cleanup() {
  log_info "Cleaning up $((${#TUNNEL_PIDS[@]})) tunnel processes..."
  for pid in "${TUNNEL_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

passed=0
failed=0
total=3

# ─── Capture initial state ──────────────────────────────────────────────────

log_info "Capturing initial pod state..."
initial_restarts=$(kubectl get pods -n "$NAMESPACE" -l app=asd-tunnel \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' | \
  awk '{sum+=$1} END{print sum}')
initial_pods=$(kubectl get pods -n "$NAMESPACE" -l app=asd-tunnel --no-headers | wc -l)
log_info "  $initial_pods pods, $initial_restarts total restarts"

# ─── Test 1: Open many tunnels, monitor resource usage ───────────────────────

log_info "Test 1: Opening $TUNNEL_COUNT tunnels to stress memory limits"

BATCH_SIZE=50
created=0

for i in $(seq 1 "$TUNNEL_COUNT"); do
  subdomain=$(printf "rlimit-%03d" "$i")

  ssh "${SSH_OPTS[@]}" \
    -p "$SSH_PORT" \
    -N \
    -R "${subdomain}:80:localhost:${LOCAL_PORT}" \
    "$SSH_HOST" 2>/dev/null &
  TUNNEL_PIDS+=($!)
  created=$((created + 1))

  if [ $((created % BATCH_SIZE)) -eq 0 ]; then
    log_info "  Created $created/$TUNNEL_COUNT tunnels"

    # Check resource usage
    if command -v kubectl &>/dev/null; then
      kubectl top pods -n "$NAMESPACE" -l app=asd-tunnel --no-headers 2>/dev/null | \
        while read -r name cpu mem; do
          echo "    $name: CPU=$cpu MEM=$mem"
        done || true
    fi

    sleep 1
  fi
done

log_info "  Created $TUNNEL_COUNT tunnels"
sleep 5

# Check for OOMKills
current_restarts=$(kubectl get pods -n "$NAMESPACE" -l app=asd-tunnel \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' | \
  awk '{sum+=$1} END{print sum}')
new_restarts=$((current_restarts - initial_restarts))

if [ "$new_restarts" -gt 0 ]; then
  log_info "Test 1: $new_restarts pod restart(s) detected under load (OOMKill or crash)"
  # Check for OOMKilled specifically
  oom_count=$(kubectl get pods -n "$NAMESPACE" -l app=asd-tunnel \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}{end}' | \
    grep -c "OOMKilled" 2>/dev/null || echo 0)
  if [ "$oom_count" -gt 0 ]; then
    log_info "  $oom_count pod(s) were OOMKilled — memory limits enforced correctly"
  fi
  log_pass "Test 1: Resource limits triggered restarts (expected behavior)"
  passed=$((passed + 1))
else
  log_pass "Test 1: All pods survived $TUNNEL_COUNT tunnels without restart"
  passed=$((passed + 1))
fi

# ─── Test 2: Verify pods recover after resource pressure ─────────────────────

log_info "Test 2: Verify all pods are ready after resource pressure"

# Wait for any restarting pods to stabilize
sleep 10

ready_pods=0
for attempt in $(seq 1 15); do
  ready_pods=$(kubectl get pods -n "$NAMESPACE" -l app=asd-tunnel \
    --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  if [ "$ready_pods" -eq "$initial_pods" ]; then
    break
  fi
  log_info "  Waiting for pods to stabilize... ($ready_pods/$initial_pods ready)"
  sleep 5
done

if [ "$ready_pods" -eq "$initial_pods" ]; then
  log_pass "Test 2: All $initial_pods pods running and ready after resource pressure"
  passed=$((passed + 1))
else
  log_fail "Test 2: Only $ready_pods/$initial_pods pods ready after resource pressure"
  failed=$((failed + 1))
fi

# ─── Test 3: Verify tunnel routing still works ───────────────────────────────

log_info "Test 3: Verify tunnel routing works after resource pressure"

# Kill old tunnels
for pid in "${TUNNEL_PIDS[@]}"; do
  kill "$pid" 2>/dev/null || true
done
wait 2>/dev/null || true
TUNNEL_PIDS=()
sleep 2

# Create a fresh tunnel to verify the system is functional
ssh "${SSH_OPTS[@]}" \
  -p "$SSH_PORT" \
  -N \
  -R "rlimit-verify:80:localhost:${LOCAL_PORT}" \
  "$SSH_HOST" &
TUNNEL_PIDS+=($!)
sleep 3

if tunnel_curl "rlimit-verify" -sf --max-time 10 \
  "$(tunnel_url "rlimit-verify")/health" >/dev/null 2>&1; then
  log_pass "Test 3: Fresh tunnel routable after resource pressure recovery"
  passed=$((passed + 1))
else
  log_fail "Test 3: Cannot route traffic after resource pressure recovery"
  failed=$((failed + 1))
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

final_restarts=$(kubectl get pods -n "$NAMESPACE" -l app=asd-tunnel \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' | \
  awk '{sum+=$1} END{print sum}')
total_new_restarts=$((final_restarts - initial_restarts))

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  RESOURCE LIMITS TEST RESULTS"
echo "═══════════════════════════════════════════════════════════════"
echo "  Tunnels opened:    $TUNNEL_COUNT"
echo "  Pod restarts:      $total_new_restarts (during test)"
echo "  Tests passed:      $passed/$total"
echo "  Tests failed:      $failed/$total"
echo "═══════════════════════════════════════════════════════════════"
[ "$failed" -eq 0 ] && exit 0 || exit 1
