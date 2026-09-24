# Giving rclone its own Google Drive client ID

**Why this is not optional.** Every Drive remote on this Mac uses rclone's
*shared* OAuth client, and Google is retiring it during 2026 — rclone prints
the warning on every run. When it stops working, `deploy/backup.sh` can no
longer upload and **the off-site backups stop**. `mac/backup-age-check.sh`
would notice within two days, but noticing is not the same as not losing
them.

Affects every remote here, because the encrypted ones are layered on the
two Drive remotes:

| Remote | Used by |
|---|---|
| `gdrive-stock-tracker` | InsiderTrack backups, and `keystore-vault` on top of it |
| `gdrive` | Lecture Notes backups |
| `stock-tracker-backup` | crypt over `gdrive-stock-tracker` |
| `lecture-backup` | crypt over `gdrive` |
| `keystore-vault` | crypt over `gdrive-stock-tracker` — the Android signing keys |

Only the two Drive remotes need changing; the crypt remotes inherit it and
their passphrases are untouched.

## 1. Make the OAuth client (browser, ~10 minutes)

Full instructions: https://rclone.org/drive/#making-your-own-client-id

1. https://console.cloud.google.com/ → create a project (any name).
2. **APIs & Services → Library** → search *Google Drive API* → **Enable**.
3. **APIs & Services → OAuth consent screen** → **External** → fill in the
   app name and your email. Add your own Google account under **Test users**.
   **Publish the app** (consent screen → *Publish app*). In *Testing* mode
   Google expires refresh tokens after 7 days, which would silently stop the
   backups a week later. Publishing needs no Google review for the
   `drive.file` scope with only your own account using it.
   - Scope to add: `https://www.googleapis.com/auth/drive.file` — that is
     the scope `backup-setup.sh` uses, and it limits rclone to files it
     created itself.
4. **APIs & Services → Credentials → Create credentials → OAuth client ID**
   → application type **Desktop app**.
5. Copy the **Client ID** and **Client secret**.

## 2. Point the remotes at it (terminal)

```sh
ID='<client id>'; SECRET='<client secret>'
[ -n "$ID" ] && [ -n "$SECRET" ] || echo "BOTH must be set — stop"

for r in gdrive-stock-tracker gdrive; do
  rclone config update "$r" client_id "$ID" client_secret "$SECRET"
done
```

Then re-authorise each one — the old token was issued to the old client and
will not work with the new one:

```sh
rclone config reconnect gdrive-stock-tracker:
rclone config reconnect gdrive:
```

A browser window opens for each; sign in with the Google account that owns
the backups. Then **answer `n` to "Configure this as a Shared Drive (Team
Drive)?"** — these are personal Drive folders, and the `drive.file` scope
cannot list Team Drives, so answering `y` ends the reconnect with:

```
Error: listing Team Drives failed: googleapi: Error 403:
  Request had insufficient authentication scopes.
```

That failure is only the last question; the authorisation itself succeeded.
Rerun `reconnect` and answer `n`.

### If a token or secret ever gets exposed

Pasting `rclone config show` output anywhere shares a live `refresh_token`
— that alone is ongoing access to everything rclone created in the Drive,
which here means both backup folders and the keystore vault. `client_secret`
is less sensitive (desktop OAuth clients are not really secret) but rotate
both together:

1. https://myaccount.google.com/connections → remove the connection. **It is
   not listed as "rclone"** — it carries the name from the OAuth consent
   screen, currently **"Lecture App rclone backups"**. One entry covers all
   three remotes (`gdrive`, `gdrive-stock-tracker`, and `keystore-vault` on
   top of it), so removing it revokes everything and re-authorising restores
   everything. This is the step that actually kills the refresh token.
2. https://console.cloud.google.com/apis/credentials → the OAuth client →
   **Add secret** (newer consoles have no "Reset"). Copy the new value.
3. Rerun step 2 above with the new secret, `reconnect` both remotes, confirm
   the listings in step 3 work, and **only then** delete the old secret.
   Deleting first leaves a window where the 03:00 backup fails.

Use `rclone config show <remote> | grep -v token` if you need to check a
remote's settings.

## 3. Prove it works

The warning should be gone, and every remote should still list:

```sh
rclone lsf stock-tracker-backup:daily | sort | tail -2
rclone lsf lecture-backup:daily      | sort | tail -2
rclone ls  keystore-vault:
mac/backup-age-check.sh --quiet
```

No `NOTICE: ... shared Google Drive client_id` line means it took. If the
listings are empty or error, the reconnect did not complete — rerun step 2's
`reconnect` before the next 03:00 backup.

Then run one real backup by hand rather than waiting for the schedule:

```sh
/Users/mario/projects/insidertrack/deploy/backup.sh
/Users/mario/projects/lecture-note-app/deploy/backup.sh
```
