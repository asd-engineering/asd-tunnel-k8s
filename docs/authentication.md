# Authentication

ASD Tunnel supports two authentication modes for controlling who can create tunnels. Both are configured via Kustomize overlays.

## No Authentication (Default)

The base manifests and `minimal` overlay run without authentication. Any SSH client can connect and create a tunnel. Suitable for local development and testing.

## File-Based Authentication

The `file-auth` overlay enables SSH public key authentication by mounting a directory of `.pub` files into the tunnel pods.

### How It Works

1. Public keys are stored in a ConfigMap (`tunnel-pubkeys`)
2. The ConfigMap is mounted at `/etc/tunnel/pubkeys/` in each pod
3. When a client connects, the tunnel server checks the client's key against all `.pub` files in the directory
4. Only ED25519 keys are recommended

### Deploying

```bash
OVERLAY=file-auth asd run deploy
```

### Adding Keys

1. Place your `.pub` file in `k8s/overlays/file-auth/ssh-keys/`:
   ```bash
   cp ~/.ssh/id_ed25519.pub k8s/overlays/file-auth/ssh-keys/myname.pub
   ```

2. Update the ConfigMap in `pubkeys-configmap.yaml` or regenerate it:
   ```bash
   kubectl create configmap tunnel-pubkeys \
     --from-file=k8s/overlays/file-auth/ssh-keys/ \
     -n asd-tunnel-demo \
     --dry-run=client -o yaml > k8s/overlays/file-auth/pubkeys-configmap.yaml
   ```

3. Redeploy:
   ```bash
   kubectl apply -k k8s/overlays/file-auth
   ```

### Demo Key

A demo ED25519 keypair is generated automatically when you run `asd run quickstart-full`. The private key is not committed to the repository — it is created locally by `scripts/generate-demo-key.sh`. To use it:

```bash
asd run tunnel-auth
```

### Environment Variables

| Variable | Value | Description |
|----------|-------|-------------|
| `ASD_TUNNEL_AUTHENTICATION` | `true` | Enable authentication |
| `ASD_TUNNEL_AUTHENTICATION_KEYS_DIRECTORY` | `/etc/tunnel/pubkeys` | Directory containing `.pub` files |

## HTTP-Based Authentication

The `http-auth` overlay delegates key validation to an external HTTP service. This is the pattern used in production with Supabase API integration.

### How It Works

1. A `key-validator` service runs in the cluster
2. When a client connects, the tunnel server sends a POST request to the validator:
   ```json
   {
     "auth_key": "ssh-ed25519 AAAA...",
     "user": "username",
     "remote_addr": "10.0.0.1:1234"
   }
   ```
3. The validator responds with `200 + {"status":"approved"}` or `403 + {"status":"denied","reason":"..."}`
4. Only `ssh-ed25519` keys are accepted by the included validator

### Deploying

```bash
OVERLAY=http-auth asd run deploy
```

### Custom Validators

You can replace the included `key-validator` with any HTTP service that implements the same contract:

**Request** (POST to configured URL):
```json
{
  "auth_key": "ssh-ed25519 AAAA... comment",
  "user": "ssh-username",
  "remote_addr": "client-ip:port"
}
```

**Approved response** (HTTP 200):
```json
{"status": "approved", "user": "username"}
```

**Denied response** (HTTP 403):
```json
{"status": "denied", "reason": "description of why"}
```

### Client Authentication

The included key-validator optionally supports client authentication (for production scenarios where the tunnel server itself must authenticate):

```bash
REQUIRE_CLIENT_AUTH=true
ALLOWED_CLIENTS='[{"id":"tunnel-server","secret":"s3cret"}]'
```

The tunnel server would then send `X-Client-ID` and `X-Client-Secret` headers with each validation request.

### Environment Variables

| Variable | Value | Description |
|----------|-------|-------------|
| `ASD_TUNNEL_AUTHENTICATION` | `true` | Enable authentication |
| `ASD_TUNNEL_AUTHENTICATION_KEY_REQUEST_URL` | `http://key-validator...:3000/validate` | Validator endpoint |
