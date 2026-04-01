# Air-Gap Deployment Guide

Deploy asd-tunnel-k8s in an environment with no internet access.

## Prerequisites

- Access to an internet-connected machine (one-time, for image export)
- A container registry accessible from the air-gapped cluster, **or** direct image loading via `kind` / `ctr`
- `kubectl` configured for the target cluster
- SSH key pair generated for tunnel authentication

## Step 1: Export Images (Internet-Connected Machine)

```bash
# Clone the repo and build images
git clone <repo-url> && cd asd-tunnel-k8s
./scripts/export-images.sh asd-tunnel-images.tar.gz
```

This produces a single `asd-tunnel-images.tar.gz` containing:

| Image | Purpose |
|-------|---------|
| `asd-tunnel:k8s-demo` | Tunnel server (SSH + HTTP muxer + NATS) |
| `validation-server:local` | Test/validation HTTP server |
| `key-validator:local` | HTTP-based SSH key validator |
| `caddy:2-alpine` | TLS termination sidecar (optional) |

Transfer this file to the air-gapped environment via USB, secure file transfer, or approved media.

## Step 2: Load Images

### Option A: Private Registry

```bash
# Extract the archive
tar xzf asd-tunnel-images.tar.gz

# Load images into Docker
for img in *.tar; do docker load -i "$img"; done

# Tag and push to internal registry
REGISTRY="registry.internal.company.com"

docker tag asd-tunnel:k8s-demo ${REGISTRY}/asd-tunnel:latest
docker tag validation-server:local ${REGISTRY}/validation-server:latest
docker tag key-validator:local ${REGISTRY}/key-validator:latest
docker tag caddy:2-alpine ${REGISTRY}/caddy:2-alpine

docker push ${REGISTRY}/asd-tunnel:latest
docker push ${REGISTRY}/validation-server:latest
docker push ${REGISTRY}/key-validator:latest
docker push ${REGISTRY}/caddy:2-alpine
```

### Option B: Kind Cluster (Development/Testing)

```bash
tar xzf asd-tunnel-images.tar.gz

for img in *.tar; do
  kind load image-archive "$img" --name asd-tunnel-demo
done
```

### Option C: Containerd (Production Clusters)

```bash
tar xzf asd-tunnel-images.tar.gz

for img in *.tar; do
  ctr -n k8s.io images import "$img"
done
```

## Step 3: Create Registry Credentials (Option A Only)

If using a private registry that requires authentication:

```bash
kubectl create namespace asd-tunnel-demo

kubectl create secret docker-registry registry-credentials \
  -n asd-tunnel-demo \
  --docker-server=registry.internal.company.com \
  --docker-username=<user> \
  --docker-password=<password>
```

## Step 4: Configure the Airgap Overlay

Edit `k8s/overlays/airgap/kustomization.yaml`:

```yaml
images:
  - name: asd-tunnel
    newName: registry.internal.company.com/asd-tunnel
    newTag: latest
    # For supply chain verification, pin by digest:
    # digest: sha256:<digest-from-export-manifest>
  - name: validation-server
    newName: registry.internal.company.com/validation-server
    newTag: latest
  - name: key-validator
    newName: registry.internal.company.com/key-validator
    newTag: latest
```

If using `imagePullSecrets`, verify `patch-airgap.yaml` has the correct secret name:

```yaml
spec:
  template:
    spec:
      imagePullSecrets:
        - name: registry-credentials  # Must match Step 3
```

If loading images directly (Option B/C), remove the `imagePullSecrets` from the patch since authentication isn't needed.

## Step 5: Generate SSH Keys

```bash
# Generate a key pair for tunnel authentication
ssh-keygen -t ed25519 -f k8s/overlays/file-auth/ssh-keys/demo \
  -C "tunnel@company.com" -N ""

# The public key is already referenced in pubkeys-configmap.yaml.
# For additional users, add their public keys to the ConfigMap.
```

## Step 6: Deploy

```bash
# Apply the airgap overlay
kubectl apply -k k8s/overlays/airgap

# Wait for rollout
kubectl rollout status statefulset/asd-tunnel -n asd-tunnel-demo --timeout=180s
kubectl rollout status deployment/validation-server -n asd-tunnel-demo --timeout=60s

# Verify pods
kubectl get pods -n asd-tunnel-demo
```

## Step 7: Verify

```bash
# Port-forward to test internally
kubectl port-forward -n asd-tunnel-demo svc/asd-tunnel-ssh 30022:2222 &
kubectl port-forward -n asd-tunnel-demo svc/asd-tunnel-http 30080:8081 &

# Test tunnel creation
ssh -o StrictHostKeyChecking=no -o IdentitiesOnly=yes -p 30022 \
  -i k8s/overlays/file-auth/ssh-keys/demo \
  -N -R "test:80:localhost:8080" 127.0.0.1
```

## Image Digest Pinning

For supply chain security, pin images by SHA256 digest instead of tag:

```bash
# Get the digest of a loaded image
docker inspect asd-tunnel:k8s-demo --format='{{.Id}}'

# Use in kustomization.yaml
images:
  - name: asd-tunnel
    newName: registry.internal.company.com/asd-tunnel
    digest: sha256:<full-digest>
```

## Production Considerations Beyond This Demo

For a production air-gapped deployment, also consider:

- **mTLS**: Deploy cert-manager with a local CA for encrypted inter-pod NATS traffic
- **Image Signing**: Use cosign/notation to sign and verify images before loading
- **SIEM Integration**: Forward structured JSON logs to your security monitoring platform
- **Ingress Controller**: Replace NodePort services with an internal Ingress/LoadBalancer
- **Network Segmentation**: Tighten NetworkPolicies to match your cluster's CIDR ranges
- **Secrets Management**: Use a secrets operator (Vault, Sealed Secrets) instead of ConfigMaps for SSH keys
