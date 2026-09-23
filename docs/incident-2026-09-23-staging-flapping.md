# Incident: staging VM kept going down and coming back (2026-09-23)

Context for whoever reads this next (a person or Claude). The repo is
`homelab-gitops`: k3s + Argo CD **staging** in a Lima VM (`k3s`) on the Mac
mini. **Production** runs separately in Docker Compose on the Mac and was
**not affected**.

## Symptom

The user reported that the dev environment "keeps dropping and coming back".
Staging URLs, the Argo CD UI and the claude.ai "InsiderTrack staging" MCP
connection went up and down. That MCP connection was failing with a
Cloudflare 502.

## Current state (as of ~18:55 EDT, 2026-09-23)

- **The VM is stopped.** The user chose to leave it stopped for now.
  Nothing was deleted.
- The VM's own config now says **6 CPUs** (it was 4). The restart after that
  change failed, and nobody has looked into why yet (see "Open items").
- While it is stopped, none of these run: the staging apps, Argo CD, Uptime
  Kuma, the weekly restore test CronJob, or the daily backup-age check.
  Nothing will warn if production's 03:00 backups stop.

## Root cause: the VM ran out of CPU

Evidence collected inside the VM at 18:53:

- `nproc` = 4. Load average **63 / 72 / 54**.
- `top`: 50% user, 48% system, **0% idle**. `vmstat` showed 18–22 processes
  waiting for CPU. I/O wait was low (1–4%) and there was plenty of free
  memory (~2.5 GB available, no swap in use), so this was CPU, not disk or
  RAM.
- The k3s datastore (kine/SQLite) logged `Slow SQL` warnings of
  **11–17 seconds** per query.
- The Metrics API was unavailable, because metrics-server itself kept
  failing.
- Pods across every namespace were failing readiness or restarting: coredns,
  metrics-server, sealed-secrets, image-updater, minio, uptime-kuma,
  lecture-notes. Events showed a steady stream of restarts and
  `Synced -> Unknown` / `Healthy -> Progressing` changes in Argo.
- The biggest CPU user was a `uvicorn` process with about 1 GB of memory and
  **22+ minutes of CPU time**. It is *probably* Lecture Notes' Whisper
  transcription. That is an inference and was not confirmed.

Why it fed itself: CPU starvation made liveness and readiness probes and the
kubelet's heartbeats time out. Kubernetes then restarted pods, the restarts
used more CPU, and more probes timed out. The same failure was already seen
earlier that day at 4 vCPUs (NodeNotReady, and Argo's repo-server being
killed by its own liveness probe). See `bootstrap/lima.yaml` and
`docs/OPERATIONS.md`.

## Why the committed fix didn't apply

Commit `7d53e1e` changed `bootstrap/lima.yaml` from `cpus: 4` to `cpus: 6`.
**Lima reads that template only when an instance is created.** An existing
instance runs from its own copy at `~/.lima/k3s/lima.yaml`, and that copy
still said `cpus: 4`. The running VM therefore never got the extra cores.

## What was done

```sh
limactl stop k3s
limactl edit k3s --cpus 6 --tty=false   # updates ~/.lima/k3s/lima.yaml
limactl start k3s --tty=false           # FAILED
```

The start failed with the host agent exiting fatally:

```
tcpproxy: ... error dialing "": Error Domain=VZErrorDomain Code=3
  "Invalid virtual machine state. The virtual machine is no longer live."
fatal msg="exiting, status={Running:false ... Exiting:true ...}"
  (hint: see ~/.lima/k3s/ha.stderr.log)
```

`limactl list` afterwards: `k3s  Stopped  ...  6 CPUs  6GiB  60GiB`.

## Open items

1. **Find out why `limactl start` failed.** Read `~/.lima/k3s/ha.stderr.log`,
   then retry `limactl start k3s`. The `tcpproxy` lines may be leftovers from
   the shutdown rather than the real cause.
2. **Whisper's CPU use.** 6 cores only buys headroom. If transcription can
   still take whole cores, the same failure can come back. Check the
   lecture-notes chart's CPU requests and limits, and whether transcription
   concurrency can be capped.
3. **Pods that were broken apart from the CPU problem** (seen before the
   stop; not investigated):
   - `insidertrack-staging/insidertrack-*`: `CreateContainerConfigError`
     (usually a missing Secret or ConfigMap key)
   - `insidertrack-staging/insidertrack-mcp-*`: `Error`
4. **Monitoring gap while stopped.** The backup-age check and the restore
   test are off, so production backups need to be checked by hand until
   staging is back.
5. **Document the Lima gotcha** in `docs/OPERATIONS.md`: changing
   `bootstrap/lima.yaml` does not change an existing VM. Use
   `limactl edit k3s --cpus N` (or `--memory`) followed by a restart, or
   delete and recreate the VM.
