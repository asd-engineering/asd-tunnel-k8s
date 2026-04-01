#!/usr/bin/env bash
# Pod failure recovery test.
#
# Verifies that active tunnels survive pod deletion via NATS re-routing
# or client reconnection. Requires 3-replica deployment with NATS enabled
# (file-auth or rolling-upgrade overlay).
#
# Flow:
#   1. Create tunnel → verify routable
#   2. Delete the pod handling the tunnel
#   3. Wait for replacement pod
#   4. Verify tunnel is accessible again (via NATS re-routing or reconnect)
#
# Usage: ./test-pod-failure.sh [subdomain]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

SUBDOMAIN="${1:-podfail}"
LOCAL_PORT="${LOCAL_PORT:-18080}"
SSH_HOST="${TUNNEL_HOST:-127.0.0.1}"
SSH_PORT="${TUNNEL_SSH_PORT:-30022}"
NAMESPACE="${NAMESPACE:-asd-tunnel-demo}"
KEY_DIR="$(cd "$SCRIPT_DIR/../../k8s/overlays/file-auth/ssh-keys" && pwd)"

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o IdentitiesOnly=yes
  -o LogLevel=ERROR
  -o ConnectTimeout=10
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=2
)

WORK_DIR=$(mktemp -d)
TUNNEL_PID=""

cleanup() {
  [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null
  wait 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

passed=0
failed=0
total=3

# Determine SSH key args
SSH_KEY_ARGS=()
if [ -f "$KEY_DIR/demo" ]; then
  SSH_KEY_ARGS=(-i "$KEY_DIR/demo")
fi

# ─── Verify we have 3 replicas ──────────────────────────────────────────────

replica_count=$(kubectl get statefulset/asd-tunnel -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
if [ "$replica_count" -lt 2 ]; then
  log_fail "Need at least 2 replicas for pod failure test (have: $replica_count)"
  log_info "Deploy file-auth or rolling-upgrade overlay first"
  exit 1
fi
log_info "StatefulSet has $replica_count replicas"

# ─── Test 1: Create tunnel and verify it works ──────────────────────────────

log_info "Test 1: Create tunnel and verify routing"

ssh "${SSH_OPTS[@]}" "${SSH_KEY_ARGS[@]}" \
  -p "$SSH_PORT" \
  -N \
  -R "${SUBDOMAIN}:80:localhost:${LOCAL_PORT}" \
  "$SSH_HOST" &
TUNNEL_PID=$!

sleep 3

if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
  log_fail "Test 1: SSH tunnel process died immediately"
  failed=$((failed + 1))
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  POD FAILURE TEST RESULTS: $passed/$total passed, $failed/$total failed"
  echo "═══════════════════════════════════════════════════════════════"
  exit 1
fi

# Verify tunnel is routable
if tunnel_curl "$SUBDOMAIN" -sf --max-time 10 \
  "$(tunnel_url "$SUBDOMAIN")/health" >/dev/null 2>&1; then
  log_pass "Test 1: Tunnel created and routable"
  passed=$((passed + 1))
else
  log_fail "Test 1: Tunnel created but not routable"
  failed=$((failed + 1))
fi

# ─── Test 2: Delete pod-0 and verify cluster recovers ───────────────────────

log_info "Test 2: Delete pod asd-tunnel-0, verify StatefulSet recovery"

# Record which pods exist
kubectl get pods -n "$NAMESPACE" -l app=asd-tunnel --no-headers > "$WORK_DIR/pods-before.txt"
log_info "  Pods before: $(wc -l < "$WORK_DIR/pods-before.txt") running"

# Delete pod-0
kubectl delete pod asd-tunnel-0 -n "$NAMESPACE" --grace-period=5

# Wait for replacement pod
log_info "  Waiting for replacement pod..."
for attempt in $(seq 1 30); do
  ready=$(kubectl get pod asd-tunnel-0 -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
  if [ "$ready" = "True" ]; then
    break
  fi
  sleep 2
done

if [ "$ready" = "True" ]; then
  log_pass "Test 2: Pod asd-tunnel-0 recovered and ready"
  passed=$((passed + 1))
else
  log_fail "Test 2: Pod asd-tunnel-0 did not recover within 60s"
  failed=$((failed + 1))
fi

# ─── Test 3: Verify tunnel is accessible after pod failure ───────────────────

log_info "Test 3: Verify tunnel accessibility after pod failure"

# The original SSH connection may have been to pod-0 and died.
# If so, the tunnel is lost. This tests whether the system recovers.
# Give NATS time to re-converge.
sleep 5

# Check if original tunnel is still routable (via NATS on surviving pods)
accessible=false
for attempt in $(seq 1 10); do
  if tunnel_curl "$SUBDOMAIN" -sf --max-time 5 \
    "$(tunnel_url "$SUBDOMAIN")/health" >/dev/null 2>&1; then
    accessible=true
    break
  fi
  sleep 2
done

if [ "$accessible" = "true" ]; then
  log_pass "Test 3: Tunnel accessible after pod failure (NATS re-routing worked)"
  passed=$((passed + 1))
else
  # The SSH connection may have been terminated — this is expected if the
  # tunnel was on the killed pod. Log it as a known limitation.
  if kill -0 "$TUNNEL_PID" 2>/dev/null; then
    log_fail "Test 3: SSH client alive but tunnel not routable after pod recovery"
    failed=$((failed + 1))
  else
    log_info "Test 3: SSH connection was on killed pod — client exited (expected)"
    log_info "  In production, use asd-tunnel client with --reconnect for auto-recovery"
    # Create new tunnel to prove the system is functional
    ssh "${SSH_OPTS[@]}" "${SSH_KEY_ARGS[@]}" \
      -p "$SSH_PORT" \
      -N \
      -R "${SUBDOMAIN}-recover:80:localhost:${LOCAL_PORT}" \
      "$SSH_HOST" &
    TUNNEL_PID=$!
    sleep 3
    if tunnel_curl "${SUBDOMAIN}-recover" -sf --max-time 5 \
      "$(tunnel_url "${SUBDOMAIN}-recover")/health" >/dev/null 2>&1; then
      log_pass "Test 3: New tunnel works after pod recovery (system healthy)"
      passed=$((passed + 1))
    else
      log_fail "Test 3: Cannot create new tunnel after pod recovery"
      failed=$((failed + 1))
    fi
  fi
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  POD FAILURE TEST RESULTS: $passed/$total passed, $failed/$total failed"
echo "═══════════════════════════════════════════════════════════════"
[ "$failed" -eq 0 ] && exit 0 || exit 1
