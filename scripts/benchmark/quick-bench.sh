#!/usr/bin/env bash
# Quick benchmark: roundtrip + payload + concurrent through the tunnel.
# Usage: ./scripts/benchmark/quick-bench.sh [subdomain]
set -euo pipefail

SUBDOMAIN="${1:-app}"
DOMAIN="${TUNNEL_DOMAIN:-tunnel.local}"
PORT="${TUNNEL_HTTP_PORT:-30080}"
HOST_HEADER="${SUBDOMAIN}.${DOMAIN}"
BASE_URL="http://localhost:${PORT}"

pass=0
fail=0
total=0

result() {
  total=$((total + 1))
  if [ "$1" = "pass" ]; then
    pass=$((pass + 1))
    printf "  \033[32m✓\033[0m %s\n" "$2"
  else
    fail=$((fail + 1))
    printf "  \033[31m✗\033[0m %s — %s\n" "$2" "$3"
  fi
}

echo ""
echo "══════════════════════════════════════════"
echo "  ASD Tunnel — Quick Benchmark"
echo "  Target: ${HOST_HEADER} via ${BASE_URL}"
echo "══════════════════════════════════════════"
echo ""

# --- Test 1: Roundtrip ---
echo "▸ Roundtrip"
uuid="bench-$(date +%s)"
got=$(curl -sf -H "X-Request-ID: $uuid" -H "Host: $HOST_HEADER" "${BASE_URL}/echo" | jq -r '.request_id' 2>/dev/null || echo "")
if [ "$got" = "$uuid" ]; then
  result pass "Echo returns correct X-Request-ID"
else
  result fail "Echo returns correct X-Request-ID" "expected=$uuid got=$got"
fi

# --- Test 2: Payload upload (1MB) ---
echo ""
echo "▸ Payload integrity"
dd if=/dev/urandom of=/tmp/bench-1m.bin bs=1048576 count=1 2>/dev/null
expected=$(sha256sum /tmp/bench-1m.bin | awk '{print $1}')
got=$(curl -sf -X POST --data-binary @/tmp/bench-1m.bin -H "Host: $HOST_HEADER" "${BASE_URL}/hash" | jq -r '.sha256' 2>/dev/null || echo "")
rm -f /tmp/bench-1m.bin
if [ "$got" = "$expected" ]; then
  result pass "1MB upload — SHA-256 match"
else
  result fail "1MB upload — SHA-256 match" "hash mismatch"
fi

# --- Test 3: Payload download (1MB) ---
curl -sf -D /tmp/bench-headers.txt -o /tmp/bench-dl.bin -H "Host: $HOST_HEADER" "${BASE_URL}/payload/1048576"
expected=$(grep -i X-Payload-SHA256 /tmp/bench-headers.txt | tr -d '\r' | awk '{print $2}')
got=$(sha256sum /tmp/bench-dl.bin | awk '{print $1}')
rm -f /tmp/bench-dl.bin /tmp/bench-headers.txt
if [ "$got" = "$expected" ]; then
  result pass "1MB download — SHA-256 match"
else
  result fail "1MB download — SHA-256 match" "hash mismatch"
fi

# --- Test 4: Concurrent isolation (10 parallel) ---
echo ""
echo "▸ Concurrent isolation"
tmpdir=$(mktemp -d)
for i in $(seq 1 10); do
  uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)
  echo "$uuid" > "$tmpdir/uuid-$i"
  curl -sf -H "X-Request-ID: $uuid" -H "Host: $HOST_HEADER" "${BASE_URL}/echo" > "$tmpdir/result-$i" &
done
wait
concurrent_pass=0
for i in $(seq 1 10); do
  expected=$(cat "$tmpdir/uuid-$i")
  got=$(jq -r '.request_id' "$tmpdir/result-$i" 2>/dev/null || echo "")
  [ "$got" = "$expected" ] && concurrent_pass=$((concurrent_pass + 1))
done
rm -rf "$tmpdir"
if [ "$concurrent_pass" -eq 10 ]; then
  result pass "10/10 parallel requests — no cross-contamination"
else
  result fail "Parallel requests" "${concurrent_pass}/10 passed"
fi

# --- Summary ---
echo ""
echo "══════════════════════════════════════════"
if [ "$fail" -eq 0 ]; then
  printf "  \033[32m✓ All %d tests passed\033[0m\n" "$total"
else
  printf "  \033[31m✗ %d/%d tests failed\033[0m\n" "$fail" "$total"
fi
echo "══════════════════════════════════════════"
echo ""

[ "$fail" -eq 0 ]
