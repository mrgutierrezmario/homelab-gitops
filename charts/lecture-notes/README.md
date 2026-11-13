# lecture-notes

[AI Lecture Notes](https://github.com/mrgutierrezmario/lecture-note-app) as
it runs in production — Postgres 18, Garage (S3), the app — plus a **restore Job**
that seeds the database (and optionally the audio bucket) from the newest
bundle `deploy/backup.sh` uploaded to the encrypted Drive remote.

```
wave 0  StatefulSet lecture-notes-postgres   PVC 2 Gi
        StatefulSet lecture-notes-garage     PVC 20 Gi, dxflrs/garage:v2.1.0, production's garage.toml
wave 1  Job         lecture-notes-restore    fetch (rclone) → restore-db (psql) → garage-init [→ import-audio]
wave 2  Deployment  lecture-notes            init: alembic upgrade head; then uvicorn. Whisper on CPU
        Ingress     lecture-notes            / → app :8000, Funnel
```

| Value | Staging | Notes |
|---|---|---|
| `ingress.host` | `lecture-notes-staging` | `PUBLIC_URL` is derived from it |
| `restore.rcloneRemote` | `lecture-backup:` | the crypt remote from `deploy/backup-setup.sh` |
| `restore.audio` | `true` | also pull `remote:audio/` and upload it to the bucket (~3,000 chunks, ~5 min). Without it, opening a restored lecture breaks the page — a frontend bug production can hit after retention (docs/OPERATIONS.md) |
| `restore.scrubTables` | `drive_links`, `drive_files` | see below |
| `app.ollamaBaseUrl` | `http://host.lima.internal:11434` | the Mac from inside the VM |
| `app.registrationOpen` | `"false"` | a copy on a public URL takes no sign-ups |
| `app.whisperModel` | `small` | ~2 GB while transcribing; the pod's limit is 3 Gi |

Secrets (SealedSecrets under `secrets/lecture-notes/`): `lecture-notes-db`
(`POSTGRES_PASSWORD`), `lecture-notes-garage` (`GARAGE_RPC_SECRET`,
`GARAGE_ADMIN_TOKEN`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`), `lecture-notes-app` (`SECRET_KEY`),
`lecture-notes-rclone` (`rclone.conf` with the `gdrive` and `lecture-backup`
remotes). `secrets/README.md` has the commands.

## Garage (replaced MinIO, 2026-11-13)

Production moved to Garage on 2026-09-25 when MinIO stopped publishing
community images; `quay.io/minio/*` now refuses anonymous pulls, so this
chart could no longer deploy. It now runs the same image and config as
production.

Garage needs a layout, a key and a bucket before the app can use it.
Production does that with the CLI (`deploy/garage-init.sh`); the Garage image
is distroless, so here the restore Job's **garage-init** step does the same
three things through the v2 admin API (`garage-init.py` in the restore
ConfigMap, run with the app image's Python). It is idempotent and runs before
`import-audio` on every restore and drill.

The key is *imported* with the ID and secret from `lecture-notes-garage`, so
the app and garage-init agree without a generated value being passed around.
Staging has its own credentials; nothing is shared with production.

Garage's `/health` returns 503 until a layout exists, so its probes are TCP:
an HTTP readiness probe would keep the pod unready, and garage-init could
never reach it to apply the layout.

## What the copy does and does not carry

- **Accounts and lectures**: all of them. Password hashes come along, so
  production credentials log in to staging.
- **Saved settings and API keys** (`app-state` volume in the bundle):
  **not restored** — deleted unread. Staging's Settings panel starts blank,
  the text provider defaults to Ollama, vision falls back to the local
  models. No paid key is ever spent from here.
- **Users' Google Drive links**: deleted (`restore.scrubTables`). They are
  encrypted with production's `SECRET_KEY` and unreadable with staging's
  anyway; deleting makes it explicit that staging can never write to a
  student's Drive.
- **Audio**: with `restore.audio: true` (staging: on).
- **Mail**: unset. "Forgot password?" is hidden.

## Migrations

`deploy/docker-entrypoint.sh` runs `alembic upgrade head` then uvicorn. The
chart splits that: the `migrate` initContainer runs the same command in the
same image, the app container runs uvicorn with the entrypoint's flags. A
restored dump carries `alembic_version`, so a newer image on `main` migrates
last night's production data — the Dependabot check this cluster exists for.

## Re-run the restore

```sh
kubectl -n lecture-notes-staging delete job lecture-notes-restore
kubectl -n lecture-notes-staging logs -f job/lecture-notes-restore -c fetch
kubectl -n lecture-notes-staging logs -f job/lecture-notes-restore -c restore-db
```

## Smoke test (DESIGN.md phase 4 "done when")

Open `https://lecture-notes-staging.tail3659a6.ts.net`, log in with a
production account, check History shows the restored lectures, start a
recording and speak for twenty seconds: the transcript should appear. The
first recording downloads Whisper `small` (~460 MB) into the cache PVC.
