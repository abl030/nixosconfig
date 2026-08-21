# Home Assistant — unattended updates and the backup chain behind them

**Researched / implemented:** 2026-08-21
**Status:** Operational
**Related:** [home-assistant-deploy.md](home-assistant-deploy.md) (SSH + YAML deploy procedure),
[kopia.md](kopia.md) (offsite), [containers-backup-restore.md](../infrastructure/containers-backup-restore.md)
(the sibling pattern this reuses)

Home Assistant now updates itself — Core, OS, add-ons and HACS — without a human.
HA's own docs recommend against unattended Core/OS updates. The reason that advice
exists is that a bad update leaves you with no working system and no recent restore
point. This page documents the net that was built first, so the recommendation no
longer applies to this fleet.

## Topology reminder

HA is **HAOS on prom VM 116** (`192.168.1.20`). It is *not* a NixOS flake host, so
none of the fleet's usual guarantees (signed deploys, `nixos-upgrade`, deep probes)
covered it. That is why it needed its own arrangement.

## What updates itself, and when

| Layer | Mechanism | Schedule | Pre-update backup |
|---|---|---|---|
| Supervisor | Built in, always on (`auto_update: true`) | Supervisor's own | n/a |
| Add-ons (all 7) | Native per-add-on `auto_update` flag | Supervisor's window | yes, per add-on, automatic |
| **Core** | `automation.auto_update_home_assistant_core` | daily 05:00 | yes (`backup: true`) |
| **HAOS** | `automation.auto_update_home_assistant_os` | Sundays 05:30 | yes (`backup: true`) |
| **HACS** items | `automation.auto_update_hacs_integrations_and_cards` | daily 05:45 | no — entities lack the BACKUP feature |
| ESPHome **device firmware** | **deliberately manual** | — | — |

Add-ons that were already on auto-update: SSH terminal, ESPHome Device Builder,
MCP Server, Music Assistant, Tailscale. Mosquitto and File editor were switched on
2026-08-21 so all seven are consistent.

ESPHome *device* firmware stays manual on purpose: a failed OTA to a physical ESP
means walking over with a USB cable. The ESPHome *add-on* auto-updates; the devices
it flashes do not.

### Why 05:00

prom runs a PBS snapshot job (`backup-712b47c2-f5a9`) at 03:00 covering VMs 104,
114 and 116; VM 116's snapshot actually starts around 03:47. Updating at 05:00
means the most recent whole-VM image is always a **pre-update** one.

That job originally ran `prune-backups keep-last=1`, which bought roughly 22 hours:
the *next* night's 03:00 run captured the post-update state and pruned the last good
copy. It was changed to **`keep-daily=7`** on 2026-08-21, so the whole-VM images now
span a weekend too.

Keep an eye on space: the `PBS_Tower` datastore's underlying array was at **87.7%
used (1.84 TiB free)** when that changed. PBS deduplicates, so six extra dailies of
three VMs cost only their changed chunks — but it is not free.

### Why Core holds back `x.y.0`

HA ships `x.y.0` on the first Wednesday of each month, and that is the release
carrying breaking changes; `x.y.1`+ are the fixes. The Core automation has a
condition aliased `hold_zero_release` that refuses to install a version whose patch
component is `0`. Practically you land on `2026.9.1` rather than `2026.9.0`, a week
or so later, without doing anything.

**To go full yolo**, delete that one condition from
`automation.auto_update_home_assistant_core` in `ha/automations.yaml` and redeploy.

## The backup chain

Before this work: HA's automatic backups were **off** (`recurrence: never`), the
only agent was `hassio.local`, there were no network mounts, and the newest full
backup in `/backup` was from **April 2025**. That is the state unattended updates
would have been running into.

Now:

```
HA automatic backup  (daily 02:00, keep 7, database + all add-ons, ~1.1 GB each)
   └─ agent hassio.tower_backups
        → Supervisor NFS mount → tower:/mnt/user/VMBackups/homeassistant
             → kopia-mum on doc2 (source: /mnt/backup/vm-backups/homeassistant)
                  → Mum's Synology over Tailscale        ← the offsite leg
```

Plus, independently: prom's nightly PBS snapshot of the whole VM 116 to
`PBS_Tower` (`keep-daily=7` since 2026-08-21).

### Why the local agent was dropped

`hassio.local` writes into `/backup` on the HA VM's own 30.8 GB disk (14.9 GB free).
At ~1.1 GB per backup, seven copies is ~7.7 GB, leaving too little headroom — and
HA also writes pre-update backups during an update. More to the point, a backup on
the same disk as the thing it protects is not a backup. Tower is separate hardware
and is the leg kopia can reach, so automatic backups go there only.

