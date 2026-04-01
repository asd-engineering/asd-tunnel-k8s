#!/usr/bin/env bash
# End-to-end demo: expose a local HTTP service through the tunnel cluster.
#
# Prerequisites:
#   1. kind cluster running (./scripts/setup-cluster.sh)
#   2. Tunnel deployed (./scripts/deploy.sh minimal --build-services)
#   3. A local service running (e.g., python3 -m http.server 9000)
#
# This script:
#   1. Starts a simple HTTP server on a random port
#   2. Creates an SSH tunnel to expose it
#   3. Verifies access through the tunnel
#   4. Cleans up
set -euo pipefail

SSH_PORT="${TUNNEL_SSH_PORT:-30022}"
SSH_HOST="${TUNNEL_HOST:-localhost}"
SUBDOMAIN="demo-$$"
LOCAL_PORT=9876

echo "=== ASD Tunnel Demo ==="
echo ""

# Step 1: Start a simple local server
echo "Step 1: Starting local HTTP server on :${LOCAL_PORT}..."
python3 -c "
import http.server, socketserver, json, datetime
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps({
            'message': 'Hello from local service!',
            'time': datetime.datetime.now().isoformat(),
            'path': self.path
        }).encode())
    def log_message(self, *args): pass
socketserver.TCPServer(('', $LOCAL_PORT), Handler).serve_forever()
" &
SERVER_PID=$!
sleep 1

cleanup() {
  echo ""
  echo "Cleaning up..."
  kill "$SERVER_PID" 2>/dev/null || true
  kill "$TUNNEL_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Step 2: Create SSH tunnel
echo "Step 2: Creating tunnel (subdomain: $SUBDOMAIN)..."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  -p "$SSH_PORT" -N \
  -R "${SUBDOMAIN}:80:localhost:${LOCAL_PORT}" \
  "$SSH_HOST" &
TUNNEL_PID=$!
sleep 3

# Step 3: Verify access
echo "Step 3: Verifying tunnel access..."
TUNNEL_URL="http://${SUBDOMAIN}.tunnel.local:30080"

response=$(curl -sf --max-time 5 \
  -H "Host: ${SUBDOMAIN}.tunnel.local" \
  "$TUNNEL_URL/" 2>/dev/null) || {
  echo "Error: Could not reach tunnel at $TUNNEL_URL"
  echo "Make sure tunnel.local resolves to 127.0.0.1"
  echo "Add to /etc/hosts: 127.0.0.1 ${SUBDOMAIN}.tunnel.local"
  exit 1
}

echo ""
echo "Response from tunnel:"
echo "$response" | python3 -m json.tool 2>/dev/null || echo "$response"
echo ""
echo "=== Success! ==="
echo "Your local service is accessible at: $TUNNEL_URL"
echo "Press Ctrl+C to stop."
echo ""

# Keep running until interrupted
wait "$TUNNEL_PID"
