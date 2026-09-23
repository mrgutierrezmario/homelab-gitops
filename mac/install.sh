#!/bin/bash
# Install the daily backup-age check as a launchd job. Safe to re-run.
#
#   mac/install.sh            install / reinstall
#   mac/install.sh --remove   uninstall
set -euo pipefail
cd "$(dirname "$0")"
REPO=$(cd .. && pwd)
LABEL=com.mgnetwork.backup-age-check
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ "${1:-}" = "--remove" ]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Removed $LABEL."
  exit 0
fi

command -v rclone >/dev/null || { echo "rclone is not installed (brew install rclone)" >&2; exit 1; }
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
sed "s|__REPO__|$REPO|g; s|__HOME__|$HOME|g" "$LABEL.plist" > "$PLIST"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "Installed $LABEL — runs daily at 09:30."
echo "Log: $HOME/Library/Logs/backup-age-check.log"
echo
echo "Running it once now to prove it works:"
echo
exec ./backup-age-check.sh
