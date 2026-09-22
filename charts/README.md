# charts/

One Helm chart per project, built in DESIGN.md §8 order:

| Chart | Phase | Source repo | Staging URL |
|---|---|---|---|
| `insidertrack-mcp/` | 2 ✓ | github.com/mrgutierrezmario/insidertrack-mcp | `insidertrack-staging.tail3659a6.ts.net/mcp` |
| `insidertrack/` | 3 ✓ | github.com/mrgutierrezmario/insidertrack | `insidertrack-staging.tail3659a6.ts.net` |
| `lecture-notes/` | 4 ✓ | github.com/mrgutierrezmario/lecture-note-app | `lecture-notes-staging.tail3659a6.ts.net` |

Patterns the three share (read one chart's README for the details):

- **Secrets never in values.** Each chart names the Secrets it expects;
  they are SealedSecrets under `secrets/<chart>/`, a second source of the
  Argo Application.
- **Sync waves:** data services 0 → restore Job 1 → app 2. A restore Job
  runs once per spec change, with no retries, and fails within a deadline
  rather than hanging (a hung Job blocks every later sync).
- **Restore = rclone init container fetches the newest bundle → psql loads
  into `<db>_restore`, scrubs what a copy must not hold, rename-swaps it
  in.** Production's `.env` and Tailscale identity in the bundle are
  deleted unread.
- **Images from GHCR** `:main`, `pullPolicy: Always`, built by each repo's
  CI for amd64 and arm64 (the VM is arm64).

Each chart: `Chart.yaml`, `templates/`, `values.yaml` (defaults that are
true everywhere), `values-staging.yaml` (the `…-staging` hostname, the
restore source, `MAIL_USERNAME` empty). The Argo Application in
`apps/staging/` picks the values file.

The source of truth for what each app needs is its `deploy/compose.yml`;
a chart is that file translated, not reinvented. If a chart seems to need
a change in the app, write it in the chart's README and build around it
first (DESIGN.md §7).
