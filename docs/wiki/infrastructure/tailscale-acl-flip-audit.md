# Tailscale ACL — pre-flip path audit (#239)

- **Date:** 2026-06-21
- **Status:** ✅ **DEFAULT-DENY FLIPPED + verified 2026-06-21.** Allow-all removed; the
  5-tag policy is live (20 nodes tagged, 6 stale culled). The wsl/cullen NFS grant was
  added (`cullen→192.168.1.2:2049`, tower NFSv4.2). Verified from doc1: server paths
  (doc2:22, kerrynas:2049, pfSense:53), DNS, `doc1→cullen:22` deploy, and `ssh wsl`
  showing wsl DNS + git:443 + tower-NFS all OK; static accept+deny gate passes; no Loki
  connectivity errors post-flip. **Owner still to live-verify** the device-to-device paths
  (Sunshine/RDP, Syncthing), `overseer.ablz.au` from a roaming device, and ali@'s overseer
  share. REVERT if needed: re-add the allow-all grant + `gitops-pusher apply` from doc1.
- **Why this exists:** the 2026-06-07 plan's grants were drafted from the requirements,
  not a live path audit. Three things would have broken on a blind flip (shares,
  wsl-deploy, client↔client). This audit enumerates EVERY tailnet-traversing path on the
  live fleet so the flip can't dark a service. Method: 3 Explore sweeps + live `tailscale`
  + API data, cross-referenced against `tailscale/acl.hujson`.

## The rule of thumb

The ACL only governs **tailnet** traffic (100.x / MagicDNS / advertised-route). Anything
over the **LAN** (192.168.x — doc1/doc2/igpu are all on 192.168.1.x natively) is NOT
ACL-governed and cannot be broken by the flip. So the audit's job is to separate the two.

## Paths that are ALREADY covered (no action)

