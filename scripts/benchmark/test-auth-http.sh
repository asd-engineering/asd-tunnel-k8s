#!/usr/bin/env bash
# HTTP authentication integration tests.
#
# Requires: http-auth overlay deployed with key-validator service running.
# The key-validator validates SSH public keys via HTTP POST /validate.
#
# Tests:
#   1. Valid ed25519 key → key-validator approves → tunnel created
#   2. Invalid key → key-validator rejects → connection refused
#   3. Key-validator down → tunnel server rejects (fail closed)
#
# Usage: ./test-auth-http.sh [subdomain_prefix]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

PREFIX="${1:-httpauth}"
LOCAL_PORT="${LOCAL_PORT:-18080}"
SSH_HOST="${TUNNEL_HOST:-127.0.0.1}"
SSH_PORT="${TUNNEL_SSH_PORT:-30022}"
NAMESPACE="${NAMESPACE:-asd-tunnel-demo}"

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o IdentitiesOnly=yes
  -o LogLevel=ERROR
  -o ConnectTimeout=10
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=2
)

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

passed=0
failed=0
total=3

# ─── Helper: attempt SSH tunnel, return 0 if tunnel established ──────────────

try_tunnel() {
  local subdomain="$1"
  shift
  local ssh_pid

  ssh "${SSH_OPTS[@]}" "$@" \
    -p "$SSH_PORT" \
    -N \
    -R "${subdomain}:80:localhost:${LOCAL_PORT}" \
    "$SSH_HOST" &
  ssh_pid=$!

  sleep 3

  if kill -0 "$ssh_pid" 2>/dev/null; then
    if tunnel_curl "$subdomain" -sf --max-time 5 \
      "$(tunnel_url "$subdomain")/health" >/dev/null 2>&1; then
      kill "$ssh_pid" 2>/dev/null
      wait "$ssh_pid" 2>/dev/null || true
      return 0
    fi
    kill "$ssh_pid" 2>/dev/null
    wait "$ssh_pid" 2>/dev/null || true
    return 1
  else
    wait "$ssh_pid" 2>/dev/null || true
    return 1
  fi
}

# ─── Test 1: Valid key → approved by key-validator ───────────────────────────

log_info "Test 1: Valid ed25519 key → key-validator should approve"

# Generate a key — the demo key-validator accepts any valid ed25519 key
ssh-keygen -t ed25519 -f "$WORK_DIR/valid-key" -C "valid@httpauth" -N "" -q

subdomain="${PREFIX}-valid"
if try_tunnel "$subdomain" -i "$WORK_DIR/valid-key"; then
  log_pass "Test 1: Valid key approved by key-validator, tunnel routable"
  passed=$((passed + 1))
else
  log_fail "Test 1: Valid key was rejected (key-validator may be down)"
  failed=$((failed + 1))
fi

# ─── Test 2: No key → rejected ──────────────────────────────────────────────

log_info "Test 2: No key (batch mode) → should be rejected"

subdomain="${PREFIX}-nokey"
if ssh "${SSH_OPTS[@]}" -o BatchMode=yes \
  -p "$SSH_PORT" \
  -N \
  -R "${subdomain}:80:localhost:${LOCAL_PORT}" \
  "$SSH_HOST" &
then
  nokey_pid=$!
  sleep 3
  if kill -0 "$nokey_pid" 2>/dev/null; then
    log_fail "Test 2: No-key connection was ACCEPTED"
    kill "$nokey_pid" 2>/dev/null
    wait "$nokey_pid" 2>/dev/null || true
    failed=$((failed + 1))
  else
    wait "$nokey_pid" 2>/dev/null || true
    log_pass "Test 2: No-key connection correctly rejected"
    passed=$((passed + 1))
  fi
fi

# ─── Test 3: Key-validator down → fail closed ───────────────────────────────

log_info "Test 3: Key-validator scaled to 0 → tunnel should reject (fail closed)"

# Scale down key-validator
kubectl scale deployment/key-validator -n "$NAMESPACE" --replicas=0
kubectl rollout status deployment/key-validator -n "$NAMESPACE" --timeout=30s 2>/dev/null || true
sleep 3

# Try to connect — should be rejected because validator is unreachable
ssh-keygen -t ed25519 -f "$WORK_DIR/failclose-key" -C "failclose@httpauth" -N "" -q

subdomain="${PREFIX}-failclose"
if try_tunnel "$subdomain" -i "$WORK_DIR/failclose-key"; then
  log_fail "Test 3: Connection ACCEPTED with key-validator down (should fail closed)"
  failed=$((failed + 1))
else
  log_pass "Test 3: Connection correctly rejected when key-validator is down (fail closed)"
  passed=$((passed + 1))
fi

# Restore key-validator
log_info "  Restoring key-validator..."
kubectl scale deployment/key-validator -n "$NAMESPACE" --replicas=1
kubectl rollout status deployment/key-validator -n "$NAMESPACE" --timeout=60s

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  HTTP AUTH TEST RESULTS: $passed/$total passed, $failed/$total failed"
echo "═══════════════════════════════════════════════════════════════"
[ "$failed" -eq 0 ] && exit 0 || exit 1
