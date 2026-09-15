# Winery hot-water history archive

Date: 2026-09-15. Status: managed hourly archive on doc1.

## Purpose and scope

Keep fine-grained hot-water usage and matching PV/grid power beyond Home
Assistant Recorder's approximately ten-day raw-history window. Hourly
long-term statistics exist back to July 2026 for the water meter, but cannot
reconstruct brief draws or the duration of a maximum. Model inlet/outlet
temperatures remain assumptions by user direction; no probes or temperature
configuration changes are part of this service.

Managed by `homelab.services.wineryHistory` on doc1 (`proxmox-vm`):

- `sensor.indoor_water_meter_total_water_litres` — cumulative litres.
- `sensor.indoor_water_meter_flow_rate` — L/min.
- `sensor.sa_generation_power` — PV generation in W.
- `sensor.sa_import_export_power` — net grid W, negative for export.

No resampling, clipping, integration or gap-filling occurs in the archive.
HA state strings, original returned timestamps, attributes and unavailable
states are retained. A cumulative counter decrease remains present as a reset;
consumers must not interpret it as negative consumption. Source outages may
prevent measurement even when counters are unchanged across the outage.

## Storage and collection

- Local: `/var/lib/winery-history` on doc1's local block filesystem.
- Backup: `/mnt/data/Life/Tech/Backups/WineryHotWater` on tower.
- Existing Kopia `/mnt/data/Life` sources cover that backup directory in both
  the Wasabi/photos and Mum/Synology repositories. No new backup credentials
  or source registration is required. The normal offsite snapshots run daily.
- Archive files have no automatic expiry: retain at least a complete vintage
  and seasonal cycle. They remain small compressed JSON chunks; reassess space
  after a year rather than silently pruning observations.

`winery-history.timer` runs hourly at :15, with up to two minutes jitter.
Both collection and backup also run at boot/first activation, ordered before
the freshness probe. The first deployment demonstrated why: an immediate probe
correctly failed before the initial archive existed; explicit startup ordering
prevents that commissioning race.
The collector archives through the previous committed hour, leaving at least
five minutes for Recorder writes. First run retrieves ten days in bounded
one-day requests; subsequent runs catch up from the last durable cursor.
Requests overlap by five minutes around boundaries.

Each `chunks/<start>-<end>.json.gz` stores schema version, requested interval,
query start, source, collection timestamp, per-entity counts/unavailable counts
and the untouched history response. Files are written through a same-directory
temporary file, fsynced and atomically renamed. The capture checkpoint advances
only after a validated chunk exists. Interrupted checkpoint writes can resume
from that immutable chunk. A failed/missing-entity response never advances it.

The requested interval is **not proof of complete source coverage**. In
particular, initial backfill can begin before retained data for a given entity.
If collection is down longer than its ten-day recovery window, a `gaps/` record
and alert identify the unrecovered interval; collection then resumes. Older
hourly statistics or backups may still help reconstruct coarse consumption.

## Replay contract

Use `last_updated` to order events; attribute-only changes can share a
`last_changed` value. These are HA receipt timestamps, not necessarily meter
measurement times (Solar Analytics also carries its own `time_stamp` attribute).
The REST history API does not return original `last_reported` or context.
Read chunks in timestamp order. Retain the first state of a series as a
boundary/baseline observation: HA can synthesize its timestamp at query start.
Do not count that first state as a new water pulse. Use the actual subsequent
counter transitions, prefer real observations over synthetic boundary points,
deduplicate overlapping records by entity and returned
timestamp/state/attributes, and establish the counter baseline before deriving
litres. Do not sum snapshot values or count duplicate boundary observations.
For gaps, keep availability and the uncertainty about timing explicitly.

The four source entities are deliberately fixed in the script. A future rename
or exclusion fails collection visibly and requires updating this contract;
the archive must not quietly drop a series.

