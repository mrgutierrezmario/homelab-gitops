# monitoring/

A small Prometheus + Grafana for the production containers on this Mac —
for **looking** at how things behave. **Alerts are UptimeRobot's job**, from
outside the house, so it also notices when this whole Mac is down; nothing
here can.

- **Grafana:** https://grafana.tail3659a6.ts.net (tailnet devices only, no
  Funnel) or http://localhost:3030 — user `admin`, password in `.env`.
- **Prometheus:** http://localhost:9090 (this Mac only).

```sh
./start.sh     # start or update; first run generates .env and asks for a Tailscale sign-in
./stop.sh      # stop; metrics, dashboards and the login are kept
```

## What it collects

| Service | What | Cap |
|---|---|---|
| `docker-exporter` | CPU, memory, network per container, from the Docker API (`docker stats` numbers) | 64 MB |
| `node-exporter` | the Docker VM: CPU, memory, load, disk | 48 MB |
| `blackbox` | the three public sites, through Funnel: up/down and response time | 48 MB |
| `prometheus` | scrapes every 30 s, keeps **7 days or 1 GB** | 384 MB |
| `grafana` | one provisioned dashboard, *Mac mini — production* | 256 MB |

About 250 MB in use, with hard caps well under 1 GB. The design doc's
reason to keep this small still holds: CPU, not memory, is what took the
staging cluster down (`../../docs/incident-2026-09-23-staging-flapping.md`).

## Why not cAdvisor

It was the first choice and it does not work here: Docker Desktop's
containerd image store leaves cAdvisor unable to identify containers
("failed to identify the read-write layer ID"), so it reports only the VM
total. `docker-exporter/exporter.py` is ~90 lines of standard-library
Python that asks Docker directly.

## On a Mac, "node" means the Docker VM

node-exporter sees the Linux VM Docker Desktop runs, not macOS — which is
the memory and CPU production actually lives in. macOS itself (Ollama,
swap) is not in these graphs.

## Changing the dashboard

The dashboard is provisioned read-only from
`grafana/dashboards/mac-mini.json`: edit it in Grafana, *Export → JSON*,
save over that file, commit. Changes made only in the UI are not kept.
