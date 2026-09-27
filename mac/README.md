# mac/

The parts of this repo that run **on the Mac** rather than in the cluster:
the daily backup-age check (below), Prometheus + Grafana for the production
containers (`monitoring/`), and the rclone client-ID runbook.

While the staging cluster ran, a CronJob in it checked daily that the
off-site backups were still being made. That cluster was retired from this
Mac (see `../README.md`), and the check is the one thing from it that was
worth keeping alive — because it covers a gap nothing else does:
`deploy/backup.sh` emails when a backup **fails**, and says nothing at all
when it silently **stops running**.

`monitoring/` — a small Prometheus + Grafana for the production containers
(dashboards only; alerts are UptimeRobot's). See `monitoring/README.md`.

## Install

```sh
mac/install.sh
```

Runs daily at 09:30 and emails only when something is wrong. It reuses the
Gmail app password already in `insidertrack/deploy/.env` — nothing new to
store. Uninstall with `mac/install.sh --remove`.

## rclone's own Drive client ID — done

`rclone-own-client-id.md` — rclone's shared Google Drive client is retired
during 2026. Both Drive remotes on this Mac now use their own client ID
(verified 2026-09-26, backups current). Keep the runbook for a new machine
(`PLAN.md` step 2), and re-seal the two rclone secrets before the cluster
is rebuilt (`docs/OPERATIONS.md`).

## Check it by hand any time

```sh
mac/backup-age-check.sh            # emails if stale
mac/backup-age-check.sh --quiet    # prints only, exit code 1 if stale
```

Or without the script at all:

```sh
rclone lsf stock-tracker-backup:daily | sort | tail -3
rclone lsf lecture-backup:daily | sort | tail -3
```

Today's or yesterday's date in the newest filename means it ran.

## What it does and does not cover

| | |
|---|---|
| Covers | a backup that stopped running, an unreadable remote, an expired Drive token, an empty backup folder |
| Threshold | whole calendar days, not hours, so the answer does not move with the time of day you run it. Default 1: yesterday's backup is fine, the night before last is not. `MAX_AGE_DAYS=2 mac/backup-age-check.sh` to loosen it |
| Does **not** cover | whether the bundle actually *restores*. That was the cluster's weekly restore drill (`docs/restore-drill.md`), and it is gone until the cluster is rebuilt |
| Does **not** cover | itself. If this job stops running, nothing says so. Real dead-man cover needs something off this machine — which is what Uptime Kuma's push monitors did |

Both gaps close when the cluster comes back on the dedicated mini. Until
then, `launchctl list | grep mgnetwork` shows whether it is still scheduled.
