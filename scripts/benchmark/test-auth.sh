#!/usr/bin/env bash
# Authentication tests for file-based SSH key auth.
#
# Requires: file-auth overlay deployed with ASD_TUNNEL_AUTHENTICATION=true
# and the demo public key loaded into the tunnel-pubkeys ConfigMap.
#
# Tests:
#   1. Valid key → tunnel created successfully
#   2. Invalid key → connection REJECTED
#   3. No key when auth required → connection REJECTED
#   4. Wrong key type (RSA) → connection REJECTED
#   5. Revoked key (removed from ConfigMap) → connection REJECTED
#
# Usage: ./test-auth.sh [subdomain_prefix]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

PREFIX="${1:-authtest}"
LOCAL_PORT="${LOCAL_PORT:-18080}"
SSH_HOST="${TUNNEL_HOST:-127.0.0.1}"
SSH_PORT="${TUNNEL_SSH_PORT:-30022}"
NAMESPACE="${NAMESPACE:-asd-tunnel-demo}"
KEY_DIR="$(cd "$SCRIPT_DIR/../../k8s/overlays/file-auth/ssh-keys" && pwd)"

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
total=5

# ─── Helper: attempt SSH tunnel, return 0 if tunnel established ──────────────

try_tunnel() {
  local subdomain="$1"
  shift
  local ssh_pid

  # Start SSH tunnel in background
  ssh "${SSH_OPTS[@]}" "$@" \
    -p "$SSH_PORT" \
    -N \
    -R "${subdomain}:80:localhost:${LOCAL_PORT}" \
    "$SSH_HOST" &
  ssh_pid=$!

  # Give it time to either connect or fail
  sleep 3

  # Check if process is still running (connected)
  if kill -0 "$ssh_pid" 2>/dev/null; then
    # Tunnel established — verify it's actually routing
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
    # Process exited (rejected)
    wait "$ssh_pid" 2>/dev/null || true
    return 1
  fi
}

# ─── Test 1: Valid key → accepted ────────────────────────────────────────────

log_info "Test 1: Valid key → tunnel should be accepted"

if [ ! -f "$KEY_DIR/demo" ]; then
  log_fail "Test 1: Private key not found at $KEY_DIR/demo"
  log_info "  Generate with: ssh-keygen -t ed25519 -f $KEY_DIR/demo -C demo@asd-tunnel-k8s -N ''"
  failed=$((failed + 1))
else
  subdomain="${PREFIX}-valid"
  if try_tunnel "$subdomain" -i "$KEY_DIR/demo"; then
    log_pass "Test 1: Valid key accepted, tunnel routable"
    passed=$((passed + 1))
  else
    log_fail "Test 1: Valid key was rejected or tunnel not routable"
    failed=$((failed + 1))
  fi
fi

# ─── Test 2: Invalid key → rejected ─────────────────────────────────────────

log_info "Test 2: Invalid (unknown) key → tunnel should be rejected"

# Generate a throwaway key not in the ConfigMap
ssh-keygen -t ed25519 -f "$WORK_DIR/invalid-key" -C "invalid@test" -N "" -q

subdomain="${PREFIX}-invalid"
if try_tunnel "$subdomain" -i "$WORK_DIR/invalid-key"; then
  log_fail "Test 2: Invalid key was ACCEPTED (should have been rejected)"
  failed=$((failed + 1))
else
  log_pass "Test 2: Invalid key correctly rejected"
  passed=$((passed + 1))
fi

# ─── Test 3: No key → rejected ──────────────────────────────────────────────

log_info "Test 3: No key (password auth) → tunnel should be rejected"

subdomain="${PREFIX}-nokey"
# Use BatchMode=yes to disable interactive password prompt
if ssh "${SSH_OPTS[@]}" -o BatchMode=yes \
  -p "$SSH_PORT" \
  -N \
  -R "${subdomain}:80:localhost:${LOCAL_PORT}" \
  "$SSH_HOST" &
