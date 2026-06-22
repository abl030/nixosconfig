# Tailscale ACL — the fleet's tailnet trust boundary

- **Date:** 2026-06-21
- **Status:** ✅ **Default-deny LIVE** (flipped 2026-06-21). 5-tag `grants` policy; all
  20 nodes tagged; 6 stale nodes culled. Route-grant hardening landed 2026-06-22:
  broad home-LAN route access was replaced with exact `/32` + port grants.
- **Source of truth:** [`tailscale/acl.hujson`](../../../tailscale/acl.hujson) (repo-authoritative).
- **Issue:** GitHub #239. **Plan:** [`docs/plans/2026-06-07-002-feat-tailscale-acl-least-privilege-plan.md`](../../plans/2026-06-07-002-feat-tailscale-acl-least-privilege-plan.md).
- **Pre-flip path audit + complete grant rationale:** [tailscale-acl-flip-audit.md](tailscale-acl-flip-audit.md).
- **Related:** [pfsense-dns-resolver](pfsense-dns-resolver.md) (the load-bearing `:53` grant),
  [nfs-over-tailscale](nfs-over-tailscale.md), [wsl-tailscale-ssh](wsl-tailscale-ssh.md),
  [tailscale-untrust](tailscale-untrust.md) (the host-firewall layer), [tailscale-lan-priority](tailscale-lan-priority.md).
- **Open follow-ups:** forgejo#4 (Cullen NFS→Syncthing migration), forgejo#3 (stale-NFS-handle
  noise on deploys).

---

## What this is

The tailnet was **default-allow** — every device could reach every port on every other
device, the whole fleet user-owned (`abl030@`), **zero tags**. `base.nix` already justified
passwordless `tailscale` with "the trust boundary is the tailnet ACL, not local sudo" — a
boundary that was never written. This is that boundary: a **default-deny** policy in the
modern `grants` syntax (classic `acls` are frozen upstream), on **five role tags**.

The ACL governs **tailnet** traffic only (100.x / MagicDNS / advertised-route). Traffic over
the **LAN** (doc1/doc2/igpu are all on `192.168.1.x` natively) is NOT ACL-governed. This split
is the single most important thing to keep straight when reasoning about what the ACL can and
can't break. There is a **second, independent** enforcement layer — each NixOS host's
`nixos-fw` with `homelab.tailscale.netfilterMode` (see [tailscale-untrust](tailscale-untrust.md))
— which only filters *inbound* tailnet packets at the host. This doc is about the central ACL.

## Subnet-route footgun

Tailscale route injection and grants are independent: route acceptance puts an advertised
subnet in a client's routing table, while grants decide whether packets through that route
are permitted. A broad route grant is therefore real LAN access, not just "routing". It can
also defeat "LAN-only" admin hardening, because the packet exits tower's subnet router onto
the home LAN and may be seen as LAN-side.

Policy distinction: `tag:client` is intentionally trusted for tailnet nodes and non-Cullen
routes, but does **not** get the Cullen work subnet (`192.168.100.0/24`) by default. Less-
trusted roles (`tag:cullen`, `tag:edge`, `tag:share`, `autogroup:shared`) must use exact
destination IP + port route grants into fleet LANs. Route approval (`autoApprovers`) is only
reachability plumbing; it is not an access decision.

## The five tags

| tag | what | members (2026-06-21) |
|---|---|---|
| `tag:server` | fleet service VMs + infra; full mesh | proxmox-vm (doc1), doc2, igpu, caddy, downloader, pfsense, tower |
| `tag:client` | trusted personal/admin devices; full tailnet + approved non-Cullen subnet-route access | framework, epimetheus, epimetheus-vm, s-a55 (phone) |
| `tag:share` | inbound-443 share sidecars (own devices + inter-tailnet shares) | overseer, jellyfin-1, audiobookshelf, hermes-ui |
| `tag:edge` | remote/isolated nodes; no implicit fleet access | homeassistant, raspberrypi (dad's), kerrynas (mum's), hermes |
| `tag:cullen` | the Cullen-site laptop (laptop-btibh4ie/wsl); **strictest** | laptop-btibh4ie |

## Access matrix (what each tag may reach)