Pre-update backups (`update.install` with `backup: true`) follow
`default_backup_mount`, which is `tower_backups`, so those land on tower too.

Verified end to end on 2026-08-21: a manually triggered `backup.create_automatic`
produced `automatic_backup_2026_8_2_2026-08-21_10.39_07033336.tar` (1.1 GB) in
`/mnt/user/VMBackups/homeassistant` on tower.

## Monitoring

Two signals, deliberately one in-band and one out-of-band:

- **In-band:** `automation.auto_update_report_versions_after_restart` fires on
  `homeassistant.start`, waits two minutes, and Gotifies the running Core / OS /
  Supervisor versions. Confirms HA came back.
- **Out-of-band:** the `Home Assistant` Uptime Kuma monitor
  (`https://home.ablz.au/manifest.json`), declared in
  `hosts/doc2/configuration.nix` under `homelab.monitoring.monitors`.

The out-of-band one matters because the in-band one cannot fire if HA is the thing
that is down. Before 2026-08-21 **none of Kuma's 59 monitors watched HA at all**.

`/manifest.json` is served by HA itself without auth, so a 200 proves HA's HTTP
stack is up rather than just the caddy edge.

Notifications reuse `notify.gotify_battery` — the REST notify service defined in
`ha/configuration.yaml`. The name is historical (it was added for battery alerts);
it is just a Gotify channel. Worth renaming one day, but renaming breaks every
existing automation that references it.

## Tower NFS export — tightened 2026-08-21

> The full tower export inventory, the Unraid "`/etc/exports` is generated" gotcha,
> and the later retirement of the `appdata` export now live in
> [tower-nfs-exports.md](../infrastructure/tower-nfs-exports.md). This section keeps
> the VMBackups detail because it is what the HA backup chain depends on.

Adding HA as an NFS client prompted an audit of that share. It was exported
`*(rw,sec=sys,insecure,anongid=100,anonuid=99,all_squash)` — **read-write to any
host that could reach tower's NFS** — even though
`hosts/doc2/configuration.nix` and `containers-backup-restore.md` both documented
it as scoped read-only to doc2. The comment had been aspirational.

Who actually reaches `/mnt/user/VMBackups`, established by inspection rather than
assumption:

| Consumer | Path | Transport | Needs the NFS rule? |
|---|---|---|---|
| doc2 kopia-mum | `containers`, `homeassistant` | NFS **ro** from .35 | yes |
| doc1 `containers-backup.service` | `containers` | SSH (root fleet key) | no |
| doc1 `prom-rpool-backup.service` | `prom-rpool` | SSH | no |
| PBS VM (`192.168.1.30`) | `proxmox` | **virtiofs passthrough** | no |
| Unraid-local jobs | `servarr`, `logs` | local | no |
| HAOS (new) | `homeassistant` | NFS **rw** from .20 | yes |

Current rule in `/boot/config/shares/VMBackups.cfg`
(`shareSecurityNFS="private"`, `shareHostListNFS=...`):

```
192.168.1.35(ro,sync,no_subtree_check,insecure,anonuid=99,anongid=100,all_squash)
192.168.1.36(ro,sync,no_subtree_check,insecure,anonuid=99,anongid=100,all_squash)
192.168.1.20(rw,sync,no_subtree_check,insecure,anonuid=99,anongid=100,all_squash)
```

Verified after applying: doc2 still reads the share; doc1 (`192.168.1.29`) is
refused with `reason given by server: No such file or directory`, which is how
NFSv4 denies an unexported path to an unauthorised client.

**Unraid caveat:** `/etc/exports` is generated. Edit
`/boot/config/shares/<Share>.cfg` (`shareSecurityNFS` + `shareHostListNFS`) for
persistence, then mirror the change into `/etc/exports` and `exportfs -ra` to apply
it live. Editing only `/etc/exports` is lost on array restart. Unraid has **no
python3** — use sed/awk in any script you pipe over. Copy the rule syntax from an
already-scoped share (`magazines.cfg` is a good model) rather than inventing it.

## Operating it

```bash
# What is pending right now
python3 - <<'EOF'   # or just look at Settings > System > Updates
EOF
curl -s -H "Authorization: Bearer $HA_TOKEN" http://192.168.1.20:8123/api/states \
  | jq -r '.[] | select(.entity_id|startswith("update.")) | "\(.entity_id) \(.state)"'

# Disable all unattended updating, immediately, without touching YAML:
#   turn off the four automation.auto_update_* entities in the HA UI
#   (Settings > Automations), and clear the add-on auto_update flags.

# Roll back a bad Core update: restore the most recent backup from tower
#   Settings > System > Backups > (tower_backups agent) > restore
```

