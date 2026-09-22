# insidertrack

[InsiderTrack](https://github.com/mrgutierrezmario/insidertrack) as it runs
in production — Postgres 18 + the app — plus one thing production does not
have: a **restore Job** that seeds the database from the newest bundle
`deploy/backup.sh` uploaded to the encrypted Google Drive remote. The
cluster never holds data it did not restore itself (DESIGN.md §2).

```
wave 0  StatefulSet insidertrack-postgres    PVC 5 Gi, pg_isready probes
wave 1  Job         insidertrack-restore     init: rclone fetches the newest daily bundle
                                             main: psql loads it into <db>_restore, scrubs, swaps
wave 2  Deployment  insidertrack             the app, Recreate strategy (one scheduler at a time)
        Ingress     insidertrack             / → app :8003, /mcp → insidertrack-mcp :8100, Funnel
```

## Values worth knowing

| Value | Staging | Notes |
|---|---|---|
| `ingress.host` | `insidertrack-staging` | `PUBLIC_DOMAIN` (CORS) is derived from it |
| `ingress.mcpService` | `insidertrack-mcp` | the MCP release's Service; empty = no `/mcp` route |
| `restore.rcloneRemote` | `stock-tracker-backup:` | the crypt remote from `deploy/backup-setup.sh` |
| `restore.scrubSettings` | API keys + mail credentials | `app_settings` rows deleted from the copy |
| `app.ollamaBaseUrl` | `http://host.lima.internal:11434` | the Mac from inside the VM; see below |
| `app.trustedProxies` | empty | see "Known differences" |

Secrets (all SealedSecrets under `secrets/insidertrack/`): `insidertrack-db`
(`DB_PASSWORD`), `insidertrack-app` (`ADMIN_PASSWORD`), `insidertrack-rclone`
(`rclone.conf`). How to make them: `secrets/README.md`.

## The restore

`restore.sh` in the ConfigMap, tested against a real Postgres 18 before the
first deploy:

1. Extract the bundle; **delete its `env` and `tailscale-state.tar.gz`
   immediately** — production's secrets and identity, not for a copy.
2. `CREATE DATABASE <db>_restore`, load `db.sql.gz`, print the row counts
   the way `deploy/restore.sh` does.
3. Scrub: delete `restore.scrubSettings` rows, upsert
   `ai_provider`/`ai_batch_provider`/`ollama_base_url` so the copy never
   spends a paid key or sends an email.
4. Swap: terminate connections, rename the live database to `<db>_old`,
   rename `<db>_restore` in, drop `<db>_old`. The app reconnects.

**Run it again** (a fresh copy of last night, or after a failed run):

```sh
kubectl -n insidertrack-staging delete job insidertrack-restore   # Argo recreates it
kubectl -n insidertrack-staging logs -f job/insidertrack-restore -c fetch
kubectl -n insidertrack-staging logs -f job/insidertrack-restore
```

Phase 9 wraps this in a CronJob.

## Ollama from the VM

Pods reach the Mac at `host.lima.internal`. Ollama on the Mac listens on
`127.0.0.1` by default; for the VM to reach it, it has to listen on all
interfaces: Ollama menu-bar app → Settings → *Expose Ollama to the
network*, or `launchctl setenv OLLAMA_HOST 0.0.0.0` and restart Ollama.
Check from the Mac: `curl -s http://$(ipconfig getifaddr en0):11434/api/tags`.
Without it the app runs fine — AI notes and the daily brief just fail
quietly, as they do in production when Ollama is not running.

## Known differences from production

- **`TRUSTED_PROXIES` is empty.** The app matches proxies by exact IP and
  the Ingress proxy pod's IP is not stable, so `X-Forwarded-For` is ignored
  and every visitor shares one rate-limit bucket. Harmless in staging. The
  fix, if it ever matters, is a CIDR match in `routers/access.py:_get_ip`
  (DESIGN.md §7 says: note it, build around it).
- **Backups dir is an emptyDir.** The app's own nightly `pg_dump` lands
  there; a copy of a copy, gone with the pod. Production keeps a volume.
- **No Tailscale sidecar, no watchdog loop** in the entrypoint doing
  anything useful: `POSTGRES_HOST` is a Service name that always resolves.
- **The scrapers run** against the copy, the same schedule as production.
  That is deliberate (DESIGN.md §4): it is what a dependency bump breaks.