| src → | gets |
|---|---|
| `tag:server` | full mesh (`*` to all servers); `kerrynas` NFS (backup); `tag:share:443` (Kuma health-checks); `hermes:22` (deploy) |
| `tag:client` | full tailnet access; home/dad/mum subnet routes; exit-node egress. No Cullen `192.168.100.0/24` route grant by default |
| `tag:share` | **nothing** into the fleet (egress denied — the deny tests enforce it); served *to* clients/servers/shared-in users on 443 |
| `tag:edge` | nothing implicit. HA → the two Cullen inverter `/32`s on `:443` only. hermes → `pfsense:53` only (and inbound `:22` from servers) |
| `tag:cullen` | Outbound: `pfsense:53` (DNS), exact HTTPS endpoints via tower (`192.168.1.29:443`, `192.168.1.35:443`, `192.168.1.33:443`, `192.168.1.6:443`), `192.168.1.35:8050` (Gotify), `192.168.1.2:2049` (tower NFS), Syncthing mesh. Inbound: trusted `tag:client` devices can reach it; doc1 gets deploy SSH |
| `framework` | `tag:cullen:22` (Cullen dev path, in addition to `doc1`) |
| `autogroup:shared` | `tag:share:443` (inter-tailnet shares, e.g. overseer shared to ali@) |

The authoritative, commented version with exact IPs/ports is **`tailscale/acl.hujson`** — read
that, not this table, when changing policy.

## `tag:cullen` — the Cullen-site isolation

> [!WARNING]
> **The Cullen LAN footgun.** The fleet reaches the Cullen site (`192.168.100.0/24`,
> advertised by `laptop-btibh4ie`) at **exactly two destinations**: `HA → 192.168.100.139/32`
> + `192.168.100.133/32` on `:443` (the solar inverters), and `doc1/framework → laptop:22`.
> **The route existing is NOT access.** A future project that assumes "the fleet can reach the
> Cullen LAN" will be silently denied — it needs its own `/32` (or host) added to a grant.
> `laptop-btibh4ie`/wsl is the intended handler for Cullen-side resources.

