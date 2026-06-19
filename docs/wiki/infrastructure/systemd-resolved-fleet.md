# systemd-resolved fleet-wide (MagicDNS stub)

**Researched / written:** 2026-06-19
**Status:** live — epimetheus (canary) + framework verified; promoted to `base.nix`,
rolling to doc1/doc2/igpu via the nightly `rolling-flake-update`.
**Module:** `modules/nixos/profiles/base.nix` (the two `mkDefault` lines)
**Issue:** GitHub #262
**Related:** [tailscale-lan-priority.md](tailscale-lan-priority.md) (routing, not DNS),
[pfsense-dns-resolver.md](pfsense-dns-resolver.md) (the upstream resolver),
[wsl-tailscale-ssh.md](wsl-tailscale-ssh.md) (why WSL opts out)

## What changed (#262)

`base.nix` now enables, fleet-wide, as `lib.mkDefault`:

```nix
services.resolved.enable = lib.mkDefault true;
networking.networkmanager.dns = lib.mkDefault "systemd-resolved";
```

This was originally a host-local fix on **framework** (commit `85232575`); #262
promoted it after canarying on **epimetheus**. framework's redundant host-local
lines were removed at the same time (base now carries them).

## Why resolved is needed (the latent MagicDNS gap)

`base.nix` enables NetworkManager **and** tailscale on every NixOS host, but
nothing enabled `systemd-resolved`. Without a real local resolver, tailscale has
nowhere to publish MagicDNS, so `tailscaled` **clobbers `/etc/resolv.conf`** to
point straight at `100.100.100.100` and falls back to its own DNS forwarding —
which is flaky and SERVFAILs/times out (badly so while roaming; framework was the
host that actually broke).

Enabling resolved gives tailscale the local resolver it wants:

```
application → nss-resolve → systemd-resolved stub (127.0.0.53)
           → tailscale0  ~.  → 100.100.100.100 (MagicDNS) → pfSense (upstream)
           → enp9s0 local.com → 192.168.1.1 (pfSense, for LAN names)
```

**Tailscale owns DNS** — `resolvectl status` shows `tailscale0` holding
`DNS Domain: <tailnet>.ts.net ~.` with `Default Route: yes`. The `~.` catch-all
means *everything* routes through MagicDNS (which forwards non-tailnet queries to
the tailnet's configured upstream = pfSense). This is intended; we are **not**
trying to bypass tailscale. The LAN link (`192.168.1.1`) only answers names in
its own `local.com` domain.

## pfSense :53 lockdown (read before diagnosing)

pfSense **firewalls outbound `:53` so only pfSense itself answers**, *plus* a NAT
**redirect** that transparently catches `:53` to public resolvers (1.1.1.1,
8.8.8.8, 9.9.9.9, …) and sends them to pfSense. Consequences:

- resolved's compiled-in **fallback DNS** (`1.1.1.1`/`8.8.8.8`/`9.9.9.9`, visible
  in `resolvectl status` Global) actually *work* — the redirect answers them. So
  we deliberately **leave `fallbackDns` at its default** (no `services.resolved.
  fallbackDns` pin). Without the redirect they'd hang; with it they fail-safe.
- All resolution paths terminate at pfSense regardless (MagicDNS forwards there;
  LAN link points there; redirect sends strays there).

## Per-host matrix

| Host | resolved | Why |
|------|----------|-----|
| epimetheus, framework, doc1 (proxmox-vm), doc2, igpu | **true** | base default |
| **wsl** | **false** (explicit opt-out) | NM disabled; manages its own Windows-bridged `/etc/resolv.conf`. resolved would fight it. `networking.networkmanager.dns` from base is inert there (NM off). |
| caddy | n/a | Home-Manager-only host, no `base.nix`. |
| mk-pg / mk-mariadb nspawn containers | true (own netns) | They already run resolved with `useHostResolvConf = false` — unaffected by the host setting. |

## Verification (epimetheus canary, 2026-06-19)

After `fleet-update`: resolved `active`, `/etc/resolv.conf` → `127.0.0.53` stub,
`resolvectl status` mode `stub`, tailscale0 owns `~.`.

- `git.ablz.au` → 192.168.1.35 (**was timing out pre-change** — the fix)
- `doc2` → `100.87.177.120` via `doc2.<tailnet>.ts.net` (MagicDNS peer)
- `doc1` → `192.168.1.29` via `doc1.local.com` (LAN link)
- external + fallback (`@1.1.1.1`/`@8.8.8.8`/`@9.9.9.9` via redirect) all resolve
- `systemd-resolved` journal clean (no SERVFAIL / timeout)

## Gotcha: use `getent`/`resolvectl query`, NOT bare `dig`, to diagnose

Bare `dig <single-label>` (e.g. `dig doc1`) **times out** against the stub, while
`getent hosts doc1` and `resolvectl query doc1` resolve correctly and fast. Why:
`dig` iterates `search` domains and tries `doc1.<tailnet>.ts.net` first; that's a
MagicDNS **in-domain miss** (doc1's tailnet node name is `proxmox-vm`, not `doc1`),
and tailscale slow-fails it instead of returning a fast NXDOMAIN. `dig` chokes;
nss-resolve (what applications use) applies resolved's per-link split logic and
resolves via `local.com`. This is **not a regression** (`dig doc1` timed out
before the change too) and nothing relies on bare-`doc1` DNS (`ssh doc1` uses the
SSH alias). **Lesson: diagnose resolution with `getent`/`resolvectl query`, not
`dig` — `dig` bypasses nss and exposes the tailscale search-domain quirk.**

## When to revisit

- A host that genuinely should not run resolved (new NM-less / self-managed-resolv
  host) needs the same explicit `services.resolved.enable = false;` WSL uses.
- If pfSense ever drops the `:53` NAT redirect, pin `services.resolved.fallbackDns`
  to `[ "192.168.1.1" ]` (or `[]`) so resolved never hangs on an unreachable
  public fallback.
- If the tailnet's upstream DNS changes away from pfSense, the whole funnel
  assumption above changes — re-check `resolvectl status` per host.
