# The home infrastructure plan

Where everything runs today, where it is going, and how it gets there —
written 2026-09-20 so the decisions are in one place, updated 2026-09-28
for what changed since (custom domains through Cloudflare, Garage in place
of MinIO, the Mac config backup, the staging cluster's retirement). `DESIGN.md` covers the
Kubernetes project itself; this is the bigger picture around it.

## 1. The machines

| Machine | Today | End state |
|---|---|---|
| **Mac mini (current, 16 GB)** | everything: production, Ollama, backups, monitoring, dev container. At its limit: heavy swap under normal load (2026-09-26), and the staging VM starved production of CPU (2026-09-23), so the cluster is retired until this box is free | **staging cluster — that is its one job.** (Rollback for the first week after migration; then keep it only if the staging cluster (this repo) goes ahead, otherwise sell it) |
| **Mac mini M5 Pro (new, 48 GB, 10 GbE)** | — | video editing + production + Ollama + dev container |
| **NAS (later)** | — | footage library + on-site backup tier for everything + restore source for staging |
| Google Drive (rclone, encrypted) | off-site backups | unchanged — the copy that survives the house |

The principle: **each box has one job it is best at.** The Pro chip's GPU
and cores go to the things that are slow today (Whisper in real time,
Ollama, 4K editing). The old mini gets to be experimented on and broken. The
NAS holds the bulk data nothing else should hold.

## 2. What "production" is

Two app stacks and the business website, each with public HTTPS
addresses, one native process, and the pieces that watch and back them up.
Public traffic arrives only through outbound tunnels: a custom domain via
Cloudflare Tunnel, and the original Tailscale Funnel address. Nothing on the
home router is forwarded.

```
AI Lecture Notes   app (FastAPI + Whisper + UI) · Postgres · Garage (S3) · Tailscale sidecar · Cloudflare tunnel
InsiderTrack       app (FastAPI + scrapers + UI) · Postgres · MCP server · Tailscale sidecar · Cloudflare tunnel
mgnts-site         static site + contact form · Tailscale · Cloudflare tunnel (mgnetsolutions.com)
Ollama             native macOS process on the GPU, used by both app stacks
Monitoring         this repo's mac/: Prometheus + Grafana, the daily backup-age check;
                   an external uptime monitor watches every public address
Mac config         mac/config-backup.sh (nightly): the tunnel and stack settings
                   the app bundles don't carry, encrypted off-site
```

Each stack has: `deploy/start.sh` (build + start), a nightly `backup.sh`
(DB dump + settings + audio → encrypted bundle → Google Drive), `restore.sh`
(same machine or a new one), a health endpoint watched by an uptime
monitor, and an operator runbook. **None of that changes in this plan** —
the stacks move as a unit, and the scripts are how they move.

## 3. The steps, in order

### Step 0 — after the migration (10 minutes)

Plug an SSD into the new mini. Both `backup.sh` scripts get one added
step: rsync the bundle to it before the Drive sync. Result: three copies
of every backup (internal disk, the SSD, Google Drive) — the 3-2-1 shape
that is missing today. The old mini is *not* part of the backup story;
Google Drive covers the "whole machine dies" case, and the SSD covers
"fast restore without downloading".

### Step 1 — the new mini arrives: set it up as a workstation

Normal Mac setup for editing: Final Cut / DaVinci, the external NVMe as the
working drive. Install Docker Desktop and Tailscale, join the tailnet.
Nothing server-side yet; the old mini keeps running production untouched.

### Step 2 — move production (one evening, reversible)

This is the documented "new machine" path, and the best possible restore
drill because it is real:

1. On the new mini, clone the two repos and the MCP repo.
2. `deploy/restore.sh --from-remote latest` in each app repo: pulls last
   night's bundle from Google Drive, recreates the stack with the same
   passwords and settings, restores the database and the audio in Garage. Both stacks
   come up on the new machine with **temporary Tailscale names**
   (`…-new`), so the old ones keep serving.
3. Install Ollama natively, pull `llama3` and `llava`. Point `deploy/.env`
   at it (same `host.docker.internal:11434` — nothing to change).
4. Compare: open both new URLs, check History / Data sources / the MCP.
   Run both machines in parallel for a day; the old one is still the one
   the public hits.
5. Flip: stop the old stacks **and their Cloudflare tunnels**, rename the
   new Tailscale nodes to the real names (`mgnts-note-app`,
   `mgnts-stock-tracker`), then start the tunnels on the new mini. Funnel
   addresses and certificates follow the Tailscale name; the custom domains
   follow the tunnel credentials, so DNS needs no change. Never run a
   tunnel on both machines at once: Cloudflare splits visitors between
   them.
6. Before the flip, restore the Mac config from its backup
   (`mac/README.md` → "Config backup"): it brings the tunnel settings and
   every stack's settings files. Then re-register the nightly backups on
   the new mini (`backup-setup.sh`), move the dev container there (open the
   folder in VS Code), and go through the same setup checklist the old one
   did, so it comes back by itself after a reboot and has the same macOS
   security settings.
   Then the rest of the Mac's jobs: `mgnts-site` (`deploy/start.sh`, at
   the flip, like the other tunnels), and this repo's `mac/install.sh`
   (backup-age check, config backup) and `mac/monitoring/start.sh`.
   The external uptime monitor and the Prometheus probes watch the public
   addresses, so they carry on unchanged.