`ha/automations.yaml` in this repo is the source of truth for the four
automations. Deploy changes with the tar-over-ssh procedure in
[home-assistant-deploy.md](home-assistant-deploy.md), then `automation.reload`.

## Gotchas worth keeping

### 1. The Supervisor API is reachable over the HA **websocket**, not REST

`ha core info` / `ha os info` on HAOS still fail with
`unauthorized: missing or invalid API token` (the long-standing gotcha in
[home-assistant-deploy.md](home-assistant-deploy.md)), and `SUPERVISOR_TOKEN` is
**not** in the SSH add-on's login environment (nor readable from `/proc/1/environ`).
The REST proxy at `/api/hassio/...` returns **401** for a long-lived access token.

What does work, with an ordinary long-lived token, is the websocket command:

```json
{"type": "supervisor/api", "endpoint": "/addons", "method": "get"}
{"type": "supervisor/api", "endpoint": "/mounts", "method": "post",
 "data": {"name": "tower_backups", "usage": "backup", "type": "nfs",
          "server": "192.168.1.2", "path": "/mnt/user/VMBackups/homeassistant",
          "version": "4.2"}}
```

That is how the backup mount and the add-on `auto_update` flags were set here. Any
Supervisor endpoint is reachable this way. Use `websocat` (`nix shell nixpkgs#websocat`);
authenticate with `{"type":"auth","access_token":...}` on connect, then send
commands with incrementing integer `id`s.

### 2. Backup schedule config is websocket-only

`backup/config/info` and `backup/config/update` have no REST equivalent. Do not
hand-edit `/config/.storage/backup` — HA holds it in memory and rewrites it.

```json
{"type": "backup/config/update",
 "create_backup": {"agent_ids": ["hassio.tower_backups"], "include_all_addons": true,
                   "include_database": true},
 "retention": {"copies": 7, "days": null},
 "schedule": {"recurrence": "daily", "time": "02:00:00"}}
```

`automatic_backups_configured` stays `false` until the UI onboarding flow is
completed; it does not gate the schedule. Trust `next_automatic_backup` instead.

### 3. Adding the kopia source needs a deploy outside the maintenance window

The `fleet-deploy doc2` that shipped `/mnt/backup/vm-backups/homeassistant` ran at 11:12 —
straight into kopia-mum's daily full-maintenance window (~10:43, holds the repo **write** lock
for 1–2.5 h). Reads kept working so nothing looked wrong: no failed units, correct revision,
`GET /api/v1/sources` instant. But every write hung, and the new source **did not register**.
`kopia-mum-source-sync.service` has no timer, so it does not retry.

Recovery is `sudo systemctl start kopia-mum-source-sync.service` once
`Finished full maintenance` appears in `journalctl -u kopia-mum.service`. Full detail in
[kopia.md](kopia.md#gotcha-the-daily-full-maintenance-window-blocks-reconciliation-found-2026-08-21).

### 4. `check_config` has a REST endpoint

`POST /api/config/core/check_config` returns
`{"result":"valid","errors":null,"warnings":null}`. This is a better pre-reload gate
than the `homeassistant.check_config` service (which only raises a persistent
notification) and it works where `ha core check` does not.

## Pre-existing issues noticed

All predate this work.

**Resolved 2026-08-21:**

- The four automations sharing the id `start_vm_101_with_epi_on_switch` are gone.
  They all called `proxmoxve.start_vm` against a VM on epi, and the HACS ProxmoxVE
  integration behind them was stuck in `setup_retry` ("Connection is unreachable to
  host 192.168.1.5"). The integration was removed entirely — config entry, HACS
  repo `514096198`, and `/config/custom_components/proxmoxve`.
- tower's `/mnt/user/appdata` export (empty rule → treated as `*`) was retired
  along with every fleet consumer. See
  [tower-nfs-exports.md](../infrastructure/tower-nfs-exports.md).

**Still open:**

- `Epi_On` / `Epi_Off` also depended on ProxmoxVE — they press
  `button.qemu_epimetheus_101_start` / `_shutdown` on the "QEMU epimetheus-vm (101)"
  device it owned. They had already been dead for as long as the integration failed
  to load. They were **left in place** rather than silently deleted, because the
  Zigbee button (`0xa4c1384adb4c272d`) that drove them still exists and the
  "single-press starts epi" capability is probably worth rebuilding — wake-on-LAN
  being the natural replacement.
- `Outside Lights All` and `Outside lights off` still use the legacy
  `trigger:`/`action:` keys rather than `triggers:`/`actions:`.
- tower's `/mnt/user/domains` export is still `*(ro)` — world-readable VM disk
  images, with no NixOS consumer found. See
  [tower-nfs-exports.md](../infrastructure/tower-nfs-exports.md).
