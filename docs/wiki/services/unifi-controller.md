# UniFi Network Controller (on doc2)

**Date:** 2026-08-13 · **Status:** ⚠️ **production runs native UniFi + embedded MongoDB.**
The first external-MongoDB cutover (PR #144) was merged, deployed, failed and was rolled
back on 2026-08-13; master was reverted by `c2c2789b`. This page documents the **second**
attempt — see [External MongoDB container](#external-mongodb-container-142) ·
**Module:** `modules/nixos/services/unifi-controller.nix` · **Issue:** forgejo #142

The UniFi Network controller (v10.5.54) runs on **doc2** as a standard
`homelab.localProxy` service module. It was **migrated off the caddy LXC** (CT 108,
`192.168.1.6`) on 2026-07-02/03 because that placement violated the module rules three
ways: hand-rolled `services.caddy` reverse proxy, `openFirewall` 0.0.0.0 bind, and state
stranded on the LXC's **unbacked-up root disk** (`/var/lib/unifi`, not `/mnt/virtio`).

- **UI:** `https://unifi.ablz.au` → doc2 nginx (localProxy, `https`+`insecureSkipVerify`) → controller `:8443`.
- **State:** `/mnt/virtio/unifi` (portable, backed up), bind-mounted over `/var/lib/unifi`.
- **MongoDB (target state, not yet live):** a dedicated, digest-pinned **official MongoDB 7
  container** (`docker.io/library/mongo`, 7.0.40), loopback-only on `127.0.0.1:27117`, with
  its dbpath at `/mnt/virtio/unifi-mongodb`. The controller itself stays native NixOS.
  **Today production still runs the embedded nixpkgs `mongodb-7.0.37`** on
  `/mnt/virtio/unifi/data/db`; the `mongodb-nixpkgs` input stays pinned at 7.0.37 until the
  migration lands.
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
4. Confirm `curl -sk https://127.0.0.1:8443/status` → `up:true` and the `uuid` matches
   the source controller. **Caveat (learned the hard way on 2026-08-13):** `uuid` lives in
   `system.properties` **on disk**, so it only evidences anything when the whole `data/`
   directory moved, as here. It is *not* proof that a database carried — check record
   counts for that. See [External MongoDB container](#external-mongodb-container-142).
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

**Status: production still runs the embedded MongoDB.** The first cutover (PR #144, merged
as `31214c3c`, deployed to doc2 as generation 1428) failed and was rolled back to
`15e4b5c9` / generation 1427 on 2026-08-13; master was reverted by `c2c2789b`. This
section is the corrected, second design. Read all of it before deploying doc2.

### Why the database moves at all

The isolated `mongodb-nixpkgs` input required a local, unfree, **uncached MongoDB source
build**. On 7.0.39 the final `mongod` link OOM-killed GNU ld on doc1 (~19 GiB virtual,
5.2 GiB anon RSS; a prior candidate ran ~4 h before timing out), which wedged the nightly
rolling update. UniFi runs fine natively; only its *database* needed to stop being a
from-source Nix package. The controller was **not** containerised — that would have been a
much larger change for no benefit.

### Why the first attempt failed (and what it disproved)

Two defects, only one of them fatal.

**1. The setup unit raced the image's initialisation mongod.** `unifi-mongodb-setup`
waited for an unauthenticated `db.adminCommand({ping:1})`. On an empty dbpath the official
image runs a **temporary** mongod to create the root user — and
`docker-entrypoint.sh` (lines 306-312 of the pinned 7.0.40 image) starts it with
`--bind_ip 127.0.0.1` forced, `--bind_ip_all` stripped and **`--auth` stripped**. That
temporary server answered the ping at 08:33:31.282, the role provisioning ran against it,
and it shut down at 08:33:32.504 → `failed to ensure the UniFi application role`. Only
ever fires on an empty dbpath, i.e. exactly a migration or a disaster-recovery rebuild.

**2. The `.unf` restore was unreachable — the fatal one.** UniFi came up correctly against
the fresh external database (90 collections, `admin=0`) but there was no way to get data
into it:

| Attempt | Result |
|---|---|
| `POST /upload/backup` | **401** `api.err.LoginRequired` |
| `POST /api/cmd/sitemgr {"cmd":"add-default-admin"}` | **401**, with and without a session cookie, on both `/api/cmd/sitemgr` and `/api/s/default/cmd/sitemgr` |
| login with the existing credential | 400 — correct, `admin=0`, no admin exists |

**A restore requires an admin, and no admin could be created.** The runbook assumed a fresh
database yields the first-run setup wizard. It does not: the wizard is gated on
**`is_setup_completed=true` in `/mnt/virtio/unifi/data/system.properties`**, an on-disk
file that the migration never touched. A fresh DB alone is not a fresh controller. And the
`.unf` file is an **encrypted archive** (no zip magic, uniformly high entropy) that only
the controller itself can consume, so there was no offline path in either.

That rules out the entire "point the controller at an empty database and restore a `.unf`"
family unless the data directory is *also* rebuilt — which would mean a new keystore and
losing everything `system.properties` carries.

### The mechanism this design uses: migrate the database contents

`mongodump` the frozen embedded database and `mongorestore` it into the container **under
the same namespaces**, then flip `system.properties`. `ace.admin` travels with everything
else, so there is no admin bootstrap problem, no wizard, no browser upload, no new
keystore and no device re-adoption.

`unifi.db.name` is set to **`ace`** — both UniFi's own default and the name the embedded
instance already uses — so nothing is renamed. Setting it to `unifi` (as the first attempt
did) would have turned a same-name restore into a rename of ~100 collections for cosmetic
gain.

**Rehearsed end-to-end against this network's own data** before being proposed, on doc1,
touching nothing live (the retained `mongodump-ace-precutover-20260813.tar.gz`):

| Step | Result |
|---|---|
| Restore the production dump into a 7.0.x source instance | 103 collections across `ace`, `ace_stat`, `ace_audit`; 132,483 documents |
| Baseline counts | device 5 · site 3 · wlanconf 5 · networkconf 7 · user 139 · **admin 1** · setting 70 · portconf 2 — identical to the recorded pre-cutover baseline |
| `mongodump --archive` → fresh `--auth` instance → `mongorestore` **as the application role** with exactly the grant set below | 132,483 restored, **0 failed** |
| Per-collection count comparison | every one of the 103 collections identical |
| `admin.system.users` after the restore | root + app both intact — `--nsInclude` keeps the restore off the `admin` database |

The old objections to a "raw dbpath handoff" do not apply to a **logical** dump/restore:
database names now match by construction; the auth model is irrelevant because the users
are created by us, not carried in the files; and 7.0.37 → 7.0.40 is a patch move within one
series, proven above on the real data. What remains true is that Ubiquiti publishes no
local→external runbook — but the vendor-supported alternative is the `.unf` wizard path
that is provably unreachable here, and `.unf` does not contain `ace_stat` anyway.

### Shape

| Piece | Value |
|---|---|
| Image | `docker.io/library/mongo@sha256:444d798458e5aa40f3667230a9c631974fa169c32ae4a2d924658ac72b753122` (7.0.40) |
| Host exposure | `127.0.0.1:27117` → container `27017`. Never on the LAN or tailnet. |
| Network | dedicated `isolated-unifi-mongodb` bridge (auto, via `homelab.podman.containers`) |
| Runtime user | fixed **UID/GID 2015** (`unifi-mongodb`), `cap-drop=all`, `no-new-privileges` |
| dbpath | `/mnt/virtio/unifi-mongodb/db`, `0750 unifi-mongodb:unifi-mongodb` |
| Databases | `ace`, `ace_stat`, `ace_audit` (+ `ace_restore` on demand) |
| App role | `clusterMonitor` + `dbOwner` on those four, in the `admin` auth database |
| Auth | `--auth`; root + application credentials from `secrets/hosts/doc2/unifi-mongodb.yaml` |
| Health | Kuma UI monitor + `UniFi MongoDB write-path` deep probe + 4 `errorPatterns` |

**Why `mongodb-7_0` leaves the closure.** `services.unifi.mongodbPackage` points at
`unifi-mongodb-absent`, a derivation whose `bin/` is **empty**. In external-DB mode UniFi
never spawns `mongod` — verified against `linuxserver/docker-unifi-network-application`,
whose image installs *zero* MongoDB packages (only `jsvc`, `logrotate`, a JRE and `unzip`).
The upstream NixOS module still bind-mounts `${mongodbPackage}/bin` over
`/var/lib/unifi/bin`, so the option must point at something; an empty `bin/` satisfies that
and is **fail-closed** — if `system.properties` were ever lost, UniFi would fail to start
rather than silently initialising a second, empty embedded database beside the real one.

**Why this one image is digest-pinned** (the fleet's only registry pin — see
[Image trust](../nixos-service-modules.md#image-trust)): MongoDB's major version is coupled
to the installed UniFi release, and **MongoDB refuses to start on a dbpath written by a
newer major version, with no downgrade path**. An auto-pulled `:latest` would roll the
database to MongoDB 8 unattended and leave an un-downgradable dbpath. The failure mode is
silent data loss, not the supply-chain risk the no-pinning policy knowingly trades away.
The MongoDB 8 move is a tracked, explicit migration.

### Secrets

`secrets/hosts/doc2/unifi-mongodb.yaml` (doc2 + editor + break-glass) holds
`root_username`/`root_password` and `app_username`/`app_password`, regenerated for this
attempt. **Already committed encrypted — no operator provisioning is required.**

- The **root** credential reaches the container only through the official image's
  `MONGO_INITDB_ROOT_{USERNAME,PASSWORD}_FILE` convention (bind-mounted files, never a unit
  environment variable, never argv).
- The **application** credential is read only by root-run host units. UniFi requires it
  inline in a `mongodb://` URI in `system.properties`; that file is rendered **at runtime**
  as `0600 unifi:unifi` inside the persistent data dir. It is never in the Nix store.
- Both are alphanumeric by construction (`openssl rand -hex 32`), so no percent-encoding in
  the URI and no quoting in the `mongosh` JS. Every unit **asserts** that invariant at
  runtime and fails closed if a hand-rotated value breaks it.
- Every `mongosh` script is fed on **stdin**, never `--eval` — `podman exec` argv is
  readable through `podman inspect`. `mongorestore` gets its whole URI from a
  `--config` file built *inside* the container from the secret it already has mounted.

To rotate: `sops secrets/hosts/doc2/unifi-mongodb.yaml` (alphanumeric values only), deploy,
and `unifi-mongodb-setup.service` re-applies the password and re-renders `system.properties`
on the next start. `restartUnits` wires that automatically.

### Two mongosh rules this module encodes

Both were established empirically against mongosh 2.9 and both have bitten this migration:

1. **An uncaught throw in a stdin-fed script exits 0.** `db.auth()` *throws* on failure, it
   does not return false — so a readiness gate written as
   `if (!admin.auth(u, p)) quit(1)` reports **ready** on a bad credential. Every script
   here wraps each fallible call in `try/catch` and ends every path in an explicit `quit()`.
2. **Never parse a stdin-fed mongosh's stdout.** It runs as a REPL and interleaves `test>`
   prompts and spinner characters with the script's output; an anchored `^` match silently
   drops the first row. Count rows carry a `UNIFICOUNT ` marker and are extracted with
   `grep -o`.

### Startup order

```
/mnt/virtio (virtiofs mount)
  └─ podman-unifi-mongodb.service          (mongod, --auth, loopback publish)
       └─ unifi-mongodb-setup.service      (oneshot; waits for the FINAL mongod, ensures
            │                               the application role, renders system.properties
            │                               only once the migration marker exists)
            └─ unifi.service               (ExecCondition = migration gate)
```

`unifi.service` carries `restartTriggers` on the **host-side** `podman-unifi-mongodb.service`
unit (not the container's inner definition) — the cascade-stop rule from
`mk-pg-container.nix`'s header applies identically here.

### The readiness gate (defect 1, fixed)

`unifi-mongodb-setup` now requires **three** conditions to hold in the same iteration:

1. the **published** loopback socket `127.0.0.1:27117` accepts a TCP connection — the exact
   socket UniFi dials. Podman DNATs it to the container's bridge address, which the
   initialisation mongod (bound to the container's *own* loopback) structurally cannot
   answer;
2. an **unauthenticated privileged command is refused** — access control is genuinely
   enforced, which is only true of the final `--auth` mongod, and stays true even after the
   temporary server has created the root user;
3. the **root credential authenticates**.

Proven on doc1 against a real 7.0.x `mongod` pair (no production contact): against a
temp-style server with `--auth` stripped *and the root user already created* — the exact
live failure window — the old ping gate exits **0** (proceeds) and this gate exits **10**
(refuses). Against the final `--auth` server it exits 0; on a wrong password, 11; on a dead
port, 1.

Diagnostics are no longer swallowed by `>/dev/null` (defect 3): the last failure state is
reported, with every credential value scrubbed out by bash parameter expansion — putting a
secret in `sed`'s argv would defeat the point.

### Deploying is now non-destructive (defect 4, fixed at the root)

`unifi-mongodb-setup` **only writes `system.properties` once the migration marker exists.**
Deploying this module therefore mutates **no** persistent UniFi state: the controller stops
(the gate), MongoDB starts, the role is provisioned, and `system.properties` still selects
the embedded database. Rolling back before the migration is a **pure generation switch**.

In the first attempt `system.properties` was rewritten at deploy time in the *persistent*
data dir, so a generation rollback would silently have left the embedded controller
pointing at the **empty** external database. When the renderer does eventually run, it
first copies the file to `system.properties.pre-external-mongodb` — once, never
overwritten — which is what makes rollback an exact restore.

### The migration gate (why UniFi will not start yet)

`unifi.service` has an `ExecCondition` that **refuses to start** while legacy embedded state
exists at `/mnt/virtio/unifi/data/db` and `/mnt/virtio/unifi/migrated-to-external-mongodb`
is absent. Starting anyway would bring the controller up against an **empty** database — an
unadopted, factory-looking controller. Staying down is loud (the Kuma monitor pages) and
completely reversible; coming up empty is neither.

So: **deploying doc2 from this commit takes the UniFi UI down** until the migration is run.
Everything else on doc2 is unaffected. Plan a window — it is one command long.

### Preconditions

- Production healthy on the native-Mongo generation; note the generation number
  (`nix-env --list-generations -p /nix/var/nix/profiles/system | tail -3`).
- A **fresh** `.unf` via the authenticated API and a fresh `mongodump`, both off-box. The
  automatic autobackup is stale — on 2026-08-13 the newest was 10.4.57 against a 10.5.54
  controller.
- An out-of-band ZFS snapshot: `ssh root@prom zfs snapshot nvmeprom/containers@pre-unifi-mongo-cutover-<date>`.
- ≥ 3× the embedded dbpath free on `/mnt/virtio` (the unit checks this and refuses).
- The 2026-08-13 artefacts are retained and **must not be altered**: doc2
  `/mnt/virtio/unifi-cutover-backup/`, doc1 `~/unifi-cutover-2026-08-13/`, and
  `nvmeprom/containers@pre-unifi-mongo-cutover-20260813`.

### Pre-deploy validation (touches nothing live)

Runs against the **live** controller without stopping it. `mongodump` is a logical read: it
does not modify the dbpath, and the first attempt's instruction to `systemctl stop unifi`
first was simply wrong — the embedded `mongod` is a **child of `unifi.service`**, so
stopping the unit kills the very server being dumped.

```bash
# On doc2. Scratch paths only; the live controller keeps running throughout.
IMG=docker.io/library/mongo@sha256:444d798458e5aa40f3667230a9c631974fa169c32ae4a2d924658ac72b753122
# Own the scratch by the SAME fixed uid the migration runs mongod/mongodump as.
# NOT root-owned 0700 — see the entrypoint note below.
sudo install -d -o 2015 -g 2015 -m 0750 /mnt/virtio/unifi-precheck

# 1. The digest resolves and is the MongoDB we think it is.
sudo podman pull "$IMG"
sudo podman inspect --format '{{.Config.Env}}' "$IMG" | tr ' ' '\n' | grep MONGO_VERSION   # 7.0.40

# 2. Dump the LIVE embedded DB, read-only, WITHOUT stopping unifi.
sudo podman run --rm --network=host --user 2015:2015 \
  --security-opt=no-new-privileges --cap-drop=all \
  -v /mnt/virtio/unifi-precheck:/out:rw "$IMG" \
  mongodump --host 127.0.0.1 --port 27117 --archive=/out/precheck.archive

# 3. Load it into a throwaway hardened 7.0.40 and compare counts. The dump directory
#    is mounted (the first attempt pointed mongorestore at a path that was not).
sudo install -d -o 2015 -g 2015 -m 0750 /mnt/virtio/unifi-precheck/db
sudo podman run --rm -d --name mongo-shadow --network=none \
  --user 2015:2015 --security-opt=no-new-privileges --cap-drop=all \
  -v /mnt/virtio/unifi-precheck/db:/data/db:rw \
  -v /mnt/virtio/unifi-precheck:/in:ro "$IMG" mongod --bind_ip 127.0.0.1
sleep 10
sudo podman exec mongo-shadow sh -c 'mongorestore --quiet --archive < /in/precheck.archive'
sudo podman exec mongo-shadow mongosh --quiet --norc --eval '
  ["ace","ace_stat","ace_audit"].forEach(d => print(d + " collections=" +
    db.getSiblingDB(d).getCollectionNames().length));
  print("device=" + db.getSiblingDB("ace").device.countDocuments({}));
  print("admin=" + db.getSiblingDB("ace").admin.countDocuments({}));'
sudo podman rm -f mongo-shadow
sudo rm -rf /mnt/virtio/unifi-precheck
```

**Why every step passes `--user 2015:2015` (measured on doc2, 2026-08-13).** The official
image's `docker-entrypoint.sh` drops privileges for **any** argv[0] matching `mongo*`, not
just `mongod`:

```sh
if [[ "$originalArgOne" == mongo* ]] && [ "$(id -u)" = '0' ]; then   # line 12
        ...
        exec gosu mongodb "$BASH_SOURCE" "$@"
fi
```

So a rootful `podman run … mongodump` still executes as the image's `mongodb` user (uid
999) and **cannot write into a root-owned `0700` scratch dir** — the first form of this
runbook failed exactly there with `Failed: open /out/precheck.archive: permission denied`,
while a plain `sh -c` in the same image stayed uid 0 and wrote fine. Passing `--user`
explicitly makes `id -u` non-zero, skips the `gosu` branch entirely, and matches the
identity the real migration uses. The migration unit was never affected: it always passes
`--user=${uid}:${gid}` and chowns its scratch to the same uid.

Record those numbers. **`admin` must be ≥ 1** — that is the record whose absence deadlocked
the first attempt.

**Result of this pre-check against production, 2026-08-13 12:34 AWST** (live controller
never stopped; scratch removed afterwards; `system.properties` checksum unchanged):

| Measure | Value |
|---|---|
| Image actually pulled and run | `sha256:444d7984…`, `MONGO_VERSION=7.0.40`, `db.version()` = **7.0.40** |
| Restored into the 7.0.40 shadow | `ace` 92 + `ace_stat` 10 + `ace_audit` 1 = **103 collections**, **132,745 documents** |
| Live source at the same moment | 103 collections, 132,750 documents (stats accrue between reads) |
| Identity collections | device 5 · site 3 · wlanconf 5 · networkconf 7 · user 139 · **admin 1** · setting 70 · portconf 2 |
| Databases a full embedded dump carries | `ace`, `ace_audit`, `ace_stat`, **`admin`**, `config`, `local` — which is why the migration's `--nsInclude` is load-bearing, not cosmetic |

That closes the "rehearsal used 7.0.37, not the 7.0.40 image" uncertainty: the official
7.0.40 image reads and round-trips this network's own 7.0.37-written data.

> Do **not** use the controller `uuid` as an acceptance check. It lives in
> `system.properties` **on disk** and survives regardless of what the database contains, so
> a matching uuid proves nothing about the restore. Use record counts.

### Cutover

```bash
# --- 1. Deploy. UniFi will NOT start (gate). MongoDB will. -------------------
fleet-deploy doc2                                    # from doc1
ssh doc2 'systemctl status podman-unifi-mongodb unifi-mongodb-setup'   # both green
ssh doc2 'systemctl status unifi'                    # condition-failed, with instructions
# system.properties is still untouched at this point — rollback is a pure generation switch.

# --- 2. Migrate. One command; it verifies before it commits. -----------------
ssh doc2 'sudo systemctl start unifi-mongodb-migrate && journalctl -u unifi-mongodb-migrate -n 40 --no-pager'

# --- 3. Start the controller and check acceptance. ---------------------------
ssh doc2 'sudo systemctl start unifi && sudo unifi-mongodb-verify'
```

`unifi-mongodb-migrate.service` is a manual oneshot — nothing pulls it in. It:

1. refuses unless `unifi.service` is stopped, the container is up, the marker is absent, the
   external database holds no UniFi documents, and there is ≥ 3× the dbpath free;
2. copies `/mnt/virtio/unifi/data/db` to `/mnt/virtio/unifi-mongodb/migration/legacy-db` —
   the original is **copied, never mounted**, so it stays byte-frozen as the rollback;
3. serves the copy with a throwaway `--network=none` mongod from the same pinned image
   (the copied dbpath is non-empty, so the image's initdb phase never runs for it — which is
   why a plain ping *is* the right readiness test for this one instance);
4. records per-collection counts, then `mongodump --archive`;
5. streams the archive into the container on stdin and `mongorestore`s it with
   `--nsInclude 'ace.*' 'ace_stat.*' 'ace_audit.*'` — the `admin` database is deliberately
   excluded so the restore cannot clobber the MongoDB users;
6. re-reads every collection **as the application role** and refuses to continue unless
   every count matches. On mismatch the marker is **not** written and UniFi stays gated off;
7. only then writes the marker and renders `system.properties`.

### Acceptance checks

`unifi-mongodb-verify` (installed on doc2, run as root) asserts all of:

- `podman-unifi-mongodb.service` active, running the **digest-pinned** image;
- **nothing but `127.0.0.1` listens on 27117** — no LAN (`192.168.1.35/.36`), no tailnet;
- access control enforced *and* the root credential authenticates;
- every migrated collection count still matches the pre-migration source;
- migration marker present; `system.properties` selects the external DB and is `0600 unifi:unifi`;
- `system.properties.pre-external-mongodb` exists (rollback is possible);
- `unifi.service` active and `https://127.0.0.1:8443/status` reports `up:true`.

Then, by hand: log in at `https://unifi.ablz.au` with the existing credential (proves
`ace.admin` carried), and confirm all devices report `state=1` across a few polls. Devices
re-adopt themselves via L2 discovery if needed — see
[Gotcha 4](#gotcha-4--device-re-inform--doc2s-dual-nic-3536-quirk).

### Rollback

```bash
ssh doc2 'sudo unifi-mongodb-rollback'          # dry run: prints exactly what it will do
ssh doc2 'sudo unifi-mongodb-rollback --yes'    # or --generation N to pin the target
```

Executable and verified, in this order, because the order is what the first attempt got
wrong:

1. stop `unifi.service` (and confirm it stopped);
2. **restore `system.properties`** from `system.properties.pre-external-mongodb`, or, if
   that copy is missing, strip the four external-database keys;
3. **assert** no external-database keys survive — and refuse to switch generations if any do;
4. remove the migration marker;
5. `nix-env --switch-generation` + `switch-to-configuration switch` (the old generation is
   already in the store: no rebuild, no network);
6. poll `https://127.0.0.1:8443/status` until `up:true`, and fail loudly if it never comes.

Nothing is deleted: `/mnt/virtio/unifi/data/db` is frozen from the moment the controller
stops, and the migration copy plus dump archive stay under
`/mnt/virtio/unifi-mongodb/migration/`. Anything configured *after* the cutover is lost by a
rollback — inherent, and why the window should be short.

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
`/mnt/virtio/unifi/data/backup/`. **They run on UniFi's own schedule and go stale** — take a
fresh one through the authenticated API before any disruptive work.

## Deploy / access notes

- doc2 deploy: `fleet-deploy doc2` from doc1 (async). The caddy LXC is also a
  verified push-deploy target and is deployed with `fleet-deploy caddy`.
- Root-level log/DB access into the caddy LXC: `ssh root@192.168.1.12 'pct exec 108 -- …'`
  (use absolute paths — `pct exec` has a minimal PATH; NixOS binaries are in
  `/run/current-system/sw/bin`).
- doc2 grants abl030 full passwordless sudo, so `ssh doc2 "sudo …"` works directly.

Related: [nixos-service-modules.md](../nixos-service-modules.md) (localProxy `https`),
[prom-hypervisor.md](../infrastructure/prom-hypervisor.md).

### Deploy attempt 2026-08-13 12:44 — rolled back on a missing runtime dependency

The first deploy of this design (merge `b066b1fb`, doc2 generation 1431) was rolled
back at 12:52 AWST. **No data was at risk and nothing needed repairing**: the failure
was the fail-closed path working exactly as designed.

`unifi-mongodb-setup.service` failed after its full 180 s budget with:

```
unifi-mongodb: authenticated mongod did not become ready within 180s
unifi-mongodb: last state: published port 127.0.0.1:27117 is not accepting connections
```

**The message was accurate but the diagnosis it suggests is wrong — the port was
fine.** The readiness gate's first condition probes the published socket with
`timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/27117'`. `/dev/tcp` is a **bash
builtin** with no coreutils equivalent, and a systemd unit's `PATH` is only
`systemd.services.<name>.path` (coreutils, findutils, gnugrep, gnused, systemd)
plus the script's `runtimeInputs` — **it does not include bash**. `mongoSetup`'s
`runtimeInputs` were `[coreutils podman]`, so `timeout` exited **127** ("bash: No
such file or directory") on every one of the 180 iterations, and the gate could
never pass no matter how healthy MongoDB was.

Measured on doc2 with the unit's exact PATH:

| Build | probe against an OPEN port | probe against a CLOSED port |
|---|---|---|
| as merged | **127** (bash not found — always fails) | 127 |
| with `pkgs.bash` added | **0** | 1 |

Everything else worked on the first try and was verified live before the rollback:
the container ran the digest-pinned image, the entrypoint's initdb created the root
user (`admin.system.users` count 1), the root credential authenticated, access
control was genuinely enforced (`listDatabases` → `Unauthorized`), and the published
loopback socket accepted connections from the host.

An audit of all five shipped scripts for the same defect class found exactly one
other instance: `unifi-mongodb-verify`'s loopback-only assertion pipes `ss` through
`awk` without `pkgs.gawk` in `runtimeInputs`. That one resolves *interactively*
— it is in `systemPackages` and `writeShellApplication` appends the ambient `PATH`
— so it would have passed by luck, not by design. Both are fixed.

**Rollback behaved exactly as documented** and is now production-tested:
`unifi-mongodb-rollback --generation 1430 --yes` stopped `unifi`, took the
"no pre-migration copy" branch (correct — the deploy never wrote
`system.properties`), asserted no external-DB keys survived, switched generation and
polled `/status` until `up:true`. Post-rollback the controller was healthy on
generation 1430 with 103 collections / 132,797 documents and the exact baseline
identity counts (admin 1 · device 5 · site 3 · user 139 · wlanconf 5 ·
networkconf 7 · setting 70 · portconf 2), zero failed units, and the embedded
`mongod` owning `127.0.0.1:27117` again.

`system.properties` came back with **all 10 operator/UniFi `key=value` pairs
identical**; the only delta in the whole file was the `#<date>` comment line UniFi
itself rewrites on every start.

**Lesson worth generalising:** `writeShellApplication` + `runtimeInputs` is not a
substitute for thinking about a *systemd unit's* PATH. Shellcheck cannot see a
missing runtime dependency, the derivation builds fine, and the failure only appears
under the unit's sanitised environment — not in an interactive rehearsal. Any shell
builtin invoked through a *sub-shell* (`bash -c`, `sh -c`) needs its interpreter
declared explicitly.

### Deploy attempt 2026-08-13 13:01 — second runtime defect, same review blind spot

With `bash` declared, the readiness gate passed on the first try — and immediately
exposed the next bug. `unifi-mongodb-setup` failed with:

```
unifi-mongodb: failed to ensure the UniFi application role (mongosh exited 13)
could not ensure the application role: APP_USER is not defined
```

`mongosh_script` bound **one** credential pair — `root` *or* `app` — but
`ensureRoleJs` needs **all four**: it authenticates as ROOT and then
creates/updates the APP user. The call site passed `root`, so `APP_USER` and
`APP_PASS` were never defined.

**This produced the exact same operator-visible message as PR #144's failure**
("failed to ensure the UniFi application role") for a completely unrelated cause.
That collision is worth remembering: the message names the *step*, not the *fault*.
Always read the line beneath it — the module preserves mongosh's own diagnostic
(defect 3 of the original seven), which is what made this a two-minute diagnosis
instead of another race-condition hunt.

Fixed by adding a `both` mode. `root` and `app` remain separate rather than always
emitting all four, so a script needing one identity never carries the other in its
stdin. Call sites were then audited mechanically against the variables each JS body
actually references:

| JS body | needs | call mode |
|---|---|---|
| `readinessJs` | ROOT_USER, ROOT_PASS | `root` |
| `ensureRoleJs` | all four | `both` |
| `appCountsJs` | APP_USER, APP_PASS | `app` |
| `countsJs` | none (unauthenticated `--eval`) | n/a |

**Why the rehearsal missed both defects.** The doc1 rehearsal exercised the
*restore wrapper* and hand-run `mongosh` sessions, never `unifi-mongodb-setup`
itself as a systemd unit. Both bugs live exclusively in that unit's own runtime
envelope: one in its PATH, one in its argument plumbing. Neither is visible to
`nix flake check`, shellcheck, or a `nix build` — all of which passed on both
broken revisions.

**Practice change adopted here:** the fixed script was `nix copy`'d to doc2 and run
directly against the live container *before* being committed, which proved
`exit 0`, "role provisioned", and the exact intended grant set
(`dbOwner` on `ace`/`ace_stat`/`ace_audit`/`ace_restore` + `clusterMonitor`) with
the APP credential authenticating. Do that for any unit that cannot be rehearsed
end-to-end off-box — building it is not the same as running it.

### Migration attempt 2026-08-13 13:08 — third defect: a spurious "RESTORE MISMATCH"

`unifi-mongodb-migrate` ran the whole pipeline correctly and then failed on its own
verification step:

```
unifi-mongodb-migrate/bin/unifi-mongodb-migrate: line 215: TMPDIR: unbound variable
unifi-mongodb-migrate: RESTORE MISMATCH (source vs target):
```

**The restore was perfect.** The comparison was what broke. The step is:

```bash
if ! printf '%s\n' "$restored" | diff -u "$sourceCounts" - > "$TMPDIR/counts.diff" 2>&1; then
```

systemd's `PrivateTmp=` gives a unit a *private* `/tmp` but does **not export
`TMPDIR`**, and `writeShellApplication` sets `set -o nounset`. So expanding
`$TMPDIR` aborted that very line — and because the abort makes `if !` true, the
script reported a mismatch that did not exist, then died on line 217 expanding
`$TMPDIR` again.

Verified by hand immediately afterwards, comparing the container's contents against
the migration's own `source-counts.txt`: **all 103 collection counts identical.**

**Fail-closed held perfectly.** Marker not written, `system.properties`
byte-for-byte identical, `unifi` still gated off, legacy dbpath untouched. The
failure mode was a false negative, which is the safe direction.

Fixed with a script-owned `mktemp` file and a trap that cleans it up alongside the
throwaway container. An audit of all five scripts for the same class — an
environment variable referenced without a `:-` default under `set -u` — found this
as the **only** instance (`UNIFI_MIGRATE_FORCE` already had one).

**If you hit "RESTORE MISMATCH", read the line above it before believing it.** A
genuine mismatch prints a `diff -u` body; this one printed a shell error.