then
  nokey_pid=$!
  sleep 3
  if kill -0 "$nokey_pid" 2>/dev/null; then
    log_fail "Test 3: No-key connection was ACCEPTED (should have been rejected)"
    kill "$nokey_pid" 2>/dev/null
    wait "$nokey_pid" 2>/dev/null || true
    failed=$((failed + 1))
  else
    wait "$nokey_pid" 2>/dev/null || true
    log_pass "Test 3: No-key connection correctly rejected"
    passed=$((passed + 1))
  fi
fi

# ─── Test 4: Wrong key type (RSA) → rejected ────────────────────────────────

log_info "Test 4: Wrong key type (RSA, not in authorized list) → should be rejected"

ssh-keygen -t rsa -b 2048 -f "$WORK_DIR/rsa-key" -C "rsa@test" -N "" -q

subdomain="${PREFIX}-rsa"
if try_tunnel "$subdomain" -i "$WORK_DIR/rsa-key"; then
  log_fail "Test 4: RSA key was ACCEPTED (should have been rejected)"
  failed=$((failed + 1))
else
  log_pass "Test 4: RSA key correctly rejected"
  passed=$((passed + 1))
fi

# ─── Test 5: Key removed from ConfigMap → rejected after pod restart ────────

log_info "Test 5: Revoked key (removed from ConfigMap) → should be rejected"

# Create a temporary key, add to ConfigMap, verify it works, remove, verify rejection
ssh-keygen -t ed25519 -f "$WORK_DIR/revoke-key" -C "revoke@test" -N "" -q
revoke_pub=$(cat "$WORK_DIR/revoke-key.pub")

# Add to ConfigMap
kubectl patch configmap tunnel-pubkeys -n "$NAMESPACE" \
  --type merge -p "{\"data\":{\"revoke.pub\":\"$revoke_pub\"}}" 2>/dev/null || {
  log_fail "Test 5: Could not patch ConfigMap (is file-auth overlay deployed?)"
  failed=$((failed + 1))
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  AUTH TEST RESULTS: $passed/$total passed, $failed/$total failed"
  echo "═══════════════════════════════════════════════════════════════"
  [ "$failed" -eq 0 ] && exit 0 || exit 1
}

# Restart pods to pick up new ConfigMap
kubectl rollout restart statefulset/asd-tunnel -n "$NAMESPACE"
kubectl rollout status statefulset/asd-tunnel -n "$NAMESPACE" --timeout=120s

# Wait for SSH readiness
sleep 5

# Verify the key works before revocation
subdomain="${PREFIX}-revoke"
if ! try_tunnel "$subdomain" -i "$WORK_DIR/revoke-key"; then
  log_fail "Test 5: Newly-added key should have been accepted before revocation"
  failed=$((failed + 1))
else
  log_info "  Key accepted before revocation (expected)"

  # Now remove the key from ConfigMap
  kubectl patch configmap tunnel-pubkeys -n "$NAMESPACE" \
    --type json -p '[{"op":"remove","path":"/data/revoke.pub"}]'

  # Restart pods to pick up the change
  kubectl rollout restart statefulset/asd-tunnel -n "$NAMESPACE"
  kubectl rollout status statefulset/asd-tunnel -n "$NAMESPACE" --timeout=120s
  sleep 5

  subdomain="${PREFIX}-revoke2"
  if try_tunnel "$subdomain" -i "$WORK_DIR/revoke-key"; then
    log_fail "Test 5: Revoked key was ACCEPTED after ConfigMap removal"
    failed=$((failed + 1))
  else
    log_pass "Test 5: Revoked key correctly rejected after ConfigMap removal"
    passed=$((passed + 1))
  fi
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  AUTH TEST RESULTS: $passed/$total passed, $failed/$total failed"
echo "═══════════════════════════════════════════════════════════════"
[ "$failed" -eq 0 ] && exit 0 || exit 1
