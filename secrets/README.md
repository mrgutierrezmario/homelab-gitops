# secrets/

Only `SealedSecret` manifests — encrypted to the cluster's controller, safe
to commit. Plain `Secret`s never go here; `.gitignore` refuses
`*.yaml.unsealed` and `*.key` as a second line of defence.

One directory per consumer, matching the Argo Application that mounts it:

```
secrets/
├── pub-cert.pem          # the controller's public key — lets kubeseal work without cluster access
├── tailscale/            # operator-oauth — read by apps/platform/tailscale-operator.yaml
├── insidertrack-mcp/     # mcp-tokens — read by apps/staging/insidertrack-mcp.yaml
└── insidertrack/         # insidertrack-db, insidertrack-app, insidertrack-rclone — apps/staging/insidertrack.yaml
```

## Sealing a secret

`kubeseal` (`brew install kubeseal`) encrypts to the controller's public
key. That key is committed as `pub-cert.pem` (public — safe), so sealing
works from any machine, the dev container included, with no kubeconfig:

```sh
kubectl create secret generic <name> -n <namespace> \
  --from-literal=KEY=value \
  --dry-run=client -o yaml \
  | kubeseal --cert secrets/pub-cert.pem --format yaml \
  > secrets/<consumer>/<name>.yaml
```

`--dry-run=client` means kubectl only prints the manifest; nothing touches
a cluster. Refresh `pub-cert.pem` after the controller's key is rotated or
the cluster rebuilt (needs `KUBECONFIG`; the controller is not in
kubeseal's default namespace):

```sh
kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets-controller --fetch-cert > secrets/pub-cert.pem
```

### The MCP tokens (phase 2)

Staging gets its own token — never production's. Name it after the client
that will hold it:

```sh
TOKEN=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
kubectl create secret generic mcp-tokens -n insidertrack-staging \
  --from-literal=MCP_TOKENS="claude-ai-staging:$TOKEN" \
  --dry-run=client -o yaml \
  | kubeseal --cert secrets/pub-cert.pem --format yaml \
  > secrets/insidertrack-mcp/mcp-tokens.yaml
echo "$TOKEN"      # paste into the claude.ai connector, then forget it
```

Commit the output. Argo applies it, the controller unseals it into a real
`Secret` in that namespace, and the consumer starts. The name and namespace
are part of the encryption — a sealed secret cannot be moved to another
namespace by editing the file.

### InsiderTrack (phase 3)

`insidertrack-db` and `insidertrack-app` were generated and sealed without
anyone reading them; read one back from the cluster when needed:

```sh
kubectl -n insidertrack-staging get secret insidertrack-app -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d; echo
```

`insidertrack-rclone` is the one only the Mac can produce — it holds the
Google Drive token and the crypt passphrase `deploy/backup-setup.sh`
created. Just the two remotes the restore needs, straight from rclone,
never through a file that outlives the command:

```sh
{ rclone config show gdrive-stock-tracker; echo; rclone config show stock-tracker-backup; } \
  | kubectl create secret generic insidertrack-rclone -n insidertrack-staging \
      --from-file=rclone.conf=/dev/stdin --dry-run=client -o yaml \
  | kubeseal --cert secrets/pub-cert.pem --format yaml \
  > secrets/insidertrack/insidertrack-rclone.yaml
```

That token can write to the backup folder. The restore only ever reads
(`rclone lsf`, `rclone copyto`), and Drive keeps 30 days of versions, so
the blast radius of a staging bug is bounded — but it is production's
backup credential living in the cluster; rotate it (`rclone config
reconnect gdrive-stock-tracker:` on the Mac, re-seal) if the cluster is
ever compromised. rclone will warn it cannot save a refreshed token to the
read-only mount; harmless, the refresh token itself does not change.

## The Tailscale OAuth client (first secret, phase 1)

This one is sealed before `pub-cert.pem` exists, so it uses the cluster
directly:

```sh
export KUBECONFIG=~/.lima/k3s/copied-from-guest/kubeconfig.yaml
kubectl create secret generic operator-oauth -n tailscale \
  --from-literal=client_id=… --from-literal=client_secret=… \
  --dry-run=client -o yaml \
  | kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets-controller --format yaml \
  > secrets/tailscale/operator-oauth.yaml
```

Tailnet admin console → Settings → OAuth clients → Generate. Scopes:
`Devices: Core` write, `Auth Keys` write, tag `tag:k8s-operator`. Before
that, the ACL policy needs the tags:

```json
"tagOwners": {
  "tag:k8s-operator": [],
  "tag:k8s": ["tag:k8s-operator"]
},
"nodeAttrs": [
  { "target": ["tag:k8s"], "attr": ["funnel"] }
]
```

(`funnel` on `tag:k8s` is what lets the staging Ingresses ask for Funnel
later; Argo's own Ingress does not.)

## Backing up the sealing key

The whole directory is useless without the controller's private key. After
the first sync, and after any rotation:

```sh
kubectl -n sealed-secrets get secret -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets.key            # gitignored
```

Put `sealed-secrets.key` with the other off-site secrets (the rclone
passphrase, the `.env` files). Restoring it into a rebuilt cluster is in
`docs/OPERATIONS.md`. Alternative when moving to the dedicated mini: skip the
restore and re-seal everything — there are only a handful.
