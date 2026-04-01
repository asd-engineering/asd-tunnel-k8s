#!/usr/bin/env bash
# Test: Large payload integrity through tunnel.
# Sends 12MB and 25MB payloads, verifies SHA-256 matches on the other side.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

SUBDOMAIN="${1:-app}"
BASE_URL="$(tunnel_url "$SUBDOMAIN")"
TMPDIR="${TMPDIR:-/tmp}"

sizes=(12582912 26214400)  # 12MB, 25MB
results=()
all_pass=true

for size in "${sizes[@]}"; do
  mb=$(( size / 1048576 ))
  log_info "Testing ${mb}MB payload upload..."

  # Generate random payload and compute expected hash
  payload_file="$TMPDIR/payload-${size}.bin"
  dd if=/dev/urandom of="$payload_file" bs=1048576 count="$mb" 2>/dev/null
  expected_hash=$(sha256sum "$payload_file" | awk '{print $1}')

  # POST payload through tunnel to /hash endpoint
  response=$(tunnel_curl "$SUBDOMAIN" -sf --max-time 60 \
    -X POST \
    --data-binary "@${payload_file}" \
    "${BASE_URL}/hash" 2>/dev/null) || {
    log_fail "payload upload ${mb}MB: curl failed"
    results+=("{\"mb\":$mb,\"match\":false,\"error\":\"curl_failed\"}")
    all_pass=false
    rm -f "$payload_file"
    continue
  }

  got_hash=$(echo "$response" | jq -r '.sha256 // empty')
  got_size=$(echo "$response" | jq -r '.size // 0')

  if [ "$got_hash" = "$expected_hash" ] && [ "$got_size" = "$size" ]; then
    log_pass "payload upload ${mb}MB: hash matches ($got_hash)"
    results+=("{\"mb\":$mb,\"match\":true}")
  else
    log_fail "payload upload ${mb}MB: hash mismatch"
    echo "  expected: $expected_hash (size $size)"
    echo "  got:      $got_hash (size $got_size)"
    results+=("{\"mb\":$mb,\"match\":false}")
    all_pass=false
  fi

  rm -f "$payload_file"
done

# Test download via /payload/{size}
log_info "Testing deterministic payload download..."
download_size=1048576  # 1MB for download test
response_file="$TMPDIR/download-test.bin"
header_file="$TMPDIR/download-headers.txt"

tunnel_curl "$SUBDOMAIN" -sf --max-time 30 \
  -D "$header_file" \
  -o "$response_file" \
  "${BASE_URL}/payload/${download_size}" 2>/dev/null || {
  log_fail "payload download: curl failed"
  results+=("{\"mb\":1,\"direction\":\"download\",\"match\":false}")
  all_pass=false
}

if [ -f "$response_file" ] && [ -f "$header_file" ]; then
  expected_dl_hash=$(grep -i 'X-Payload-SHA256' "$header_file" | tr -d '\r' | awk '{print $2}')
  actual_dl_hash=$(sha256sum "$response_file" | awk '{print $1}')

  if [ -n "$expected_dl_hash" ] && [ "$actual_dl_hash" = "$expected_dl_hash" ]; then
    log_pass "payload download 1MB: hash matches ($actual_dl_hash)"
    results+=("{\"mb\":1,\"direction\":\"download\",\"match\":true}")
  else
    log_fail "payload download 1MB: hash mismatch"
    results+=("{\"mb\":1,\"direction\":\"download\",\"match\":false}")
    all_pass=false
  fi
fi

rm -f "$response_file" "$header_file"

status=$($all_pass && echo "pass" || echo "fail")
sizes_json=$(printf '%s,' "${results[@]}" | sed 's/,$//')
json_result "payload" "$status" "{\"sizes\":[$sizes_json]}"
