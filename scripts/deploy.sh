#!/usr/bin/env bash
# Deploy an asd-tunnel overlay to the current Kubernetes cluster.
# Usage: ./deploy.sh <overlay> [--build-services]
#   overlay: minimal, with-caddy, file-auth, http-auth, rolling-upgrade
#   --build-services: build and load service images into kind first
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

OVERLAY="${1:-minimal}"
BUILD_SERVICES=false
CLUSTER_NAME="${CLUSTER_NAME:-asd-tunnel-demo}"
NAMESPACE="asd-tunnel-demo"

shift || true
for arg in "$@"; do
  case "$arg" in
    --build-services) BUILD_SERVICES=true ;;
  esac
done

OVERLAY_DIR="$REPO_ROOT/k8s/overlays/$OVERLAY"
if [ ! -d "$OVERLAY_DIR" ]; then
  echo "Error: overlay '$OVERLAY' not found at $OVERLAY_DIR"
  echo "Available overlays:"
  ls "$REPO_ROOT/k8s/overlays/"
  exit 1
fi

echo "Deploying overlay: $OVERLAY"
echo ""

# Build and load service images if requested
if $BUILD_SERVICES; then
  echo "Building and loading images..."

  # Pull tunnel image from GHCR (public) and load into kind
  TUNNEL_IMAGE="${TUNNEL_IMAGE:?TUNNEL_IMAGE not set — run 'asd env init' first}"
  echo "  Pulling tunnel image: $TUNNEL_IMAGE"
  docker pull "$TUNNEL_IMAGE"
  docker tag "$TUNNEL_IMAGE" asd-tunnel:k8s-demo
  kind load docker-image asd-tunnel:k8s-demo --name "$CLUSTER_NAME"

  if [ -d "$REPO_ROOT/services/validation-server" ]; then
    echo "  Building validation-server..."
    docker build -t validation-server:local "$REPO_ROOT/services/validation-server"
    kind load docker-image validation-server:local --name "$CLUSTER_NAME"
  fi

  if [ -d "$REPO_ROOT/services/key-validator" ] && [ "$OVERLAY" = "http-auth" ]; then
    echo "  Building key-validator..."
    docker build -t key-validator:local "$REPO_ROOT/services/key-validator"
    kind load docker-image key-validator:local --name "$CLUSTER_NAME"
  fi

  echo ""
fi

# Apply the overlay
echo "Applying kustomization..."
kubectl apply -k "$OVERLAY_DIR"

echo ""
echo "Waiting for StatefulSet rollout..."
kubectl rollout status statefulset/asd-tunnel -n "$NAMESPACE" --timeout=180s

echo ""
echo "Waiting for validation-server..."
kubectl rollout status deployment/validation-server -n "$NAMESPACE" --timeout=60s 2>/dev/null || true

echo ""
echo "Deployment complete."
echo ""
kubectl get pods -n "$NAMESPACE" -o wide
echo ""
echo "Services:"
kubectl get svc -n "$NAMESPACE"
