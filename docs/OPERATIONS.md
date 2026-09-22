# Operations — the staging cluster

Runbook for the k3s VM. Design in `../DESIGN.md`, the bigger picture in
`../PLAN.md`. Everything here is run **from the Mac's terminal**, not from
the dev container (Lima is a Mac program); the dev container can use the
same kubeconfig with the server changed to `host.docker.internal`.

Commands assume (it is in `~/.zshrc` on the mini, so every new terminal
has it — the `localhost:8080 … EOF` error from kubectl means it is not set):

```sh
export KUBECONFIG=~/.lima/k3s/copied-from-guest/kubeconfig.yaml
```

The Mac itself must be on the tailnet (the Tailscale app, logged in as the
tailnet owner). Production never needed that — its Tailscale runs inside
the containers — but every cluster URL is tailnet-only unless a manifest
asks for Funnel, and Argo's does not.

## Build the cluster from nothing

Order matters only once; after that Argo keeps it converged.

1. **VM** — `limactl start --name k3s bootstrap/lima.yaml`. Ubuntu LTS, k3s
   from the stable channel, ~2 min. Check: `kubectl get nodes` shows one
   `Ready` node.
2. **Argo CD** — `bootstrap/argocd.sh`. Installs the chart, waits, applies
   the root app. Check: `kubectl -n argocd get applications` lists `root`,
   `argocd`, `sealed-secrets`, `tailscale-operator`, `image-updater`.
   `tailscale-operator` stays `Progressing` — expected, it needs step 3.
3. **First secret** — seal the Tailscale OAuth client into
   `secrets/tailscale/operator-oauth.yaml` as `secrets/README.md` says,
   commit, push. Within 3 min the operator syncs and
   `https://argocd.tail3659a6.ts.net` answers (tailnet only). Impatient:
   `kubectl -n argocd annotate application tailscale-operator argocd.argoproj.io/refresh=hard --overwrite`.
   The operator pod sits in `ContainerCreating` until the Secret exists —
   that is it waiting, not a failure.
4. **Back up the sealing key** — also in `secrets/README.md`. Do it now,
   not later. Also commit the public half so sealing works from anywhere:
   `kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets-controller --fetch-cert > secrets/pub-cert.pem`.
5. **Log in** — `admin` plus the password from
   `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`.
   Change it in the UI (User Info → Update password), then delete the
   initial secret: `kubectl -n argocd delete secret argocd-initial-admin-secret`.

Done when `argocd app list` (or the UI) shows every app **Synced / Healthy**
— DESIGN.md phase 1.

## Rebuild on the dedicated mini (PLAN.md step 3)

The cluster carries nothing worth keeping: every app restores its own data
from the backup bundles on first start.

```sh
limactl stop k3s && limactl delete k3s
# edit bootstrap/lima.yaml: memory: 12GiB
limactl start --name k3s bootstrap/lima.yaml
bootstrap/argocd.sh
```

Then **restore the sealing key before the first sync of anything that uses
a secret**: the controller comes up in wave 0 and, finding no key, would
generate a new one that cannot read the committed files.

```sh
kubectl create namespace sealed-secrets
kubectl -n sealed-secrets apply -f sealed-secrets.key
# if the controller already started and made its own key:
kubectl -n sealed-secrets delete pod -l app.kubernetes.io/name=sealed-secrets
```

Or re-seal every file in `secrets/` against the new controller and commit —
fine while the count is small.

## Day to day

| | |
|---|---|
| Is it up | `limactl list`; `kubectl get nodes`; the Argo UI |
| Mac rebooted | Lima does not autostart. `limactl start k3s`; everything else comes back on its own (k3s is a systemd unit, Argo reconverges) |
| VM out of memory | `limactl shell k3s -- free -m`; `kubectl top pods -A`. Under 6 GiB, Whisper in Lecture Notes is the only thing that pushes it — see DESIGN.md §5 |
| Stop everything | `limactl stop k3s` — production is unaffected, it is not in the VM |
| Something is `OutOfSync` and stays so | click Sync in the UI once; if it flips back, someone edited the cluster by hand and `selfHeal` is reverting it — fix it in git |
| Roll back a change | `git revert`, push; Argo applies the revert |
| Upgrade k3s | `limactl shell k3s -- curl -sfL https://get.k3s.io \| INSTALL_K3S_CHANNEL=stable sh -` — same installer, in place. Pods restart, PVC data stays |
| Upgrade Argo CD | bump `targetRevision` in `apps/platform/argocd.yaml` (Argo upgrades itself). If it ever cannot, `bootstrap/argocd.sh` reads the same file |
| Kubectl from the dev container | copy the kubeconfig in and `sed -i 's/127.0.0.1/host.docker.internal/' …`; the cert is valid for that name |

## Images

Each app's CI pushes to GHCR on `main` (`:main`, `:main-<sha>`) and on
`v*` tags (`:X.Y.Z`, `:X.Y`, `:latest`), amd64 + arm64. A package created
by a public repo's workflow comes out public (verified with the MCP,
2026-09-21); if a pod ever sits in `ImagePullBackOff` on a fresh package,
check github.com/mrgutierrezmario?tab=packages → Package settings →
visibility.

## Restore a namespace

Phase 3+: delete the namespace's PVC and the restore Job reruns on next
sync. Written up when the first chart with state lands.

## Rotate a secret

Re-run the `kubeseal` line from `secrets/README.md` with the new value,
commit. The controller updates the `Secret`; the pod that mounts it needs a
restart (`kubectl rollout restart deploy/<name> -n <ns>`) unless the chart
hashes the secret into the pod template — the charts here should.
