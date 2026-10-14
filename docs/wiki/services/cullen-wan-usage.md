# Cullen WAN usage counters

Date: 2026-10-14. Status: managed per-minute SNMP collector on doc1.

## Purpose

Monthly/daily usage per Cullen WAN link (Fairtel NBN, Telstra 4G, Starlink) and
per port, queried on demand by the cullen-assistant agent (`scripts/wan-usage`
in that repo). No dashboard by user direction.

## How it works

`homelab.services.cullenWanUsage` on doc1 (`proxmox-vm`):

- `cullen-wan-usage.timer` (minutely) runs one SNMP v2c GET against the SonicWall
  TZ 370W at `192.168.100.14`: `sysUpTime` plus, for ifIndex 1–10 (X0…X7, W0, U0),
  `ifName`, `ifHCInOctets`, `ifHCOutOctets` and `ifOperStatus`. One row per port
  into `/var/lib/cullen-wan-usage/usage.sqlite` (table `samples`).
- Daily 03:40 copy to `/mnt/data/Life/Tech/Backups/CullenWanUsage/usage.sqlite`
  (SQLite backup API, atomic replace; no network in that unit).
- Deep probe "Cullen WAN usage collection" fails if no sample in 24 h.

Raw counters only. Consumers sum positive deltas per port; a `uptime_cs` decrease
marks a firewall reboot (counter reset to zero, so the post-reboot value is the
delta). Gaps (Andy's laptop off, Tailscale down) lose time resolution but not bytes,
because the next sample's cumulative delta still includes them, unless the
firewall rebooted during the gap. Attribution across a gap spanning a month
boundary goes to the later sample.

## Network path and firewall side

doc1 reaches the Cullen LAN only through the Tailscale subnet route advertised by
Andy's laptop (see cullen-assistant `knowledge/systems/network.md`). The route
SNATs, so the firewall sees doc1 as the laptop. SonicWall SNMP is read-only v2c,
answered on X0 only, source restricted to the address group "Andy laptop" (audit
IDs 298–302, 2026-10-14). The community is
`secrets/hosts/proxmox-vm/sonicwall-snmp.env` (`SNMP_COMMUNITY`), passed via
`LoadCredential` and handed to net-snmp through a private `snmp.conf`
(`SNMPCONFPATH`), never argv.

## Operations

```bash
systemctl list-timers 'cullen-wan-usage*'
journalctl -u cullen-wan-usage -n 20
sqlite3 -readonly /var/lib/cullen-wan-usage/usage.sqlite 'select count(*), datetime(max(ts),"unixepoch","localtime") from samples'
```

Port-to-service mapping changes over time (Fairtel moved X2→X1 on 2026-10-14 07:44);
the cullen-assistant repo records the history.
