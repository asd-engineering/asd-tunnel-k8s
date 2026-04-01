#!/usr/bin/env bash
# DEPRECATED: Prefer `asd run tunnel` (or `asd run tunnel-auth`) which uses
# declarative step composition in asd.yaml. This script is kept for standalone
# use without the asd CLI.
#
# Create an SSH tunnel from the validation server to the tunnel cluster.
# Uses kubectl port-forward to make the validation server accessible locally,
# then creates an SSH tunnel through the asd-tunnel server.
#
# Usage: ./create-tunnel.sh [subdomain] [--auth <keyfile>]
set -euo pipefail

SUBDOMAIN="${1:-app}"
SSH_PORT="${TUNNEL_SSH_PORT:-30022}"
SSH_HOST="${TUNNEL_HOST:-localhost}"
NAMESPACE="${NAMESPACE:-asd-tunnel-demo}"
LOCAL_PORT="${LOCAL_PORT:-18080}"
AUTH_KEY=""

shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --auth) AUTH_KEY="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Build SSH options
SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -p "$SSH_PORT"
)

if [ -n "$AUTH_KEY" ]; then
  SSH_OPTS+=(-o IdentitiesOnly=yes -i "$AUTH_KEY")
fi

# Cleanup on exit
cleanup() {
  [ -n "${PF_PID:-}" ] && kill "$PF_PID" 2>/dev/null
  exit 0
}
trap cleanup EXIT INT TERM

# Port-forward the validation server to localhost
# SSH -R resolves the target on the CLIENT side, so the target must be
# reachable from the host — ClusterIPs are not, hence the port-forward.
echo "Starting port-forward to validation-server..."
kubectl port-forward -n "$NAMESPACE" svc/validation-server "${LOCAL_PORT}:8080" &
PF_PID=$!
sleep 2

# Verify port-forward is working
if ! curl -sf -m 3 "http://localhost:${LOCAL_PORT}/health" > /dev/null 2>&1; then
  echo "Error: port-forward to validation-server failed."
  exit 1
fi

TUNNEL_TARGET="localhost:${LOCAL_PORT}"

echo ""
echo "Creating tunnel:"
echo "  Subdomain:  $SUBDOMAIN"
echo "  SSH target:  ${SSH_HOST}:${SSH_PORT}"
echo "  Backend:     $TUNNEL_TARGET (via port-forward)"
echo "  Access URL:  curl --resolve ${SUBDOMAIN}.tunnel.local:30080:127.0.0.1 http://${SUBDOMAIN}.tunnel.local:30080/echo"
echo ""
echo "Press Ctrl+C to close the tunnel."
echo ""

# The -R flag creates a remote forward:
#   subdomain:80 on the tunnel server routes HTTP traffic through the SSH
#   channel back to the client, which connects to localhost:LOCAL_PORT
ssh "${SSH_OPTS[@]}" \
  -N \
  -R "${SUBDOMAIN}:80:${TUNNEL_TARGET}" \
  "$SSH_HOST"
