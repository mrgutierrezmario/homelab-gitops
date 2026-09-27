#!/bin/bash
# Off-site copy of the Mac's own configuration — the files the apps' nightly
# bundles do not carry, without which a restored machine comes back with its
# data but not its public addresses:
#
#   ~/.cloudflared                 Cloudflare tunnel credentials and configs
#   mgnts-site/deploy/.env         the business site's mail + tunnel settings
#   mac/monitoring/.env            Grafana's admin password
#
# Tarred, then uploaded through an rclone *crypt* remote, so it is encrypted
# before it leaves the machine (same passphrase as the InsiderTrack backups).
# Keeps the newest $KEEP copies. It does not email on failure: the daily
# backup-age check (backup-age-check.sh) notices when this stops producing
# copies, the same way it does for the apps.
#
#   mac/config-backup.sh           back up now
#   mac/config-backup.sh --list    show the copies in the remote
#
# Restore: see mac/README.md → "Config backup".
set -euo pipefail

REMOTE="${CONFIG_BACKUP_REMOTE:-stock-tracker-backup:mac-config}"
PREFIX=mac-config
KEEP="${KEEP:-30}"
PATHS=(
  "$HOME/.cloudflared"
  "$HOME/projects/mgnts-site/deploy/.env"
  "$HOME/projects/homelab-gitops/mac/monitoring/.env"
)

log() { echo "[config-backup $(date '+%Y-%m-%d %H:%M:%S')] $*"; }
command -v rclone >/dev/null || { log "rclone is not on PATH"; exit 1; }

if [ "${1:-}" = "--list" ]; then
  rclone lsl "$REMOTE" | sort -k2,3
  exit 0
fi

# tar paths relative to $HOME, so a restore is one `tar -xzf … -C ~`.
rel=()
for p in "${PATHS[@]}"; do
  if [ -e "$p" ]; then rel+=("${p#"$HOME"/}"); else log "skipping (not found): $p"; fi
done
[ ${#rel[@]} -gt 0 ] || { log "nothing to back up"; exit 1; }

work=$(mktemp -d); chmod 700 "$work"
trap 'rm -rf "$work"' EXIT
name="$PREFIX-$(date '+%Y-%m-%d').tar.gz"
tar -czf "$work/$name" -C "$HOME" "${rel[@]}"
rclone copyto "$work/$name" "$REMOTE/$name"
log "uploaded $name ($(du -h "$work/$name" | cut -f1 | tr -d ' ')): ${rel[*]}"

# Prune: keep the newest $KEEP (names sort by date).
old=$(rclone lsf "$REMOTE" --files-only | grep -E "^$PREFIX-[0-9]{4}-[0-9]{2}-[0-9]{2}\.tar\.gz$" \
  | sort -r | awk -v keep="$KEEP" 'NR > keep')
for f in $old; do
  rclone deletefile "$REMOTE/$f" && log "pruned $f"
done
