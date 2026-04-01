#!/bin/sh
set -e

cleanup() { kill "$DOCS_PID" 2>/dev/null; exit 0; }
trap cleanup TERM INT

python3 server.py &
DOCS_PID=$!
sleep 1

exec asd-tunnel connect \
  --no-auth \
  --server "${TUNNEL_HOST}:${TUNNEL_SSH_PORT}" \
  -F "${DOCS_SUBDOMAIN}:localhost:${DOCS_PORT}" \
  --reconnect
