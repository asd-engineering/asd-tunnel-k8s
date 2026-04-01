#!/usr/bin/env bash
# Create a kind cluster with port mappings for asd-tunnel NodePort services.
set -euo pipefail

CLUSTER_NAME="${1:-asd-tunnel-demo}"

if ! command -v kind &>/dev/null; then
  echo "Error: 'kind' not found. Install from https://kind.sigs.k8s.io/"
  exit 1
fi

# Check if cluster already exists
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "Cluster '$CLUSTER_NAME' already exists."
  echo "To recreate: kind delete cluster --name $CLUSTER_NAME"
  exit 0
fi

echo "Creating kind cluster '$CLUSTER_NAME'..."

cat <<EOF | kind create cluster --name "$CLUSTER_NAME" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      # SSH tunnel creation
      - containerPort: 30022
        hostPort: 30022
        protocol: TCP
      # HTTP muxer (direct)
      - containerPort: 30080
        hostPort: 30080
        protocol: TCP
      # Caddy sidecar (with-caddy overlay)
      - containerPort: 30443
        hostPort: 30443
        protocol: TCP
EOF

echo ""
echo "Cluster '$CLUSTER_NAME' created."
echo "Context: kind-${CLUSTER_NAME}"
echo ""
echo "Port mappings:"
echo "  30022 → SSH (tunnel creation)"
echo "  30080 → HTTP (tunnel access)"
echo "  30443 → Caddy (with-caddy overlay)"
