# Plan: Automated Monitoring Registration (Uptime Kuma)

## Goals (MVP)
- When a stack registers a host via `stackHosts`, also register a Uptime Kuma monitor for that hostname.
- Use the **existing Uptime Kuma /metrics** API-key access (basic auth) for now.
- Only monitor **smokeping** for the MVP (to limit blast radius).
- Ensure changes are **stateful**: avoid re-creating monitors on every rebuild.

## Non-Goals / Later Wishlist
- Alert routing policies, escalation, and notification targets.
- Per-stack alerting overrides (timeouts, retries, maintenance windows).
- Multi-host or multi-zone monitoring.
- Deleting monitors that were created manually or by other systems.

## High-Level Design
- Extend the stack registration pipeline to optionally declare monitoring metadata.
- Add a host-local **monitoring sync** systemd oneshot triggered on rebuild.
- Maintain a local cache of monitors created by this host.
- Use the Kuma API (Socket.IO) for create/update; metrics for read-only checks.

## Proposed Data Model
### Stack declaration (smokeping only for MVP)
Add to smokeping stack:
```nix
monitoring = [
  {
    name = "Smokeping";
    url = "https://ping.ablz.au/smokeping/";
  }
];
```

### Local cache
```
/var/lib/homelab/monitoring/records.json
{
  "https://ping.ablz.au/smokeping/": {
    "name": "Smokeping",
    "url": "https://ping.ablz.au/smokeping/",
    "monitorId": 123
  }
}
```

## Implementation Sketch (Portable)
- Add a small monitoring sync module:
  - `modules/nixos/services/monitoring_sync.nix`
  - Reads desired monitor list.
  - Queries Kuma to check existing monitors.
  - Creates missing monitors.
  - Updates cache and avoids duplicates.
- Ensure nginx supports WebSocket upgrades for `status.ablz.au` (Socket.IO).
- Use `https://status.ablz.au` as the Kuma URL so any host can register.
- For MVP: only smokeping registration to validate the flow.
 - Run Uptime Kuma containers with `network_mode: host` so they can reach LAN IPs (e.g., `ping.ablz.au` → 192.168.1.29).

## API Access
Use the documented skill:
- `.claude/skills/uptime-kuma/SKILL.md`
- Basic auth to `/metrics` currently works.
- For create/update, use Socket.IO with Kuma username/password.

## Testing Plan (Smokeping only)
1) Add monitoring declaration to smokeping stack.
2) Ensure nginx supports WebSocket upgrades for `status.ablz.au`.
3) Rebuild doc1.
4) Verify monitor exists via Uptime Kuma (UI or API).
5) Verify monitor is **UP** via metrics:
```sh
curl -fsS --user ":<API_KEY>" https://status.ablz.au/metrics | rg '^monitor_status' | rg 'Smokeping'
```
6) Rebuild without changes and confirm no duplicate monitors are created.

## Notes / Risks
- Socket.IO requires WebSocket proxying on `status.ablz.au` to work from remote hosts.
- Avoid spamming Kuma by caching created monitor IDs and comparing desired set.
