# lecture-notes

[AI Lecture Notes](https://github.com/mrgutierrezmario/lecture-note-app) as
it runs in production — Postgres 18, MinIO, the app — plus a **restore Job**
that seeds the database (and optionally the audio bucket) from the newest
bundle `deploy/backup.sh` uploaded to the encrypted Drive remote.

```
wave 0  StatefulSet lecture-notes-postgres   PVC 2 Gi
        StatefulSet lecture-notes-minio      PVC 20 Gi
wave 1  Job         lecture-notes-restore    fetch (rclone) → restore-db (psql) → bucket (mc) [→ import-audio]
wave 2  Deployment  lecture-notes            init: alembic upgrade head; then uvicorn. Whisper on CPU
        Ingress     lecture-notes            / → app :8000, Funnel
```

| Value | Staging | Notes |
|---|---|---|
| `ingress.host` | `lecture-notes-staging` | `PUBLIC_URL` is derived from it |
| `restore.rcloneRemote` | `lecture-backup:` | the crypt remote from `deploy/backup-setup.sh` |
| `restore.audio` | `false` | also pull `remote:audio/` and upload it to the bucket (hundreds of MB; old lectures become playable) |
| `restore.scrubTables` | `drive_links`, `drive_files` | see below |
| `app.ollamaBaseUrl` | `http://host.lima.internal:11434` | the Mac from inside the VM |
| `app.registrationOpen` | `"false"` | a copy on a public URL takes no sign-ups |
| `app.whisperModel` | `small` | ~2 GB while transcribing; the pod's limit is 3 Gi |

Secrets (SealedSecrets under `secrets/lecture-notes/`): `lecture-notes-db`
(`POSTGRES_PASSWORD`), `lecture-notes-minio` (`MINIO_ROOT_USER`,
`MINIO_ROOT_PASSWORD`), `lecture-notes-app` (`SECRET_KEY`),
`lecture-notes-rclone` (`rclone.conf` with the `gdrive` and `lecture-backup`
remotes). `secrets/README.md` has the commands.

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
- **Audio**: only with `restore.audio: true`.
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
