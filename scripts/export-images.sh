#!/usr/bin/env bash
# Export all container images as a single tarball for air-gapped deployment.
#
# This script:
#   1. Builds local images (validation-server, key-validator)
#   2. Tags the tunnel image
#   3. Exports all images to a single .tar.gz archive
#   4. Outputs SHA256 checksum for integrity verification
#
# The resulting tarball can be transferred to an air-gapped environment
# and loaded into a registry or directly into a kind cluster.
#
# Usage: ./export-images.sh [output_file]
#   Default: asd-tunnel-images.tar.gz
#
# Load into kind:
#   tar xzf asd-tunnel-images.tar.gz
#   for img in *.tar; do kind load image-archive "$img" --name <cluster>; done
#
# Load into Docker (then push to internal registry):
#   tar xzf asd-tunnel-images.tar.gz
#   for img in *.tar; do docker load -i "$img"; done
#   docker tag asd-tunnel:k8s-demo REGISTRY.INTERNAL/asd-tunnel:latest
#   docker push REGISTRY.INTERNAL/asd-tunnel:latest
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT="${1:-asd-tunnel-images.tar.gz}"
WORK_DIR=$(mktemp -d)

trap 'rm -rf "$WORK_DIR"' EXIT

echo "=== ASD Tunnel Image Export ==="
echo ""

# ─── Step 1: Build local images ─────────────────────────────────────────────

echo "[1/4] Building validation-server image..."
docker build -t validation-server:local "$PROJECT_ROOT/services/validation-server/" -q

echo "[2/4] Building key-validator image..."
docker build -t key-validator:local "$PROJECT_ROOT/services/key-validator/" -q

# ─── Step 2: Ensure tunnel image exists ──────────────────────────────────────

echo "[3/4] Checking tunnel image..."
if ! docker image inspect asd-tunnel:k8s-demo >/dev/null 2>&1; then
  echo "  Pulling from GHCR (one-time download)..."
  docker pull ghcr.io/asd-engineering/asd-cli:asd-tunnel-latest
  docker tag ghcr.io/asd-engineering/asd-cli:asd-tunnel-latest asd-tunnel:k8s-demo
fi

# ─── Step 3: Export images ───────────────────────────────────────────────────

echo "[4/4] Exporting images to $OUTPUT..."

IMAGES=(
  "asd-tunnel:k8s-demo"
  "validation-server:local"
  "key-validator:local"
)

for img in "${IMAGES[@]}"; do
  safe_name=$(echo "$img" | tr ':/' '-')
  echo "  Saving $img..."
  docker save "$img" -o "$WORK_DIR/${safe_name}.tar"
done

# Also include caddy for with-caddy overlay
if docker image inspect caddy:2-alpine >/dev/null 2>&1; then
  echo "  Saving caddy:2-alpine..."
  docker save caddy:2-alpine -o "$WORK_DIR/caddy-2-alpine.tar"
else
  echo "  caddy:2-alpine not in local Docker — skipping (pull it first if needed)"
fi

# Create image manifest
cat > "$WORK_DIR/MANIFEST.txt" <<MANIFEST_EOF
ASD Tunnel K8s — Air-Gap Image Bundle
Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

Images included:
$(for img in "${IMAGES[@]}"; do
  digest=$(docker inspect "$img" --format='{{index .RepoDigests 0}}' 2>/dev/null || echo "local-only")
  size=$(docker inspect "$img" --format='{{.Size}}' 2>/dev/null | numfmt --to=iec 2>/dev/null || echo "unknown")
  echo "  - $img ($size) $digest"
done)

Load instructions:
  # Extract archive
  tar xzf $(basename "$OUTPUT")

  # Load into Docker
  for img in *.tar; do docker load -i "\$img"; done

  # Load into kind cluster
  for img in *.tar; do kind load image-archive "\$img" --name <cluster>; done

  # Push to internal registry
  docker tag asd-tunnel:k8s-demo REGISTRY.INTERNAL/asd-tunnel:latest
  docker tag validation-server:local REGISTRY.INTERNAL/validation-server:latest
  docker tag key-validator:local REGISTRY.INTERNAL/key-validator:latest
  docker push REGISTRY.INTERNAL/asd-tunnel:latest
  docker push REGISTRY.INTERNAL/validation-server:latest
  docker push REGISTRY.INTERNAL/key-validator:latest
MANIFEST_EOF

# Package everything
tar czf "$OUTPUT" -C "$WORK_DIR" .

# ─── Step 4: Checksum ───────────────────────────────────────────────────────

CHECKSUM=$(sha256sum "$OUTPUT" | awk '{print $1}')
SIZE=$(du -h "$OUTPUT" | awk '{print $1}')

echo ""
echo "=== Export Complete ==="
echo "  File:     $OUTPUT"
echo "  Size:     $SIZE"
echo "  SHA256:   $CHECKSUM"
echo ""
echo "Transfer this file to the air-gapped environment and follow"
echo "the instructions in docs/airgap-deployment.md"
