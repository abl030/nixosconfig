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
- Use the Kuma API (or metrics + future API key endpoint) to create/verify monitors.

## Proposed Data Model
### Stack declaration (smokeping only for MVP)
Add to smokeping stack:
```nix
monitoring = [
  {
    name = "Smokeping";
    url = "https://ping.ablz.au";
  }
];
```

### Local cache
```
/var/lib/homelab/monitoring/records.json
{
  "ping.ablz.au": {
    "name": "Smokeping",
    "url": "https://ping.ablz.au",
    "monitorId": 123
  }
}
```

## Implementation Sketch
- Add a small monitoring sync module:
  - `modules/nixos/services/monitoring_sync.nix`
  - Reads desired monitor list.
  - Queries Kuma to check existing monitors.
  - Creates missing monitors.
  - Updates cache and avoids duplicates.
- For MVP: hardcode only smokeping registration to validate the flow.

## API Access
Use the documented skill:
- `.claude/skills/uptime-kuma/SKILL.md`
- Basic auth to `/metrics` currently works.
- If the API key cannot create monitors, fall back to creating via Socket.IO login or add a new API key with create permissions.

## Testing Plan (Smokeping only)
1) Add monitoring declaration to smokeping stack.
2) Rebuild doc1.
3) Verify monitor exists via Uptime Kuma (manual UI check or API).
4) Verify monitor status via metrics:
```sh
curl -fsS --user ":<API_KEY>" https://status.ablz.au/metrics | rg '^monitor_status' | rg 'Smokeping'
```
5) Rebuild without changes and confirm no duplicate monitors are created.

## Notes / Risks
- Current API key appears to be read-only for Socket.IO calls; may need a dedicated key or user login for monitor creation.
- Avoid spamming Kuma by caching created monitor IDs and comparing desired set.
