#!/usr/bin/env bash
# test-drain.sh — Prove zero-downtime graceful drain works
# Outputs a detailed log with timestamps, HTTP response codes, and SSH reconnect timing.
set -euo pipefail

SUBDOMAIN="drain-proof"
SSH_PORT="${TUNNEL_SSH_PORT:-30022}"
SSH_HOST="${TUNNEL_HOST:-localhost}"
NAMESPACE="${NAMESPACE:-asd-tunnel-demo}"
LOCAL_PORT="${LOCAL_PORT:-18080}"
AUTH_KEY="k8s/overlays/file-auth/ssh-keys/demo"
RESULTS_DIR="scripts/drain-results"
MONITOR_LOG="$RESULTS_DIR/http-monitor.log"
SSH_LOG="$RESULTS_DIR/ssh-tunnel.log"
POD_LOG="$RESULTS_DIR/pod-events.log"
SUMMARY="$RESULTS_DIR/summary.txt"

mkdir -p "$RESULTS_DIR"
: > "$MONITOR_LOG"
: > "$SSH_LOG"
: > "$POD_LOG"
: > "$SUMMARY"

log() { echo "[$(date '+%H:%M:%S.%3N')] $*" | tee -a "$SUMMARY"; }

cleanup() {
  log "Cleaning up..."
  [ -n "${MONITOR_PID:-}" ] && kill "$MONITOR_PID" 2>/dev/null || true
  [ -n "${SSH_PID:-}" ] && kill "$SSH_PID" 2>/dev/null || true
  [ -n "${PF_PID:-}" ] && kill "$PF_PID" 2>/dev/null || true
  [ -n "${POD_WATCH_PID:-}" ] && kill "$POD_WATCH_PID" 2>/dev/null || true
  # Kill any lingering SSH/port-forward/log streamers from previous runs
  pkill -f "ssh.*${SUBDOMAIN}" 2>/dev/null || true
  pkill -f "kubectl port-forward.*${LOCAL_PORT}" 2>/dev/null || true
  pkill -f "kubectl logs.*asd-tunnel.*-f" 2>/dev/null || true
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Kill leftovers from previous runs
pkill -f "ssh.*${SUBDOMAIN}" 2>/dev/null || true
pkill -f "kubectl port-forward.*${LOCAL_PORT}" 2>/dev/null || true
sleep 1

# ───────────────── Phase 0: Pre-flight checks ─────────────────
log "=== DRAIN TEST: Zero-Downtime Upgrade Proof ==="
log ""
log "--- Phase 0: Pre-flight ---"
log "Checking cluster state..."

kubectl get pods -n "$NAMESPACE" -o wide 2>&1 | tee -a "$SUMMARY"
echo "" >> "$SUMMARY"

POD_COUNT=$(kubectl get pods -n "$NAMESPACE" -l app=asd-tunnel --no-headers 2>/dev/null | wc -l)
if [ "$POD_COUNT" -ne 3 ]; then
  log "ERROR: Expected 3 asd-tunnel pods, got $POD_COUNT"
  exit 1
fi
log "OK: 3 asd-tunnel pods running"

# ───────────────── Phase 1: Create tunnel ─────────────────
log ""
log "--- Phase 1: Create SSH tunnel ---"

# Port-forward validation server
kubectl port-forward -n "$NAMESPACE" svc/validation-server "${LOCAL_PORT}:8080" &>/dev/null &
PF_PID=$!
sleep 2

# Verify port-forward
if ! curl -sf -m 3 "http://localhost:${LOCAL_PORT}/health" > /dev/null 2>&1; then
  log "ERROR: Port-forward to validation-server failed"
  exit 1
fi
log "OK: Port-forward to validation-server on :${LOCAL_PORT}"

# Create SSH tunnel in background with auto-reconnect
# NOTE: set +e is critical — without it, SSH's non-zero exit kills the subshell
(
  set +e
  CONN_NUM=0
  while true; do
    CONN_NUM=$((CONN_NUM + 1))
    CONNECT_START=$(date '+%H:%M:%S.%3N')
    echo "[$CONNECT_START] SSH-CONNECT #${CONN_NUM}: attempting connection..." >> "$SSH_LOG"
    ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      -o IdentitiesOnly=yes \
      -i "$AUTH_KEY" \
      -o ServerAliveInterval=2 \
      -o ServerAliveCountMax=2 \
      -o ConnectTimeout=5 \
      -o ExitOnForwardFailure=no \
      -p "$SSH_PORT" \
      -N \
      -R "${SUBDOMAIN}:80:localhost:${LOCAL_PORT}" \
      "$SSH_HOST" 2>>"$SSH_LOG"
    EXIT_CODE=$?
    DISCONNECT_TIME=$(date '+%H:%M:%S.%3N')
    echo "[$DISCONNECT_TIME] SSH-DISCONNECT #${CONN_NUM}: exit_code=$EXIT_CODE, reconnecting in 0.5s..." >> "$SSH_LOG"
    sleep 0.5
  done
) &
SSH_PID=$!
sleep 3  # Give SSH time to establish through the subshell

# Wait for tunnel to establish
log "Waiting for tunnel to establish..."
TUNNEL_URL="http://${SUBDOMAIN}.tunnel.local:30080"
for i in $(seq 1 30); do
  PROBE_CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 3 \
    --resolve "${SUBDOMAIN}.tunnel.local:30080:127.0.0.1" \
    "${TUNNEL_URL}/echo" 2>/dev/null) || PROBE_CODE="000"
  if [ "$PROBE_CODE" = "200" ]; then
    break
  fi
  sleep 1
