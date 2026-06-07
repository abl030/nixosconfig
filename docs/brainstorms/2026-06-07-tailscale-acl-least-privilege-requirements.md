---
date: 2026-06-07
topic: tailscale-acl-least-privilege
---

# Tailscale ACL — Least-Privilege Tailnet

## Summary

Replace the tailnet's default-allow policy with a repo-owned `tailscale/acl.hujson`
built on four role tags (`server`, `client`, `share`, `edge`). Servers keep their
mutual-trust mesh; personal client devices drop to a short port allowlist;
inter-tailnet share sidecars and inbound-only edge nodes (Home Assistant, off-site
Pi/NAS) lose the ability to initiate into the fleet. A pre-requisite renumber of
the nspawn service network clears a subnet collision that would otherwise make the
policy fragile. The policy is validated and applied from a trusted fleet host (no
third-party CI), gated by a `tests {}` block plus live post-apply probes for the
connectivity paths that are invisible by inspection.

## Problem Frame

The tailnet is default-allow: every device can reach every TCP/UDP port on every
other device. The fleet is currently 100% user-owned (`abl030@`) — zero tags
exist, even though `secrets/tailscale-oauth.yaml` is staged with `tag:server`.

This is not an abstract gap. The rest of the security posture already *assumes*
the ACL is the boundary: `modules/nixos/profiles/base.nix:322-329` grants the
fleet user passwordless access to the full `tailscale` CLI and justifies it with
"The trust boundary is the tailnet ACL, not local sudo." That boundary was never
written. A lost phone (`s-a55`), a forgotten VM, or any of the 8 stale offline
nodes is one `tailscale up` away from raw TCP to every internal service.

A tailnet ACL operates at **device** granularity, not process. A popped
*container* on doc2 already holds doc2's tailnet identity, so server↔server
rules do nothing to contain it — that blast radius belongs to the podman/nspawn
hardening in #232. The ACL's unique leverage is stopping a whole *device* that
should not be a full-mesh peer from being one: personal clients, exposed share
sidecars, and inbound-only edge nodes.

## Key Decisions

- **Tag at device granularity; do not microsegment the server mesh.** A
  compromised peer server is contained by #232's container hardening, not by
  ACL. Microsegmenting server↔server traffic costs perpetual rule maintenance
  (every NFS mount, DNS forward, syncoid pull, Prometheus scrape, nix-cache
  fetch) for near-zero gain. The mesh stays open. The share sidecars are the one
  apparent exception: they run *on* server hosts but join the tailnet as
  distinct nodes (own identity, `--accept-routes=false`), so tagging them
  `tag:share` genuinely contains them despite their host.

- **Four role tags, each earning its place from a real trust relationship:**
  `server` (mesh), `client` (limited → server), `share` (inbound 443 only),
  `edge` (initiates into the fleet only via explicitly enumerated grants).
  Rejected the issue's six-tag scheme: per-service `share-*` tags and a `guest`
  tag defend against shared-in friends that Tailscale node-sharing already scopes
  to a single node.

- **`edge` is defined by trust direction, not geography.** An edge node initiates
  into the fleet only through explicitly enumerated grants (currently: none into
  fleet nodes; HA → the Cullen route is non-fleet egress). It is otherwise
  inbound-only. Home Assistant (on the home LAN), dad's Pi, and mum's NAS share
  this posture. The invariant is "no implicit fleet access," not "sends no
  packets" — the HA exception proves grants will be enumerated, not assumed.

- **Subnet routes are first-class, not an afterthought.** Every connectivity
  surprise found during this brainstorm was a routed/transport dependency, not a
  configured-address one. The route map is the real risk surface; it is asserted
  by live post-apply probes, not eyeballed.

- **nspawn renumber `192.168.100.0/24 → 10.20.0.0/24` is in scope as the pre-req
  (Phase 0), not a sibling issue.** The current `/24` is overloaded: the fleet's
  local nspawn service network *and* the Cullen site LAN. `10.20.0.0/24` is
  confirmed unused fleet-wide and avoids both Docker's `172.16–31` auto-pool and
  podman's `10.88`. The renumber covers both the Postgres and MariaDB container
  helpers and must preserve genuine Cullen `192.168.100.x` references.

- **Self-hosted, repo-authoritative apply.** `acl.hujson` in the repo is the
  source of truth, validated and applied from a trusted fleet host using an
  `acl`-write OAuth key held in sops. Rejected a GitHub Action: the repo runs no
  CI workflows (they were deliberately removed; the fleet deploys via the
  `rolling-flake-update.service` systemd unit), and a CI-held `acl`-write
  credential would be a single point of failure that could rewrite the whole
  policy with no fleet access. Losing auto-on-merge apply is acceptable for a
  single committer.

