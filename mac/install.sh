#!/bin/bash
# Install the Mac's launchd jobs. Safe to re-run.
#
#   com.mgnetwork.config-backup      03:30  encrypted off-site copy of the Mac's config
#   com.mgnetwork.backup-age-check   09:30  are the off-site backups still being made?
#
#   mac/install.sh            install / reinstall both
#   mac/install.sh --remove   uninstall both
set -euo pipefail
cd "$(dirname "$0")"
REPO=$(cd .. && pwd)
LABELS=(com.mgnetwork.config-backup com.mgnetwork.backup-age-check)

if [ "${1:-}" = "--remove" ]; then
  for LABEL in "${LABELS[@]}"; do
    PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Removed $LABEL."
  done
  exit 0
fi

command -v rclone >/dev/null || { echo "rclone is not installed (brew install rclone)" >&2; exit 1; }
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
for LABEL in "${LABELS[@]}"; do
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  sed "s|__REPO__|$REPO|g; s|__HOME__|$HOME|g" "$LABEL.plist" > "$PLIST"
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load "$PLIST"
  echo "Installed $LABEL."
done
echo "Logs: $HOME/Library/Logs/config-backup.log, backup-age-check.log"
echo
echo "Running both once now to prove they work:"
echo
./config-backup.sh
exec ./backup-age-check.sh