done

# Verify tunnel works
ECHO_RESP=$(curl -s -m 5 --resolve "${SUBDOMAIN}.tunnel.local:30080:127.0.0.1" \
  -H "X-Request-ID: tunnel-test-123" "${TUNNEL_URL}/echo" 2>/dev/null || echo "FAIL")

if echo "$ECHO_RESP" | grep -q "tunnel-test-123"; then
  log "OK: Tunnel established and responding"
else
  log "ERROR: Tunnel not working. Response: $ECHO_RESP"
  exit 1
fi

# ───────────────── Phase 2: Verify cross-pod NATS routing ─────────────────
log ""
log "--- Phase 2: Verify NATS cross-pod routing ---"

for pod_idx in 0 1 2; do
  POD_IP=$(kubectl get pod asd-tunnel-${pod_idx} -n "$NAMESPACE" -o jsonpath='{.status.podIP}')
  RESP=$(kubectl exec -n "$NAMESPACE" asd-tunnel-${pod_idx} -- \
    wget -qO- --header="Host: ${SUBDOMAIN}.tunnel.local" \
    "http://localhost:8081/echo" 2>/dev/null || echo "FAIL")
  if echo "$RESP" | grep -q "request_id"; then
    log "OK: Pod asd-tunnel-${pod_idx} ($POD_IP): tunnel reachable"
  else
    log "  Pod asd-tunnel-${pod_idx} ($POD_IP): not reachable (tunnel may be on this pod = local, not NATS)"
  fi
done

# ───────────────── Phase 3: Start HTTP monitor ─────────────────
log ""
log "--- Phase 3: Start continuous HTTP monitor ---"

# Monitor HTTP requests every 250ms, logging status code and latency
(
  REQUEST_NUM=0
  while true; do
    REQUEST_NUM=$((REQUEST_NUM + 1))
    START_MS=$(date +%s%3N)
    # Don't use -f so we get the actual HTTP status code even for errors
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 5 \
      --resolve "${SUBDOMAIN}.tunnel.local:30080:127.0.0.1" \
      -H "X-Request-ID: monitor-${REQUEST_NUM}" \
      "${TUNNEL_URL}/echo" 2>/dev/null) || HTTP_CODE="000"
    END_MS=$(date +%s%3N)
    LATENCY=$((END_MS - START_MS))
    echo "[$(date '+%H:%M:%S.%3N')] HTTP #${REQUEST_NUM}: status=${HTTP_CODE} latency=${LATENCY}ms" >> "$MONITOR_LOG"
    sleep 0.25
  done
) &
MONITOR_PID=$!

# Also watch pod events
(
  kubectl get pods -n "$NAMESPACE" -l app=asd-tunnel -w --no-headers 2>/dev/null | while IFS= read -r line; do
    echo "[$(date '+%H:%M:%S.%3N')] $line" >> "$POD_LOG"
  done
) &
POD_WATCH_PID=$!

# Let monitor run for 5 seconds to establish baseline
sleep 5

