# insidertrack-mcp

The [InsiderTrack MCP server](https://github.com/mrgutierrezmario/insidertrack-mcp):
one Deployment, one Service, one Tailscale Ingress. No state — every answer
comes from the InsiderTrack instance at `insidertrackUrl`.

| Value | Staging | Notes |
|---|---|---|
| `insidertrackUrl` | production's public URL | phase 3 points it at the staging copy (`http://insidertrack:8003`) |
| `mountPath` | `/mcp` | drives the Ingress path, `MCP_PATH` and the probes together |
| `tokensSecret` | `mcp-tokens` | a SealedSecret in `secrets/insidertrack-mcp/`, key `MCP_TOKENS` |
| `ingress.host` | `insidertrack-mcp-staging` | → `https://insidertrack-mcp-staging.tail3659a6.ts.net/mcp` |
| `ingress.funnel` | `true` | claude.ai has to reach it |

## Path prefix (DESIGN.md §9 Q2)

`tailscale serve` strips its mount path, which is why production's MCP
listens at `/`. A Kubernetes Ingress does not: the operator's proxy passes
`/mcp/...` through unchanged, so here `MCP_PATH=/mcp` and health is at
`/mcp/health`. Verified on the first deploy (2026-09-21): `/mcp/health`
200, `/health` 404.

## Gotcha: runAsNonRoot needs a number

The image's `USER mcp` is a name. With `runAsNonRoot: true` alone the
kubelet refuses to start it (`CreateContainerConfigError`: cannot verify a
non-numeric user). The chart pins `runAsUser: 999`, the uid `useradd
--system` gave `mcp`. If the Dockerfile ever changes the user, change both.

## Token rotation

Re-seal `mcp-tokens` (see `secrets/README.md`), commit. The Secret changes
in place but the pod's env does not: `kubectl -n insidertrack-staging
rollout restart deploy/insidertrack-mcp`.

## Compared with production's Compose service

Same image, same env names. Differences: `INSIDERTRACK_URL` is a full URL
instead of `http://tailscale:8003`; `MCP_PATH` is `/mcp` for the reason
above; the token secret is a Kubernetes Secret instead of `deploy/.env`.
