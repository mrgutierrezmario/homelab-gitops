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

6. **The apps** need nothing from git — their charts and generated secrets
   are already there — except the two rclone configs only the Mac can
   produce (`insidertrack-rclone`, `lecture-notes-rclone`;
   `secrets/README.md`). Until each is committed, that app's restore Job
   fails after its deadline and the app waits. After a rebuild with the
   sealing key restored, the committed ones still decrypt and nothing is
   needed at all.

Whole thing, from `limactl start` to three apps serving restored data:
about half an hour, most of it image pulls and the audio mirror.

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
| A commit is not being applied, app says `Syncing` for ages | a sync waiting on a wave (a Job that cannot start) blocks all later syncs. `kubectl -n argocd patch application <name> --type json -p '[{"op":"remove","path":"/operation"}]'` terminates it; auto-sync restarts on the newest commit |
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

## The staging update loop (phase 5)

```
merge to main in an app repo
  → its CI builds and pushes ghcr.io/…:main (amd64 + arm64)
  → Image Updater sees a new digest behind that tag (polls every 2 min)
  → it commits the digest to charts/<app>/values-staging.yaml in THIS repo
  → Argo syncs the commit like any other → new pod
```

Nothing reaches the cluster that is not in git first, and `git log
charts/*/values-staging.yaml` is the deployment history. What it writes
looks like:

```yaml
image:
  repository: ghcr.io/mrgutierrezmario/insidertrack
  tag: main@sha256:…
```

| | |
|---|---|
| Is it working | `kubectl -n argocd logs deploy/image-updater --tail=50`; or just `git log --oneline -- charts` |
| It is not updating | the image must be in the Application's *rendered* template for Image Updater to consider it; check the alias in `platform/image-updater/imageupdater.yaml` matches `image.repository`/`image.tag` in that chart |
| Write-back fails with a permission error | the deploy key lost write access, or was removed in GitHub — `secrets/README.md` |
| Pause it for one app | delete that `applicationRefs` entry in `platform/image-updater/imageupdater.yaml`, commit. The app then stays on whatever digest is in its values file |
| Pause it entirely | `kubectl -n argocd scale deploy/image-updater --replicas=0` — but Argo's selfHeal puts it back; the durable way is the file above |
| Go back to a known-good image | `git revert` the write-back commit. The digest in git is what runs |

Production is untouched by all of this: it builds from source on the Mac
(`deploy/start.sh`) and only moves when a person says so.

## Follow-ups the cluster surfaced

- **Lecture Notes: opening a lecture whose audio is gone breaks the page**
  (seen in staging before the audio mirror was restored, 2026-09-21; the
  server logged nothing, so it is the frontend). Production reaches the
  same state once the 14-day retention has deleted a recording. Reproduce
  in staging with `restore.audio: false`, capture the browser console,
  fix in the app repo.
- **rclone's shared Google Drive client_id is being retired during 2026**
  (rclone prints a NOTICE on every run). This hits production's nightly
  `backup.sh` on the Mac, not just the staging restore. Fix in the
  InsiderTrack repo: make an own client_id
  (https://rclone.org/drive/#making-your-own-client-id), `rclone config
  update gdrive-stock-tracker client_id … client_secret …`, then re-seal
  `insidertrack-rclone` here. Lecture Notes' `gdrive` remote likewise.

## Restore a namespace (re-seed staging from last night's backup)

Each stateful chart has a restore Job that runs once per change to its
spec. To run it again — a fresh copy, or after a failure — delete it and
Argo's selfHeal brings it back:

```sh
kubectl -n insidertrack-staging delete job insidertrack-restore
kubectl -n insidertrack-staging logs -f job/insidertrack-restore -c fetch    # rclone
kubectl -n insidertrack-staging logs -f job/insidertrack-restore             # psql

kubectl -n lecture-notes-staging delete job lecture-notes-restore
kubectl -n lecture-notes-staging logs -f job/lecture-notes-restore -c restore-db
```

The restore swaps the database under the running app (rename, not drop
and reload), so the app needs no restart; it sees the new copy on its
next query. A wiped cluster restores itself the same way on first sync.
Lecture Notes also re-downloads and re-uploads the audio mirror (~3,000
chunks, about five minutes) each run; a cache for that is a phase-9 item.

A restore Job runs **once, no retries**: if it fails, read its log, fix,
push. While a Job is running or retrying, the sync that created it is
"Running" and later commits wait — that is why retries are off.

If the Job fails: `describe job` shows which container; `fetch` failing
is the rclone secret (token expired → re-seal per `secrets/README.md`) or
Drive; `restore` failing is the dump or the swap (its log says which
step). A failed Job blocks the app's sync wave, on purpose — an app on an
empty schema would look like a working staging.

## Rotate a secret

Re-run the `kubeseal` line from `secrets/README.md` with the new value,
commit. The controller updates the `Secret`; the pod that mounts it needs a
restart (`kubectl rollout restart deploy/<name> -n <ns>`) unless the chart
hashes the secret into the pod template — the charts here should.