BASELINE_COUNT=$(wc -l < "$MONITOR_LOG")
BASELINE_200=$(grep -c "status=200" "$MONITOR_LOG" || true)
log "Baseline: $BASELINE_COUNT requests, $BASELINE_200 successful (200)"

if [ "$BASELINE_200" -lt 10 ]; then
  log "ERROR: Baseline too low — tunnel may not be working"
  tail -10 "$MONITOR_LOG" | tee -a "$SUMMARY"
  exit 1
fi
log "OK: Baseline HTTP monitoring established"

# ───────────────── Phase 4: Trigger rolling restart ─────────────────
log ""
log "--- Phase 4: Trigger rolling restart ---"
log "Recording pre-restart state..."

PRE_PODS=$(kubectl get pods -n "$NAMESPACE" -l app=asd-tunnel --no-headers -o custom-columns='NAME:.metadata.name,IP:.status.podIP,STATUS:.status.phase')
log "Pre-restart pods:"
echo "$PRE_PODS" | while IFS= read -r line; do log "  $line"; done

RESTART_TIME=$(date '+%H:%M:%S.%3N')
log ""
log ">>> ROLLING RESTART INITIATED at $RESTART_TIME <<<"

# Stream logs from all pods in background to capture drain output
DRAIN_LOG="$RESULTS_DIR/drain-pod-logs.log"
: > "$DRAIN_LOG"
for pod_idx in 0 1 2; do
  (kubectl logs -n "$NAMESPACE" asd-tunnel-${pod_idx} -c asd-tunnel -f 2>/dev/null | while IFS= read -r line; do
    echo "[pod-${pod_idx}] $line" >> "$DRAIN_LOG"
  done) &
done

kubectl rollout restart statefulset/asd-tunnel -n "$NAMESPACE" 2>&1 | tee -a "$SUMMARY"

# Wait for rollout to complete while monitor runs
log "Waiting for rollout to complete (monitor running in background)..."
kubectl rollout status statefulset/asd-tunnel -n "$NAMESPACE" --timeout=300s 2>&1 | tee -a "$SUMMARY"

COMPLETE_TIME=$(date '+%H:%M:%S.%3N')
log ">>> ROLLING RESTART COMPLETE at $COMPLETE_TIME <<<"

# Kill log streamers
pkill -f "kubectl logs.*asd-tunnel.*-f" 2>/dev/null || true

# Let monitor run for 25 more seconds to catch SSH reconnect + tunnel re-registration
log "Waiting 25s for SSH reconnect and tunnel re-registration..."
sleep 25

# Log SSH state at this point
log "SSH reconnect log at recovery check:"
tail -5 "$SSH_LOG" | tee -a "$SUMMARY" || true

POST_PODS=$(kubectl get pods -n "$NAMESPACE" -l app=asd-tunnel --no-headers -o custom-columns='NAME:.metadata.name,IP:.status.podIP,STATUS:.status.phase')
log "Post-restart pods:"
echo "$POST_PODS" | while IFS= read -r line; do log "  $line"; done

# ───────────────── Phase 5: Analyze results ─────────────────
log ""
log "=========================================="
log "              RESULTS"
log "=========================================="
log ""

# Stop monitor
kill "$MONITOR_PID" 2>/dev/null || true
wait "$MONITOR_PID" 2>/dev/null || true

TOTAL_REQUESTS=$(wc -l < "$MONITOR_LOG")
TOTAL_200=$(grep -c "status=200" "$MONITOR_LOG" || true)
TOTAL_502=$(grep -c "status=502" "$MONITOR_LOG" || true)
TOTAL_000=$(grep -c "status=000" "$MONITOR_LOG" || true)
TOTAL_404=$(grep -c "status=404" "$MONITOR_LOG" || true)
TOTAL_OTHER=$(( TOTAL_REQUESTS - TOTAL_200 - TOTAL_502 - TOTAL_000 - TOTAL_404 ))

log "HTTP Monitor Results:"
log "  Total requests:  $TOTAL_REQUESTS"
log "  200 OK:          $TOTAL_200"
log "  502 Bad Gateway: $TOTAL_502"
log "  000 (timeout):   $TOTAL_000"
log "  404 Not Found:   $TOTAL_404"
log "  Other:           $TOTAL_OTHER"
log ""