| Path | Grant that covers it |
|---|---|
| DNS → pfSense:53 (the #1 lockout risk) | server-mesh (servers); `client→pfsense:53`; `hermes→pfsense:53` |
| doc1 → doc2 / igpu / hermes :22 (deploy + bastion SSH) | server-mesh; `server→hermes:22` |
| Telemetry push: every host → `loki.ablz.au`/`mimir.ablz.au` :443 | `client→server:443` + server-mesh (nginx fronts loki/mimir; 3100/9009 are NOT firewall-open) |
| Tempo OTLP `4317/4318` (tower → doc2 traces) | server-mesh (tower = server) |
| kerrynas NFS backup (doc2 → kerrynas:2049) | `server→kerrynas [tcp:2049,tcp:111,udp:111]` |
| Home/dad routes, exit node | `client→192.168.0.0/23`, `client→192.168.2.0/24`, `client→autogroup:internet` |
| framework → wsl-router:22 (Cullen dev path) | `framework→wsl-router:22` |
| HA → Cullen inverters :443 | `homeassistant→{.139,.133}/32:443` |

**LAN-only (not ACL-governed, can't break):** Gotify (`192.168.1.35:8050`), syslog
`1514` (pfSense/tower→doc2), syncoid-pfsense (doc2→pfSense ZFS over SSH), pfSense/ntopng
exporters (doc2 pulls `192.168.1.1`), node-exporter `9100` (scraped by *local* alloy),
nginx `:80/:443` for LAN-resolved FQDNs (jellyfin/photos/abs → `192.168.1.x`).

## GAPS — what the flip would break, and the grant to add

### 1. wsl deploy (CONFIRMED break)
`fleet-deploy wsl` connects **doc1 → wsl-router(laptop-btibh4ie):22** over the tailnet, but
the only `wsl-router:22` grant is `framework`-only. Add doc1.
→ **`{src:["doc1","framework"], dst:["wsl-router"], ip:["tcp:22"]}`** (add a `doc1` host alias = `100.89.160.60`).

### 2. Share services (CONFIRMED break)
`overseer.ablz.au` → `100.70.211.51` (the share node) — reached over the tailnet by the
owner's own devices AND shared inter-tailnet to **ali@** (overseerr). `tag:share` has no
inbound grant. (immich-share-to-meg was never re-created → currently unused.)
→ **`{src:["tag:client"], dst:["tag:share"], ip:["tcp:443"]}`** (owner's devices)
→ **`{src:["autogroup:shared"], dst:["tag:share"], ip:["tcp:443"]}`** (ali@ / future inter-tailnet shares)

### 3. client↔client device-to-device (CONFIRMED break)
The plan gave `tag:client` no client→client path, but the workstations expose, over the tailnet:
| Service | Host(s) | Ports | Status |
|---|---|---|---|
| Sunshine (Moonlight) | epi | tcp 47984/47989/47990/48010, udp 47998-48002/48010 | ACTIVE |
| GNOME RDP | epi (firewalled), framework | tcp 3389/3390 | ACTIVE |
| Syncthing GUI | epi/framework/wsl/doc1/igpu | tcp 8384 (tailscale0-gated) | ACTIVE |
| WayVNC | epi | tcp 5900 | **inactive** (commented out) |

Consumers are the owner's *other* personal devices (phone→desktop, laptop→desktop). All
are `tag:client → tag:client`.
→ **`{src:["tag:client"], dst:["tag:client"], ip:["*"]}`** — personal devices trust each
other (the real restriction stays client→*server*). *(Decision: full client↔client vs
port-scoped — see below.)*

### 4. Syncthing across the client/server boundary (LIKELY break)
Syncthing is a mesh over epi/framework/wsl (clients) + doc1/igpu (servers), ports
**tcp/udp 22000** (data) + **udp 21027** (discovery), NOT tailscale0-gated. Among clients →
covered by #3. doc1/igpu↔workstations is LAN when home, but **wsl (Cullen) ↔ doc1/igpu is
always tailnet**, and roaming workstations too. (May use relays instead of direct — include
defensively; harmless if unused.)
→ add `tcp:22000,udp:22000,udp:21027` to **`client→server`** and a new
**`{src:["tag:server"], dst:["tag:client"], ip:["tcp:22000","udp:22000","udp:21027"]}`**.
(server↔server syncthing = mesh, already covered.)

## Revised design (owner, 2026-06-21): 5th tag `tag:cullen`

The Cullen laptop (`laptop-btibh4ie`) is the least-trusted node (remote site, Windows
host, the fleet's only Cullen presence). Pull it OUT of the `client↔client` blanket into a
stricter `tag:cullen` so a Cullen compromise can't pivot into the fleet, and the fleet
can't roam the Cullen LAN. Supersedes treating it as `tag:client`.

- **tagOwners:** add `tag:cullen → autogroup:admin`.
- **Re-tag** `laptop-btibh4ie`: `tag:client → tag:cullen` (live API + acl.hujson).
- **autoApprovers:** `192.168.100.0/24 → tag:cullen` (was `tag:client`).
- **Inbound to cullen:** `{src:["doc1","framework"], dst:["tag:cullen"], ip:["tcp:22"]}`
  (deploy + dev SSH to WSL) + NFS — **scope pending #4**.
- **Outbound (minimal management plane — wsl is a managed NixOS host, so NOT zero):**
  - `{src:["tag:cullen"], dst:["pfsense"], ip:["tcp:53","udp:53"]}` (DNS)
  - `{src:["tag:cullen"], dst:["192.168.1.0/24"], ip:["tcp:443","tcp:8050"]}` (Forgejo /
    nix-cache / Loki on doc1+doc2 via tower's route; Gotify 8050) — NOT the broad fleet,
    NOT client↔client, NOT exit.
- **NOT** in `tag:client→tag:client`. **NOT** `client→server`. **NOT** exit node.
- **Syncthing on wsl:** recommend DROP wsl from the syncthing mesh (cleaner isolation);
  else add a scoped grant. Tracked in #4.
- This means the syncthing client↔server grant (gap #4) excludes wsl.

Net effect vs goals: popped Cullen box → can reach DNS + doc1/doc2 web ports only (not
personal devices, not igpu/caddy/tower, not arbitrary services); popped fleet node → Cullen
LAN reachable only at the two inverter `/32`s, Cullen laptop only via `doc1/framework→:22`.

## To confirm before the flip
- **Forgejo git-SSH `:2222`** (doc2): the fleet pushes via `https://git.ablz.au` (:443,
  token header), so 2222 looks unused over the tailnet. If any host pushes via `ssh://…:2222`,
  add `{src:["tag:client","tag:server"], dst:["doc2"], ip:["tcp:2222"]}`.
- **client↔client scope:** full `tag:client→tag:client:*` (simple, matches "my own devices")
  vs enumerating the ports above (more least-privilege, brittle as services change).

## Flip procedure (the follow-up)
1. Add the grants above to `tailscale/acl.hujson`; keep allow-all; `gitops-pusher test`.
2. Apply (still non-destructive); confirm everything still green.
3. Remove the allow-all grant + enable the parked deny tests; `gitops-pusher test` (final).
4. **From the home LAN** (break-glass = doc1-local revert via the policy_file cred, which
   reaches `api.tailscale.com` over the internet, NOT the tailnet — so revert survives a
   darked tailnet): `gitops-pusher apply`.
5. Post-flip verify: from doc1, hand-check the server-side preserve-or-die paths (fleet DNS
   via pfSense `:53`, doc1→doc2 `:22`, kerrynas NFS `:2049` — e.g. `dig @100.123.61.111
   google.com`, `nc -z`); then **live-test the device-to-device + share paths**
   (Sunshine/RDP/syncthing from a phone/laptop; overseer from a roaming device; ping ali to
   confirm overseer) — these can't be asserted from doc1.
6. Revert trigger: re-add allow-all via `gitops-pusher apply` from doc1 if anything breaks.

## Probe note (RETIRED 2026-06-21)
The ACL-path deep-probe (`check-acl-paths` CLI + Kuma push monitor on doc1/doc2) was
**removed** the day after the flip — commit `0234a5f4`. It shipped with a packaging bug
(`bash` missing from `runtimeInputs`, so its `/dev/tcp` SSH/NFS checks exited 127 and the
Kuma monitor sat falsely DOWN, paging Gotify) while the paths were actually healthy. Its only
real value — the one-time pre/post-flip cutover gate — was spent, and the preserve-or-die
paths it watched are covered by other alerting if they break. Verify those paths by hand from
doc1 per step 5 above; there is no longer a continuous probe.
