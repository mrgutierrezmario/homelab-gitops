#!/bin/bash
# Restart Homebridge child bridges that come up but never log in to their cloud.
#
# Midea (homebridge-midea-air-ac) and Dreo try to log in once at startup. If the
# internet is briefly down at that moment they sit there forever, cached in
# HomeKit as "No Response", until someone restarts the bridge by hand. This runs
# every 5 minutes (com.mgnetwork.homebridge-watchdog) and does that restart.
#
# For each bridge, look at its most recent "Child bridge started" line. If no
# success line follows it within GRACE seconds (or a failure line does), and the
# cloud host is reachable now, kill the child process; Homebridge relaunches it.
#
# Midea's poll loop logs nothing when healthy, so a silent stall after a good
# login can't be seen in the log. Backstop: restart Midea once a day at 04:30.
#
# Log: ~/Library/Logs/homebridge-watchdog.log
set -uo pipefail

HBLOG="${HBLOG:-$HOME/.homebridge/homebridge.log}"
STATE="${STATE:-$HOME/.homebridge/.watchdog-state}"
DRY_RUN="${DRY_RUN:-}"   # DRY_RUN=1: report what would be restarted, touch nothing
GRACE=180          # seconds a bridge gets to log in after starting
MAX_PER_HOUR=6     # stop restarting a bridge after this many tries in an hour

# name | process match | log tag | success pattern | failure pattern | cloud host
BRIDGES=(
  "midea|homebridge: homebridge-midea-air-ac|[homebridge-midea-air-ac]|Created device:|Login failed|mapp.appsmb.com"
  "dreo|homebridge: homebridge-dreo|[Dreo Platform]|Region:|Authentication error|app-api-us.dreo-tech.com"
)

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }
now=$(date +%s)
mkdir -p "$(dirname "$STATE")"; touch "$STATE"

[ -f "$HBLOG" ] || { log "no $HBLOG, nothing to do"; exit 0; }
# Recent, colour-stripped log is all we need.
recent=$(tail -n 4000 "$HBLOG" | sed $'s/\x1b\\[[0-9;]*m//g')

to_epoch() { # "[11/12/2026, 8:59:25 PM] ..." -> epoch seconds
  local ts; ts=$(sed -nE 's/^\[([0-9/]+, [0-9:]+ [AP]M)\].*/\1/p' <<<"$1")
  [ -n "$ts" ] && date -j -f "%m/%d/%Y, %I:%M:%S %p" "$ts" +%s 2>/dev/null
}

restart() { # name, process match, reason
  local name=$1 match=$2 reason=$3
  # Flap guard: count this bridge's restarts in the last hour.
  local recent_count
  recent_count=$(awk -v n="$name" -v t=$((now - 3600)) '$1==n && $2>t' "$STATE" | wc -l | tr -d ' ')
  if [ "$recent_count" -ge "$MAX_PER_HOUR" ]; then
    log "$name: $reason, but already restarted $recent_count times this hour; leaving it alone"
    return
  fi
  if [ -n "$DRY_RUN" ]; then
    log "$name: $reason -> would restart (dry run)"; return
  fi
  if pkill -f "$match"; then
    echo "$name $now" >>"$STATE"
    log "$name: $reason -> restarted"
  else
    log "$name: $reason, but no running process matched '$match'"
  fi
}

for row in "${BRIDGES[@]}"; do
  IFS='|' read -r name match tag ok bad host <<<"$row"

  start_line=$(grep -nF "$tag Child bridge started successfully" <<<"$recent" | tail -1)
  [ -n "$start_line" ] || continue
  lineno=${start_line%%:*}
  started=$(to_epoch "${start_line#*:}") || continue
  after=$(tail -n +"$lineno" <<<"$recent" | grep -F "$tag")

  if grep -qF "$ok" <<<"$after"; then
    continue                                   # logged in fine
  fi
  if grep -qF "$bad" <<<"$after"; then
    reason="login failed after start"
  elif [ $((now - started)) -gt "$GRACE" ]; then
    reason="no login $(( (now - started) / 60 )) min after start"
  else
    continue                                   # still within grace period
  fi

  # Restarting while the internet is down just fails the same way again.
  if ! curl -s -m 8 -o /dev/null "https://$host/"; then
    log "$name: $reason, but $host is unreachable; will retry next run"
    continue
  fi
  restart "$name" "$match" "$reason"
done

# Daily backstop for Midea's silent stalls (runs in the 04:30-04:34 window).
today=$(date +%F)
if [ "$(date +%H%M)" -ge 0430 ] && [ "$(date +%H%M)" -lt 0435 ] && ! grep -q "^daily-midea $today" "$STATE"; then
  echo "daily-midea $today" >>"$STATE"
  restart midea "homebridge: homebridge-midea-air-ac" "daily 04:30 refresh"
fi

# Keep the state file small.
awk -v t=$((now - 86400 * 7)) '($1=="daily-midea") || $2>t' "$STATE" >"$STATE.tmp" && mv "$STATE.tmp" "$STATE"
exit 0
