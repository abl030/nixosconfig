---
name: service-debug
description: Debug a NixOS service that is down, unhealthy, or misbehaving. Identifies which host runs the service, connects via SSH if remote, and investigates using journalctl. Trigger phrases include "debug X", "X is down", "why is X broken", "check X service", "X not working", "investigate X".
version: 1.0.0
---

# Service Debug Skill

Systematic service debugging workflow that handles both local and remote services.

> **Privilege posture varies by host.** doc2 and servarr deliberately grant
> `abl030` full passwordless sudo despite retaining `role = "locked"`; igpu and
> wsl retain only the narrow read-only/container recovery allowlist. Read the
> target host config before assuming. `systemctl status` works without sudo;
> Loki is the default remote log path and is required when journal access is
> unavailable. Deploy config fixes through `fleet-deploy <host>` from doc1.
> See `docs/wiki/infrastructure/fleet-deploy-and-sibling-lockdown.md`.

## Step 1: Identify the service and its host

Parse the user's request to determine the service name. Then find which host runs it:

```bash
# Check all host configs for the service
grep -rl "homelab.services.<name>" hosts/*/configuration.nix
# Or for upstream services
grep -rl "services.<name>" hosts/*/configuration.nix
```

If unclear, search the module for clues:
```bash
grep -l "<service>" modules/nixos/services/*.nix
```

## Step 2: Determine if local or remote

```bash
CURRENT=$(hostname)
# TARGET is the host identified in Step 1
```

- If `CURRENT == TARGET`: debug locally (direct systemctl/journalctl)
- If `CURRENT != TARGET`: use SSH via the host's `sshAlias` from `hosts.nix`

### SSH aliases (from hosts.nix)

| Host       | SSH alias | Address                    |
|------------|-----------|----------------------------|
| proxmox-vm | doc1      | 192.168.1.29               |
| doc2       | doc2      | 192.168.1.35               |
| igpu       | igpu      | 192.168.1.33               |
| servarr    | servarr   | 192.168.1.4                |
| caddy      | cad       | 192.168.1.6                |
| wsl        | wsl       | Windows SSH port-forward   |
| framework  | fra       | dynamic                    |
| epimetheus | epi       | 192.168.1.5                |

## Step 3: Check service status

### Local
```bash
systemctl status <service> --no-pager
systemctl is-active <service>
```

### Remote
```bash
ssh <alias> "systemctl status <service> --no-pager"
ssh <alias> "systemctl is-active <service>"
```

## Step 4: Investigate with journalctl

### Recent logs (start here)
```bash
# Local
journalctl -u <service> --no-pager -n 50

# Remote when the target permits root journal access (doc2/servarr)
ssh <alias> "sudo journalctl -u <service> --no-pager -n 50"

# Otherwise query Loki, e.g. {host="igpu", unit="<service>.service"}
```

### Logs around a specific incident
```bash
journalctl -u <service> --since "2026-04-10 04:00:00" --until "2026-04-10 04:30:00" --no-pager
```

### Follow logs in real-time
```bash
ssh <alias> "journalctl -u <service> -f --no-pager"
```

### Check for rebuild-related stops
```bash
# Find recent switch-to-configuration runs
journalctl --grep "switch-to-configuration" --since "24 hours ago" --no-pager

# Check what was stopped/started during a rebuild
journalctl --since "<time>" --until "<time+5min>" --no-pager _PID=1 --grep "<service>"
```

## Step 5: Common failure patterns

### Cascade-stop orphaning (service dead after rebuild)
Services with `Requires=` on a DB container can be cascade-stopped when the container restarts during `switch-to-configuration`. Check if the service has `restartTriggers`:
```bash
grep "X-Restart-Triggers" /etc/systemd/system/<service>.service
```
If missing, the service needs `restartTriggers` in its module (see `docs/wiki/nixos-service-modules.md`).

