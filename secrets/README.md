# secrets/

Only `SealedSecret` manifests — encrypted to the cluster's controller, safe
to commit. Plain `Secret`s never go here; `.gitignore` refuses
`*.yaml.unsealed` and `*.key` as a second line of defence.

One directory per consumer, matching the Argo Application that mounts it:

```
secrets/
└── tailscale/            # operator-oauth — read by apps/platform/tailscale-operator.yaml
```

## Sealing a secret

Needs the controller running (it comes up in wave 0 of the root app) and
`kubeseal` on the Mac (`brew install kubeseal`). The controller is not in
kubeseal's default namespace, so always pass both flags:

```sh
export KUBECONFIG=~/.lima/k3s/copied-from-guest/kubeconfig.yaml
export SEAL="kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets-controller --format yaml"

kubectl create secret generic operator-oauth -n tailscale \
  --from-literal=client_id=… --from-literal=client_secret=… \
  --dry-run=client -o yaml | $SEAL > secrets/tailscale/operator-oauth.yaml
```

Commit the output. Argo applies it, the controller unseals it into a real
`Secret` in that namespace, and the consumer starts. The name and namespace
are part of the encryption — a sealed secret cannot be moved to another
namespace by editing the file.

## The Tailscale OAuth client (first secret, phase 1)

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
