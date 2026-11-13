#!/bin/bash
# Nightly Homebridge plugin updates (com.mgnetwork.homebridge-plugin-update, 04:00).
#
# - Patch/minor updates install automatically, then that plugin's child bridge
#   is restarted so the new version loads (Homebridge relaunches it).
# - Major updates (and minor bumps of 0.x plugins, which semver treats as
#   breaking) are NOT installed: they're logged and shown as a Mac notification
#   so you can read the changelog and update from the Homebridge UI.
# - Homebridge itself and the Homebridge UI are left alone; update those by hand.
#
# Roll back a bad update:  npm install -g --prefix /usr/local homebridge-foo@<old>
# (the old version is in the log), then restart that bridge in the Homebridge UI.
#
# Log: ~/Library/Logs/homebridge-plugin-update.log
#   DRY_RUN=1 ./homebridge-plugin-update.sh   show what would happen, change nothing
set -uo pipefail

PREFIX=/usr/local
DRY_RUN="${DRY_RUN:-}"
SKIP_RE='^(homebridge|homebridge-config-ui-x)$'

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }
notify() { [ -n "$DRY_RUN" ] || osascript -e "display notification \"$1\" with title \"Homebridge updates\"" 2>/dev/null || true; }

# OUTDATED_JSON lets tests feed fake `npm outdated` output.
json="${OUTDATED_JSON:-$(npm outdated -g --prefix "$PREFIX" --json 2>/dev/null)}"
[ -n "$json" ] || json='{}'

# name <TAB> current <TAB> latest, plugins only.
rows=$(node -e '
  const d = JSON.parse(process.argv[1] || "{}");
  for (const [n, v] of Object.entries(d)) {
    if (/^(@[^/]+\/)?homebridge-/.test(n) || n === "homebridge")
      console.log([n, v.current, v.latest].join("\t"));
  }' "$json") || { log "could not parse npm outdated output"; exit 1; }

if [ -z "$rows" ]; then
  log "all plugins up to date"
  exit 0
fi

held=()
failed=()
while IFS=$'\t' read -r name cur new; do
  [ -n "$name" ] || continue
  if [[ "$name" =~ $SKIP_RE ]]; then
    log "$name $cur -> $new available; core package, update it by hand in the Homebridge UI"
    continue
  fi
  cmaj=${cur%%.*}; nmaj=${new%%.*}
  cmin=$(cut -d. -f2 <<<"$cur"); nmin=$(cut -d. -f2 <<<"$new")
  if [ "$cmaj" != "$nmaj" ] || { [ "$cmaj" = 0 ] && [ "$cmin" != "$nmin" ]; }; then
    log "$name $cur -> $new is a major update; NOT installed (check the changelog, update in the Homebridge UI)"
    held+=("$name $new")
    continue
  fi
  if [ -n "$DRY_RUN" ]; then
    log "$name $cur -> $new would install and restart its bridge (dry run)"
    continue
  fi
  if out=$(npm install -g --prefix "$PREFIX" --omit=dev "$name@$new" 2>&1); then
    log "$name updated $cur -> $new (roll back: npm install -g --prefix $PREFIX $name@$cur)"
    # Child bridge processes are titled "homebridge: <plugin>".
    if pkill -f "homebridge: $name( |\$)"; then
      log "$name: bridge restarted"
    else
      log "$name: no child bridge found; restart Homebridge for the update to take effect"
    fi
  else
    log "$name update to $new FAILED, still on $cur:"; sed 's/^/    /' <<<"$out" | tail -15
    failed+=("$name")
  fi
done <<<"$rows"

[ ${#held[@]} -eq 0 ]   || notify "Major update waiting: ${held[*]}"
[ ${#failed[@]} -eq 0 ] || notify "Update failed: ${failed[*]} (see homebridge-plugin-update.log)"
exit 0
