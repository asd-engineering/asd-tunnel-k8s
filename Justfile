# asd-tunnel-k8s task runner
# Thin wrapper around `asd run <task>` — all logic lives in asd.yaml.
# Run `just --list` for available recipes or `asd run` for the full set.

set dotenv-load := true
set dotenv-path := ".env"

# List available recipes
default:
    @just --list

# Check + install prerequisites
preflight:
    ./setup

preflight-dry-run:
    ./setup --dry-run

# --- Cluster Lifecycle ---

# Create kind cluster + deploy minimal overlay
quickstart:
    asd run quickstart

# Create kind cluster + deploy 3-node NATS cluster with file-auth
quickstart-full:
    asd run quickstart-full

# Delete kind cluster
teardown:
    asd run teardown

# Show pods, services, and port reachability
status:
    asd run status

# --- Build & Deploy ---

# Build all service Docker images
build:
    asd run build

# Deploy the overlay specified by $OVERLAY env var
deploy:
    asd run deploy

# Validate all 7 Kustomize overlays build
validate:
    asd run validate

# --- Tunnels ---

# Create SSH tunnel to validation server (minimal overlay)
tunnel:
    asd run tunnel

# Create authenticated SSH tunnel (file-auth overlay)
tunnel-auth:
    asd run tunnel-auth

# Create tunnel with asd-tunnel client (auto-reconnect)
tunnel-client:
    asd run tunnel-client

# --- Benchmarks ---

# Quick benchmark (roundtrip + payload + concurrent)
bench:
    asd run bench

bench-roundtrip:
    asd run bench-roundtrip

bench-payload:
    asd run bench-payload

bench-concurrent:
    asd run bench-concurrent

bench-cross-pod:
    asd run bench-cross-pod

bench-stress:
    asd run bench-stress

bench-auth:
    asd run bench-auth

bench-auth-http:
    asd run bench-auth-http

bench-resilience:
    asd run bench-resilience

bench-resource-limits:
    asd run bench-resource-limits

# --- Rolling Upgrade ---

rolling-upgrade:
    asd run rolling-upgrade

rolling-upgrade-full:
    asd run rolling-upgrade-full

# --- Tests ---

# Prove zero-downtime graceful drain (rolling restart)
test-drain:
    ./scripts/test-drain.sh

# Prove NATS retry recovers HTTP after ungraceful pod death
test-hardkill:
    ./scripts/test-hardkill-recovery.sh

# --- Docs Demo ---

docs:
    asd run docs

# --- Logs ---

# Follow tunnel pod logs
logs pod="0":
    kubectl logs -n ${NAMESPACE:-asd-tunnel-demo} asd-tunnel-{{pod}} -c asd-tunnel -f
