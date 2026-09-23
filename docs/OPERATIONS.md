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

## Before rebuilding: what took it down

The cluster ran on the *current* mini alongside production and a dev
container, and twice starved the Mac of CPU. Deleted 2026-09-23. Do not
rebuild it on a machine that is doing anything else. What it needs:

| | |
|---|---|
| Its own box | the old mini once production moves (`PLAN.md` step 3) — not a share of a working machine |
| CPU, not RAM | memory was never the binding constraint. Four vCPUs gave load averages of 63 with the disk idle |
| Whisper capped | `OMP_NUM_THREADS` **and** a CPU limit. CTranslate2 sizes its thread pool from the cores it can see, ignoring the cgroup, so a quota alone means threads outnumber it: everything runnable, nothing running, throttle stalls at each period |
| A first boot with nothing heavy | Lecture Notes is at `replicas: 0` in `values-staging.yaml`. Bring the node up, watch it idle, then set it to 1 |

The failure is self-feeding: starvation times out liveness probes and
kubelet heartbeats, Kubernetes restarts pods, restarts cost CPU. It does
not recover on its own.

## While it is not running

The weekly restore drill is gone until the cluster is rebuilt — nothing
proves the bundles still restore.

The daily backup-age check survived: `mac/install.sh` puts it on the Mac as
a launchd job (09:30 daily, emails only on trouble), covering the gap where
`backup.sh` stops running silently. `mac/README.md` says what it does and
does not cover. By hand, any time:

