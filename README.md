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

Status: **phase 1 done 2026-09-21** — k3s + Argo CD + Sealed Secrets +
Tailscale operator, all Synced/Healthy, Argo UI on the tailnet. Running on
the current mini in a 6 GiB VM (DESIGN.md §5 "Phase A") ahead of the new
machine; `docs/OPERATIONS.md` has the rebuild for when the old mini is
dedicated. Next: phase 2, the InsiderTrack MCP chart.
