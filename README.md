# homelab-gitops

Kubernetes (k3s) + Argo CD staging for three apps that run in production as
Docker Compose stacks on a Mac mini:
[InsiderTrack](https://github.com/mrgutierrezmario/insidertrack),
[InsiderTrack MCP](https://github.com/mrgutierrezmario/insidertrack-mcp) and
[AI Lecture Notes](https://github.com/mrgutierrezmario/lecture-note-app).
Staging runs *copies* restored from last night's backups; every merge to
`main` lands there on its own, production moves only by hand.

| | |
|---|---|
| `DESIGN.md` | what gets built and why — decisions, memory budget, phases |
| `PLAN.md` | the machines around it: the migration to the new mini, the NAS |
| `docs/OPERATIONS.md` | runbook: build the cluster, rebuild it, day to day |
| `docs/restore-drill.md` | how the cluster proves the backups restore, and what that does not cover |
| `bootstrap/` | the VM template and the two scripts that bring up k3s and Argo CD |
| `apps/platform/` | Argo Applications for the platform: Argo CD itself, Sealed Secrets, Tailscale operator, Image Updater |
| `apps/staging/` | Argo Applications for the three apps (phases 2–4) |
| `charts/` | one Helm chart per app |
| `secrets/` | SealedSecrets only |

## How it fits together

```
        merge to main in an app repo
                 │
                 ▼
        GitHub Actions ──build──►  GHCR   ghcr.io/mrgutierrezmario/…
                                    :main  :main-<sha>  :vX.Y.Z
                                      │                (amd64 + arm64)
                                      │ a new digest behind :main
                                      ▼
                          Argo CD Image Updater
                                      │
                                      │ commits  image.tag: main@sha256:…
                                      ▼
                     ┌──────────  homelab-gitops  ──────────┐
                     │   charts/  apps/  platform/ secrets/ │
                     └────────────────┬─────────────────────┘
                                      │  Argo CD polls every ~3 min
                                      ▼
╔═══ Mac mini (16 GB) ══════════════════════════════════════════════════╗
║                                                                       ║
║  PRODUCTION                           STAGING — Lima VM (6 GiB) · k3s ║
║  Docker Compose, built from source    ┌─────────────────────────────┐ ║
║  ┌─────────────────────────┐          │ argocd          Argo CD +   │ ║
║  │ stock-tracker           │          │                 Image Updtr │ ║
║  │   app · pg · mcp · ts   │          │ sealed-secrets  controller  │ ║
║  │ lecture-notes           │          │ tailscale       operator    │ ║
║  │   app · pg · minio · ts │          ├─────────────────────────────┤ ║
║  └───────────┬─────────────┘          │ insidertrack-staging        │ ║
║              │                        │   app · pg · mcp  + restore │ ║
║              │ 03:00  backup.sh       │ lecture-notes-staging       │ ║
║              ▼                        │   app · pg · minio + restore│ ║
║      ┌───────────────┐                └─────────────────────────────┘ ║
║      │ Google Drive  │   restore Job pulls last night's bundle        ║
║      │ (rclone crypt)│──────────────────────────────────────────────► ║
║      └───────────────┘   on first sync and whenever it changes        ║
║                                                                       ║
║   Ollama (native, GPU) ◄─── both, over host.lima.internal             ║
╚═══════════════════════════════════════════════════════════════════════╝
                                      │
                       Tailscale Funnel (HTTPS, real certs)
                                      ▼
            mgnts-stock-tracker  ·  mgnts-note-app        ← production
            insidertrack-staging ·  lecture-notes-staging ← staging
            argocd                                        ← tailnet only
```

Three properties this shape buys, and they are the point of the project:

- **Staging holds no data it did not restore itself.** The worst a bug here
  can do is corrupt a copy of last night's backup. Production's `.env`,
  saved API keys and Tailscale identity are in those bundles and are
  deleted unread by the restore (`charts/*/README.md`).
- **The repo is the deployment history.** Nothing reaches the cluster that
  is not a commit first — including the robot's. `git log -- charts` is
  the log of what ran when, and `git revert` is the rollback.
- **Production is untouched by all of it.** It still builds from source on
  the Mac and moves only when a person runs `deploy/start.sh`.

## Status — phases 1–5 done (2026-09-21 / 23)

Running on the current mini in a **6 GiB Lima VM** (DESIGN.md §5 "Phase A")
ahead of the new machine; `docs/OPERATIONS.md` has the rebuild for when the
old mini is dedicated.

| | |
|---|---|
| Cluster | k3s 1.36, Argo CD 3.5 (self-managed), Sealed Secrets, Tailscale operator; UI at `argocd.tail3659a6.ts.net` (tailnet only) |
| InsiderTrack | `https://insidertrack-staging.tail3659a6.ts.net` — Postgres seeded from last night's off-site bundle (19,984 trades, 284 members, 37,867 Form 4 rows); production API keys and mail credentials scrubbed from the copy; `/mcp` → the MCP |
| InsiderTrack MCP | same host, `/mcp`; answers claude.ai with its own token |
| Lecture Notes | `https://lecture-notes-staging.tail3659a6.ts.net` — 3 users, 201 lectures, 2,872 transcript segments, 2,998 audio chunks restored; migrations in an initContainer; a live recording transcribed by Whisper on CPU |
| Images | each repo's CI pushes amd64 + arm64 to GHCR on every merge to `main` |
| Update loop | Image Updater watches those three tags and **commits the new digest to this repo**; Argo syncs the commit, and `git log` is the deployment history. Both halves verified 2026-09-23 — the bot pinned all three apps to `main@sha256:…` (digests checked against GHCR), and a later commit reached the cluster with nobody refreshing anything. Getting there took three real fixes, all in `docs/OPERATIONS.md`: the repo-server was being killed by a one-second liveness probe, nothing capped Whisper's CPU, and the restore Job re-ran on every sync |

**Next:** the platform extras (DESIGN §8a) — Uptime Kuma, then
Prometheus/Grafana/Loki, then the restore drill as a weekly CronJob.

**Found by staging already** (`docs/OPERATIONS.md` → Follow-ups): opening a
Lecture Notes lecture whose audio is gone breaks the page; rclone's shared
Drive client_id retires in 2026 and production's backups use it.
