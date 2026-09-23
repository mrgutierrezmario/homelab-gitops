# mac/

The one piece of this repo that runs **on the Mac** rather than in the
cluster.

While the staging cluster ran, a CronJob in it checked daily that the
off-site backups were still being made. That cluster was retired from this
Mac (see `../README.md`), and the check is the one thing from it that was
worth keeping alive — because it covers a gap nothing else does:
`deploy/backup.sh` emails when a backup **fails**, and says nothing at all
when it silently **stops running**.

## Install

```sh
mac/install.sh
```

Runs daily at 09:30 and emails only when something is wrong. It reuses the
Gmail app password already in `insidertrack/deploy/.env` — nothing new to
store. Uninstall with `mac/install.sh --remove`.

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
| Threshold | 36 hours — one missed night is noise, two is a problem. `MAX_AGE_HOURS=48 mac/backup-age-check.sh` to change it |
| Does **not** cover | whether the bundle actually *restores*. That was the cluster's weekly restore drill (`docs/restore-drill.md`), and it is gone until the cluster is rebuilt |
| Does **not** cover | itself. If this job stops running, nothing says so. Real dead-man cover needs something off this machine — which is what Uptime Kuma's push monitors did |

Both gaps close when the cluster comes back on the dedicated mini. Until
then, `launchctl list | grep mgnetwork` shows whether it is still scheduled.
