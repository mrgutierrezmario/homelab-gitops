#!/bin/bash
# Point rclone's Drive remotes at a client ID/secret and re-authorise them.
#
# Use it when giving rclone its own OAuth client for the first time, or when
# rotating a secret that leaked. Full context: mac/rclone-own-client-id.md
#
#   mac/rclone-rotate.sh            prompt for the values and do it
#   mac/rclone-rotate.sh --verify   just check the remotes still work
#
# It asks for the secret without echoing it, so nothing sensitive lands in
# your shell history or on screen.
set -uo pipefail

REMOTES=(gdrive-stock-tracker gdrive)
CRYPT=(stock-tracker-backup lecture-backup keystore-vault)

verify() {
  echo
  echo "── Checking every remote still works ──"
  local bad=0
  for c in "${CRYPT[@]}"; do
    if [ "$c" = keystore-vault ]; then
      n=$(rclone ls "$c:" 2>/dev/null | wc -l | tr -d ' ')
      [ "${n:-0}" -gt 0 ] && echo "  OK   $c: $n files" || { echo "  FAIL $c: nothing listed"; bad=1; }
    else
      newest=$(rclone lsf "$c:daily" 2>/dev/null | sort | tail -1)
      [ -n "$newest" ] && echo "  OK   $c: newest is $newest" || { echo "  FAIL $c: nothing listed"; bad=1; }
    fi
  done
  echo
  if [ $bad = 0 ]; then
    echo "All good. Now, in the Cloud Console, delete the OLD secret —"
    echo "and run a real backup rather than waiting for 03:00:"
    echo "  ~/projects/insidertrack/deploy/backup.sh"
  else
    echo "Something did not list. Re-run the reconnect step; at"
    echo '"Configure this as a Shared Drive (Team Drive)?" answer n.'
  fi
  return $bad
}

[ "${1:-}" = "--verify" ] && { verify; exit $?; }

command -v rclone >/dev/null || { echo "rclone is not installed"; exit 1; }

# rclone's auth callback always listens on this port. A previous attempt that
# was interrupted leaves it held, and the next run dies with
# "bind: address already in use" long after you have typed everything in.
free_auth_port() {
  local pids
  pids=$(lsof -ti tcp:53682 2>/dev/null)
  [ -z "$pids" ] && return 0
  echo "Port 53682 is still held by an earlier rclone auth attempt."
  printf 'Stop it? [Y/n] '; read -r a
  case "${a:-y}" in
    [Nn]*) echo "Leaving it; the reconnect will fail until it is gone."; return 1 ;;
  esac
  echo "$pids" | while read -r p; do kill "$p" 2>/dev/null; done
  sleep 1
  [ -z "$(lsof -ti tcp:53682 2>/dev/null)" ] && echo "  freed" || echo "  still held — try: lsof -ti tcp:53682 | xargs kill -9"
}
free_auth_port

echo "Paste the OAuth client ID, then the secret (the secret stays hidden)."
printf 'client ID     : '; read -r ID
printf 'client secret : '; read -rs SECRET; echo

if [ -z "$ID" ] || [ -z "$SECRET" ]; then
  echo "Both values are required — nothing changed."; exit 1
fi

# The two are easy to swap, and a swap is only discovered several prompts and
# one browser round-trip later. They have distinct shapes, so just check.
case "$ID" in
  *.apps.googleusercontent.com) ;;
  GOCSPX-*) echo; echo "That is the SECRET, not the client ID — they are swapped."
            echo "The ID ends in .apps.googleusercontent.com. Nothing changed."; exit 1 ;;
  *) echo; echo "That does not look like a client ID (expected it to end in"
     echo ".apps.googleusercontent.com). Nothing changed."; exit 1 ;;
esac
case "$SECRET" in
  *.apps.googleusercontent.com)
     echo; echo "That is the client ID in the secret field. Nothing changed."; exit 1 ;;
esac

for r in "${REMOTES[@]}"; do
  rclone config update "$r" client_id "$ID" client_secret "$SECRET" >/dev/null \
    && echo "  updated $r" || { echo "  FAILED to update $r"; exit 1; }
done

cat <<'NOTE'

Now re-authorising. For EACH remote a browser window opens:
  1. sign in with the Google account that owns the backups
  2. at "Configure this as a Shared Drive (Team Drive)?"  answer  n
     (these are personal Drive folders; the drive.file scope cannot list
      Team Drives, and answering y fails with a 403 about scopes)
NOTE

for r in "${REMOTES[@]}"; do
  echo; echo "── reconnect $r ──"
  rclone config reconnect "$r:" || echo "  reconnect reported a problem — see the note above"
done

verify
