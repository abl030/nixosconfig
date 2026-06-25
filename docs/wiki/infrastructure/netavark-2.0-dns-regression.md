# netavark 2.0.0 broke rootful-podman container DNS (pinned to 1.17.x)

- **Date:** 2026-06-25
- **Status:** WORKED AROUND (pin). Upstream regression in netavark 2.0.0. Revisit when a verified netavark ≥ 2.x lands in nixpkgs.
- **Scope:** fleet-wide latent — every rootful-podman host (doc2, doc1, igpu, …). doc2 hit it first because it rebooted on the nightly auto-update.

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

## Fix (the pin)

`nix/overlay.nix` pins both packages back to the last-known-good **1.17.x** from a fixed
nixpkgs rev:

- rev `4a29d733e8a7d5b824c3d8c958a946a9867b3eb2` (2026-05-21) → **netavark 1.17.2 / aardvark-dns 1.17.1**
  (1.17.1 also carries the CVE-2026-35406 aardvark fix; 1.17.x still supports iptables **and**
  nftables, matching this fleet's firewall).
- `builtins.fetchTarball` is `sha256`-pinned so the nightly `nix flake update` cannot drag it
  forward. Both are pinned **together** (they are version-paired).

This is the upstream-recommended remedy. It is durable, not a band-aid: it holds the working
version until 2.x is verified, then the overlay block is deleted.

### Activating the new netavark on an already-broken host

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

## When to revisit / remove the pin

Remove the `netavark`/`aardvark-dns` overlay block in `nix/overlay.nix` once nixpkgs ships a
netavark ≥ 2.x that reliably installs the DNS DNAT rules on this fleet (test on one host:
deploy unpinned, reboot, `getent hosts` from a container). Until then, keep it.

## Related

- MusicBrainz readiness decoupling (same incident, separate fix): `docs/wiki/services/musicbrainz.md` "Readiness decoupling".
- podman DNS assumptions: `modules/nixos/homelab/podman.nix` (the "netavark/aardvark answers DNS on isolated bridges" note was verified under 1.x).