## Actors

- A1. Operator — authors the ACL, runs the migration, owns the OAuth credential
  and the apply host.
- A2. Server fleet (`tag:server`) — doc1, doc2, igpu, caddy, downloader,
  pfsense, tower. Mutual-trust mesh; pfSense is also the fleet DNS resolver.
- A3. Personal client (`tag:client`) — framework, epimetheus, s-a55,
  laptop-btibh4ie. Reaches servers on a port allowlist.
- A4. Share sidecar (`tag:share`) — overseer, jellyfin-1, audiobookshelf.
  Inter-tailnet pinhole, reachable on 443 only; distinct tailnet nodes.
- A5. Edge node (`tag:edge`) — homeassistant, raspberrypi (dad's), kerrynas
  (mum's). Reachable by the fleet; no implicit fleet egress.
- A6. Subnet router — tower (home `192.168.0.0/23` + exit), laptop-btibh4ie
  (Cullen `192.168.100.0/24`; also the `wsl` SSH jump host), raspberrypi (dad's
  `192.168.2.0/24` + exit), kerrynas (mum's `192.168.4.0/23`). The fleet depends
  on these routes.
- A7. Apply host — the trusted fleet host that validates and pushes the policy
  using the sops-held `acl`-write key.
- A8. Shared-in user — a member of another tailnet reaching a `tag:share` node.
  This tailnet's ACL cannot name them; their access is bounded sidecar-side
  (see R7).

## Key Flows

- F1. **Preserve fleet DNS.**
  - **Trigger:** any host resolves a non-MagicDNS name.
  - **Steps:** the host's `tailscaled` forwards to pfSense (`100.123.61.111:53`,
    TCP in this environment); pfSense recurses to Cloudflare DoT.
  - **Outcome:** resolution survives the policy flip.
  - **Covered by:** R12, R16, R21.

- F2. **Preserve SSH.**
  - **Trigger:** operator runs the deploy pattern (`ssh <host> "sudo
    nixos-rebuild ..."`) or a Tailscale SSH session.
  - **Steps:** OpenSSH (`:22`) and Tailscale SSH both remain reachable from
    `tag:client`/`tag:server`.
  - **Outcome:** no self-lockout; deploys continue.
  - **Covered by:** R13, R16, R21.

- F3. **Roaming client reaches the home LAN.**
  - **Trigger:** framework/phone, away from home, fetches from the nix cache
    (`192.168.1.29`) or mounts NFS.
  - **Steps:** traffic to `192.168.0.0/23` routes via tower's advertised subnet.
  - **Outcome:** roaming dev/cache/NFS keeps working.
  - **Covered by:** R9, R14, R21.

- F4. **Home Assistant polls the Cullen inverters (edge egress exception).**
  - **Trigger:** the `pysmaplus` integration reads `192.168.100.139` / `.133`.
  - **Steps:** HA (`tag:edge`) initiates over the tailnet to the
    `192.168.100.0/24` route advertised by laptop-btibh4ie (Cullen).
  - **Outcome:** solar polling survives even though HA is otherwise inbound-only;
    HA still cannot reach any fleet node. The grant is a full `/24` (Tailscale
    cannot narrow below the advertised route); narrowing to the two inverter IPs,
    if wanted, happens with a host firewall on laptop-btibh4ie (see R10, OQ).
  - **Covered by:** R8, R9, R10, R21.

- F5. **Server pushes backup to the off-site NAS.**
  - **Trigger:** kopia/syncoid ships to `kerrynas`.
  - **Steps:** `tag:server` (doc2, pfsense) initiates to the kerrynas node;
    kerrynas never initiates back.
  - **Outcome:** backups continue; mum's network cannot pivot inward.
  - **Covered by:** R8, R9.

- F6. **Policy change lifecycle (self-hosted).**
  - **Trigger:** a commit edits `tailscale/acl.hujson`.
  - **Steps:** on the trusted apply host, validate (`tests {}` grant assertions +
    live reachability probes), then apply with the sops-held `acl`-write key.
  - **Outcome:** repo and live policy stay in lockstep; a path-breaking change is
    caught before apply.
  - **Covered by:** R15, R16, R17.

- F7. **Tag migration without lockout.**
  - **Trigger:** operator rolls out tags to a live, untagged fleet.
  - **Steps:** revoke the stale nodes' keys first; tag every remaining live node;
    tag the operator's own client in an order that never strands the session;
    flip default-deny last, with a tailnet-independent break-glass path available.
  - **Outcome:** no connectivity gap mid-migration; a botched flip is recoverable.
  - **Covered by:** R18, R19, R22.

## Requirements

**Phase 0 — nspawn renumber (pre-req)**
- R1. Renumber the nspawn service network from `192.168.100.0/24` to
  `10.20.0.0/24` fleet-wide, so `192.168.100.0/24` denotes only the Cullen site.
  (`192.168.101.0/24` was rejected — it is the live IoT VLAN where HA itself
  sits at `192.168.101.4`.)
- R2. Update both nspawn container helpers and all their consumers:
  `modules/nixos/lib/mk-pg-container.nix` and
  `modules/nixos/lib/mk-mariadb-container.nix` (used by `youtarr`, hostNum 9),
  plus `modules/nixos/services/tailscale/subnet-priority.nix`, the podman
  bridge/firewall rules, and any standalone literal in the old range (e.g.
  `modules/nixos/services/probes/check-immich-sync.nix`). Sweep every
  `192.168.100.x` reference and preserve genuine Cullen ones — notably
  `hosts.nix:86` `localIp = 192.168.100.128` (the Cullen Windows host) must NOT
  change. Verify each Postgres and MariaDB instance reachable from its host
  after the change.
- R3. Phase 0 lands and is verified before the ACL flips to default-deny.

**Tag model**
- R4. Define four tags (`server`, `client`, `share`, `edge`) with `tagOwners`;
  every live node carries exactly one.
- R5. `tag:server` → `tag:server` is open (the mesh).
- R6. `tag:client` reaches `tag:server` only on a defined port allowlist; no
  other fleet access.
- R7. `tag:share` is not part of the mesh and has no `tag:share` → fleet path.
  Port-443-only reachability for shared-in users is enforced sidecar-side (Caddy
  binds 443, `--accept-routes=false`), not by this tailnet's ACL — shared-in
  users belong to another tailnet and cannot be named in these rules.
- R8. `tag:edge` initiates into the fleet only through explicitly enumerated
  grants; it is otherwise reachable inbound from `tag:server`/`tag:client` on
  specific ports and may egress to explicit non-fleet route CIDRs.

**Route and exit grants**
- R9. Grant each depended-on subnet route explicitly: `tag:client` →
  `192.168.0.0/23` (tower), `192.168.2.0/24` (raspberrypi); HA(`tag:edge`) →
  `192.168.100.0/24` (laptop-btibh4ie); `tag:server` → `kerrynas`.
- R10. HA → `192.168.100.0/24` is the sole edge-egress exception. The ACL grant
  is the full advertised `/24`; narrowing to the inverter IPs (`.139`, `.133`),
  if adopted, is a host firewall on laptop-btibh4ie, not an ACL rule.
- R11. Permit exit-node use (`tower`) for `tag:client` roaming egress.

**Preserve-or-die invariants**
- R12. Every host retains DNS to pfSense (`:53`).
- R13. SSH stays reachable: include an `ssh {}` block for Tailscale SSH and
  `:22` for OpenSSH; the operator deploy path must not break.
- R14. Roaming `tag:client` retains home-LAN reach (nix cache, NFS) via tower's
  route.

**Application (self-hosted)**
- R15. `tailscale/acl.hujson` is the source of truth, validated and applied from
  a trusted fleet host — not a GitHub Action (the repo runs no CI workflows).
- R16. Before apply, run the policy `tests {}` block (static grant assertions:
  DNS reachable, SSH reachable, `share`→`server` denied) AND independent live
  reachability probes for the subnet-route paths in F3–F5, because `tests {}`
  asserts policy decisions, not on-wire reachability through subnet routers.
- R17. The `acl`-write OAuth credential is stored in the repo sops tree, readable
  only on the apply host, with a defined rotation/revocation procedure and scope
  limited to ACL writes (separate from the authkey-scoped
  `tailscale-oauth.yaml`).

**Migration and hygiene**
- R18. Tag every live node before flipping to default-deny; order the rollout so
  the operator's own session is never stranded. laptop-btibh4ie is both the
  Cullen subnet router and the `wsl` SSH jump host — tag/grant it so the deploy
  path through it is not cut mid-migration.
- R19. Revoke/expire the 8 stale nodes' keys as the first migration step, then
  delete them: mailstore, epimetheus-vm, sandbox, dev, immich, invoices,
  caddy-1, jellyfin. `dev` and `sandbox` still carry `hosts.nix` definitions —
  decide whether to also remove those host configs (see OQ).
- R20. Tag future joins (the share authkeys and the fleet OAuth join) so new
  nodes are tag-owned, not user-owned.

**Verification**
- R21. After apply, live-verify every preserve-or-die path (F1–F5) and at least
  three negative tests: `tag:client` → a non-allowlisted server port fails,
  `tag:edge` → a fleet node fails, and `tag:share` → a server node fails.
- R22. A tailnet-independent break-glass path exists for the default-deny flip:
  LAN/console access to pfSense and at least one server, or a timed auto-revert
  of the ACL, so a botched flip is recoverable without the tailnet.

## Node inventory

| node | tag | notes |
|---|---|---|
| proxmox-vm (doc1), doc2, igpu, caddy, downloader, tower | `server` | mesh; caddy + downloader are un-nix-managed legacy VMs (trusted for now — residual risk, see below) |
| pfsense | `server` | also the fleet DNS resolver (`:53`) |
| framework, epimetheus, s-a55 | `client` | laptop / workstation / phone |
| laptop-btibh4ie | `client` | also the Cullen subnet router (`192.168.100.0/24`) and `wsl` SSH jump host |
| overseer, jellyfin-1, audiobookshelf | `share` | inter-tailnet pinhole, 443 only |
| homeassistant | `edge` | inbound-only + Cullen route egress |
| raspberrypi | `edge` | dad's; inbound-only; exit + `192.168.2.0/24` |
| kerrynas | `edge` | mum's; backup target; `192.168.4.0/23` |
| mailstore, epimetheus-vm, sandbox, dev, immich, invoices, caddy-1, jellyfin | — | delete (stale) |

The live `jellyfin-1` share node carries that name only because the stale
`jellyfin` node squats the configured hostname (`jellyfin`); deleting the stale
node (R19) frees the name. Tag the node by its live name at migration time.

## Acceptance Examples

- AE1. **Covers R6, R21.** Given the policy is applied, when `s-a55` connects to
  an allowlisted server port (e.g. `443`), it succeeds; when it connects to a
  non-allowlisted port, it is refused.
- AE2. **Covers R8, R10.** Given HA is `tag:edge`, when it polls
  `192.168.100.139`, the read succeeds; when it attempts any fleet node, it is
  refused.
- AE3. **Covers R12, R13, R16.** Given a policy change removes the DNS or SSH
  grant, when the apply host runs validation, the `tests {}` block fails and the
  change is not applied.
- AE4. **Covers R3.** Given Phase 0 is incomplete, when the ACL change is staged,
  the Cullen route grant still references a `/24` shared with the nspawn network,
  so the default-deny flip must not proceed until Phase 0 is verified.
- AE5. **Covers R7, R21.** Given the policy is applied, when a `tag:share` node
  attempts to open a connection to any `tag:server` node, it is refused.
- AE6. **Covers R18, R22.** Given the migration is mid-flight, when the
  operator's own client device is tagged, the SSH session driving the migration
  is not dropped — and if it is, the break-glass path restores access without the
  tailnet.

## Success Criteria

- A non-server device that is lost or compromised can reach servers only on the
  allowlist, not every port.
- Every preserve-or-die path (DNS, SSH, the three routes, backups) survives the
  flip, proven by live post-apply probes — not assumed from static policy tests.
- Repo and live policy stay in lockstep; the apply path is self-hosted with no
  third-party CI holding an `acl`-write credential.
- The `192.168.100.0/24` collision is gone: the CIDR means Cullen and nothing
  else, and nspawn lives on `10.20.0.0/24`.
- Planning can proceed without re-litigating the tag count or whether to
  microsegment the mesh.

## Scope Boundaries

- No server↔server microsegmentation — the mesh stays open.
- No per-service `share-*` tags and no `guest` tag — node-sharing already scopes
  shared-in friends.
- No GitHub Actions / third-party CI for policy apply.
- Do not redesign tailscale-share, the DNS topology, or exit-node setup.
- Do not move the fleet off Tailscale SSH or remove OpenSSH.
- The nspawn renumber changes addressing only; it does not redesign
  `mk-pg-container` auth (that is #232's separate track).

## Dependencies / Assumptions

- **Phase 0 (R1–R3) is a hard dependency** of the ACL flip.
- `10.20.0.0/24` is the chosen nspawn target (alternatives `10.50.0.0/24`,
  `172.20.0.0/24`), confirmed unused via a full pfSense subnet enumeration.
- A new OAuth client with `acl` write scope is required; the existing
  `tailscale-oauth.yaml` is authkey-scoped (`tag:server`, 600s expiry) and is
  the wrong credential for policy apply.
- Tailscale `tests {}` asserts policy grant decisions statically; it does NOT
  prove on-wire reachability through subnet routers or exit nodes — hence the
  live probes in R16/R21.
- HA reaches Cullen *only* via the laptop-btibh4ie tailnet route (operator
  confirmed); there is no separate site-to-site VPN.
- The home LAN, dad's, and mum's routes are advertised and approved as recorded
  in the route map.

## Outstanding Questions

### Resolve Before Planning

- [Affects R9, R11] Does any device other than HA need the Cullen route, and do
  client devices actually use tower (or the Pi) as an exit node in practice?
  Confirm so grants aren't broader than needed.
- [Affects R10] Narrow HA→Cullen to the two inverter IPs via a host firewall on
  laptop-btibh4ie, or accept the full-`/24` egress as a documented residual?
- [Affects R19] Also remove the `dev` and `sandbox` host definitions from
  `hosts.nix`, or only delete their tailnet nodes? (Operator confirmed `dev` is
  dead.)

### Deferred to Planning

- [Affects R6] The exact `tag:client` → `tag:server` port allowlist (SSH, HTTPS,
  DNS, NFS, …).
- [Affects R8, R9, R15] Whether to express the policy in classic `acls` or the
  newer `grants` syntax.
- [Affects R15, R16] The concrete self-hosted apply mechanism (script /
  systemd unit / Makefile target) and how the live reachability probes are run.
- [Affects R18] The tag-migration ordering runbook (tag-self-last; whether to use
  autoApprovers for routes during the cutover).
- [Affects F4] Trivial check that HA's `notify.gotify_battery` URL uses the LAN
  IP or a public `*.ablz.au` name, not a tailnet address; if tailnet, add a
  single `tag:edge` → doc2:gotify grant (enumerated, per R8).

## Residual Risks

- `caddy` and `downloader` are un-nix-managed legacy VMs placed in the open
  `tag:server` mesh — the least-controlled nodes carry full reach. Accepted for
  now (pending nix migration); revisit when they are migrated.
- `pfsense` and `tower` are non-NixOS mesh members not covered by #232 container
  hardening; a compromise of either has no compensating control. **pfSense
  mitigated 2026-06-07:** its management plane (web GUI `:443` + SSH `:22`) is now
  LAN-only via floating block rules 39–46; DNS `:53` deliberately untouched.
  `tower`'s mesh exposure remains open.

## Sources / Research

- `modules/nixos/profiles/base.nix:322-329` — "the trust boundary is the tailnet
  ACL, not local sudo".
- `modules/nixos/services/ssh/default.nix:60` — "all in on tailscale SSH"; both
  Tailscale SSH and OpenSSH `:22` are live.
- `modules/nixos/services/tailscale/subnet-priority.nix` — the `192.168.100.0/24`
  "local nspawn service network" naming that collides with Cullen.
- `modules/nixos/lib/mk-pg-container.nix`, `modules/nixos/lib/mk-mariadb-container.nix`
  (youtarr, hostNum 9 → `.18/.19`), `modules/nixos/services/probes/check-immich-sync.nix`
  (`192.168.100.5` literal) — the full Phase 0 renumber surface.
- `modules/nixos/services/loki.nix:494`, `docs/chromecast-reliability.md`,
  `.claude/agents/pfsense.md` — confirm `192.168.101.0/24` is the live IoT VLAN
  (HA at `192.168.101.4`); rejected as the renumber target.
- No `.github/workflows` directory exists (workflows were removed); the fleet
  deploys via `rolling-flake-update.service` — basis for the self-hosted apply.
- `secrets/tailscale-oauth.yaml` — staged OAuth client (`tag:server`, authkey
  scope), not wired into any module.
- Live `tailscale status` (2026-06-07) — 25 nodes, all `abl030@`-owned, zero
  tags; route map: tower `192.168.0.0/23`+exit, laptop-btibh4ie
  `192.168.100.0/24`, raspberrypi `192.168.2.0/24`+exit, kerrynas
  `192.168.4.0/23`.
- pfSense subnet enumeration (2026-06-07) — `10.20.0.0/24` confirmed free
  (avoids podman `10.88/16`, AirVPN `10.136/16`, Docker `172.16–31` auto-pool).
- HA integration audit (2026-06-07) — no fleet service reached by tailnet
  address *except* the Cullen inverters via the laptop subnet route; Gotify URL
  unverified (HA OS, outside repo).
- Issue #232 — least-privilege umbrella; this ACL closes the device-granularity
  gap and the Tier-2 share concern at the network layer.
