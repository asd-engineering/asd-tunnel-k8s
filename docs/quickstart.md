# Quickstart

Get an ASD Tunnel cluster running on a local kind cluster in 5 minutes.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [ASD CLI](https://github.com/asd-engineering/asd-cli) (`asd run` task runner)
- SSH client (`ssh`)

## 1. Initialize and deploy

```bash
# Initialize environment variables
asd env init

# Create cluster + deploy single-replica setup
asd run quickstart
```

For a full 3-node NATS cluster with file-based auth:

```bash
asd run quickstart-full
```

## 2. Create a tunnel

In a separate terminal:

```bash
asd run tunnel
```

This starts a port-forward to the validation server, then creates an SSH tunnel forwarding `app.tunnel.local` through the tunnel cluster.

For the `file-auth` overlay, use the included demo key:

```bash
asd run tunnel-auth
```

For auto-reconnecting tunnels (using the asd-tunnel client binary):

```bash
asd run tunnel-client
```

> **Note:** `asd-tunnel connect` automatically reconnects on network drops, combining the functionality of autossh and askpass into a single binary.

## 3. Test it

In another terminal:

```bash
curl --resolve "app.tunnel.local:30080:127.0.0.1" \
  http://app.tunnel.local:30080/echo
```

You should see a JSON response with your request metadata echoed back.

## 4. Run benchmarks

```bash
# Built-in benchmark (roundtrip + payload + concurrent)
asd run bench

# Full script-based benchmarks
asd run bench-roundtrip      # 100 UUID echoes
asd run bench-payload        # 12MB + 25MB SHA-256 integrity
asd run bench-concurrent     # 20 parallel isolated requests
```

## 5. Check cluster status

```bash
asd run status
```

## Cleanup

```bash
asd run teardown
```

## Next Steps

- [Authentication modes](authentication.md) - File-based and HTTP-based auth
- [Benchmarking](benchmarking.md) - Understanding the test suite
- [Rolling upgrades](rolling-upgrade.md) - Zero-downtime upgrade verification
- [Architecture](architecture.md) - Component design and data flow