`laptop-btibh4ie` is a Windows laptop at the Cullen winery running the `wsl` NixOS instance;
WSL's tailnet traffic egresses *through* the Windows host, so `tag:cullen` governs both. It is
the least-trusted node, so it is **deliberately excluded** from the `client↔client` blanket.
Design goals: a Cullen compromise can't pivot into the fleet; the fleet can't roam the Cullen
LAN. But `wsl` is still a **managed NixOS host**, so it gets a *minimal* outbound management
plane (DNS + exact HTTPS/Gotify endpoints + tower NFS) — "deny everything" would brick
auto-updates.
NFS is the current data transport; **Syncthing-only is the planned end state (forgejo#4)**, at
which point the `cullen→192.168.1.2:2049` grant is dropped. Trusted `tag:client` devices can
still reach the Cullen laptop; the isolation boundary is about Cullen's outbound movement.

## How policy is applied — `gitops-pusher` on doc1

The policy is pushed to Tailscale CONTROL by [`gitops-pusher`](https://pkgs.tailscale.com)
(nixpkgs `tailscale-gitops-pusher`), driven by
[`modules/nixos/services/tailscale/acl-apply.nix`](../../../modules/nixos/services/tailscale/acl-apply.nix).

**Why doc1 (the bastion), not doc2** (the plan originally said doc2): the `policy_file` OAuth
credential can rewrite the *entire tailnet trust boundary*. doc1 is already maximally
privileged (fleet SSH key, passwordless sudo, the pfSense/UniFi/HA control creds since #234),
so a doc1 compromise is already game-over — adding ACL-write there expands its blast radius by
~nil. doc2 runs a large surface of internet-facing services; putting the crown-jewel
credential there would make "doc2 popped" *also* mean "tailnet policy rewritten." Concentrate
fleet-control creds on the one hardened, audited host.

- **Service:** `tailscale-acl-apply.service` — a hardened oneshot. **Trigger:** a daily timer
  (`05:10`) + `restartTriggers` on the policy file + manual `systemctl start`. It is **NOT**
  `wantedBy multi-user.target`, deliberately, so a transient Tailscale-API failure can never
  fail doc1's nightly `fleet-update`. Apply is idempotent (no-op when CONTROL's checksum already
  matches). `OnFailure` → Gotify (a 401 = expired/revoked credential).
- **Credential:** `policy_file`-scoped OAuth client, sops at
  `secrets/hosts/proxmox-vm/tailscale-acl-oauth.env` (`TS_OAUTH_ID` + `TS_OAUTH_SECRET`),
  auto-scoped to doc1 + editor + break-glass by the existing `^hosts/proxmox-vm/` rule. No
  `IPAddressAllow` pin (api.tailscale.com is CDN-fronted with rotating IPs — a static allowlist
  would be an outage source); containment is least-scope OAuth + the dedicated user + fs sandbox.

### Manual apply / validate (from doc1)
```sh
cd ~/nixosconfig
set -a; eval "$(cd secrets && sops -d hosts/proxmox-vm/tailscale-acl-oauth.env)"; set +a
export TS_TAILNET=-
nix run nixpkgs#tailscale-gitops-pusher -- -policy-file=tailscale/acl.hujson -github-syntax=false test    # validate + run tests{}
nix run nixpkgs#tailscale-gitops-pusher -- -policy-file=tailscale/acl.hujson -github-syntax=false apply   # push
```
`test` runs the `tests{}` block server-side — the real grant-correctness gate. Always `test`
before `apply`. The committed `acl.hujson` MUST match what's applied, or the daily timer reverts
your manual change.

### Credential lifecycle
- **Create:** Tailscale admin → Settings → OAuth clients → grant **`policy_file` Write** only.
- **Rotate:** create a new client → re-sops the env file → redeploy doc1 → delete the old client.
- **Revoke** (suspected doc1 compromise): delete the client in the console (instant), then re-key.

## Tagging nodes

Tagging needs a credential the `policy_file` cred does **not** have — it can't touch devices, by
design. Use a **separate, short-lived `devices` (core) Write OAuth client**, then **delete it**
when done (no device-write cred should persist on the fleet). Tag via the API:
`POST /api/v2/device/{id}/tags  {"tags":["tag:X"]}`.

Lessons from the 2026-06-21 migration:
- **The API `hostname` field is the OS hostname, not the tailnet node name.** `downloader`'s OS
  hostname is `genericvm`; `caddy`/`epimetheus`/`jellyfin` each appeared twice (stale + live
  sharing an OS hostname). **Map nodes by tailnet IP / FQDN (`.name`), never by `hostname`.**
- **Admin-API tag assignment is non-disruptive** — the node stays online and **route approvals
  survive** (verified). This is the recommended path; the disconnect bug (Tailscale #13572) is
  the *CLI self-advertise* (`tailscale up --advertise-tags`) flow, which the locked-down siblings
  can't run anyway.
- **Chicken-and-egg:** a `devices`-write OAuth client can only select tags that already exist in
  the *applied* policy's `tagOwners`. So **apply the policy (with all tagOwners) first**, then
  create the tagging client. Do NOT add tagOwners by hand in the console editor — that's a manual
  edit `gitops-pusher` will later refuse to push over.

## Routes & exit nodes (`autoApprovers`)

`autoApprovers` pre-approve advertised routes **by tag** (not retroactive): `192.168.0.0/23`→
`tag:server` (tower→home), `192.168.100.0/24`→`tag:cullen`, `192.168.2.0/24`+`192.168.4.0/23`→
`tag:edge` (dad's pi / mum's kerrynas). Approval only lets clients learn the routes; grants
still decide access. `tag:client` is trusted for full tailnet node access and non-Cullen
routes, but Cullen's `192.168.100.0/24` work subnet stays closed until a deliberate grant is
added. Untrusted roles use exact `/32` + port grants. `exitNode`→`tag:server` is
**tag-server-wide**: only tower advertises exit today; if another server ever does, it's
auto-approved — revisit with a dedicated `tag:exit` if more appear. (raspberrypi also offers
exit but is `tag:edge`, so it is NOT auto-approved — intentional.)

## Break-glass / revert

The flip and its revert both run from **doc1** via `gitops-pusher`, which reaches
`api.tailscale.com` **over the internet, not the tailnet** — so the revert survives even a fully
darked tailnet. To revert, re-add the allow-all grant to `acl.hujson` and `apply`:
```
{ "src": ["*"], "dst": ["*"], "ip": ["*"] }
```
The owner being **on the home LAN** during a flip is the secondary safety (pfSense admin + direct
SSH to a server are LAN-reachable regardless of tailnet state).

## Operations cheatsheet

- **New fleet node:** tag it (devices-write client, by IP/FQDN) before it relies on tailnet
  access — an untagged node fails closed under default-deny.
- **New inter-tailnet share** (share a service to an external user): just share the node in the
  console — `autogroup:shared → tag:share:443` already covers it, as long as the target is
  `tag:share`. Sharing a non-`tag:share` node needs a new grant.
- **A service needs a new tailnet port:** find who consumes it over the tailnet (vs LAN — check
  what its FQDN resolves to), add the narrowest grant, add a `tests{}` accept (+ an adjacent
  deny), `test`, `apply`. The audit doc has the methodology.
- **Monitoring gotcha:** Uptime Kuma runs on doc2 (`tag:server`) and health-checks tailnet
  services — `tag:server → tag:share:443` exists so it can reach `overseer.ablz.au`. Any *new*
  tailnet-resolved monitor target needs the matching `server→…` grant or Kuma false-alarms.

## Verification (post-flip, 2026-06-21)

`gitops-pusher test` passes (accepts + denies). Verified from doc1: server-mesh paths, DNS via
pfSense, `doc1→cullen:22` deploy, `ssh wsl` → wsl DNS + Forgejo:443 + tower-NFS all OK; no Loki
connectivity errors. **One regression caught + fixed:** Kuma (server) → overseer (share) was
denied → added `server→share:443`. Owner-side live checks (device→device Sunshine/RDP/Syncthing,
overseer from a roaming device, ali@'s share) are the remaining confirmation.
