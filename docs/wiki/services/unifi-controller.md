# UniFi Network Controller (on doc2)

**Date:** 2026-08-12 · **Status:** ⚠️ external-MongoDB migration merged but **NOT yet cut
over** — see [External MongoDB container](#external-mongodb-container-142) ·
**Module:** `modules/nixos/services/unifi-controller.nix` · **Issue:** forgejo #142

The UniFi Network controller (v10.5.54) runs on **doc2** as a standard
`homelab.localProxy` service module. It was **migrated off the caddy LXC** (CT 108,
`192.168.1.6`) on 2026-07-02/03 because that placement violated the module rules three
ways: hand-rolled `services.caddy` reverse proxy, `openFirewall` 0.0.0.0 bind, and state
stranded on the LXC's **unbacked-up root disk** (`/var/lib/unifi`, not `/mnt/virtio`).

- **UI:** `https://unifi.ablz.au` → doc2 nginx (localProxy, `https`+`insecureSkipVerify`) → controller `:8443`.
- **State:** `/mnt/virtio/unifi` (portable, backed up), bind-mounted over `/var/lib/unifi`.
- **MongoDB:** a dedicated, digest-pinned **official MongoDB 7 container**
  (`docker.io/library/mongo`, 7.0.40), loopback-only on `127.0.0.1:27117`, with its
  dbpath at `/mnt/virtio/unifi-mongodb`. The controller itself stays native NixOS.
  Nothing in the fleet builds MongoDB from source any more.
- **msn-history-viewer** moved in the same migration → a hardened `static-web-server`
  sandbox on doc2 (`msn.ablz.au`). See its module; it's a stateless static site.
- **caddy LXC** now runs the *legacy-edge* Caddy for appliance FQDNs only (apollo, plex,
  pihole, cockpit, brother, …) — `modules/nixos/services/legacy-edge-caddy.nix`.

## Gotcha 1 — UniFi CSRF/Origin check: nginx MUST send `Host: $host` (the login bug)

The symptom that kicked off the migration: **"Login error — There was an error making
that request. Please try again later."** UniFi 8.x+/10.x enforces a **CSRF/same-origin
check**: it rejects any POST whose `Origin` header host ≠ the **`Host` header the
controller receives** → HTTP **403** (which the UI surfaces as that generic error, NOT
"invalid credentials").

The old hand-rolled Caddy config (`reverse_proxy https://127.0.0.1:8443`) forwarded
`Host: 127.0.0.1:8443` upstream, so the browser's `Origin: https://unifi.ablz.au` never
matched → 403 on every login. Proven directly on `:8443`:

| Host the controller receives | Origin sent | Result |
|---|---|---|
| `unifi.ablz.au` | `unifi.ablz.au` | **400** (match → login processed) |
| `unifi.ablz.au` | `127.0.0.1:8443` | **403** (mismatch) |

**Fix (free on the nginx path):** `homelab.nginx` sets `recommendedProxySettings = true`,
which emits `proxy_set_header Host $host;`. So localProxy → the controller sees
`Host: unifi.ablz.au` = the browser Origin → login works. This is *why* the module-way
(localProxy/nginx) is the fix and the bespoke Caddy proxy was the bug. localProxy gained
additive `https`/`insecureSkipVerify` options to proxy UniFi's self-signed `:8443`.

## Gotcha 2 — UniFi needs port 8080 (device inform); it silently exits if it's taken

UniFi binds **8080** for device inform (fixed by the AP/switch protocol — changing it
means re-provisioning every device). On doc2, **netboot's asset server owned host :8080**,
so the controller **pre-flight-checked its ports, found 8080 taken, and exited cleanly
(status 0) BEFORE launching mongod** — the launcher just logged "Initiating startup" and
died in a restart loop, with **no error and no `mongod.log`**. Extremely easy to
misdiagnose as a data/bind-mount problem (it isn't).

**Fix:** `netboot.assetsPort = 8070` on doc2 (netboot.nix already documented this intent).
netboot's web UI (localProxy → `webPort` 3005) and TFTP are unaffected; only the direct
asset HTTP host port moved. **When adding any service to doc2, check it doesn't want 8080.**

## Gotcha 3 — relocating UniFi state (StateDirectory + namespace BindPaths)

`services.unifi` hard-codes `/var/lib/unifi` via `StateDirectory=unifi`, and the unit sets
up its runtime dirs as **namespace `BindPaths`**: `logs`→`/var/log/unifi`,
`run`→`/run/unifi`, `bin`/`lib`/`dl`/`webapps/ROOT`→ the nix-store packages, plus
`TemporaryFileSystem=/var/lib/unifi/webapps`. So on the host, `/var/lib/unifi/{bin,lib,dl,
logs,run,webapps}` show as **empty root-owned dirs — that's expected** (they're mount
points; the real content is bound in inside the unit's namespace). The **only persistent
state is `/var/lib/unifi/data/`** (WiredTiger DB, `keystore`, `system.properties`, sites,
autobackups). The real app log is `/var/log/unifi/server.log`, **not** the journal — the
module's journal-based `errorPatterns` therefore only catch process-level fatals.

Relocation (in the module): a **host-level bind mount** `fileSystems."/var/lib/unifi" =
{ device = cfg.dataDir; fsType = "none"; options = ["bind" "nofail"
"x-systemd.requires-mounts-for=/mnt/virtio"]; }` with `dataDir = /mnt/virtio/unifi`. This
coexists fine with the unit's own StateDirectory/BindPaths — the whole-dir bind was NOT
the cause of the startup loop (Gotcha 2 was).

## Migration procedure (for reference / redo)

1. `systemctl stop unifi` on the source (quiesces mongod for a consistent copy).
2. Move **only `data/`** (`tar -C /var/lib/unifi -cf - .` then extract `./data`; the DB
   is sparse — `du` shows ~51 MB allocated but the tar is ~360 MB logical, both fine).
   **scp the tar and extract locally** — a `cat tar | ssh host tar -x` pipe truncated
   silently once. Verify `data/db/WiredTiger.wt` + `_mdb_catalog.wt` landed.
3. Deploy the destination (creates the `unifi` user + bind mount), stop unifi there,
   `rm -rf /var/lib/unifi/data`, extract the real `./data`, `chown -R unifi:unifi`, start.
4. Confirm `curl -sk https://127.0.0.1:8443/status` → `up:true` and the **`uuid` matches
   the source controller** (proof the restored DB, keystore, sites, adoptions carried).
5. localProxy dns-sync publishes `unifi.ablz.au → doc2`, overriding the `*.ablz.au → .6`
   wildcard; individual LE certs are issued per host (not the old wildcard).
6. Remove the service from the old host (its data stays on disk as rollback).

## Gotcha 4 — device re-inform + doc2's dual-NIC (`.35`/`.36`) quirk

After the controller IP changed (caddy `.6` → doc2 `.35`), adopted devices had the old
inform URL baked in. In practice **all 5 devices self-rediscovered the new controller via
L2 broadcast** within minutes (no manual set-inform needed) — L2 discovery is the reliable
path, and a **device reboot** forces a fresh one.

Two nudges were added so future reconnects land on `.35`:
- **Override inform host:** the UI toggle (`override_inform_host`) couldn't be set via the
  unifi MCP (those tools aren't exposed to the session). Set it the file way instead:
  `system_ip=192.168.1.35` in `/var/lib/unifi/data/system.properties` + restart unifi.
- **DHCP option 43** on pfSense `lan`: `01:04:C0:A8:01:23` (suboption 1, IP `192.168.1.35`).

**The dual-NIC quirk:** doc2 is dual-homed on the LAN — **`.35`/ens18 AND `.36`/ens19 both
on `192.168.1.0/24`**. UniFi devices that discovered doc2 via broadcast can latch onto
`.36` for inform, and the controller's live `set-inform` UDP nudge to those devices
**doesn't land** (doc2 appears to egress that same-subnet packet from `.36`). Devices on
`.36` are **benign** — connected, `cfgversion` in sync, `.36` is the same physical LAN —
and self-correct to `.35` on their next **reboot** (guided by `system_ip` + option 43).
`unifi_set_inform_device` and a controller restart both failed to move them; only a device
reboot reliably does. If tidiness matters, reboot the stragglers (brief AP/switch blip);
otherwise leave them.

## VTech camera lag and Fixed AP pin (2026-08-10)

A VTech camera/display pair (`192.168.1.7` and `.8`) developed persistent video lag
while both devices still reported a good connection. Their WAN and AirVPN egress had
been intentionally blocked for years; that policy was not the local-stream bottleneck:
both addresses are on the same untagged LAN, so camera-to-display traffic is bridged at
Layer 2 through UniFi and never traverses pfSense. A live pfSense check found no LAN
RX/TX errors and, as expected, no VTech entries among 8,066 routed states.

The live UniFi evidence isolated the fault to the Living Room 2.4 GHz radio:

- Camera `.7` was associated with Living Room on channel 11 at -65 dBm despite being
  physically underneath the Master Bedroom AP. Its retry rate was 32.7% and it had
  several 22–41 second associations/reconnects immediately before capture.
- Display `.8` was on the same AP/BSSID at -41 dBm but still showed 34.4% retries.
- The Living Room radio showed 35.2% retries and 38% utilization. Master Bedroom on
  channel 6 and Hallway on channel 1 showed 0% retries and only 7–8% utilization.
- Living Room's wired uplink was clean at 1 Gb/s full duplex with no errors or drops.

This is normal client-directed Wi-Fi selection rather than the controller assigning the
best AP. The camera had used Master Bedroom before but strongly preferred/stuck to Living
Room. Minimum RSSI and 802.11r were disabled; 802.11v BSS transition guidance was already
enabled. Enabling 802.11r was rejected as the fix: it reduces authentication time for
clients that choose to roam, does not force AP selection, applies to the whole WLAN, and
can break legacy IoT supplicants.

The narrow remediation was UniFi **Fixed AP** on only the camera client:

- Client: `.7`, MAC `a4:97:5c:04:67:1f`
- Fixed AP: Master Bedroom, MAC `fc:ec:da:10:b5:4a`
- Controller fields: `fixed_ap_enabled=true` and `fixed_ap_mac=<Master Bedroom MAC>`
- No WLAN, 802.11r, minimum-RSSI, or display-client settings changed.

The camera disconnected from Living Room, then reassociated with Master Bedroom without
a forced kick. Initial post-change verification at 20:14 AWST showed channel 6, -54 dBm,
72.2/72.1 Mb/s PHY, 4.6% retries, CCQ 99.1%, and zero drops. A later sample remained
pinned and online at -52 dBm with 13.4% retries, CCQ 97.4%, and zero drops—still materially
better than the approximately 33% retry rate on Living Room. User-visible VTech latency
still needs observation before calling the application symptom resolved.

**Trade-off / rollback:** a Fixed AP client may not fail over while Master Bedroom is
offline. To revert, clear Fixed AP for the camera in the UniFi client settings (equivalent
to setting `fixed_ap_enabled=false`); do not enable global minimum RSSI or 802.11r as a
substitute.

## External MongoDB container (#142)

**Status: the code is merged, the database is NOT yet migrated.** `unifi.service` is
deliberately gated OFF until an operator runs the cutover below. Read this whole section
before deploying doc2.

### Why

The isolated `mongodb-nixpkgs` input required a local, unfree, **uncached MongoDB source
build**. On 7.0.39 the final `mongod` link OOM-killed GNU ld on doc1 (~19 GiB virtual,
5.2 GiB anon RSS; a prior candidate ran ~4 h before timing out), which wedged the nightly
rolling update. UniFi runs fine natively; only its *database* needed to stop being a
from-source Nix package. The controller was **not** containerised — that would have been a
much larger change for no benefit.

### Shape

| Piece | Value |
|---|---|
| Image | `docker.io/library/mongo@sha256:444d798458e5aa40f3667230a9c631974fa169c32ae4a2d924658ac72b753122` (7.0.40) |
| Host exposure | `127.0.0.1:27117` → container `27017`. Never on the LAN or tailnet. |
| Network | dedicated `isolated-unifi-mongodb` bridge (auto, via `homelab.podman.containers`) |
| Runtime user | fixed **UID/GID 2015** (`unifi-mongodb`), `cap-drop=all`, `no-new-privileges` |
| dbpath | `/mnt/virtio/unifi-mongodb/db`, `0750 unifi-mongodb:unifi-mongodb` |
| Auth | `--auth`; root + application roles from `secrets/hosts/doc2/unifi-mongodb.yaml` |
| Health | Kuma UI monitor + `UniFi MongoDB write-path` deep probe + 3 `errorPatterns` |

**Why `mongodb-7_0` is gone from the closure.** `services.unifi.mongodbPackage` now points
at `unifi-mongodb-absent`, a derivation whose `bin/` is **empty**. In external-DB mode
UniFi never spawns `mongod` — verified against the reference external-Mongo deployment,
`linuxserver/docker-unifi-network-application`, whose image installs *zero* MongoDB
packages (only `jsvc`, `logrotate`, a JRE and `unzip`). The upstream NixOS module still
bind-mounts `${mongodbPackage}/bin` over `/var/lib/unifi/bin`, so the option must point at
something — an empty `bin/` satisfies that and is **fail-closed**: if `system.properties`
were ever lost, UniFi would fail to find a local `mongod` and refuse to start, rather than
silently initialising a second, empty embedded database beside the real one.

**Why this one image is digest-pinned** (the fleet's only registry pin — see
[Image trust](../nixos-service-modules.md#image-trust)): MongoDB's major version is coupled
to the installed UniFi release, and **MongoDB refuses to start on a dbpath written by a
newer major version, with no downgrade path**. An auto-pulled `:latest` would roll the
database to MongoDB 8 unattended and leave an un-downgradable dbpath. The failure mode is
silent data loss, not the supply-chain risk the no-pinning policy knowingly trades away.
The MongoDB 8 move is a tracked, explicit migration.

### Secrets

`secrets/hosts/doc2/unifi-mongodb.yaml` (doc2 + editor + break-glass) holds
`root_username`/`root_password` and `app_username`/`app_password`. **It is already
generated and committed encrypted — no operator provisioning is required.**

- The **root** credential reaches the container only through the official image's
  `MONGO_INITDB_ROOT_{USERNAME,PASSWORD}_FILE` convention (bind-mounted files, never a unit
  environment variable, never argv).
- The **application** credential is read only by root-run host units. UniFi requires it
  inline in a `mongodb://` URI in `system.properties`; that file is rendered **at runtime**
  as `0600 unifi:unifi` inside the persistent data dir. It is never in the Nix store.
- Both are alphanumeric by construction (`openssl rand -hex 32`), so no percent-encoding in
  the URI and no quoting in the `mongosh` JS. `unifi-mongodb-setup.service` **asserts** that
  invariant at runtime and fails closed if a hand-rotated value breaks it.

To rotate: `sops secrets/hosts/doc2/unifi-mongodb.yaml` (alphanumeric values only), deploy,
and `unifi-mongodb-setup.service` re-applies the password and re-renders `system.properties`
on the next start. `restartUnits` wires that automatically.

### Startup order

```
/mnt/virtio (virtiofs mount)
  └─ podman-unifi-mongodb.service          (mongod, --auth, loopback publish)
       └─ unifi-mongodb-setup.service      (oneshot; waits for ping, ensures the
            │                               application role, renders system.properties)
            └─ unifi.service               (ExecCondition = migration gate)
```

`unifi.service` carries `restartTriggers` on the **host-side** `podman-unifi-mongodb.service`
unit (not the container's inner definition) — the cascade-stop rule from
`mk-pg-container.nix`'s header applies identically here.

### The migration gate (why UniFi will not start yet)

`unifi.service` has an `ExecCondition` that **refuses to start** while legacy embedded state
exists at `/mnt/virtio/unifi/data/db` and `/mnt/virtio/unifi/migrated-to-external-mongodb`
is absent. Starting anyway would bring the controller up against an **empty** database — an
unadopted, factory-looking controller. Staying down is loud (the Kuma monitor pages) and
completely reversible; coming up empty is neither.

So: **deploying doc2 from this commit takes the UniFi UI down** until the cutover is run.
Everything else on doc2 is unaffected. Plan a window.

### Why not a raw dbpath handoff

Do **not** copy `/mnt/virtio/unifi/data/db` into the container's dbpath. Four independent
reasons:

1. **Database names differ.** The embedded instance uses `ace`/`ace_stat`; external mode
   uses `unifi.db.name` (`unifi`, `unifi_stat`, `unifi_audit`, `unifi_restore`).
2. **Auth model differs.** The embedded mongod ran with no authentication at all. The
   container runs `--auth`; a copied dbpath contains no users, and the localhost exception
   only applies when the deployment has zero users.
3. **Different builds.** The old files were written by nixpkgs' `mongodb-7.0.37`, the
   container is the official 7.0.40. Same series, so *probably* fine — but "probably" is
   not a migration plan for the only copy of the network's configuration.
4. **Ubiquiti does not support it.** The supported local→external path is a controller
   backup/restore, which is also what carries sites, adoptions, keystore and settings.

The chosen mechanism is therefore UniFi's **own `.unf` backup/restore**.

### Shadow-copy validation (run this FIRST — touches nothing live)

This validates the container, storage, ownership, auth, exposure and probe **without
stopping UniFi and without writing to any production path**.

```bash
# On doc2. Scratch paths only; the live controller keeps running throughout.
sudo install -d -o unifi-mongodb -g unifi-mongodb -m 0750 /mnt/virtio/scratch-mongo/db

# 1. The image is what we think it is, and the digest resolves.
sudo podman pull docker.io/library/mongo@sha256:444d798458e5aa40f3667230a9c631974fa169c32ae4a2d924658ac72b753122
sudo podman inspect --format '{{.Config.Env}} {{index .Config.Labels "au.ablz.mongodb-version"}}' \
  docker.io/library/mongo@sha256:444d...   # expect MONGO_VERSION=7.0.40

# 2. Dump the LIVE embedded DB read-only, into scratch. mongodump is a
#    consistent-enough logical read for a quiesced-ish controller; take it during
#    low activity. This does NOT modify the live dbpath.
sudo systemctl stop unifi                      # optional but gives a clean dump
sudo podman run --rm --network=host -v /mnt/virtio/scratch-mongo:/out:rw \
  docker.io/library/mongo@sha256:444d... \
  mongodump --host 127.0.0.1 --port 27117 --out /out/dump
sudo systemctl start unifi

# 3. Load it into a throwaway MongoDB 7.0.40 with auth, on scratch storage.
#    Proves the on-disk data is readable by the exact image we are pinning.
sudo podman run --rm -d --name mongo-shadow \
  -v /mnt/virtio/scratch-mongo/db:/data/db:rw \
  --user 2015:2015 --security-opt=no-new-privileges --cap-drop=all \
  docker.io/library/mongo@sha256:444d... mongod --bind_ip_all
sudo podman exec mongo-shadow mongorestore /data/db/../dump
sudo podman exec mongo-shadow mongosh --quiet --eval \
  'db.getSiblingDB("ace").device.countDocuments()'   # expect your device count
sudo podman rm -f mongo-shadow
sudo rm -rf /mnt/virtio/scratch-mongo
```

Record the device/site counts — they are the acceptance numbers for the cutover.

### Cutover runbook (the real migration; schedule a window)

```bash
# --- Before ---------------------------------------------------------------
# A1. Take a UniFi backup from the UI: Settings → System → Backups → Download.
#     ALSO grab the on-disk autobackups; they are the restore vehicle.
ls -l /mnt/virtio/unifi/data/backup/autobackup/
# A2. Record the pre-cutover identity so you can prove the restore carried.
curl -sk https://127.0.0.1:8443/status    # note "uuid"
# A3. Belt and braces: ask prom for an out-of-band ZFS snapshot of the dataset.
ssh root@prom zfs snapshot nvmeprom/containers@pre-unifi-mongo-cutover

# --- Deploy ---------------------------------------------------------------
fleet-deploy doc2        # from doc1. UniFi will NOT start (gate). Mongo will.
systemctl status podman-unifi-mongodb unifi-mongodb-setup   # both must be green
systemctl status unifi   # expect condition-failed, with the gate's instructions

# --- Migrate --------------------------------------------------------------
# B1. Let UniFi initialise a FRESH external database, then restore into it.
sudo touch /mnt/virtio/unifi/migrated-to-external-mongodb
sudo systemctl start unifi
# B2. Browse to https://unifi.ablz.au — expect the setup wizard.
#     Choose "Restore from backup" and upload the .unf from A1.
# B3. Verify.
curl -sk https://127.0.0.1:8443/status    # uuid MUST match A2
systemctl start deep-probe-unifi-mongodb-write-path.service   # must exit 0
```

Devices re-adopt themselves via L2 discovery, exactly as in the caddy→doc2 move above; see
[Gotcha 4](#gotcha-4--device-re-inform--doc2s-dual-nic-3536-quirk).

### Rollback

The cutover is designed to be reversible because **it never deletes
`/mnt/virtio/unifi/data/db`**. That directory is frozen at cutover time and is a complete,
consistent embedded database.

```bash
# 1. Boot the previous generation. It still contains mongodb-7.0.37 in the local
#    store, so this needs NO rebuild and NO network.
sudo nix-env --list-generations -p /nix/var/nix/profiles/system | tail -3
sudo /nix/var/nix/profiles/system-<N>-link/bin/switch-to-configuration switch
# 2. Remove the gate marker so a later re-attempt re-gates properly.
sudo rm -f /mnt/virtio/unifi/migrated-to-external-mongodb
# 3. The embedded mongod comes back on the frozen data/db. Confirm:
curl -sk https://127.0.0.1:8443/status
```

Anything configured *after* the cutover is lost by a rollback — that is inherent and is why
the window should be short. If the generation is gone, `git revert` the migration commit and
rebuild; the MongoDB source build returns with it (and with the OOM risk from #142).

### Backup

`/mnt/virtio` is virtiofs over prom's local `nvmeprom/containers` ZFS dataset — a
paravirtualised passthrough, **not** a network filesystem (MongoDB does not support NFS/CIFS
dbpaths). Putting the dbpath there means it inherits the existing path for free:
`containers-backup.service` on doc1 takes an **atomic ZFS snapshot** of the whole dataset —
journal and data files in one consistent image, which is exactly what MongoDB requires of a
volume-snapshot backup — age-encrypts it to tower, and `kopia-mum` ships it offsite. New
directories under the dataset are included automatically (opt-out model), so no backup
change was needed.

UniFi's own `.unf` autobackups remain the application-level backup and live in
`/mnt/virtio/unifi/data/backup/`.

## Deploy / access notes

- doc2 deploy: `fleet-deploy doc2` from doc1 (async). The caddy LXC is also a
  verified push-deploy target and is deployed with `fleet-deploy caddy`.
- Root-level log/DB access into the caddy LXC: `ssh root@192.168.1.12 'pct exec 108 -- …'`
  (use absolute paths — `pct exec` has a minimal PATH; NixOS binaries are in
  `/run/current-system/sw/bin`).
- doc2 grants abl030 full passwordless sudo, so `ssh doc2 "sudo …"` works directly.

Related: [nixos-service-modules.md](../nixos-service-modules.md) (localProxy `https`),
[prom-hypervisor.md](../infrastructure/prom-hypervisor.md).
