# Metadata mirrors on dedicated Proxmox LXCs

**Status:** canary deployed 2026-07-28; doc2 retained as a frozen rollback source
**Issue:** Forgejo #53
**Owners:** `hosts/musicbrainz/configuration-lxc.nix`, `hosts/discogs/configuration-lxc.nix`

This is the reference architecture and operating runbook for moving the MusicBrainz and Discogs mirrors out of `doc2` into separate unprivileged NixOS LXCs. The split gives each mirror an independent database, storage, resource ceiling, restart boundary, and rollback path. PostgreSQL runs natively in each outer LXC; nesting another nspawn database inside a dedicated service guest would add namespaces and I/O overhead without adding a useful ownership boundary.

## Topology

| Workload | Proxmox CT | LAN address | CPU | RAM | Swap | Application plane |
|---|---:|---|---:|---:|---:|---|
| MusicBrainz + LRCLIB | 100 | `192.168.1.43` | 8 | 24 GiB | 4 GiB | native PostgreSQL + rootful Podman |
| Discogs | 102 | `192.168.1.44` | 4 | 8 GiB | 2 GiB | native PostgreSQL + native Rust API |

Both CTs are unprivileged, start with Proxmox, and use static addressing inside NixOS. Their Proxmox veth definitions may say `ip=dhcp`; `proxmoxLXC.manageNetwork = true` means the guest's declarative NixOS network configuration is authoritative.

DNS:

- `musicbrainz.local.com -> 192.168.1.43`
- `discogs.local.com -> 192.168.1.44`
- `discogs.ablz.au` is published by the Discogs guest's local proxy.

The live pfSense audit on 2026-07-28 found no DHCP static mappings for `.43`
or `.44`. This is intentional: both guests configure static addresses, and the
LAN dynamic pool is `.100` through `.200`, so neither address can be leased.
Unbound host overrides provide the canonical names above.

## Credential scope

The service LXCs opt out of fleet private-flake/GitHub credentials, Atuin sync,
and Gotify. Their age identities are not recipients for `nix-netrc`,
`atuin-key`, `atuin-session`, or `gotify.env`.

Each guest receives only its host-scoped database/application files plus the
credentials required by an enabled role:

- both retain only the root-owned Uptime Kuma synchronization credential because
  their rendered monitoring sync owns HTTP monitors and MusicBrainz replication
  freshness push state; the operator-facing metrics API key is not deployed;
- Discogs retains the Cloudflare DNS credential because it terminates
  `discogs.ablz.au` with ACME DNS-01 locally;
- MusicBrainz receives no ACME credential.

The remote Discogs importer uses a dedicated `discogs-import-coordinator`
principal, restricted to doc2's source address and host key, one forced command,
and one exact sudo rule. Normal fleet/operator keys cannot invoke that rule.

Consumers use direct LAN endpoints where metadata availability is a correctness gate:

- MusicBrainz: `http://192.168.1.43:5200`
- LRCLIB: `http://192.168.1.43:3300/api`
- Discogs gate: `http://192.168.1.44:8086`

The direct endpoints deliberately avoid making Cratedigger's gate depend on Cloudflare, ACME, or nginx. Browser/Beets Discogs traffic may continue to use `https://discogs.ablz.au`.

## Persistent storage

Data lives on dedicated `nvmeprom/metadata-mirrors` ZFS children on `prom` and is bind-mounted into the unprivileged guests. Host ownership therefore uses the normal `100000` UID/GID shift. Service UIDs must remain stable before recursively changing ownership.

### MusicBrainz

