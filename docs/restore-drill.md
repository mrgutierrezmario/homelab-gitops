# The restore drill

A backup that has never been restored is a hope, not a backup. This is how
the cluster turns that hope into a fact, what it proves, and — the part
worth reading — what it still does not.

## What it replaced

Before the cluster, two things were done by hand:

- **Proving the backups.** `lecture-note-app/deploy/restore-drill.sh`
  restored the newest bundle into a throwaway Compose project, checked the
  accounts, lectures and audio came back, and tore it down. Run when
  someone remembered. InsiderTrack had no equivalent at all.
- **Testing a dependency bump.** The same script with
  `DRILL_IMAGE=lecture-notes-app:candidate` — build an image from the
  Dependabot branch, run it against real restored data, look at it, then
  merge. An hour of attention per round.

Both now happen without anyone deciding to do them.

## What happens now

Each app's chart has a restore Job (`charts/*/templates/restore-job.yaml`).
It runs on first sync and whenever its own definition changes:

1. **fetch** — `rclone` pulls the newest `daily/<app>-YYYY-MM-DD.tar.gz`
   from the encrypted Drive remote. Read-only credentials' worth of access;
   the Job never writes to the backup.
2. **restore-db** — the dump is loaded into `<db>_restore`, row counts are
   printed, production-only rows are scrubbed, and the database is
   rename-swapped into place under the running app.
3. **bucket / import-audio** (Lecture Notes) — the audio mirror is uploaded
   into MinIO so restored lectures actually play.

Then the app starts against it, its migrations run, and its scheduled work
— InsiderTrack's scrapers, Lecture Notes' cleanup — runs against the copy.
A new image from `main` lands on top automatically (`README.md`).

So the drill is no longer an event. **Staging is a restore that stays
running**, and the app on top of it is the candidate test.

## Running one on demand

Delete the Job; Argo's selfHeal recreates it within ~3 minutes:

```sh
kubectl -n insidertrack-staging delete job insidertrack-restore
kubectl -n insidertrack-staging logs -f job/insidertrack-restore -c fetch
kubectl -n insidertrack-staging logs -f job/insidertrack-restore

kubectl -n lecture-notes-staging delete job lecture-notes-restore
kubectl -n lecture-notes-staging logs -f job/lecture-notes-restore -c restore-db
```

### Passing looks like

| | |
|---|---|
| `fetch` | names the bundle it pulled, and the date in that name is yesterday |
| `restore-db` | row counts in the same shape `deploy/restore.sh` prints — e.g. `19984 trades, 284 members, 37867 Form 4 rows`; `3 users, 201 lectures, 2872 transcript segments` |
| Job | `Completed`, one pod, no retries |
| App | `curl https://insidertrack-staging.tail3659a6.ts.net/health` → `"status":"ok"`, `"db":true`, `"scheduler":true` |
| | `curl https://lecture-notes-staging.tail3659a6.ts.net/health` → `"database":"ok"`, `"storage":"ok"` |
| By eye | History lists the restored lectures and one opens; InsiderTrack's Data sources page shows yesterday's runs |

If the counts are far off yesterday's production numbers, the bundle is
the thing to look at, not the cluster.

### Failing looks like

`fetch` failing is credentials or Drive — `secrets/README.md`. `restore-db`
failing is the dump itself, and that is the drill doing its job: the log
says which step, and production still has its own copy. A failed Job
blocks the app's sync wave on purpose, so a half-restored staging never
looks healthy.

## What this does not prove

Worth being blunt, because it is easy to feel covered and not be:

- **It restores the database, not the machine.** The bundles also carry
  production's `deploy/.env`, its saved API keys and its Tailscale
  identity. The restore Jobs **delete those unread** — staging must not
  hold them. So this proves the data comes back; it does not prove a new
  machine comes back. That path is `deploy/restore.sh --from-remote
  latest`, and it gets exercised for real in `PLAN.md` step 2, when
  production moves to the new mini.
- **It proves yesterday, not any given day.** Only the newest daily bundle
  is ever restored. The weekly copies and older dailies are untested.
- **It tests `main`, not the pull request.** Image Updater follows the
  `:main` tag, so a Dependabot bump reaches staging *after* it merges —
  the old by-hand test looked *before*. That is an accepted trade:
  patch and minor bumps auto-merge on green CI, staging catches what CI
  misses within minutes, and the fix is `git revert`. For a major bump
  worth looking at first, pin the PR's image by hand:
  `image.tag: main-<sha>` in that chart's `values-staging.yaml`, look,
  then revert the pin.
- **Nothing tells you when it stops.** There is no alert on a stale
  bundle or a failed Job today; noticing is manual. That is exactly what
  DESIGN.md phases 7 and 9 add — Uptime Kuma watching backup age, and the
  drill as a weekly `CronJob` that wipes staging, restores, runs the
  smoke checks and reports.

## The weekly drill (phase 9)

The seed Job runs once, before the app starts. A **CronJob** then repeats
the same steps every **Sunday 13:00 UTC** — after the 03:00 local backup in
any US timezone — and adds a step the seed Job cannot do, because at that
point the app does not exist yet:

```
fetch → restore-db → (bucket → import-audio) → smoke
```

`smoke` asks the running app whether it can actually serve what was just
restored: `"db":true` from InsiderTrack, `"database":"ok"` **and**
`"storage":"ok"` from Lecture Notes, plus the MCP's own `/mcp/health`. A
bundle that restores into something the app cannot read is not a restore,
and this is what catches that.

```sh
kubectl -n insidertrack-staging get cronjob
kubectl -n insidertrack-staging logs -l app.kubernetes.io/component=restore-drill --tail=50
kubectl create job --from=cronjob/insidertrack-restore-drill drill-now -n insidertrack-staging   # run one now
```

`concurrencyPolicy: Forbid` and `startingDeadlineSeconds: 3600` mean a VM
that was off over the weekend produces no catch-up storm — it simply misses
that week. `backoffLimit: 0`: one attempt, then the failure stands where it
can be read.

The drill hits `restore.pushUrl` when it passes, which is empty today and
becomes an Uptime Kuma push monitor in phase 7 — at which point *not*
running becomes visible too, which is the half a CronJob alone cannot give
you.

### What the schedule costs

Lecture Notes re-fetches the whole audio mirror each run (fresh `emptyDir`,
no cache) — a few GB from Drive and about five minutes. Weekly is a
deliberate trade against nightly for that reason. Set
`restore.schedule: ""` in a chart's values to turn its drill off.
