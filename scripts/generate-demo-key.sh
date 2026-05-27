#!/usr/bin/env bash
# Generate the demo SSH keypair and update the pubkeys ConfigMap.
# Idempotent: skips if the private key already exists.
set -euo pipefail

KEY_DIR="k8s/overlays/file-auth/ssh-keys"
KEY_FILE="${KEY_DIR}/demo"
CONFIGMAP="k8s/overlays/file-auth/pubkeys-configmap.yaml"

if [ -f "$KEY_FILE" ]; then
  echo "Demo keypair already exists, skipping"
  exit 0
fi

ssh-keygen -t ed25519 -f "$KEY_FILE" -C "demo@asd-tunnel-k8s" -N "" -q
echo "Generated demo keypair"

# Rebuild ConfigMap from all .pub files in the directory
echo "# ConfigMap holding authorized SSH public keys." > "$CONFIGMAP"
echo "apiVersion: v1" >> "$CONFIGMAP"
echo "kind: ConfigMap" >> "$CONFIGMAP"
echo "metadata:" >> "$CONFIGMAP"
echo "  name: tunnel-pubkeys" >> "$CONFIGMAP"
echo "  namespace: asd-tunnel-demo" >> "$CONFIGMAP"
echo "data:" >> "$CONFIGMAP"

for pubfile in "${KEY_DIR}"/*.pub; do
  name=$(basename "$pubfile")
  key=$(cat "$pubfile")
  echo "  ${name}: |" >> "$CONFIGMAP"
  echo "    ${key}" >> "$CONFIGMAP"
done

echo "Updated pubkeys-configmap.yaml with $(ls "${KEY_DIR}"/*.pub | wc -l) key(s)"
