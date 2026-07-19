# gotify

**Date researched:** 2026-05-25
**Status:** active
**Host:** doc2 (chosen by `gotifyServer = true` in `hosts.nix:164`)

Self-hosted push notification server at https://gotify.ablz.au. Every fleet
host posts here via the `homelab.gotify.endpoint` option — agents (claude
triage), cron jobs (rolling-flake-update), watchdogs (NFS, cratedigger
metadata gate), Home Assistant, Uptime Kuma, etc.
Mobile push delivered via the Gotify Android app.

## Apps

```
id | name
1  | Proxmox
2  | Tower
3  | Domain-Monitor
4  | Uptime-Kuma
5  | KopiaMum
6  | Youtube Playlist
7  | claude          ← alert-bridge + nixos-upgrade-diagnose + rolling-flake-update
8  | HA              ← Home Assistant (garage door, etc.)
```

Reading apps for new sources: see `modules/nixos/services/alert-bridge.nix`,
which centralises the priority→app routing for log-derived alerts.

## Failure-routing policy

As of 2026-07-01, negative/failure notifications should not raw-page the phone
directly. They route to Hermes alert-RCA first so the user gets one diagnosis
with the failing package/service and whether local action is needed. Direct
Gotify is retained only as fallback when Hermes/RCA delivery is unavailable.

Reusable helper: `modules/nixos/lib/negative-alert.nix`.

Success/useful progress notifications may still post direct to Gotify; example:
`gwm-archiver`'s “new issue picked up” notification.

### AirVPN failover and recovery

Grafana's `vpn-gateways` rule group sends sustained pfSense AirVPN state
changes through the existing alert-bridge/Gotify path. Expected firing titles
are `AirVPN USA failed over to Netherlands` and
`AirVPN Netherlands failed over to USA`; Grafana also sends a resolved message
when the preferred path returns. The USA alert notes that its USA-only inbound
qBittorrent/slskd ports are temporarily unavailable. Rules wait three minutes,
so brief packet-loss samples do not page.

## Reading messages (no client token in repo)

The repo only carries the **app token** (`secrets/gotify.env`) for *sending*
messages. There is no client token stored — clients (the phone, web UI) hold
their own. To read messages from an agent session, query the sqlite DB
directly on doc2:

```bash
# Recent pings (last 30h, all apps)
ssh doc2 "sudo sqlite3 /mnt/virtio/gotify/data/gotify.db \
  \"SELECT id, application_id, datetime(date) AS d, priority, substr(title,1,80) \
    FROM messages WHERE date >= datetime('now', '-30 hours') ORDER BY date DESC;\""

# Full text of specific message(s)
ssh doc2 "sudo sqlite3 -line /mnt/virtio/gotify/data/gotify.db \
  \"SELECT name, id FROM applications;\" \"\" \
  \"SELECT id, title, message FROM messages WHERE id IN (2988, 2989);\""
```

**Why sqlite, not the API:** Gotify's `/message` endpoint requires a **client**
token. There is no admin/default credential — admin endpoints (creating
clients, listing apps) require HTTP Basic with the gotify admin user, which
isn't reproduced in this repo (it's set during first-time UI setup). Reading
the on-disk sqlite is the simplest path that doesn't require provisioning a
new client just for triage. If we ever want HTTP-API reads, mint a client
token via the Gotify UI and store it in sops as `gotify/client-token`.

`sqlite3` lives in `/run/current-system/sw/bin/` (always on PATH for sudo).
The DB is at `/mnt/virtio/gotify/data/gotify.db` (Gotify's `WorkingDirectory`),
owned by the `gotify` system user; needs sudo.

## Schema

```
applications  (id, internal, token, name, description, ...)
clients       (id, token, name, lastseen)
messages      (id, application_id, message, title, priority, extras, date)
plugin_confs  (-- unused, plugin system not in use)
users         (id, name, pass, admin)
```

`messages.date` is stored as UTC `YYYY-MM-DD HH:MM:SS`. `priority` follows the
standard Gotify scale — alert-bridge uses 5=warning, 8=critical (this is
visible to the Android client as a per-priority sound/notification class).

## Operational notes

- **DB lives on virtiofs** (`/mnt/virtio/gotify` → ZFS dataset on prom). No
  separate Kopia source needed; the prom-side filesystem is already in the
  fleet backup tree.
- **Retention:** none. Gotify keeps everything forever unless you DELETE
  manually. The DB grew to 438 KB after ~3000 messages — not a problem at
  current rate.
- **Auth state:** admin/initial-client passwords live in
  `/mnt/virtio/gotify/data/gotify.db` (`users` table, bcrypt). They are NOT
  in sops. If lost, recover by stopping the service and `UPDATE users SET
  pass = '<bcrypt>'` directly — there is no in-band reset.
- **TLS:** terminated by the local nginx on doc2 (see
  `modules/nixos/services/gotify-server.nix:48` — `host = "gotify.ablz.au"`).
  ACME via Cloudflare DNS-01. Listens on `:8050` internally.

## Related

- [alert-bridge.nix](../../modules/nixos/services/alert-bridge.nix) — the
  Grafana-alerts → Gotify pipeline (publishes as app `claude`).
- [LGTM stack](lgtm-stack.md) — alert rules live in Grafana, fire here.
- [.claude/skills/triage-overnight/SKILL.md](../../../.claude/skills/triage-overnight/SKILL.md)
  — uses the sqlite query above to audit overnight pings.
