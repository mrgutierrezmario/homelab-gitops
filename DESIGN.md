# homelab-gitops — design

Kubernetes + Argo CD for the three projects that already run in production
as Docker Compose stacks on a Mac mini: **InsiderTrack**, **InsiderTrack
MCP** and **AI Lecture Notes**. A staging cluster first, GitOps from day one,
production cut-over only if and when it earns it.

Status: **phase 5 done** (2026-09-23) — cluster and platform up on the
current mini (Phase A, 6 GiB VM); all three apps in staging from restored
nightly bundles, public over Funnel, and following `main` unattended.
See `README.md`.

## 1. Why, in one paragraph

The Compose stacks are not broken — `git pull && deploy/start.sh` is the
whole deploy story, and it should stay that way for production for now.
This project exists for two reasons. First, the honest one: Kubernetes and
GitOps are the day-job skills, and a portfolio with three real, stateful,
backed-up apps deployed via Argo CD says more than any hello-world cluster.
Second, the practical one: today's Dependabot round (React 19, Vite 8,
pydantic 2.13) was validated by hand-building a throwaway stack from a DB
dump. A staging cluster that always runs *copies* of the apps from last
night's backups makes that a `git push`.

## 2. What must not happen

- **Production is not touched.** The live stacks keep running exactly as they
  are, on the same Compose files, with the same Funnel URLs. Nothing in this
  project changes a file under `insidertrack/deploy`, `lecture-note-app/deploy`
  or the MCP's `deploy/` — except, later and deliberately, to add an image
  push step to CI (§7).
- **The cluster never holds production data it did not restore itself.** It
  restores from the nightly backup bundles (read-only access to the off-site
  copy), so the worst a staging bug can do is corrupt a copy.
- **Memory on the mini is finite.** Today: Docker VM 7.7 GB (the two stacks
  use ~1 GB of it), native Ollama ~5 GB when a model is loaded, macOS the
  rest of 16 GB. A staging cluster must fit in what is left or run
  elsewhere (§5).

## 3. Decisions

| Decision | Choice | Why |
|---|---|---|
| Distribution | **k3s** in a Linux VM (or on a second box), not kind, not Docker Desktop's Kubernetes | kind is a test tool (clusters inside Docker, no real storage/ingress story). Docker Desktop's cluster shares the 7.7 GB VM with production. k3s is a real single-binary distro with a built-in storage class and Traefik, what the operator experience should look like |
| Where it runs | **Phase A: a Linux VM on the mini** (Lima/UTM, 6 GB) if the RAM budget allows after measuring; **Phase B: a second machine** (an old laptop or a ~$150 mini PC) if it does not | The mini's job is production. A VM keeps the cluster killable without touching anything else |
| Packaging | **Helm charts**, one per project, in this repo (`charts/`) | The lingua franca; values files make staging vs prod a one-file difference; Argo renders them natively |
| GitOps | **Argo CD**, app-of-apps, one `Application` per project per environment | The industry default; a UI that shows drift; sync waves handle "database before app before MCP" |
| Ingress | **Tailscale Kubernetes operator** (`Ingress` class `tailscale`, Funnel annotation) | Same mechanism production uses, so the staging URLs are `…-staging.<tailnet>.ts.net` with real certs, no port-forwarding, no DNS to buy |
| Images | Built by each project's existing CI, pushed to **GHCR** (`ghcr.io/mrgutierrezmario/<project>:<sha>` + `:vX.Y.Z`) | Today images are built on the mini from source. Kubernetes needs a registry; GHCR is free for public repos and CI already builds the image |
| Image updates | **Argo CD Image Updater** for staging: `digest` strategy on the mutable `:main` tag, **written back to git** (`helmvalues:` → each chart's `values-staging.yaml`); tags pinned by hand for production | Staging follows `main` automatically — the staging-for-Dependabot payoff. Git write-back, not the `argocd` method: that one patches the live Application, which the app-of-apps root would revert on its next reconcile (selfHeal). It also keeps the repo the source of truth, so `git log` *is* the deployment history |
| Secrets | **Sealed Secrets** (Bitnami) committed to this repo | Simplest GitOps-native option; no external vault to run. The sealing key is backed up like any other secret |
| State | `StatefulSet` + PVC for Postgres and MinIO via k3s's local-path provisioner; **restore job** on first start from the latest backup bundle | Production backups already exist; the cluster's data is always a restored copy. No PV backup of the cluster itself is needed while it is staging |
| Ollama / Whisper | Staging **points at the Mac's native Ollama** via `host.lima.internal:11434` (the VM's host — the same Mac in Phase A and once the old mini is dedicated); Whisper runs in the pod on CPU | Do not run a second LLM server; Whisper in staging is for smoke tests, not real-time |
| Scope of "prod cut-over" | **Out of scope for v1.** Decide after staging has run for a month | Compose in production is fine; moving it is a separate decision with its own risk |