| Host dataset/path | Guest mount | Purpose | ZFS recordsize |
|---|---|---|---:|
| `nvmeprom/metadata-mirrors/musicbrainz/postgres` | `/var/lib/musicbrainz-postgresql` | PostgreSQL 18 | 16K |
| `.../musicbrainz/solrdata` | `/var/lib/musicbrainz-mirrors/solrdata` | Solr index | 32K |
| `.../musicbrainz/lrclib` | `/var/lib/musicbrainz-mirrors/lrclib` | LRCLIB SQLite/data | 4K |
| `.../musicbrainz/state` | `/var/lib/musicbrainz` | service state | 8K |
| `.../musicbrainz/dbdump` | `/var/lib/musicbrainz-mirrors/dbdump` | transient DB transfer | 1M |
| `.../musicbrainz/solrdump` | `/var/lib/musicbrainz-mirrors/solrdump` | transient Solr transfer | 1M |

`/var/lib/containers` is a separate ext4 Proxmox volume because Podman overlay storage on ZFS is not reliable enough for this workload.

### Discogs

| Host dataset/path | Guest mount | Purpose | ZFS recordsize |
|---|---|---|---:|
| `nvmeprom/metadata-mirrors/discogs/postgres` | `/var/lib/discogs-postgresql` | PostgreSQL | 16K |
| `.../discogs/dumps` | `/var/lib/discogs-mirror/dumps` | monthly XML dumps | 1M |

Changing `recordsize` affects newly written blocks only. It does not rewrite populated database blocks; rewriting requires a deliberate dump/restore or dataset send/receive migration and is not part of this canary.

Both guest configurations install a mount-verification oneshot that must pass before PostgreSQL or an importer starts. It checks exact mount targets rather than accepting a parent filesystem, preventing accidental initialization into the LXC root disk.

The bind mounts use `backup=0`, so a Proxmox `vzdump` of either LXC rootfs does
not protect mirror data. The `@issue53-cutover-20260728` snapshots protect both
PostgreSQL datasets during the canary, and the intact doc2 source remains the
operational rollback. Establish recurring ZFS snapshot/replication before
retiring doc2; a reproducible guest rootfs is not a database backup.

## Native PostgreSQL mode

`modules/nixos/lib/mk-pg-container.nix` supports two modes from one policy implementation:

- `native = false`: the established nspawn layout used on multi-service hosts.
- `native = true`: PostgreSQL runs directly in a dedicated LXC.

Native mode reuses the same database/user setup, SCRAM password handling, ownership invariants, extension setup, and PostgreSQL audit policy. Versioned data paths remain under `<databaseDir>/postgres/<major>`.

MusicBrainz's Podman application reaches PostgreSQL via `host.containers.internal`. The firewall opens TCP 5432 only from `podman+` interfaces; it is not open on `eth0`. The NixOS fleet currently uses the iptables firewall backend, so this is an `extraCommands` rule rather than an nftables-only `extraInputRules` declaration.

Upstream MusicBrainz image references are qualified in an immutable build-context copy. Do not enable unqualified registry search: registry resolution remains fail closed.

## Discogs import coordination

A Discogs import drops and recreates tables, so it may never race Cratedigger. The safety policy remains owned by Cratedigger on doc2 even though the importer now runs in CT 102:

1. `discogs-import.timer` retains the historical schedule on doc2 and fires on
   day 2 at 04:00. Reusing the unit name preserves systemd's Persistent timer
   stamp, avoiding an unintended immediate import on first cutover activation.
2. The coordinator enters the durable `discogs-import` metadata hold, stopping Cratedigger producers.
3. doc2 authenticates to CT 102 with its machine key. CT 102 accepts that key only with OpenSSH `restrict` and a forced command; it cannot create a shell or invoke another operation.
4. The forced command starts `discogs-import.service` through one exact passwordless sudo rule.
5. doc2 retries up to four times with 15-minute spacing.
6. A failure leaves the hold in place. Success still requires both representative metadata probes to pass before the coordinator releases the hold and resumes Cratedigger.

The guest's own `discogs-import.timer` and service-level automatic restart are disabled in remote-coordinator mode. This prevents an uncoordinated local timer or delayed restart from bypassing the metadata hold.

## Migration and rollback procedure

