#!/usr/bin/env bash
# Test: NATS cross-pod routing verification.
# Creates a tunnel to one pod, then verifies the tunnel is accessible from all pods
# via their individual HTTP muxers (port 8081).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

NAMESPACE="${NAMESPACE:-asd-tunnel-demo}"
SUBDOMAIN="${1:-app}"
REPLICAS="${2:-3}"

log_info "Cross-pod test: verifying tunnel '$SUBDOMAIN' accessible from $REPLICAS pods"

passed=0
failed=0

for i in $(seq 0 $((REPLICAS - 1))); do
  pod="asd-tunnel-$i"
  log_info "Testing via $pod..."

  # Use kubectl exec to curl from inside each pod
  uuid="$(gen_uuid)"
  response=$(kubectl exec -n "$NAMESPACE" "$pod" -c asd-tunnel -- \
    sh -c "
      if command -v curl >/dev/null 2>&1; then
        curl -sf --max-time 10 \
          -H 'X-Request-ID: $uuid' \
          -H 'Host: ${SUBDOMAIN}.${TUNNEL_DOMAIN}' \
          http://localhost:8081/echo 2>/dev/null
      elif command -v wget >/dev/null 2>&1; then
        wget -qO- --timeout=10 \
          --header='X-Request-ID: $uuid' \
          --header='Host: ${SUBDOMAIN}.${TUNNEL_DOMAIN}' \
          http://localhost:8081/echo 2>/dev/null
      else
        echo '{\"error\":\"no_http_client\"}'
      fi
    " 2>/dev/null) || {
    failed=$((failed + 1))
    log_fail "$pod: kubectl exec failed"
    continue
  }

  got_id=$(echo "$response" | jq -r '.request_id // empty' 2>/dev/null)
  if [ "$got_id" = "$uuid" ]; then
    passed=$((passed + 1))
    log_pass "$pod: tunnel accessible (request_id roundtrip OK)"
  else
    # Check if the response indicates route not found vs actual failure
    error=$(echo "$response" | jq -r '.error // empty' 2>/dev/null)
    if [ "$error" = "no_http_client" ]; then
      log_info "$pod: no curl/wget in container, skipping"
    else
      failed=$((failed + 1))
      log_fail "$pod: unexpected response: $response"
    fi
  fi
done

total=$((passed + failed))
if [ "$failed" -eq 0 ] && [ "$passed" -gt 0 ]; then
  log_pass "cross-pod: $passed/$total pods can route to tunnel"
else
  log_fail "cross-pod: $passed/$total pods can route, $failed failed"
fi

json_result "cross_pod" \
  "$([ "$failed" -eq 0 ] && [ "$passed" -gt 0 ] && echo pass || echo fail)" \
  "{\"pods\":$REPLICAS,\"accessible\":$passed,\"failed\":$failed}"
