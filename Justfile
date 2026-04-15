# asd-tunnel-k8s task runner
# All recipes also available via: asd run <task>
# Environment from tpl.env → .env via: asd env init

set dotenv-load := true
set dotenv-path := ".env"

cluster_name := env("CLUSTER_NAME", "asd-tunnel-demo")
namespace := env("NAMESPACE", "asd-tunnel-demo")
overlay := env("OVERLAY", "minimal")
subdomain := env("SUBDOMAIN", "app")
tunnel_domain := env("TUNNEL_DOMAIN", "tunnel.local")
tunnel_http := env("TUNNEL_HTTP_PORT", "30080")
tunnel_ssh := env("TUNNEL_SSH_PORT", "30022")

# List available recipes
default:
    @just --list

# --- Cluster Lifecycle --- (asd run quickstart / asd run teardown)

# Create kind cluster + deploy minimal + wait for ready
quickstart: setup (deploy "minimal")

# Create kind cluster + deploy 3-node NATS cluster with file-auth
quickstart-full: setup (deploy "file-auth")

# Create kind cluster with port mappings
setup:
    ./scripts/setup-cluster.sh {{cluster_name}}

# Delete kind cluster
teardown:
    kind delete cluster --name {{cluster_name}}

# --- Build --- (asd run build)

# Build all service Docker images
build: build-validation build-validator

# Build validation-server image
build-validation:
    docker build -t validation-server:local services/validation-server/

# Build key-validator image
build-validator:
    docker build -t key-validator:local services/key-validator/

# Pull tunnel image from GHCR and load into kind
load-tunnel-image:
    docker pull ghcr.io/asd-engineering/asd-cli:asd-tunnel-latest
    docker tag ghcr.io/asd-engineering/asd-cli:asd-tunnel-latest asd-tunnel:k8s-demo
    kind load docker-image asd-tunnel:k8s-demo --name {{cluster_name}}

# Load all images into kind cluster
load-images: load-tunnel-image
    kind load docker-image validation-server:local --name {{cluster_name}}
    kind load docker-image key-validator:local --name {{cluster_name}}

# --- Deploy --- (asd run deploy)

# Deploy an overlay. Usage: just deploy [overlay]
deploy overlay=overlay: build-validation load-tunnel-image
    kind load docker-image validation-server:local --name {{cluster_name}}
    kubectl apply -k k8s/overlays/{{overlay}}
    kubectl rollout status statefulset/asd-tunnel -n {{namespace}} --timeout=180s
    kubectl rollout status deployment/validation-server -n {{namespace}} --timeout=60s 2>/dev/null || true
    @echo ""
    kubectl get pods -n {{namespace}} -o wide

# --- Tunnel --- (asd run tunnel / asd run tunnel-auth)

# Create SSH tunnel to validation server
tunnel subdomain=subdomain:
    ./scripts/create-tunnel.sh {{subdomain}}

# Create authenticated SSH tunnel (file-auth overlay)
tunnel-auth subdomain=subdomain:
    ./scripts/create-tunnel.sh {{subdomain}} --auth k8s/overlays/file-auth/ssh-keys/demo

# --- Benchmarks --- (asd run bench)

# Run all benchmarks
bench subdomain=subdomain:
    ./scripts/benchmark/run-all.sh {{subdomain}}

# Run roundtrip test (100 UUID header echoes)
bench-roundtrip subdomain=subdomain:
    ./scripts/benchmark/test-roundtrip.sh {{subdomain}}

# Run payload integrity test (12MB + 25MB SHA-256)
bench-payload subdomain=subdomain:
    ./scripts/benchmark/test-payload.sh {{subdomain}}

# Run concurrent isolation test (20 parallel requests)
bench-concurrent subdomain=subdomain:
    ./scripts/benchmark/test-concurrent.sh {{subdomain}}

# Run cross-pod NATS routing test
bench-cross-pod subdomain=subdomain:
    ./scripts/benchmark/test-cross-pod.sh {{subdomain}}

# --- Rolling Upgrade --- (asd run rolling-upgrade)

# Run rolling upgrade with availability monitoring
rolling-upgrade subdomain=subdomain:
    ./scripts/rolling-upgrade/run-upgrade.sh {{subdomain}}

# Start continuous availability monitor (Ctrl+C to stop)
monitor subdomain=subdomain:
    ./scripts/rolling-upgrade/monitor.sh {{subdomain}}

# --- Validation --- (asd run validate)

# Validate all Kustomize overlays build
validate:
    #!/usr/bin/env bash
    set -euo pipefail
    ok=0; fail=0
    for overlay in minimal file-auth http-auth with-caddy rolling-upgrade; do
      if kubectl kustomize k8s/overlays/$overlay > /dev/null 2>&1; then
        echo "  OK: $overlay"; ok=$((ok + 1))
      else
        echo "  FAIL: $overlay"
        kubectl kustomize k8s/overlays/$overlay 2>&1 | head -5
        fail=$((fail + 1))
      fi
    done
    echo ""; echo "$ok passed, $fail failed"
    [ "$fail" -eq 0 ]

# --- Status --- (asd run status)

# Show pod status
pods:
    kubectl get pods -n {{namespace}} -o wide

# Show services
services:
    kubectl get svc -n {{namespace}}

# Show all resources
status:
    kubectl get all -n {{namespace}}

# --- Tests --- (asd run test-drain / asd run test-hardkill)

# Prove zero-downtime graceful drain (rolling restart)
test-drain:
    ./scripts/test-drain.sh

# Prove NATS retry recovers HTTP after ungraceful pod death
test-hardkill:
    ./scripts/test-hardkill-recovery.sh

# Follow tunnel pod logs
logs pod="0":
    kubectl logs -n {{namespace}} asd-tunnel-{{pod}} -c asd-tunnel -f