`bootstrap/` contains the separately labelled original modelling extract and
older hourly statistics saved during initial setup. Hourly aggregates remain
distinct from raw history; they cannot restore within-hour timing.

## Independent backup and health

Successful collection starts `winery-history-backup.service`. An independent
hourly :35 timer retries the copy even if no new collection succeeded. It copies
immutable chunks without deletions, compares checksums/read-back and writes a
separate backup checkpoint. A stalled NFS copy cannot block the local collector.
Files in the Life copy are 0644 and directories 0755 so the unprivileged Kopia
LXC can read them; the contents are sensor records, never credentials.

The `Winery history archive and backup` deep probe checks both progress cursors
are within four hours, validates the latest compressed chunk and its SHA-256,
and sends its result through the normal Kuma machinery. Capture, backup and
recovery-gap errors have explicit Loki alert fingerprints. Offsite repository
health remains covered by the existing Kopia freshness/error probes.

## Identity and least privilege

HA account `winery_history_archive`, user ID
`066f20663ed9440e8ec9f6d7dc6fd84b`, is local-only in `system-read-only`.
History GET succeeded for all four entities through `https://home.ablz.au`;
admin-only `config/auth/list` was rejected. The temporary login refresh token
was revoked; one archive long-lived token remains, expiring 2036-09-15.

`secrets/hosts/proxmox-vm/winery-history.env` is encrypted for doc1 plus the
editor and break-glass recipients. SOPS installs it root-readable, and systemd
passes a private copy via `LoadCredential`. No token appears in arguments, logs
or the Nix store. The supported HA read-only role can read other entity states;
it cannot control them or administer HA. The collector itself only queries the
four named entities.

Both units run as the dedicated unprivileged `winery-history` Unix user, with
no capabilities, strict filesystem protection, private devices/tmp and hidden
home directories and `/mnt`. Only the backup unit sees its exact NFS directory;
it receives no HA token and has a private network namespace. HTTPS validates
the server certificate; redirects are refused to avoid forwarding credentials.
Neither service opens a listening socket or changes firewall rules.

## Operations and recovery

```sh
systemctl status winery-history.timer winery-history-backup.timer
sudo systemctl start winery-history.service
sudo systemctl start winery-history-backup.service
sudo cat /var/lib/winery-history/capture.json
sudo cat /var/lib/winery-history/backup.json
journalctl -u winery-history.service -u winery-history-backup.service -n 50
```

To restore, stop both timers and services, recover the immutable chunks and
`capture.json` from tower or a Kopia snapshot into the local data directory,
restore ownership to `winery-history:winery-history`, then run the collector
and backup before re-enabling the timers. It recovers data newer than the saved
cursor while still available in HA. `backup.json` is regenerated after copying.

Rollback stops ingestion without deleting historical data:

```sh
sudo systemctl stop winery-history.timer winery-history-backup.timer
sudo systemctl stop winery-history.service winery-history-backup.service
```

For permanent removal, disable `homelab.services.wineryHistory`, land and deploy
that change, then revoke the dedicated HA token/account. Preserve both archive
copies. Do not roll the whole fleet back to an older revision for this service.

Validation: `python3 -m unittest discover -s scripts -p test_winery_history.py`;
the same behaviour tests are included in `nix flake check`. They cover exact
state preservation, outage/reset observations, idempotency, interrupted writes,
missing entities, backup corruption, independent collection and recovery gaps.

Initial live verification (2026-09-15): ten chunks held 59,726 returned history
records through 13:00 AWST. Both sandboxed services completed successfully;
the archive/backup probe delivered a successful heartbeat. The saved modelling
extract and older hourly statistics were copied into `bootstrap/`. Wasabi
snapshot `83a5c84223eeb3344f1ab24ddab0a376` included the new archive; recovering
its latest gzip chunk produced SHA-256
`e0b8739a4cc7d042d5a1f621b1e6076e61159906cf02bb57e6299ebe59c8ebd5`, matching
the capture checkpoint. The normal offsite source schedules remain at 06:00.
