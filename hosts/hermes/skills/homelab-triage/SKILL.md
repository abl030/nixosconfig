---
name: homelab-triage
description: "Read-only triage of the homelab fleet from Loki logs (no credentials needed)."
version: 1.0.0
platforms: [linux]
triggers:
  - triage overnight
  - what broke overnight
  - what failed last night
  - why is the service broken
  - check host logs
  - homelab triage
  - whats wrong with the homelab
metadata:
  hermes:
    tags: [devops, homelab, loki, logs, triage, observability, readonly]
    related_skills: []
---

# Homelab Triage (read-only, via Loki)

## Overview

Diagnose the homelab fleet by querying the open Loki log API. This is a
**READ-ONLY** skill: it never deploys, edits, pushes, or SSHes into hosts — it
reads logs and summarises. **No credentials are required**: Loki at
`https://loki.ablz.au` is reachable directly from this container with no auth.

Use it for "what broke overnight", "why is <service> down", "check <host>", and
the morning triage ritual.

## Tools

- `curl` for HTTP, `python3` for JSON parsing. **Note: `jq` is NOT installed**
  in this container — parse JSON with `python3`.

## Loki endpoints

- Range query (main one):
  `GET https://loki.ablz.au/loki/api/v1/query_range`
  params: `query=<LogQL>`, `start=<RFC3339|ns>`, `end=<RFC3339|ns>`, `limit=<n>`
- Discover labels:
  `GET https://loki.ablz.au/loki/api/v1/label/host/values`
  `GET https://loki.ablz.au/loki/api/v1/label/unit/values`

Always fetch with `curl -G --data-urlencode` so LogQL is encoded for you:

```sh
curl -sG https://loki.ablz.au/loki/api/v1/query_range \
  --data-urlencode 'query={unit="rolling-flake-update.service", host="proxmox-vm"}' \
  --data-urlencode 'start=2026-06-13T14:00:00Z' \
  --data-urlencode 'limit=300' \
| python3 -c 'import sys,json
for s in json.load(sys.stdin)["data"]["result"]:
    for ts,line in s["values"]: print(line)'
```

## Fleet map (host label → machine)

- `proxmox-vm` = **doc1** (the bastion; runs `rolling-flake-update.service`
  nightly at 23:00 AWST / 15:00 UTC)
- `doc2` = main services VM (immich, cratedigger, paperless, slskd, mealie, …)
- `igpu` = media transcoding VM
- `hermes` = this agent's own VM
- `framework`, `epimetheus`, `wsl`, `cache` = other NixOS hosts
- `tower` = Unraid NAS · `pfsense` = firewall (syslog) · `prom` = hypervisor (alloy)

Container logs use the `container` label, e.g.
`{host="doc2", container="immich-server"}`. Systemd units use `unit`, e.g.
`{host="doc2", unit="cratedigger-importer.service"}`.

## Time handling

- Loki wants RFC3339 (`2026-06-14T04:00:00Z`) or a nanosecond epoch.
- The fleet is **AWST = UTC+8**. "Overnight" = last night local; convert to a UTC
  `start` (e.g. yesterday 22:00 AWST = yesterday **14:00 UTC**).
- Default range is 1h — always pass an explicit `start` for longer windows.

## LogQL recipes

- Overnight auto-update diagnoses (doc1, includes any `claude -p` failure notes):
  `{unit="rolling-flake-update.service", host="proxmox-vm"}`
  `{unit="nixos-upgrade.service"}`
- Errors on a host in a window:
  `{host="doc2"} |~ "(?i)error|fail|panic|fatal|traceback"`
- A specific service / cratedigger:
  `{host="doc2", unit=~"cratedigger.*"}`
  `{host="doc2", container="immich-server"} |~ "(?i)error"`
- Restart / boot churn:
  `{host="igpu"} |~ "(?i)started|stopped|failed"`

## Workflow

1. **Clarify scope**: which host/service, and what time window (default: last
   night AWST). If unsure what exists, hit `label/host/values` and
   `label/unit/values` first.
2. **Build LogQL**, fetch via `curl -G --data-urlencode` with explicit
   `start`/`end`/`limit`.
3. **Parse** the JSON with `python3` (jq absent): the log lines are at
   `data.result[].values[][1]`.
4. **Summarise**: what failed, the smoking-gun line(s), which host/unit, and a
   concrete next step. Quote real log lines as evidence. **Do NOT guess** — if
   the logs don't show it, say so and report the window you checked.

## Guardrails

- **READ-ONLY.** Never run deploys, file edits, `git push`, or host SSH from this
  skill. You have no credentials for them here, and that is by design.
- If the fix needs a deploy or repo change, **hand it off**: state the proposed
  change clearly and note it requires the operator (TUI) session launched from
  the doc1 bastion — do not attempt it here.
