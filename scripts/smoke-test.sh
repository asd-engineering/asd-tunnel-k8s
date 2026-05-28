#!/usr/bin/env bash
# End-to-end smoke test: simulates the full customer flow across multiple
# terminals. Tears down, deploys, opens tunnel in background, curls, verifies,
# cleans up. Reports pass/fail per variant.
#
# Usage:
#   ./scripts/smoke-test.sh              # test the recommended HTTPS + auth path
#   ./scripts/smoke-test.sh all          # test all three quickstart variants

set -euo pipefail

VARIANT="${1:-https-auth}"
LOG_DIR=".asd/workspace/logs"
TUNNEL_PID=""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

pass=0
fail=0

step()    { printf "\n${BOLD}▸ %s${NC}\n" "$1"; }
ok()      { printf "  ${GREEN}✓${NC} %s\n" "$1"; pass=$((pass+1)); }
miss()    { printf "  ${RED}✗${NC} %s\n" "$1"; fail=$((fail+1)); }
info()    { printf "  %s\n" "$1"; }

cleanup() {
  if [ -n "$TUNNEL_PID" ] && kill -0 "$TUNNEL_PID" 2>/dev/null; then
    info "Stopping tunnel (PID $TUNNEL_PID)..."
    kill "$TUNNEL_PID" 2>/dev/null || true
    wait "$TUNNEL_PID" 2>/dev/null || true
  fi
  # Also kill any port-forward leftover
  pkill -f "port-forward.*validation-server" 2>/dev/null || true
  pkill -f "ssh.*-R.*tunnel" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ─────────────────────────────────────────────────────────────────────────────

test_variant() {
  local quickstart_task="$1"
  local tunnel_task="$2"
  local test_url="$3"
  local test_resolve="$4"
  local variant_name="$5"

  step "Variant: $variant_name"

  # 1. Clean slate
  info "Tearing down any existing cluster..."
  asd run teardown > /dev/null 2>&1 || true
  asd down > /dev/null 2>&1 || true

  # 2. Run the quickstart variant
  info "Running: asd run $quickstart_task (this takes ~60s)..."
  if asd run "$quickstart_task" > "$LOG_DIR/smoke-$quickstart_task.log" 2>&1; then
    ok "Cluster deployed"
  else
    miss "Cluster deployment failed — see $LOG_DIR/smoke-$quickstart_task.log"
    return 1
  fi

  # 3. Verify pods are running
  local pod_count
  pod_count=$(kubectl get pods -n asd-tunnel-demo --no-headers 2>/dev/null | grep -c "Running" || echo 0)
  if [ "$pod_count" -ge 2 ]; then
    ok "Pods running: $pod_count"
  else
    miss "Expected >=2 running pods, got $pod_count"
    return 1
  fi

  # 4. Start tunnel in background (simulates terminal 2)
  info "Starting tunnel in background: asd run $tunnel_task..."
  asd run "$tunnel_task" > "$LOG_DIR/smoke-$tunnel_task.log" 2>&1 &
  TUNNEL_PID=$!

  # Wait for tunnel to be fully usable — keep trying curl until we get valid JSON
  local waited=0
  local response=""
  local tunnel_up=false
  while [ "$waited" -lt 30 ]; do
    response=$(curl -sk -m 3 --resolve "$test_resolve" "$test_url" 2>&1 || true)
    if echo "$response" | jq -e '.method == "GET"' > /dev/null 2>&1; then
      tunnel_up=true
      break
    fi
    sleep 1
    waited=$((waited+1))
  done

  if $tunnel_up; then
    ok "Tunnel established (took ${waited}s)"
  else
    miss "Tunnel did not become usable within 30s — see $LOG_DIR/smoke-$tunnel_task.log"
    cleanup
    return 1
  fi

  # 5. Verify the test response we already have (simulates terminal 3 — successful curl)
  info "Testing: curl $test_url"
  local host
  host=$(echo "$response" | jq -r '.host')
  ok "HTTP response valid (method=GET, host=$host)"

  # 6. Clean up tunnel
  cleanup
  TUNNEL_PID=""

  # 7. Confirm tunnel stopped
  if ! pgrep -f "ssh.*-R.*tunnel" > /dev/null 2>&1; then
    ok "Tunnel stopped cleanly"
  else
    miss "Tunnel did not stop"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════"
echo "  ASD Tunnel — End-to-End Smoke Test"
echo "════════════════════════════════════════════════════"

case "$VARIANT" in
  https-auth)
    test_variant \
      "quickstart-https" \
      "tunnel-auth" \
      "https://app.tunnel.localhost:30443/echo" \
      "app.tunnel.localhost:30443:127.0.0.1" \
      "HTTPS + SSH auth"
    ;;
  https-noauth)
    test_variant \
      "quickstart-https-noauth" \
      "tunnel" \
      "https://app.tunnel.localhost:30443/echo" \
      "app.tunnel.localhost:30443:127.0.0.1" \
      "HTTPS without auth"
    ;;
  http-auth)
    test_variant \
      "quickstart-http-auth" \
      "tunnel-auth" \
      "http://app.tunnel.local:30080/echo" \
      "app.tunnel.local:30080:127.0.0.1" \
      "HTTP-based auth"
    ;;
  all)
    test_variant "quickstart-https" "tunnel-auth" \
      "https://app.tunnel.localhost:30443/echo" \
      "app.tunnel.localhost:30443:127.0.0.1" \
      "HTTPS + SSH auth"
    test_variant "quickstart-https-noauth" "tunnel" \
      "https://app.tunnel.localhost:30443/echo" \
      "app.tunnel.localhost:30443:127.0.0.1" \
      "HTTPS without auth"
    test_variant "quickstart-http-auth" "tunnel-auth" \
      "http://app.tunnel.local:30080/echo" \
      "app.tunnel.local:30080:127.0.0.1" \
      "HTTP-based auth"
    ;;
  *)
    echo "Unknown variant: $VARIANT"
    echo "Usage: $0 [https-auth|https-noauth|http-auth|all]"
    exit 2
    ;;
esac

# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════"
if [ "$fail" -eq 0 ]; then
  printf "  ${GREEN}${BOLD}✓ All checks passed${NC} (%d/%d)\n" "$pass" "$((pass + fail))"
else
  printf "  ${RED}${BOLD}✗ %d failed${NC} (%d passed)\n" "$fail" "$pass"
fi
echo "════════════════════════════════════════════════════"
echo ""

[ "$fail" -eq 0 ]
