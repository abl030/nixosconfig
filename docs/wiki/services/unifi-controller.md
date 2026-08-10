# UniFi Network Controller (on doc2)

**Date:** 2026-07-03 · **Status:** ✅ live on doc2 · **Module:** `modules/nixos/services/unifi-controller.nix`

The UniFi Network controller (v10.4.57, bundled MongoDB) runs on **doc2** as a standard
`homelab.localProxy` service module. It was **migrated off the caddy LXC** (CT 108,
`192.168.1.6`) on 2026-07-02/03 because that placement violated the module rules three
ways: hand-rolled `services.caddy` reverse proxy, `openFirewall` 0.0.0.0 bind, and state
stranded on the LXC's **unbacked-up root disk** (`/var/lib/unifi`, not `/mnt/virtio`).

- **UI:** `https://unifi.ablz.au` → doc2 nginx (localProxy, `https`+`insecureSkipVerify`) → controller `:8443`.
- **State:** `/mnt/virtio/unifi` (portable, kopia-backed), bind-mounted over `/var/lib/unifi`.
- **MongoDB package:** selected from the independent `mongodb-nixpkgs` input, but
  the series is derived from the current upstream `services.unifi` module. Routine
  fleet nixpkgs updates therefore keep the exact MongoDB output; an upstream UniFi
  series migration is still followed. The rolling updater advances the isolated
  pin only for source/version/patch or available-series changes.
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

## Deploy / access notes

- doc2 deploy: `fleet-deploy doc2` from doc1 (async). The caddy LXC is also a
  verified push-deploy target and is deployed with `fleet-deploy caddy`.
- Root-level log/DB access into the caddy LXC: `ssh root@192.168.1.12 'pct exec 108 -- …'`
  (use absolute paths — `pct exec` has a minimal PATH; NixOS binaries are in
  `/run/current-system/sw/bin`).
- doc2 grants abl030 full passwordless sudo, so `ssh doc2 "sudo …"` works directly.

Related: [nixos-service-modules.md](../nixos-service-modules.md) (localProxy `https`),
[prom-hypervisor.md](../infrastructure/prom-hypervisor.md).