## 4. What gets deployed (staging)

```
namespace: insidertrack-staging
  postgres        StatefulSet, PVC 5 Gi, restore Job (pg_restore from bundle) — sync wave 0
  app             Deployment, 1 replica, probes on /health, env from Secret, PVC for backups dir — wave 1
  mcp             Deployment, 1 replica, INSIDERTRACK_URL=http://app:8003, tokens from Secret — wave 2
  ingress         tailscale, host insidertrack-staging, paths / → app, /mcp → mcp (the operator keeps the prefix — Q2)

namespace: lecture-notes-staging
  postgres        StatefulSet, PVC 2 Gi, restore Job — wave 0
  minio           StatefulSet, PVC 20 Gi, bucket-init Job — wave 0
  app             Deployment, 1 replica, alembic runs in an initContainer, probes on /health — wave 1
  ingress         tailscale, host lecture-notes-staging

namespace: argocd          Argo CD + Image Updater
namespace: sealed-secrets  controller
namespace: tailscale       operator (OAuth client from the tailnet admin console)
```

Cron/scheduled work inside the apps (InsiderTrack's scrapers, Lecture
Notes' cleanup) **runs in staging too** — against copies — because that is
what a Dependabot bump most often breaks. Outbound email in staging goes to
a null sink (`MAIL_USERNAME` unset) so nobody gets duplicate reports.

## 5. Memory budget

Estimated before building (Traefik has since been disabled — the Tailscale
operator is the ingress):

| | GB |
|---|---|
| k3s control plane + CoreDNS + metrics | ~0.8 |
| Argo CD (server, repo-server, controller, redis) + Image Updater | ~0.8 idle; limits raised to 1 Gi for the controller and repo-server after the first sizing proved tight. Note the control plane's real constraint here is **CPU, not memory**: the repo-server's health probes time out on a busy four-vCPU VM long before anything runs out of RAM (`docs/OPERATIONS.md`) |
| Sealed Secrets + Tailscale operator + one proxy pod per Ingress (3) | ~0.3 |
| InsiderTrack staging (postgres 0.2, app 0.3, mcp 0.1) | ~0.6 |
| Lecture Notes staging (postgres 0.1, minio 0.3, app 0.4 idle / 2.5 with Whisper) | ~0.8–2.9 |
| **Total** | **~3.3 GB idle, ~5.4 GB when Whisper runs** |

Running since 2026-09-21 in a **6 GiB, 4-vCPU** VM with all of the above,
and a live recording transcribed. **CPU turned out to be the binding
constraint, not memory**: uncapped Whisper starved the kubelet and Argo's
repo-server (2026-09-23), so the staging apps now carry CPU limits.
Real numbers to fill in: `kubectl top pods -A`
and `limactl shell k3s -- free -m` during a recording. The pod limits in
the charts (Lecture Notes app 3 Gi) are the ceiling; if the VM swaps
during a lecture, that is the number to lower or the moment to move to the
12 GiB rebuild.

The mini has roughly 4 GB free with Ollama loaded, so **Phase A fits only
while Ollama is not loaded at the same time** — true most of the day, not
during a lecture or the 08:30 brief. This resolves itself when the new mini
takes production and the VM is rebuilt at 12 GiB (`docs/OPERATIONS.md`).

## 6. Repository layout

```
homelab-gitops/
├── DESIGN.md
├── bootstrap/              # one-time: the VM, k3s, Argo CD, the root app
│   ├── lima.yaml           # the VM (memory is the one number that changes per phase)
│   ├── k3s.sh              # same install for a non-Lima box
│   ├── argocd.sh           # helm template + apply, then the root app
│   └── root-app.yaml       # app-of-apps pointing at apps/
├── apps/                   # Argo Applications, one per project × environment
│   ├── staging/
│   │   ├── insidertrack.yaml
│   │   ├── insidertrack-mcp.yaml
│   │   └── lecture-notes.yaml
│   └── platform/           # argocd, sealed-secrets, tailscale-operator, image-updater
│       └── values/         # values files shared with bootstrap (argocd.yaml)
├── platform/               # config for platform components (not Applications,
│   └── image-updater/      #   not charts): the ImageUpdater resource
├── charts/
│   ├── insidertrack/       # Chart.yaml, templates/, values.yaml, values-staging.yaml
│   ├── insidertrack-mcp/
│   └── lecture-notes/
├── secrets/                # SealedSecret manifests only (safe to commit)
└── docs/
    ├── OPERATIONS.md       # cluster runbook: reboot, upgrade k3s, restore a namespace, rotate a secret
    └── restore-drill.md    # how staging proves the backups, monthly
```

## 7. Changes to the three projects (small, listed so they stay small)

- CI in each repo: a `push-image` job on `main` and on tags → GHCR. The
  Dockerfiles already exist; this is ~20 lines of workflow each. Production
  can keep building locally or switch to pulling the same image — not
  decided here.
- `/health` already exists in all three and is probe-ready.
- Lecture Notes: migrations currently run in the entrypoint; the chart runs
  them in an initContainer instead, so no code change, only a different
  command.
- Nothing else. If a chart seems to need an app change, note it in the
  chart's README and build around it first.

## 8. Plan

| Phase | Deliverable | Done when | Status |
|---|---|---|---|
| 0 — decide where (½ day) | measure real headroom on the mini for a week (`docker stats`, Activity Monitor at the 08:30 brief and during a lecture); pick Phase A or B | a number in this doc, and a machine | **skipped, deliberately** — Phase A on the current mini at 6 GiB, since the new mini is coming and the VM is rebuilt bigger then (§9 Q1) |
| 1 — cluster (1 day) | k3s up, Tailscale operator, Argo CD reachable at `argocd.<tailnet>`, Sealed Secrets, root app syncing an empty `apps/` | `argocd app list` shows the root app Healthy | **done 2026-09-21** |
| 2 — InsiderTrack MCP (½ day) | first chart — stateless, one Deployment, easiest win; points at production InsiderTrack read-only over Tailscale for now | staging MCP answers from claude.ai with its own token | **done 2026-09-21** — pointed at production's public URL for a day, then at the staging copy in phase 3 |
| 3 — InsiderTrack (2 days) | chart with Postgres, restore Job from the nightly bundle, scrapers running against the copy, ingress with `/` and `/mcp` | the site at `insidertrack-staging` shows yesterday's data and this morning's scrape | **done 2026-09-21** — yesterday's data verified; the morning scrape is tomorrow's check |
| 4 — Lecture Notes (2 days) | chart with Postgres + MinIO + restore, alembic initContainer, Whisper smoke test (one uploaded clip) | a recorded clip transcribes; History shows the restored lectures | **done 2026-09-21** — a live recording, not a clip |
| 5 — GitOps loop (1 day) | GHCR pushes from each CI; Image Updater moves staging on every `main` merge | a Dependabot merge shows up in staging without a human | **done 2026-09-23** — digest strategy on `:main`, git write-back into each `values-staging.yaml`. Both halves demonstrated: the bot's commits matched GHCR, and a later commit synced with no human refresh. The full chain end to end is the next Dependabot merge |
| 6 — write-up (½ day) | README with the architecture diagram, `docs/OPERATIONS.md`, a restore-drill doc that replaces today's by-hand candidate test; LinkedIn About gets a fourth bullet | — | runbook exists and is kept current; diagram and drill doc pending |
| 7–12 | see §8a: Uptime Kuma, Prometheus/Grafana/Loki, restore-drill CronJob, self-hosted runner, second Ollama, registry cache | each on its own | |
| later | prod cut-over per app; a second node | only if wanted | |

Phases 1–4 took one evening, not three weekends: the charts are the Compose
files translated, and the restore scripts already existed. Each phase left
something working on its own.

## 8a. After the cluster works — what else belongs on it

A k3s VM with three staging apps idles at ~4 GB and near-zero CPU. These
earn their place because each is both useful day to day and a component
every real cluster has. All deployed the same way — Argo `Application`s
under `apps/platform/` — in this order:

| Phase | What | Why | Cost |
|---|---|---|---|
| 7 — Uptime Kuma (1 day) | self-hosted uptime checks + status page for both public URLs, `/mcp/health`, and backup age; alerts to email/phone | replaces the free third-party pinger with something you own and can link from the READMEs | ~0.1 GB |
| 8 — Observability (a weekend) | **Prometheus + Grafana + Loki**: the cluster, the staging apps, and — over Tailscale — the *production* stacks on the new mini. FastAPI gets `/metrics` (one library). One dashboard: request rates, scraper timings, Whisper lag, Ollama call durations, backup age. Loki makes "why did the scraper fail at 06:40" a query | today there is no metrics or log search at all; this is the thing listed next to Kubernetes in every job posting | ~1.5 GB |
| 9 — Restore drill as a `CronJob` (1 day) | every Sunday: wipe staging's databases, restore from last night's bundles, run the smoke checks, post the result to Uptime Kuma / email | the monthly runbook item done automatically, forever; a backup that is restored weekly is a backup | — |
| 10 — Self-hosted CI runner (a weekend) | GitHub Actions runner pods via the Actions Runner Controller; image builds happen here and push to GHCR; the "build candidate → deploy to staging → drill" pipeline lives on it | faster builds, no GitHub minutes, and ARC is a standard enterprise pattern | ~1 GB when busy |
| 11 — Second Ollama (½ day) | native Ollama on the old mini as the *slow* model server: staging points at it, and overnight batch jobs (the daily brief) can use it so the new mini's GPU stays free for editing and lectures | the old mini's GPU is still a real GPU | ~5 GB while a model is loaded |
| 12 — Registry pull-through cache (½ day) | `registry:2` mirror so staging pulls do not hit GHCR/Docker Hub every time | a component every real cluster has; makes rebuilds fast and offline-safe | ~0.2 GB |

Skipped on purpose: Pi-hole/AdGuard (fine, unrelated to the story), Home
Assistant (a hobby of its own), Nextcloud (the NAS does it better later).

With phases 7–10 the old mini runs at roughly 8 GB and does the monitoring,
testing and building for everything — the box working, not idling.

## 9. Open questions

1. ~~Phase A or B~~ — **resolved 2026-09-20 in principle**: a new Mac mini
   (M5 Pro, 48 GB) is planned as the editing workstation; it takes over
   production + Ollama + the dev container (migration = the documented
   `restore.sh --from-remote latest` on new hardware, old box kept as the
   rollback until the Tailscale names move). The **current mini becomes the
   staging box** for this project — 16 GB with nothing else on it, a k3s VM
   gets ~12 GB. §5's memory table is then comfortably met; rewrite it when
   the hardware lands. A **NAS** is planned later: media library, on-site
   backup copy for both apps (Drive stays off-site), and the restore source
   for staging (question 3).
2. ~~Does the Tailscale operator's Ingress strip path prefixes~~ —
   **resolved 2026-09-21, no.** Verified with the MCP: `/mcp/health` reaches
   the server as `/mcp/health` (so `MCP_PATH=/mcp`), and `/health` is a 404.
   Ingress semantics, unlike `tailscale serve`. Charts route and mount the
   same path.
3. ~~Restore Job source~~ — **resolved 2026-09-21: the off-site rclone
   remote.** It is the documented `restore.sh --from-remote latest` path,
   it holds no matter which machine is production, and it is the only way
   staging doubles as a drill of the copy that matters. The rclone config
   is a SealedSecret; the Job reads only. The NAS (PLAN.md step 4) can
   replace it later by changing one value.
4. **GHCR for a private repo** (the MCP was private until today; all three
   are public now) — no cost issue.
5. **Whether production ever moves.** Not a question for this doc.