1. Enter `musicbrainz-maintenance` on doc2 and stop the source import/replication timers.
2. Stop source writers, perform a final numeric-ID-preserving synchronization into the target datasets, and record source values before reopening rollback services.
3. Activate the target closures and verify exact dataset mounts before allowing PostgreSQL to initialize.
4. Compare source and target database state while source timers remain frozen.
5. Verify direct APIs and representative identities.
6. Restart the source database/API units so doc2 is immediately usable for rollback, but leave source replication/import timers stopped to prevent drift during the canary.
7. Change consumers only after target service, API, data, restart, and rollback checks pass.
8. Keep doc2 data and units intact until the canary period is accepted. Do not destroy, merge, or repurpose the source datasets.

Rollback before source retirement:

1. Enter `musicbrainz-maintenance` or `discogs-import` as appropriate.
2. Select the immediately preceding doc2 NixOS generation that still contains
   the source MusicBrainz and Discogs modules, then run that generation's
   `switch-to-configuration switch`. The cutover closure deliberately removes
   those units, so `systemctl start` alone is not a rollback.
3. Confirm that the restored generation points consumers at doc2
   (`192.168.1.35:5200` and local Discogs port `8086`).
4. Stop target writers.
5. Start the restored source database/API units. Re-enable source timers only
   after choosing to abandon the canary rather than merely rehearsing rollback.
6. Run representative probes and release the hold only after both providers pass.

## Canary verification record

The final pre-reboot source/target comparison on 2026-07-28 was exact:

| Database | Measurement | doc2 source | LXC target |
|---|---|---:|---:|
| MusicBrainz | artists | 2,944,405 | 2,944,405 |
| MusicBrainz | releases | 5,664,379 | 5,664,379 |
| MusicBrainz | replication sequence | 187,790 | 187,790 |
| MusicBrainz | last replication UTC | `2026-07-27 16:00:45.582471+00` | same |
| Discogs | artists | 10,121,640 | 10,121,640 |
| Discogs | releases | 19,267,094 | 19,267,094 |
| Discogs | masters | 2,570,491 | 2,570,491 |
| Discogs | labels | 2,394,751 | 2,394,751 |

Representative API identities:

- MusicBrainz `/ws/2/release/?query=artist:Radiohead AND release:"OK Computer"` returned 38 results with `OK Computer` first.
- Discogs `/api/releases/83182` is the stable OK Computer release probe.
- LRCLIB port 3300 returned JSON.

Representative warm-query timings on 2026-07-28 (`n=20`) showed no canary
regression:

- MusicBrainz source: p50 14.6 ms, p95 17.9 ms; target: p50 14.2 ms,
  p95 31.8 ms. Both returned the same 32,763-byte response.
- Discogs source over its local loopback: p50 2.2 ms, p95 2.5 ms; target over
  the LAN: p50 0.9 ms, p95 1.2 ms.

These are smoke-test timings rather than capacity benchmarks. Their purpose is
to reject a gross migration regression while the exact row-count and response
identity checks establish correctness.

### Required clean-restart checks

Run after deploying the exact reviewed closures:

```sh
pct reboot 100
pct reboot 102
pct exec 100 -- systemctl --failed
pct exec 102 -- systemctl --failed
curl -fsS 'http://192.168.1.43:5200/ws/2/release/?query=artist%3ARadiohead%20AND%20release%3A%22OK%20Computer%22&fmt=json'
curl -fsS http://192.168.1.44:8086/health
curl -fsS http://192.168.1.44:8086/api/releases/83182
```

Also verify:

- PostgreSQL is not listening on either guest's LAN interface except where explicitly intended; MusicBrainz TCP 5432 is reachable from its Podman bridge only.
- `discogs-import.timer` is disabled on CT 102 and active as the remote
  coordinator on doc2.
- source APIs on doc2 still pass with source replication/import timers deliberately stopped.
- ACME certificates are Let's Encrypt rather than the bootstrap minica certificate.
- Loki logs and node/process metrics identify the new host names.
