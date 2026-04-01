#!/usr/bin/env bash
# Test: UUID header roundtrip through tunnel.
# Sends 100 requests with unique X-Request-ID, validates each response echoes it back.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

SUBDOMAIN="${1:-app}"
COUNT="${2:-100}"

log_info "Roundtrip test: $COUNT requests to $(tunnel_url "$SUBDOMAIN")/echo"

passed=0
failed=0

for i in $(seq 1 "$COUNT"); do
  uuid="$(gen_uuid)"
  response=$(tunnel_curl "$SUBDOMAIN" -sf --max-time 10 \
    -H "X-Request-ID: $uuid" \
    "$(tunnel_url "$SUBDOMAIN")/echo" 2>/dev/null) || { failed=$((failed + 1)); continue; }

  got_id=$(echo "$response" | jq -r '.request_id // empty')
  if assert_eq "$got_id" "$uuid" "request $i: X-Request-ID roundtrip" 2>/dev/null; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    log_fail "request $i: expected=$uuid got=$got_id"
  fi
done

if [ "$failed" -eq 0 ]; then
  log_pass "roundtrip: $passed/$COUNT requests matched"
else
  log_fail "roundtrip: $passed/$COUNT passed, $failed/$COUNT failed"
fi

json_result "roundtrip" \
  "$([ "$failed" -eq 0 ] && echo pass || echo fail)" \
  "{\"total\":$COUNT,\"passed\":$passed,\"failed\":$failed}"
