#!/usr/bin/env bash
# Orchestrate a rolling upgrade with continuous availability monitoring.
# Deploys the rolling-upgrade overlay, creates a tunnel, monitors during rollout.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../benchmark/lib.sh"

NAMESPACE="${NAMESPACE:-asd-tunnel-demo}"
SUBDOMAIN="${1:-app}"
LOGFILE="$SCRIPT_DIR/upgrade-monitor.log"

echo "============================================"
echo "  Rolling Upgrade Test"
echo "============================================"
echo ""

# Step 1: Verify deployment is ready
log_info "Step 1: Verifying current deployment..."
kubectl rollout status statefulset/asd-tunnel -n "$NAMESPACE" --timeout=120s
replicas=$(kubectl get statefulset asd-tunnel -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')
log_pass "StatefulSet ready ($replicas replicas)"
echo ""

# Step 2: Verify tunnel is working
log_info "Step 2: Verifying tunnel connectivity..."
URL="$(tunnel_url "$SUBDOMAIN")/echo"
if ! wait_ready "$URL" 15; then
  log_fail "Tunnel not reachable at $URL"
  log_info "Create a tunnel first: ./scripts/create-tunnel.sh"
  exit 1
fi
log_pass "Tunnel is reachable"
echo ""

# Step 3: Start background monitor
log_info "Step 3: Starting availability monitor..."
"$SCRIPT_DIR/monitor.sh" "$SUBDOMAIN" "$LOGFILE" &
MONITOR_PID=$!
sleep 2
log_pass "Monitor running (PID: $MONITOR_PID)"
echo ""

# Step 4: Trigger rolling restart
log_info "Step 4: Triggering rolling restart..."
kubectl rollout restart statefulset/asd-tunnel -n "$NAMESPACE"
log_info "Waiting for rollout to complete..."
kubectl rollout status statefulset/asd-tunnel -n "$NAMESPACE" --timeout=300s
log_pass "Rollout complete"
echo ""

# Step 5: Let monitor collect a few more probes after rollout
sleep 5

# Step 6: Stop monitor and analyze
log_info "Step 5: Analyzing results..."
kill "$MONITOR_PID" 2>/dev/null || true
wait "$MONITOR_PID" 2>/dev/null || true
echo ""

# Close the JSON array
echo "]" >> "$LOGFILE"

if [ ! -f "$LOGFILE" ]; then
  log_fail "No monitor log found"
  exit 1
fi

# Parse results
total_probes=$(jq 'length' "$LOGFILE" 2>/dev/null || echo 0)
success_probes=$(jq '[.[] | select(.status == 200)] | length' "$LOGFILE" 2>/dev/null || echo 0)
failed_probes=$(jq '[.[] | select(.status != 200)] | length' "$LOGFILE" 2>/dev/null || echo 0)
max_latency=$(jq '[.[].latency_ms] | max' "$LOGFILE" 2>/dev/null || echo -1)
avg_latency=$(jq '[.[].latency_ms] | add / length | floor' "$LOGFILE" 2>/dev/null || echo -1)

if [ "$total_probes" -gt 0 ]; then
  success_rate=$(( success_probes * 100 / total_probes ))
else
  success_rate=0
fi

# Calculate max gap between successful probes
max_gap=0
if [ "$failed_probes" -gt 0 ]; then
  # Find longest streak of consecutive failures
  max_gap=$(jq -r '
    [.[] | .status] |
    reduce .[] as $s (
      {streak: 0, max: 0};
      if $s != 200 then {streak: (.streak + 1), max: [.max, .streak + 1] | max}
      else {streak: 0, max: .max}
      end
    ) | .max
  ' "$LOGFILE" 2>/dev/null || echo 0)
  max_gap_ms=$((max_gap * 500))  # Each probe is ~500ms apart
fi

zero_downtime="false"
if [ "$failed_probes" -eq 0 ]; then
  zero_downtime="true"
fi

echo ""
echo "============================================"
echo "  Rolling Upgrade Report"
echo "============================================"
echo "  Total probes:      $total_probes"
echo "  Successful:        $success_probes"
echo "  Failed:            $failed_probes"
echo "  Success rate:      ${success_rate}%"
echo "  Avg latency:       ${avg_latency}ms"
echo "  Max latency:       ${max_latency}ms"
if [ "$failed_probes" -gt 0 ]; then
echo "  Max gap:           ${max_gap} probes (~${max_gap_ms}ms)"
fi
echo "  Zero downtime:     $zero_downtime"
echo "============================================"

if [ "$zero_downtime" = "true" ]; then
  log_pass "Zero-downtime rolling upgrade verified"
else
  log_fail "Downtime detected during rolling upgrade"
fi
