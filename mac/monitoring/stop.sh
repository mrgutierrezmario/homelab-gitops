#!/bin/bash
# Stop monitoring. Metrics, dashboards and the Tailscale login are kept.
set -euo pipefail
cd "$(dirname "$0")"
docker compose -f compose.yml stop
