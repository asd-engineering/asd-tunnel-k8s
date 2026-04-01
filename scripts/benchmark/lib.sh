#!/usr/bin/env bash
# Shared functions for benchmark scripts.
set -euo pipefail

TUNNEL_DOMAIN="${TUNNEL_DOMAIN:-tunnel.local}"
TUNNEL_HTTP_PORT="${TUNNEL_HTTP_PORT:-30080}"
TUNNEL_SSH_PORT="${TUNNEL_SSH_PORT:-30022}"
TUNNEL_HOST="${TUNNEL_HOST:-127.0.0.1}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

tunnel_url() {
  local subdomain="$1"
  echo "http://${subdomain}.${TUNNEL_DOMAIN}:${TUNNEL_HTTP_PORT}"
}

# curl wrapper that resolves *.tunnel.local to TUNNEL_HOST (default: 127.0.0.1).
# This avoids needing /etc/hosts entries for wildcard tunnel domains.
# Note: curl --resolve requires an IP address, not a hostname.
tunnel_curl() {
  local subdomain="$1"
  shift
  local host="${subdomain}.${TUNNEL_DOMAIN}"
  local resolve_ip="${TUNNEL_HOST}"
  # curl --resolve needs an IP, not a hostname
  [ "$resolve_ip" = "localhost" ] && resolve_ip="127.0.0.1"
  curl --resolve "${host}:${TUNNEL_HTTP_PORT}:${resolve_ip}" \
    -H "Host: ${host}" \
    "$@"
}

gen_uuid() {
  if command -v uuidgen &>/dev/null; then
    uuidgen
  elif [ -f /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    # Fallback: random hex
    od -x /dev/urandom | head -1 | awk '{print $2$3"-"$4$5"-"$6$7"-"$8$9}'
  fi
}

json_result() {
  local test="$1" status="$2"
  shift 2
  local details="$*"
  printf '{"test":"%s","status":"%s","details":%s}\n' "$test" "$status" "$details"
}

assert_eq() {
  local actual="$1" expected="$2" msg="$3"
  if [ "$actual" != "$expected" ]; then
    echo -e "${RED}FAIL${NC}: $msg"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    return 1
  fi
  return 0
}

wait_ready() {
  local url="$1" timeout="${2:-30}"
  local start elapsed
  start=$(date +%s)
  echo "Waiting for $url to be ready (timeout: ${timeout}s)..."
  while true; do
    if curl -sf -o /dev/null --max-time 2 "$url" 2>/dev/null; then
      echo -e "${GREEN}Ready${NC}: $url"
      return 0
    fi
    elapsed=$(( $(date +%s) - start ))
    if [ "$elapsed" -ge "$timeout" ]; then
      echo -e "${RED}Timeout${NC}: $url not ready after ${timeout}s"
      return 1
    fi
    sleep 1
  done
}

log_pass() { echo -e "${GREEN}PASS${NC}: $1"; }
log_fail() { echo -e "${RED}FAIL${NC}: $1"; }
log_info() { echo -e "${YELLOW}INFO${NC}: $1"; }
