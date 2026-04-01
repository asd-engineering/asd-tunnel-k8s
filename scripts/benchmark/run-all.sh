#!/usr/bin/env bash
# Run the full benchmark suite and produce a JSON results file.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

SUBDOMAIN="${1:-app}"
OUTPUT="${2:-results.json}"

log_info "Starting benchmark suite (subdomain: $SUBDOMAIN)"
echo ""

# Collect test results
results=()
total=0
passed_count=0
failed_count=0

run_test() {
  local name="$1" script="$2"
  shift 2
  total=$((total + 1))
  log_info "=== $name ==="
  local result
  result=$("$script" "$@" 2>&1 | tail -1) || true

  # Extract status from JSON result line
  local status
  status=$(echo "$result" | jq -r '.status // "fail"' 2>/dev/null || echo "fail")

  if [ "$status" = "pass" ]; then
    passed_count=$((passed_count + 1))
  else
    failed_count=$((failed_count + 1))
  fi

  # Extract the details portion
  local details
  details=$(echo "$result" | jq -c '.details // {}' 2>/dev/null || echo '{}')

  results+=("{\"name\":\"$name\",\"status\":\"$status\",\"details\":$details}")
  echo ""
}

# Run all tests
run_test "roundtrip"  "$SCRIPT_DIR/test-roundtrip.sh" "$SUBDOMAIN"
run_test "payload"    "$SCRIPT_DIR/test-payload.sh" "$SUBDOMAIN"
run_test "concurrent" "$SCRIPT_DIR/test-concurrent.sh" "$SUBDOMAIN"

# Cross-pod test only if we have kubectl access and >1 replica
replicas=$(kubectl get statefulset asd-tunnel -n asd-tunnel-demo -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
if [ "$replicas" -gt 1 ]; then
  run_test "cross_pod" "$SCRIPT_DIR/test-cross-pod.sh" "$SUBDOMAIN" "$replicas"
else
  log_info "Skipping cross-pod test (replicas=$replicas)"
fi

# Build results JSON
tests_json=$(printf '%s,' "${results[@]}" | sed 's/,$//')
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

cat > "$OUTPUT" <<EOF
{
  "timestamp": "$timestamp",
  "tests": [$tests_json],
  "summary": {
    "total": $total,
    "passed": $passed_count,
    "failed": $failed_count
  }
}
EOF

log_info "Results written to $OUTPUT"
echo ""
if [ "$failed_count" -eq 0 ]; then
  log_pass "All $total tests passed"
else
  log_fail "$failed_count/$total tests failed"
fi
