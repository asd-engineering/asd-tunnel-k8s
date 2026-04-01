#!/usr/bin/env bash
# Test: Concurrent request isolation.
# Sends 20 parallel requests with unique UUIDs, validates no cross-contamination.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

SUBDOMAIN="${1:-app}"
CONCURRENCY="${2:-20}"
URL="$(tunnel_url "$SUBDOMAIN")/echo"
TMPDIR="${TMPDIR:-/tmp}"
WORK_DIR="$TMPDIR/concurrent-test-$$"
HOST="${SUBDOMAIN}.${TUNNEL_DOMAIN}"
mkdir -p "$WORK_DIR"

log_info "Concurrent test: $CONCURRENCY parallel requests to $URL"

# Launch parallel requests
pids=()
for i in $(seq 1 "$CONCURRENCY"); do
  uuid="$(gen_uuid)"
  echo "$uuid" > "$WORK_DIR/uuid-$i"
  (
    response=$(tunnel_curl "$SUBDOMAIN" -sf --max-time 15 \
      -H "X-Request-ID: $uuid" \
      "$URL" 2>/dev/null) || { echo "curl_failed" > "$WORK_DIR/result-$i"; exit; }
    echo "$response" > "$WORK_DIR/result-$i"
  ) &
  pids+=($!)
done

# Wait for all
for pid in "${pids[@]}"; do
  wait "$pid" 2>/dev/null || true
done

# Validate results
passed=0
failed=0
for i in $(seq 1 "$CONCURRENCY"); do
  expected=$(cat "$WORK_DIR/uuid-$i")
  result_file="$WORK_DIR/result-$i"

  if [ ! -f "$result_file" ]; then
    failed=$((failed + 1))
    log_fail "request $i: no response"
    continue
  fi

  result=$(cat "$result_file")
  if [ "$result" = "curl_failed" ]; then
    failed=$((failed + 1))
    log_fail "request $i: curl failed"
    continue
  fi

  got_id=$(echo "$result" | jq -r '.request_id // empty')
  if [ "$got_id" = "$expected" ]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    log_fail "request $i: cross-contamination! expected=$expected got=$got_id"
  fi
done

rm -rf "$WORK_DIR"

if [ "$failed" -eq 0 ]; then
  log_pass "concurrent: $passed/$CONCURRENCY requests isolated"
else
  log_fail "concurrent: $passed/$CONCURRENCY passed, $failed/$CONCURRENCY failed"
fi

json_result "concurrent" \
  "$([ "$failed" -eq 0 ] && echo pass || echo fail)" \
  "{\"concurrency\":$CONCURRENCY,\"passed\":$passed,\"failed\":$failed}"
