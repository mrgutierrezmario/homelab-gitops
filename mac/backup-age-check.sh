#!/bin/bash
# Is the off-site backup still being made?
#
# `backup.sh` emails when it *fails*. It says nothing when it silently stops
# running — an unfired launchd job, an expired Drive token, a renamed remote.
# This reads the date out of the newest bundle in each remote and complains
# if it has fallen behind.
#
# It replaces the backup-age CronJob that ran in the staging cluster until
# that cluster was retired from this Mac (see ../README.md). No Kubernetes,
# no Docker — just rclone and the mail account the apps already use.
#
#   mac/backup-age-check.sh          check, email on trouble
#   mac/backup-age-check.sh --quiet  no email, exit code only (for testing)
#
# Install it to run daily: see mac/README.md.
set -uo pipefail

MAX_AGE_HOURS="${MAX_AGE_HOURS:-36}"
# Credentials come from InsiderTrack's deploy/.env — the same Gmail app
# password backup.sh uses. Nothing new to store.
ENV_FILE="${ENV_FILE:-$HOME/projects/insidertrack/deploy/.env}"
QUIET=0; [ "${1:-}" = "--quiet" ] && QUIET=1

# remote:bundle-name-prefix
REMOTES=(
  "stock-tracker-backup:stock-tracker"
  "lecture-backup:lecture-notes"
)

log() { echo "[backup-age $(date '+%Y-%m-%d %H:%M:%S')] $*"; }

command -v rclone >/dev/null || { log "rclone is not on PATH"; exit 1; }

# Same reader backup.sh uses: values may contain spaces, so no `source`.
load_env() {
  local line key val
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%=*}; val=${line#*=}
    case "$val" in \"*\") val=${val#\"}; val=${val%\"} ;; \'*\') val=${val#\'}; val=${val%\'} ;; esac
    export "$key=$val"
  done < "$1"
}
load_env "$ENV_FILE"

send_mail() {
  local subject=$1 body=$2
  local to="${MAIL_ADMIN_TO:-${MAIL_FROM:-${MAIL_USERNAME:-}}}"
  [ $QUIET = 1 ] && return 0
  if [ -z "${MAIL_USERNAME:-}" ] || [ -z "${MAIL_PASSWORD:-}" ] || [ -z "$to" ]; then
    log "no mail credentials in $ENV_FILE — not sending"; return 0
  fi
  printf 'From: %s\nTo: %s\nSubject: %s\n\n%s\n' \
    "${MAIL_FROM:-$MAIL_USERNAME}" "$to" "$subject" "$body" |
    curl -s --url "smtps://smtp.gmail.com:465" \
      --mail-from "${MAIL_FROM:-$MAIL_USERNAME}" --mail-rcpt "$to" \
      --user "$MAIL_USERNAME:$MAIL_PASSWORD" -T - >/dev/null 2>&1 \
    && log "emailed $to" || log "could not send mail"
}

problems=""
for entry in "${REMOTES[@]}"; do
  remote=${entry%%:*}; prefix=${entry##*:}
  listing=$(rclone lsf "${remote}:daily" --files-only 2>&1)
  if [ $? -ne 0 ]; then
    log "$remote: CANNOT READ — $listing"
    problems+="$remote: cannot read the remote. $listing"$'\n'
    continue
  fi
  latest=$(printf '%s\n' "$listing" \
    | grep -E "^${prefix}-[0-9]{4}-[0-9]{2}-[0-9]{2}\.tar\.gz$" | sort | tail -1)
  if [ -z "$latest" ]; then
    log "$remote: NO BUNDLES at all"
    problems+="$remote: no bundles found in daily/."$'\n'
    continue
  fi
  day=${latest#"$prefix"-}; day=${day%.tar.gz}
  # BSD date (macOS): -j parses without setting the clock.
  made=$(date -j -f "%Y-%m-%d" "$day" "+%s" 2>/dev/null)
  if [ -z "$made" ]; then
    log "$remote: could not parse the date in $latest"
    problems+="$remote: could not parse the date in $latest."$'\n'
    continue
  fi
  age=$(( ( $(date "+%s") - made ) / 3600 ))
  if [ "$age" -gt "$MAX_AGE_HOURS" ]; then
    log "$remote: STALE — $latest is ${age}h old (limit ${MAX_AGE_HOURS}h)"
    problems+="$remote: newest backup is $latest, ${age}h old (limit ${MAX_AGE_HOURS}h)."$'\n'
  else
    log "$remote: ok — $latest, ${age}h old"
  fi
done

if [ -n "$problems" ]; then
  send_mail "Backups may have stopped on $(hostname -s)" \
"A daily check found a problem with the off-site backups.

$problems
The backups themselves run at 03:00 from launchd:
  com.mgnetwork.stock-tracker-backup
  com.mgnetwork.lecture-backup

Check with:  launchctl list | grep mgnetwork
Logs:        <repo>/deploy/state/backups/backup.log
Run one now: <repo>/deploy/backup.sh

-- mac/backup-age-check.sh"
  exit 1
fi
log "all backups are current"
