# charts/

One Helm chart per project, built in DESIGN.md §8 order:

| Chart | Phase | Source repo |
|---|---|---|
| `insidertrack-mcp/` | 2 | github.com/mrgutierrezmario/insidertrack-mcp |
| `insidertrack/` | 3 | github.com/mrgutierrezmario/insidertrack |
| `lecture-notes/` | 4 | github.com/mrgutierrezmario/lecture-note-app |

Each chart: `Chart.yaml`, `templates/`, `values.yaml` (defaults that are
true everywhere), `values-staging.yaml` (the `…-staging` hostname, the
restore source, `MAIL_USERNAME` empty). The Argo Application in
`apps/staging/` picks the values file.

The source of truth for what each app needs is its `deploy/compose.yml`;
a chart is that file translated, not reinvented. If a chart seems to need
a change in the app, write it in the chart's README and build around it
first (DESIGN.md §7).