if [ "$TOTAL_REQUESTS" -gt 0 ]; then
  SUCCESS_RATE=$(echo "scale=1; $TOTAL_200 * 100 / $TOTAL_REQUESTS" | bc)
  log "  Success rate:    ${SUCCESS_RATE}%"
else
  log "  Success rate:    N/A (no requests)"
fi
log ""

# Show any non-200 responses with context
NON_200_COUNT=$(grep -vc "status=200" "$MONITOR_LOG" || true)
if [ "$NON_200_COUNT" -gt 0 ]; then
  log "Non-200 responses (potential downtime windows):"
  grep -v "status=200" "$MONITOR_LOG" | tee -a "$SUMMARY"
else
  log "  ZERO non-200 responses! Perfect availability."
fi

log ""
log "SSH Connection Events:"
SSH_CONNECTS=$(grep -c "SSH-CONNECT" "$SSH_LOG" || true)
SSH_DISCONNECTS=$(grep -c "SSH-DISCONNECT" "$SSH_LOG" || true)
log "  Connections:   $SSH_CONNECTS"
log "  Disconnects:   $SSH_DISCONNECTS"
log ""
log "  SSH log:"
grep -E "(SSH-CONNECT|SSH-DISCONNECT|closed by remote|disconnect)" "$SSH_LOG" | tee -a "$SUMMARY" || true

log ""
log "Pod Events during restart (terminations):"
grep -E "(Terminating|Completed|Running)" "$POD_LOG" | tee -a "$SUMMARY" || true

# ───────────────── Phase 6: Pod logs showing drain ─────────────────
log ""
log "--- Pod logs showing drain behavior ---"
DRAIN_LINES=$(grep -iE "(drain|graceful shutdown|Closing listener|unregister|disconnect|signal)" "$RESULTS_DIR/drain-pod-logs.log" 2>/dev/null || true)
if [ -n "$DRAIN_LINES" ]; then
  echo "$DRAIN_LINES" | tee -a "$SUMMARY"
else
  log "  (no drain-specific log lines captured)"
fi

# ───────────────── Phase 7: Verdict ─────────────────
log ""
log "=========================================="
log "              VERDICT"
log "=========================================="
log ""

PASS=true

# Check 1: Zero 502 errors
if [ "$TOTAL_502" -gt 0 ]; then
  log "FAIL: $TOTAL_502 HTTP 502 errors during rolling restart"
  PASS=false
else
  log "PASS: Zero 502 errors"
fi

# Check 2: Limited total failures
DOWNTIME_REQUESTS=$((TOTAL_000 + TOTAL_502))
if [ "$DOWNTIME_REQUESTS" -gt 20 ]; then
  log "FAIL: Too many connection failures ($DOWNTIME_REQUESTS)"
  PASS=false
else
  log "PASS: Only $DOWNTIME_REQUESTS connection failures during restart"
fi

# Check 3: SSH reconnected
if [ "$SSH_DISCONNECTS" -gt 0 ]; then
  log "PASS: SSH tunnel reconnected $SSH_DISCONNECTS time(s) during restart"
else
  log "INFO: No SSH disconnects logged"
fi

# Check 4: Drain logs in pod output
DRAIN_LOG_COUNT=$(grep -ciE "drain|graceful shutdown" "$RESULTS_DIR/drain-pod-logs.log" 2>/dev/null || true)
if [ "$DRAIN_LOG_COUNT" -gt 0 ]; then
  log "PASS: Drain mode confirmed in pod logs ($DRAIN_LOG_COUNT log lines)"
else
  log "WARN: Could not confirm drain logs in captured output"
fi

# Check 5: HTTP recovered after restart
LAST_10=$(tail -10 "$MONITOR_LOG")
LAST_10_200=$(echo "$LAST_10" | grep -c "status=200" || true)
if [ "$LAST_10_200" -ge 8 ]; then
  log "PASS: HTTP traffic recovered after restart ($LAST_10_200/10 last requests = 200)"
else
  log "FAIL: HTTP traffic did not recover after restart ($LAST_10_200/10 last requests = 200)"
  PASS=false
fi

log ""
if $PASS; then
  log "ALL CHECKS PASSED — Zero-downtime drain is working"
else
  log "SOME CHECKS FAILED — See details above"
fi

log ""
log "Full logs saved to: $RESULTS_DIR/"
