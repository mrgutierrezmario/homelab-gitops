# Uptime Kuma

`https://uptime.tail3659a6.ts.net` — tailnet only (see the Ingress comment
in `uptime-kuma.yaml` before considering Funnel).

Running **Uptime Kuma 2.x, rootless**, pinned to an exact version in
`uptime-kuma.yaml`. Bumping it is a deliberate edit — check the release
notes first, because its data (below) is the one thing here that no restore
job can bring back.

## First login

Kuma has no default account: the first person to open it creates the admin.
Do that immediately after the first sync — until then, anyone on the tailnet
can. Use a real password and turn on 2FA in *Settings → Security*.

## The monitors to create

**Kuma's configuration lives in SQLite on its PVC, not in git.** That is the
one part of this repo that is click-configured, so here is the list to
recreate it from. Every monitor: interval 60 s, retries 2.

| Name | Type | URL / setting |
|---|---|---|
| InsiderTrack (prod) | HTTP(s) – Keyword | `https://mgnts-stock-tracker.tail3659a6.ts.net/health`, keyword `"db":true` |
| InsiderTrack data sources (prod) | HTTP(s) – Keyword | same URL, keyword `"status":"ok"` — this one goes red if a scraper starts failing, which is how a rate-limit from sharing the house IP with staging would show up (`docs/OPERATIONS.md`) |
| InsiderTrack MCP (prod) | HTTP(s) – Keyword | `https://mgnts-stock-tracker.tail3659a6.ts.net/mcp/health`, keyword `"status":"ok"` |
| Lecture Notes (prod) | HTTP(s) – Keyword | `https://mgnts-note-app.tail3659a6.ts.net/health`, keyword `"storage":"ok"` |
| InsiderTrack (staging) | HTTP(s) – Keyword | `https://insidertrack-staging.tail3659a6.ts.net/health`, keyword `"db":true` |
| Lecture Notes (staging) | HTTP(s) – Keyword | `https://lecture-notes-staging.tail3659a6.ts.net/health`, keyword `"storage":"ok"` |
| Argo CD | HTTP(s) | `http://argocd-server.argocd.svc/healthz` |
| **InsiderTrack backup age** | **Push** | heartbeat 24 h, grace 12 h |
| **Lecture Notes backup age** | **Push** | heartbeat 24 h, grace 12 h |
| **InsiderTrack restore drill** | **Push** | heartbeat 7 d, grace 1 d |
| **Lecture Notes restore drill** | **Push** | heartbeat 7 d, grace 1 d |

A **keyword** monitor beats a plain HTTP one here: both apps answer `200`
with a body saying `degraded`, so status-code-only checks would call a
half-broken app healthy.

### Wiring the four push monitors

A push monitor is "down" unless something tells it otherwise — which is how
a job that *stopped running* becomes visible, not just one that failed.
Kuma gives each a URL like `http://uptime:3001/api/push/<token>`. Put the
in-cluster form in the chart's staging values and commit:

```yaml
# charts/insidertrack/values-staging.yaml
restore:
  pushUrl: http://uptime-kuma.monitoring.svc:3001/api/push/<drill-token>
monitoring:
  backupAge:
    pushUrl: http://uptime-kuma.monitoring.svc:3001/api/push/<backup-token>
```

Those tokens are in a public repo, and that is fine *while this stays
tailnet-only*: the URL is not reachable from the internet, and the worst a
token does is mark a monitor up. **If Funnel is ever enabled on Kuma, treat
them as secrets** and move them to a SealedSecret.

## Notifications

*Settings → Notifications*. The same Gmail app password the apps use for
mail works for SMTP; put it in Kuma directly (it is stored in its own
database, not in git). Attach the notification to every monitor —
Kuma does not do it retroactively.

## Backing it up

The PVC holds everything: monitors, history, notification settings. It is
not in the nightly bundles, and nothing restores it. Losing it costs the
history and half an hour of clicking — the list above is the recovery plan.
If that stops being acceptable, `kubectl -n monitoring exec deploy/uptime-kuma
-- sqlite3 /app/data/kuma.db .dump` is what a backup of it would look like.