**Quick fix:** `sudo systemctl start <service>`

### NFS mount stale
```bash
stat /mnt/data  # Will hang if NFS is stale
systemctl status mnt-data.mount
```

### DB container not running
```bash
systemctl status container@<service>-db
machinectl list
```

### Port conflict
```bash
ss -tlnp | grep :<port>
```

### Secrets not decrypted
```bash
ls -la /run/secrets/<service>/
```

## Step 6: Check infrastructure integration

### Reverse proxy (nginx)
```bash
# Is nginx proxying correctly?
curl -sI https://<service>.ablz.au
# Check nginx config
grep -A5 "<service>.ablz.au" /etc/nginx/nginx.conf
```

### DNS resolution
```bash
dig <service>.ablz.au +short
```

### Uptime Kuma monitor
Use the `/uptime-kuma` skill to check monitor status.

## Step 7: Confirmation round + fleet audit (subagent)

Before presenting your diagnosis, spawn a general-purpose subagent to:
1. **Independently confirm** the root cause from scratch (do NOT include your analysis in the prompt — just the service names, host, timestamp of failure, and how to access logs/files). This catches confirmation bias.
2. **Audit the fleet** for other modules with the same at-risk pattern (e.g. other services using `mk-pg-container`, other `Requires=` on nspawn containers, etc.).

Prompt shape:
- Give the subagent: repo root, affected services + host + failure timestamps, SSH alias, relevant module file paths, the canonical pattern reference (e.g. `immich.nix` comment), and any shared libs (`modules/nixos/lib/mk-pg-container.nix`).
- Ask for: independent diagnosis, at-risk modules table (file + host + current status + risk level), recommended fix pattern.
- Explicitly say: read-only, no fixes, no restarts. Keep report under 400 words.
- Run in background if the investigation will be non-trivial.

Fold the subagent's findings into your final report — especially the fleet audit, which turns a single-service fix into a systemic one.

## Step 7b: Rule audit for modules touched by this debug

Every debug session touches a set of modules. Before closing out, spot-check each one against `docs/wiki/nixos-service-modules.md` — the checklist items in particular. Typical things that silently drift out of compliance over time:

- Missing `homelab.monitoring.monitors` entry (service can die invisibly — this was how the 2026-04-13 discogs-api outage slipped for 28h)
- Missing `homelab.localProxy.hosts` for web-facing services
- Missing `homelab.nfsWatchdog` for NFS-dependent services
- Missing or incorrect `restartTriggers` on long-running services / stateful oneshots that depend on a container (inner container toplevel vs. host-side unit)
- Secrets declared in the wrong place or with wrong ownership

You don't need to fix everything you find — just flag drift in the final report so the user can decide whether to bundle fixes into the same PR or file follow-ups. The point is periodic sampling: every debug session is an opportunity to harden a small piece of the fleet.

## Step 8: Present findings to user

**NEVER fix anything automatically.** Your job is to identify the root cause, trace the code path, and present a clear diagnosis for the user to review.

Report to the user:
1. **Service status** — what state it's in and since when
2. **Root cause** — what caused the failure (with log evidence)
3. **Code path** — which NixOS module/config file is responsible, with file paths and line numbers
4. **Confirmation** — whether the subagent agreed, and any additional findings
5. **Fleet audit** — other modules at risk of the same failure (from subagent)
6. **Rule drift** — any compliance gaps spotted in touched modules (from Step 7b)
7. **Suggested fix** — what change would resolve it (describe, don't apply)
8. **Immediate workaround** — e.g., `sudo systemctl start <service>` if the service just needs a kick

## Notes

- Always run `hostname` before any rebuild command
- Use `journalctl -u <service> --no-pager` (never `-f` in scripts, only for interactive)
- For compose stacks, logs are in user-scoped journal: `journalctl --user -u <stack>`
- Container (nspawn) DB logs: `journalctl -M <service>-db -u postgresql`
