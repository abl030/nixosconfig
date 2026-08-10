# Podman/Netavark cutover after the 2.0 DNS regression

- **Date:** 2026-06-25
- **Status:** CUTOVER PREPARED (2026-08-11). Podman 6.0.2 and Netavark 2.1.0 are temporarily overlaid; the compatible Aardvark 2.1.0 remains sourced from the rolling nixpkgs input. Deployment remains staged under **Forgejo issue #13**.
- **Scope:** every evaluated rootful-Podman host: doc2, igpu, and musicbrainz. doc2 hit the original regression first because it rebooted on the nightly auto-update.

## Symptom

After doc2's nightly auto-update reboot (07:23), container **name** resolution stopped working for every podman bridge network:

- `getent hosts valkey` (and any sibling name) inside a container hangs → the app logs
  `dial tcp: lookup valkey on 10.89.1.1:53: read udp …->10.89.1.1:53: i/o timeout`.
- aardvark-dns **is** running and **is** listening on the bridge gateway (`ss -ulnp` shows
  `10.89.1.1:53`), and `/run/containers/networks/aardvark-dns/<net>` has the correct
  container→IP records.
- Container-to-container traffic **by IP works fine** (TCP connects succeed) — so veth /
  bridge / routing are healthy. Only DNS is dead.

Downstream blast radius observed: the MusicBrainz web container couldn't resolve `valkey`
→ crash-looped on its wait-for → `/ws/2` never healthy → cratedigger's metadata gate stayed
held → cratedigger down. lrclib was unaffected (it's standalone sqlite, no DNS).

## Root cause

`netavark` / `aardvark-dns` were bumped **1.17.x → 2.0.0** in nixpkgs (~2026-06-23; arrived
with `podman 5.8.2 → 5.8.3`). The change only bit on **reboot** — the previously-running
aardvark 1.x process kept serving until the box restarted and started 2.0.0.

[netavark v2.0.0 release notes](https://github.com/containers/netavark/releases/tag/v2.0.0):

- **"Removed iptables support"** — netavark 2.0.0 is **nftables-only**.
- bridge driver now defaults to **strict isolation** (`isolate=true`).

Container DNS does not work just because aardvark listens — netavark must install an nftables
**port-53 DNAT rule** that steers each subnet's DNS to the aardvark listener. On 2.0.0 those
rules don't land on this host (the iptables→nftables-only firewall-backend switch), so the
query never reaches/returns from aardvark → `i/o timeout`. aardvark-dns 2.0.0 itself is a
no-op version-alignment bump (its release notes: "There are no breaking changes in
aardvark-dns however.").

Confirmed on the box: `nft list table inet netavark` had no port-53 DNAT chain for the
container subnets; IP connectivity worked; only name resolution failed.

## Original mitigation (superseded 2026-08-11)

`nix/overlay.nix` originally pinned both packages back to the last-known-good **1.17.x** from a fixed
nixpkgs rev:

- rev `4a29d733e8a7d5b824c3d8c958a946a9867b3eb2` (2026-05-21) → **netavark 1.17.2 / aardvark-dns 1.17.1**
  (1.17.1 also carries the CVE-2026-35406 aardvark fix; 1.17.x still supports iptables **and**
  nftables, matching this fleet's firewall).
- `builtins.fetchTarball` is `sha256`-pinned so the nightly `nix flake update` cannot drag it
  forward. Both are pinned **together** (they are version-paired).

This was the upstream-recommended immediate remedy. The Podman 6 cutover below replaces it;
the 1.17.x package-set pin is no longer present.

### Historical 1.17.x activation procedure

A `switch` puts the new binaries in the generation but the **running** aardvark 2.0.0 keeps
going. To take effect, podman must re-run netavark: either reboot, or
`systemctl restart podman.service` + restart the affected containers (kill the stale
aardvark-dns so a fresh one spawns under netavark 1.17.x). Hosts that have **not** rebooted
since the 2.0.0 bump are still running 1.x and are unaffected until their next reboot — the
pin protects them then.

### Verify

```
# inside any container on a podman bridge:
getent hosts <sibling-name>      # must resolve, not hang
# on the host:
podman exec <c> getent hosts <sibling>
ss -ulnp | grep ':53'            # aardvark listeners
```

## Forward path (Forgejo #13, revised 2026-08-11)

Waiting for the distro package set was dropped after nixpkgs stayed on Podman 5.8 while its
networking packages repeatedly moved out of lockstep. The fleet now carries a bounded,
temporary overlay:

- Podman **6.0.2** from the exact source/hash in nixpkgs PR #536860.
- Netavark **2.1.0**, including the missing-netns teardown repair needed for stale host-port
  ownership (#136), built from fixed source and Cargo-vendor hashes.
- Aardvark DNS **2.1.0**, Buildah **1.45.0**, and Skopeo **1.24.0** from the rolling fleet
  nixpkgs input. Evaluation assertions keep the supported major-version boundary intact.
- Native nftables is enabled structurally by `homelab.podman`. The Loki, mailsearch, and
  MusicBrainz source-scoped firewall rules are native nftables rules; no rootful host retains
  legacy `networking.firewall.extraCommands`.
- Activation fails before container replacement if the configured graph root still contains
  `libpod/bolt_state.db`. Live journals confirmed SQLite on doc2, igpu, and musicbrainz before
  the change was authored.

The flake check discovers every evaluated rootful-Podman host dynamically and requires the
whole transaction: Podman 6.x, Netavark >=2.1,<3, Aardvark 2.x, native nftables, no legacy
firewall commands, and the BoltDB activation guard.

## When to remove the temporary overlay

Remove only the Podman/Netavark override block when the fleet's ordinary nixpkgs input, with
no local package override, satisfies the same `podman6CutoverCheck` and the exact unmodified
Podman package plus all three rootful host closures realize successfully. Keep the native
nftables configuration, firewall translations, compatibility assertions, and BoltDB guard;
they are cutover invariants rather than package-pin baggage.

## Related

- MusicBrainz readiness decoupling (same incident, separate fix): `docs/wiki/services/musicbrainz.md` "Readiness decoupling".
- podman DNS assumptions: `modules/nixos/homelab/podman.nix` (the "netavark/aardvark answers DNS on isolated bridges" note was verified under 1.x).
