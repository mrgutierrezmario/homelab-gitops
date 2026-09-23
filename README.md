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
| `bootstrap/` | the VM template and the two scripts that bring up k3s and Argo CD |
| `apps/platform/` | Argo Applications for the platform: Argo CD itself, Sealed Secrets, Tailscale operator, Image Updater |
| `apps/staging/` | Argo Applications for the three apps (phases 2–4) |
| `charts/` | one Helm chart per app |
| `secrets/` | SealedSecrets only |

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
| Update loop | Image Updater watches those three tags and **commits the new digest to this repo**; Argo syncs the commit. A Dependabot merge reaches staging with nobody touching anything, and `git log` is the deployment history |

**Next:** phase 6, the write-up (architecture diagram, restore-drill doc),
then the platform extras (DESIGN §8a): Uptime Kuma, Prometheus/Grafana/Loki,
the restore drill as a weekly CronJob.

**Found by staging already** (`docs/OPERATIONS.md` → Follow-ups): opening a
Lecture Notes lecture whose audio is gone breaks the page; rclone's shared
Drive client_id retires in 2026 and production's backups use it.