7. **Do not wipe the old mini yet.** It is the rollback: if anything is
   wrong in the first week, stop the new stacks and rename the old nodes
   back. After a clean week, it is free.

One caution during the parallel day: InsiderTrack's scrapers would run on
both machines, and both would send the morning email. Harmless (same data,
duplicate email), but set `MAIL_USERNAME` empty on the new copy until the
flip.

### Step 3 — the old mini becomes the staging box

*Update 2026-09-28: the cluster ran in a 6 GB VM next to production
(DESIGN.md phases 1–4) until 2026-09-23, when it starved production of CPU.
The VM was retired (`mac/README.md`), so step 3 is a rebuild from this repo
once the old mini is free: 12 GB in `bootstrap/lima.yaml`, `limactl start`,
`bootstrap/argocd.sh`, then restore the backed-up sealing key or re-seal
the secrets (`secrets/README.md`) — `docs/OPERATIONS.md` "Rebuild on the dedicated
mini". Nothing here happens before the migration.*

On the old mini: a Linux VM with ~12 GB running k3s + Argo CD + the
Tailscale operator, and in it, *copies* of all three apps restored from
the nightly bundles, on `…-staging` URLs. Every merge to `main` in any repo
lands there automatically; production on the new mini moves only when a
person edits a version number. **This is the only reason to keep the old
mini.** If the staging cluster is dropped, sell it.

### Step 4 — the NAS, when the footage needs it

A 4-bay appliance (Synology / UGREEN class) with 4 CMR drives. It takes
over three things:

- the a7CR library (edit from the local NVMe, archive to the NAS over
  10 GbE);
- the on-site backup tier: both apps' bundles rsync to a NAS share
  instead of the old mini (one line in each `backup.sh`); Drive
  stays off-site;
- the restore source for staging, so the cluster no longer depends on the
  new mini being up.

Nothing before step 4 needs the NAS to exist.

## 4. How it works day to day, once done

```
                      internet / phone / claude.ai
                                 │  Cloudflare Tunnel · Tailscale Funnel (HTTPS, outbound only)
        ┌────────────────────────┼─────────────────────────┐
        │  New mini (M5 Pro)     │                         │
        │  ┌──────────────┐  ┌───┴──────────┐  ┌────────┐  │      ┌──────────────┐
        │  │ Lecture Notes│  │ InsiderTrack │  │  MCP   │  │      │ Old mini      │
        │  │ app·pg·garage│  │ app·pg       │◄─┤        │  │      │ k3s + Argo CD │
        │  └──────┬───────┘  └──────┬───────┘  └────────┘  │      │ staging copies│
        │         └──────┬──────────┘                      │      │ of all three  │
        │           Ollama (GPU)      dev container         │      │ (…-staging)   │
        │                 nightly backup.sh ──► SSD ───────────┬   │               │
        └───────────────────────────────────────────────────┘  │  └──────────────┘
                                                                 └──► Google Drive (off-site)
                                     later: NAS = library + backup tier + staging's restore source
```

- **You record a lecture / someone opens InsiderTrack** → the new mini
  serves it. Faster Whisper, faster Ollama; a video export at the same
  time slows nothing you would notice.
- **Dependabot merges a bump** (new releases wait 7 days first) → CI pushes an image → Argo on
  the old mini deploys it to staging within minutes → you glance at the
  staging URL (or don't). Production is untouched until someone
  runs its `deploy/start.sh` — on code staging has already run.
- **03:00** → backups run on the new mini → local drive → Google Drive;
  **03:30** the Mac config backup follows.
  Staging restores from the same bundles, and re-restores them weekly,
  so it doubles as the restore drill without anyone running one.
- **The new mini dies** → any machine (the old mini, a laptop) can run
  production from the Google Drive bundle in an hour (`restore.sh
  --from-remote latest`), the same way the migration was done.
- **The old mini dies** → staging is gone, production is not; rebuild the
  cluster from this repo whenever.

## 5. What this costs

| | |
|---|---|
| Mac mini M5 Pro, 48 GB, 10 GbE | the editing purchase — the server role rides along for free |
| External NVMe for footage | ~$150–250 |
| SSD on the new mini for the on-site backup copy (step 0) | ~$60 |
| Old mini, laptop | $0 (keep the mini; the laptop is too old — recycle) |
| NAS + 3–4 × 12 TB CMR drives (step 4, later) | ~$1,600–2,000 at 2026 drive prices (~$400 per 12 TB new; recertified from the Seagate/WD outlets are 30–40% less) |
| Cloud | $0 — nothing here needs it; if a job asks for EKS, deploy the same charts there for a week and tear it down |

## 6. What could go wrong, and the answer

| Risk | Answer |
|---|---|
| The migration breaks something | the old mini keeps running; flip the names back |
| A backup bundle does not restore | you find out in step 2 on hardware you can afford to fail on — that is the point of doing it this way |
| A Cloudflare tunnel running on both minis | visitors are split between them; stop the old tunnels before starting the new ones (step 2, point 5) |
| Both minis on one power strip / one router | true single points of failure for a home lab; Google Drive is the answer for data, and accepting an outage is the answer for uptime |
| Editing and a lecture at the same time | avoid exporting during class; the browser buffers 30 min if Whisper lags |
| The staging cluster eats the old mini's RAM | it has nothing else to run; 12 GB in the VM is 3× the budget |
