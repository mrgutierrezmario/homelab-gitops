#!/bin/bash
# Start (or update) the monitoring stack. Safe to re-run.
#   ./start.sh      start, print the Grafana URL
#   ./stop.sh       stop (metrics and the Tailscale login are kept)
set -euo pipefail
cd "$(dirname "$0")"
DC="docker compose -f compose.yml"
log() { echo "[monitoring] $*"; }

docker info >/dev/null 2>&1 || { echo "Docker is not running." >&2; exit 1; }

if [ ! -f .env ]; then
  log "Creating .env with a generated Grafana admin password..."
  cp .env.example .env
  pw=$(python3 -c "import secrets; print(secrets.token_urlsafe(18))")
  sed -i.bak "s|^GRAFANA_ADMIN_PASSWORD=$|GRAFANA_ADMIN_PASSWORD=$pw|" .env && rm -f .env.bak
  chmod 600 .env
fi

$DC up -d --remove-orphans

# One-time Tailscale sign-in (same approach as the apps' deploy/start.sh).
ts() { $DC exec -T tailscale tailscale "$@"; }
for i in $(seq 1 15); do ts status >/dev/null 2>&1 && break; sleep 2; done
if ! ts status >/dev/null 2>&1; then
  log "Tailscale is not signed in yet — one-time interactive login."
  $DC stop grafana tailscale >/dev/null
  $DC run --rm --no-deps -T tailscale sh -c '
    tailscaled --tun=userspace-networking --statedir=/var/lib/tailscale --socket=/tmp/tailscaled.sock >/dev/null 2>&1 &
    for i in $(seq 1 30); do [ -S /tmp/tailscaled.sock ] && break; sleep 1; done
    tailscale --socket=/tmp/tailscaled.sock up --hostname="$TS_HOSTNAME" --accept-dns=false' \
    || { echo "Sign-in did not complete — re-run ./start.sh." >&2; exit 1; }
  $DC up -d
  for i in $(seq 1 30); do ts status >/dev/null 2>&1 && break; sleep 2; done
fi

for i in $(seq 1 30); do curl -fs http://127.0.0.1:3030/api/health >/dev/null 2>&1 && break; sleep 2; done
NAME=$(ts status --self=true --peers=false --json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['Self']['DNSName'].rstrip('.'))" 2>/dev/null || true)
echo
echo "============================================================"
echo "  Grafana:     ${NAME:+https://$NAME}  (your tailnet devices only)"
echo "  Local:       http://localhost:3030"
echo "  Login:       admin / see GRAFANA_ADMIN_PASSWORD in mac/monitoring/.env"
echo "  Prometheus:  http://localhost:9090  (this Mac only)"
echo "============================================================"
