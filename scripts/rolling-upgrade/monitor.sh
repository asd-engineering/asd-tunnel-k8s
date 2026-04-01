#!/usr/bin/env bash
# Continuous probe during rolling upgrades.
# Sends requests every 500ms and logs timestamp, status, and latency.
# Usage: ./monitor.sh <subdomain> <logfile>
#   Stop with: kill $PID or Ctrl+C
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../benchmark/lib.sh"

SUBDOMAIN="${1:-app}"
LOGFILE="${2:-$SCRIPT_DIR/monitor.log}"
URL="$(tunnel_url "$SUBDOMAIN")/echo"

log_info "Starting continuous probe: $URL"
log_info "Logging to: $LOGFILE"
echo "[]" > "$LOGFILE.tmp"

probe_count=0
success_count=0
fail_count=0

cleanup() {
  # Write final summary
  echo ""
  log_info "Monitor stopped. Probes: $probe_count, Success: $success_count, Failed: $fail_count"

  # Close JSON array and move to final location
  if [ -f "$LOGFILE.tmp" ]; then
    echo "" >> "$LOGFILE.tmp"
    echo "]" >> "$LOGFILE.tmp"
    mv "$LOGFILE.tmp" "$LOGFILE"
  fi
}
trap cleanup EXIT

echo "[" > "$LOGFILE.tmp"
first=true

while true; do
  ts=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")
  start_ms=$(date +%s%N 2>/dev/null || echo "0")

  uuid="$(gen_uuid)"
  status_code=$(tunnel_curl "$SUBDOMAIN" -sf -o /dev/null -w '%{http_code}' --max-time 5 \
    -H "X-Request-ID: $uuid" \
    "$URL" 2>/dev/null) || status_code="000"

  end_ms=$(date +%s%N 2>/dev/null || echo "0")

  if [ "$start_ms" != "0" ] && [ "$end_ms" != "0" ]; then
    latency_ms=$(( (end_ms - start_ms) / 1000000 ))
  else
    latency_ms=-1
  fi

  probe_count=$((probe_count + 1))
  if [ "$status_code" = "200" ]; then
    success_count=$((success_count + 1))
  else
    fail_count=$((fail_count + 1))
  fi

  # Append probe entry
  entry="{\"ts\":\"$ts\",\"status\":$status_code,\"latency_ms\":$latency_ms}"
  if $first; then
    first=false
  else
    echo "," >> "$LOGFILE.tmp"
  fi
  echo "  $entry" >> "$LOGFILE.tmp"

  # Brief status line
  if [ "$status_code" = "200" ]; then
    printf "\r  probe #%d: %s (%dms)    " "$probe_count" "$status_code" "$latency_ms"
  else
    printf "\n  probe #%d: %s (%dms) *** FAIL ***\n" "$probe_count" "$status_code" "$latency_ms"
  fi

  sleep 0.5
done
