# homelab-gitops — design

Kubernetes + Argo CD for the three projects that already run in production
as Docker Compose stacks on a Mac mini: **InsiderTrack**, **InsiderTrack
MCP** and **AI Lecture Notes**. A staging cluster first, GitOps from day one,
production cut-over only if and when it earns it.

Status: **design** (2026-09-20). Nothing built. Start after the three
projects have had a week to breathe (LinkedIn post, MCP in daily use).

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
| Image updates | **Argo CD Image Updater** for staging (track `main` tags); tags pinned by hand in `values-prod.yaml` | Staging follows `main` automatically — that is the staging-for-Dependabot payoff; prod stays a deliberate edit |
| Secrets | **Sealed Secrets** (Bitnami) committed to this repo | Simplest GitOps-native option; no external vault to run. The sealing key is backed up like any other secret |
| State | `StatefulSet` + PVC for Postgres and MinIO via k3s's local-path provisioner; **restore job** on first start from the latest backup bundle | Production backups already exist; the cluster's data is always a restored copy. No PV backup of the cluster itself is needed while it is staging |
| Ollama / Whisper | Staging **points at the mini's native Ollama** over Tailscale (`http://<mini-tailnet-ip>:11434`); Whisper runs in the pod on CPU | Do not run a second LLM server; Whisper in staging is for smoke tests, not real-time |
| Scope of "prod cut-over" | **Out of scope for v1.** Decide after staging has run for a month | Compose in production is fine; moving it is a separate decision with its own risk |

## 4. What gets deployed (staging)

```
namespace: insidertrack-staging
  postgres        StatefulSet, PVC 5 Gi, restore Job (pg_restore from bundle) — sync wave 0
  app             Deployment, 1 replica, probes on /health, env from Secret, PVC for backups dir — wave 1
  mcp             Deployment, 1 replica, INSIDERTRACK_URL=http://app:8003, tokens from Secret — wave 2
  ingress         tailscale, host insidertrack-staging, paths / → app, /mcp → mcp (operator keeps the prefix? verify — the Funnel stripped it)

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

## 5. Memory budget (to verify before phase 0)

| | GB |
|---|---|
| k3s control plane + Traefik + CoreDNS + metrics | ~1.0 |
| Argo CD (server, repo-server, controller, redis) + Image Updater | ~0.8 |
| Sealed Secrets + Tailscale operator | ~0.2 |
| InsiderTrack staging (postgres 0.2, app 0.3, mcp 0.1) | ~0.6 |
| Lecture Notes staging (postgres 0.1, minio 0.3, app 0.4 idle / 2.5 with Whisper) | ~0.8–2.9 |
| **Total** | **~3.4 GB idle, ~5.5 GB when Whisper runs** |

The mini has roughly 4 GB free with Ollama loaded. **Phase A fits only if
Ollama is not loaded at the same time** — which is true most of the day but
not during a lecture or the 08:30 brief. Decision point after measuring on
the real machine: if headroom is under 2 GB at peak, go to Phase B (second
box) before building anything. A used mini PC with 16–32 GB is the cleaner
answer and keeps the cluster running when the Mac reboots.

## 6. Repository layout

```
homelab-gitops/
├── DESIGN.md
├── bootstrap/              # one-time: k3s install script, argo install, root app
│   ├── k3s.sh
│   └── root-app.yaml       # app-of-apps pointing at apps/
├── apps/                   # Argo Applications, one per project × environment
│   ├── staging/
│   │   ├── insidertrack.yaml
│   │   ├── insidertrack-mcp.yaml
│   │   └── lecture-notes.yaml
│   └── platform/           # argocd, sealed-secrets, tailscale-operator, image-updater
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

| Phase | Deliverable | Done when |
|---|---|---|
| 0 — decide where (½ day) | measure real headroom on the mini for a week (`docker stats`, Activity Monitor at the 08:30 brief and during a lecture); pick Phase A or B | a number in this doc, and a machine |
| 1 — cluster (1 day) | k3s up, Tailscale operator, Argo CD reachable at `argocd.<tailnet>`, Sealed Secrets, root app syncing an empty `apps/` | `argocd app list` shows the root app Healthy |
| 2 — InsiderTrack MCP (½ day) | first chart — stateless, one Deployment, easiest win; points at production InsiderTrack read-only over Tailscale for now | staging MCP answers from claude.ai with its own token |
| 3 — InsiderTrack (2 days) | chart with Postgres, restore Job from the nightly bundle, scrapers running against the copy, ingress with `/` and `/mcp` | the site at `insidertrack-staging` shows yesterday's data and this morning's scrape |
| 4 — Lecture Notes (2 days) | chart with Postgres + MinIO + restore, alembic initContainer, Whisper smoke test (one uploaded clip) | a recorded clip transcribes; History shows the restored lectures |
| 5 — GitOps loop (1 day) | GHCR pushes from each CI; Image Updater moves staging on every `main` merge | a Dependabot merge shows up in staging without a human |
| 6 — write-up (½ day) | README with the architecture diagram, `docs/OPERATIONS.md`, a restore-drill doc that replaces today's by-hand candidate test; LinkedIn About gets a fourth bullet | — |
| later | prod cut-over per app; a second node; Prometheus/Grafana (the apps expose enough for it) | only if wanted |

Roughly three weekends. Each phase leaves something working on its own.

## 9. Open questions

1. **Phase A or B** — needs the week of measurements (§5). Leaning B: a
   second box is the only option where the cluster survives the mini
   rebooting, and staging that dies with production is not staging.
2. **Does the Tailscale operator's Ingress strip path prefixes** the way
   `tailscale serve` did? Verify with the MCP in phase 2 before assuming
   either way (the MCP has `MCP_PATH` for exactly this).
3. **Restore Job source** — pull the bundle from the off-site rclone remote
   (needs the rclone config and passphrase as a SealedSecret) or from the
   mini over Tailscale (simpler, but couples staging to the mini)? Start
   with the mini; move to the remote when Phase B lands.
4. **GHCR for a private repo** (the MCP was private until today; all three
   are public now) — no cost issue.
5. **Whether production ever moves.** Not a question for this doc.
