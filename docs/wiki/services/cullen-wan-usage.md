# Cullen WAN record (usage, throughput, link flaps, latency)

Date: 2026-10-14. Status: durable collectors on doc1 and wsl.

## Purpose

One durable record answering, per Cullen WAN link (Fairtel NBN, Telstra 4G,
Starlink): how much data over months, how much bandwidth at any moment, how that
relates to latency/loss, and when the 2–4 s Ethernet link flaps happen. Queried
on demand by the cullen-assistant agent (`scripts/wan` in that repo). No dashboard
by user direction.

| Piece | Where | What |
|---|---|---|
| `homelab.services.cullenWanUsage` (`cullen-wan-usage.service`) | doc1, system | SNMP every 10 s: sysUpTime + every port's ifName, ifHCIn/OutOctets, ifOperStatus, ifLastChange → `/var/lib/cullen-wan-usage/usage.sqlite`. 03:40 daily: thin rows >35 days to 1/min, copy to `/mnt/data/Life/Tech/Backups/CullenWanUsage/`. Deep probe: sample within 24 h. |
| `homelab.services.cullenWanPing` (`cullen-wan-ping.service`) | wsl (on site), system | 1 s pings to LAN control 192.168.100.14, Fairtel gateway 205.164.127.1, 1.1.1.1, 8.8.8.8, 9.9.9.9, 139.130.4.5 → `/var/lib/cullen-wan-ping/<date>/<target>.tsv` (`epoch\trtt` or `-`), gzipped after the day, 90 days. Unprivileged ICMP sockets. |
| `cullen-wan-hourly` user timer (`hosts/proxmox-vm/cullen-wan-hourly.nix`) | doc1, abl030 user | :07 hourly, runs cullen-assistant `scripts/wan-hourly`: SonicWall event-log export (exact link down/up seconds, DHCP/failover; on-box store holds ~3 h) and TSR switch counters (FCS errors, collisions) via the API → `~/.local/share/cullen-wan/firewall/`; rsync of the wsl ping dir → `~/.local/share/cullen-wan/ping/`. |

## Notes

- ifLastChange catches flaps shorter than the 10 s poll. The TZ 370W's sysUpTime
  ticks coarsely, so derived times are ~15 s early; exact seconds come from the event log.
- Counters are cumulative: gaps (laptop off, Tailscale down) lose resolution, not
  bytes, unless the firewall reboots inside the gap (sysUpTime decrease marks it).
- SQLite uses the rollback journal (not WAL) so read-only consumers work.
- The API pulls log in as `andyAPI-ro` and bump Andy's GUI session from the same
  source IP once an hour.

## Network path and firewall side

doc1 reaches the Cullen LAN only through the Tailscale subnet route advertised by
Andy's laptop; the route SNATs, so the firewall sees doc1 as the laptop. SonicWall
SNMP is read-only v2c on X0 only, source group "Andy laptop" (audit IDs 298–302,
2026-10-14). The community is `secrets/hosts/proxmox-vm/sonicwall-snmp.env`
(`SNMP_COMMUNITY`), via `LoadCredential` and a private `snmp.conf`, never argv.
The ping probes run on wsl because they must leave from the Cullen site; their
route follows Andy's laptop policy routes on the SonicWall.

## Keeping wsl running

The ping collector only runs while the WSL VM runs. The Windows task
`Start-NixOS-WSL` holds it open (`sleep infinity`, re-triggered every 15 min);
see `docs/wiki/infrastructure/wsl-tailscale-ssh.md`. If pings stop, check
`wsl -l -v` on the laptop before suspecting the service.

## Operations

```bash
systemctl status cullen-wan-usage; journalctl -u cullen-wan-usage -n 20
systemctl --user list-timers cullen-wan-hourly; journalctl --user -u cullen-wan-hourly -n 20
ssh wsl systemctl status cullen-wan-ping
sqlite3 -readonly /var/lib/cullen-wan-usage/usage.sqlite 'select count(*), datetime(max(ts),"unixepoch","localtime") from samples'
```

Port-to-service mapping changes over time (Fairtel moved X2→X1 on 2026-10-14 07:44);
the cullen-assistant repo records the history.