```sh
mac/backup-age-check.sh --quiet
```

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
| Changing the VM's CPUs or memory | **editing `bootstrap/lima.yaml` does not touch an existing VM** — Lima copies that template once, at creation, to `~/.lima/k3s/lima.yaml`. Use `limactl stop k3s && limactl edit k3s --cpus N && limactl start k3s`, or delete and recreate. Learned the hard way 2026-09-23 |
| Mac rebooted | Lima does not autostart. `limactl start k3s`; everything else comes back on its own (k3s is a systemd unit, Argo reconverges) |
| VM out of memory | `limactl shell k3s -- free -m`; `kubectl top pods -A`. Under 6 GiB, Whisper in Lecture Notes is the only thing that pushes it — see DESIGN.md §5 |
| Stop everything | `limactl stop k3s` — production is unaffected, it is not in the VM |
| Commits are not being picked up, apps look `Synced` at an old revision | `kubectl -n argocd get pods` — restarts on `argocd-repo-server` are the thing to look for, then `describe pod` for the reason. It resolves revisions and renders manifests; while it is down or restarting, applications cannot be refreshed and keep their last known revision **without going OutOfSync or raising a condition** — they look fine. Found 2026-09-23: its liveness probe (`/healthz?full=true`, 1 s timeout by default) was timing out on a loaded VM and the kubelet was killing it. Probe timeouts are raised in `apps/platform/values/argocd.yaml`; if it recurs, that file is where to look |
| `NodeNotReady` in pod events | the kubelet could not renew its node lease in time — on this VM that means CPU starvation, not the Mac sleeping (`pmset -g` says `sleep 0`, verified 2026-09-23). Same root cause as repo-server probe timeouts. The staging workloads now carry CPU limits (Whisper 2 of 4 cores) so the control plane always has room; if it recurs, give the VM more vCPUs in `bootstrap/lima.yaml` |
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
charts/*/values-staging.yaml` is the deployment history. First run
verified 2026-09-23: three commits, each digest checked against the live
GHCR manifest for `main`. What it writes looks like:

```yaml
image:
  repository: ghcr.io/mrgutierrezmario/insidertrack
  tag: main@sha256:…
```

| | |
|---|---|
| Is it working | `git log --oneline -- charts` — its commits are the evidence. Logs: `kubectl -n argocd logs deploy/image-updater-argocd-image-updater --tail=50` (Helm expands the release name, so the Deployment is *not* called `image-updater`) |
| What is actually running | `kubectl -n <ns> get deploy -o jsonpath='{.items[*].spec.template.spec.containers[*].image}'` — should end in the same `@sha256:` as the values file |
| It is not updating | the image must be in the Application's *rendered* template for Image Updater to consider it; check the alias in `platform/image-updater/imageupdater.yaml` matches `image.repository`/`image.tag` in that chart |
| Write-back fails with a permission error | the deploy key lost write access, or was removed in GitHub — `secrets/README.md` |
| Pause it for one app | delete that `applicationRefs` entry in `platform/image-updater/imageupdater.yaml`, commit. The app then stays on whatever digest is in its values file |
| Pause it entirely | `kubectl -n argocd scale deploy/image-updater --replicas=0` — but Argo's selfHeal puts it back; the durable way is the file above |
| Go back to a known-good image | `git revert` the write-back commit. The digest in git is what runs |

Production is untouched by all of this: it builds from source on the Mac
(`deploy/start.sh`) and only moves when a person says so.

## Monitoring (phase 7)

`https://uptime.tail3659a6.ts.net` — Uptime Kuma, tailnet only. What it
watches and how to rebuild it after a lost PVC:
`platform/uptime-kuma/README.md`.

Two of its monitors are fed from inside the cluster rather than probed:

| Check | Runs | Fails when |
|---|---|---|
| `<app>-backup-age` CronJob | daily 14:00 UTC | the newest bundle in the off-site remote is older than 36 h — i.e. the nightly `backup.sh` stopped running, which otherwise sends no signal at all |
| `<app>-restore-drill` CronJob | Sunday 13:00 UTC | the restore fails, or the app cannot serve what was restored (`docs/restore-drill.md`) |

```sh
kubectl -n insidertrack-staging get cronjob
kubectl -n insidertrack-staging logs -l app.kubernetes.io/component=backup-age --tail=20
kubectl create job --from=cronjob/insidertrack-backup-age check-now -n insidertrack-staging
```

Both push to Uptime Kuma only when `pushUrl` is set in the chart's staging
values. Without it they still run and still fail visibly as failed
CronJobs — they are just not on a dashboard.

## Turning observability on (after the 12 GiB rebuild)

`apps/platform/observability.yaml` is deliberately manual-sync. Before
enabling it, measure — the reason it is off is capacity, so the check is
the point:

```sh
limactl shell k3s -- free -m       # want >2.5 GB available, not just free
kubectl top nodes                  # CPU should idle well under 50%
```

Then, once the VM is the 12 GiB one:

```sh
kubectl -n argocd patch application observability --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

and commit the same change to the file, or Argo's selfHeal on the root app
will revert it. Grafana lands at `grafana.tail3659a6.ts.net` (tailnet only);
the admin password is in the sealed `grafana-admin` secret:

```sh
kubectl -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Watch the node for an hour afterwards. If probes start timing out again
(`docs/OPERATIONS.md` above), Prometheus' `retention` and `resources` in
`apps/platform/values/kube-prometheus-stack.yaml` are the dials, and
turning it back off is removing the `automated` block again.

## What staging touches in production

Audited 2026-09-23. Staging is meant to be unable to hurt production; this
is the list of places the two actually meet, so the claim stays checkable.

| Path | Verdict |
|---|---|
| Staging MCP → InsiderTrack | Points at `http://insidertrack:8003`, the staging copy. It briefly pointed at production's public URL during phase 2 and no longer does |
| Restore + backup-age Jobs → Google Drive | Read-only calls (`rclone lsf`, `rclone copyto`) — but with production's own rclone credentials, which *can* write. A bug in those scripts could damage the backups. Drive keeps 30 days of versions, and a read-only Drive remote would remove the risk entirely if it ever feels too close |
| Uptime Kuma → production URLs | One `GET /health` a minute per monitor. Negligible, and the point |
| Outbound email from staging | Off twice over: `MAIL_USERNAME` is empty in the chart, and the restore deletes the saved mail credentials from `app_settings` |
| Paid AI keys | Deleted from the restored copy; provider pinned to Ollama |
| Ollama | Staging would share the Mac's single native Ollama with production. Not reachable today (it listens on localhost), so staging falls back to heuristics. **Exposing Ollama to the network makes them compete** — that is what DESIGN.md phase 11's second Ollama is for |
| **Scrapers → SEC / Senate / House** | **The one to watch.** Staging runs the same `CronTrigger` times as production (06:30, 07:00, 08:00, 12:00, 18:00 ET) from the same home IP, so those sources see two clients at the same minute. SEC's fair-access limit is 10 req/s and they block by IP. Volumes are small enough that it has been fine so far — but if production's Data sources page starts showing `consecutive_failures`, this is the first suspect, and an offset schedule in staging is the fix |

The last row is deliberate, not an oversight: DESIGN.md §4 runs the scrapers
in staging because that is what a dependency bump most often breaks. It is
a watched trade, not a free one — and now that Uptime Kuma exists, a keyword
monitor on production's `/health` for `"status":"ok"` catches it, because
that endpoint reports data-source failures.

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

`docs/restore-drill.md` covers what this proves and what it does not.

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

It also runs only when its *own* definition changes. That needs
`ApplyOutOfSyncOnly=true` on the Application: without it Argo re-applies
every resource on every sync, and `Replace=true` on the Job turns each of
those into a delete-and-recreate. Symptom (2026-09-23): a change to a CPU
limit made Lecture Notes re-download the whole audio mirror and sit in
`Running` for five minutes, blocking the next commit.

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
