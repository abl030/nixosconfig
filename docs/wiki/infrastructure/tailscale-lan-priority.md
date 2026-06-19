# Tailscale LAN priority (`subnet-priority.nix`)

**Researched / written:** 2026-06-06
**Status:** working (gen-3 design)
**Module:** `modules/nixos/services/tailscale/subnet-priority.nix`
**Related:** [nfs-over-tailscale.md](nfs-over-tailscale.md) § LAN-vs-Tailscale routing; [systemd-resolved-fleet.md](systemd-resolved-fleet.md) (DNS, not routing); issue #232 (least-privilege)

## What it does

Adds `ip rule` entries that send selected subnets through the **main** routing
table instead of Tailscale's table 52:

| CIDR | priority | when |
|------|----------|------|
| `192.168.1.0/24` (home LAN) | 2500 | **only when physically on the home LAN** (`onlyOnLan`) |
| `192.168.100.0/24` (local nspawn net) | 2490 | always |

Without rule 2500, table 52 (rule 5270, before main) would route `192.168.1.0/24`
via the tailnet even when the host is sitting on that LAN. With it stranded
while *away*, traffic to home hosts (e.g. the nix cache **doc1 = 192.168.1.29**)
leaks out the foreign default gateway and blackholes instead of following Tower's
advertised `192.168.0.0/23` subnet route. Keeping that one rule correct as a
laptop roams is the entire job of this module.

## Why "am I home?" is gateway-MAC, not address-presence

`on_lan` returns true iff `ip neigh show 192.168.1.1` resolves to **pfSense's
LAN MAC** (`64:62:66:21:dd:cc`). This is deliberate and bulletproof against the
two false-positive classes that caused real incidents:

- **container bridges** — docker/nspawn/veth interfaces carrying a `192.168.1.x`
  address made the old `ip addr | grep` test fire true anywhere.
- **foreign /24 collisions** — a hotel/cafe also using `192.168.1.0/24` would
  make any address-presence test think it was home and shadow the tailnet route
  to the *real* home subnet. A different gateway MAC defeats this.

If pfSense's LAN NIC is ever replaced, update `homeGatewayMac` in the module
**and** the matching fixture in `flake.nix`'s `onLanMatcherCheck`.

## Architecture (gen-3)

Two cooperating units, both calling the same idempotent apply pass (flock-serialised):

- **`tailscale-lan-priority.service`** — event watcher. Runs `ip monitor address`
  and re-applies on every netlink address change for fast reaction. Exits
  non-zero if the monitor dies so systemd restarts it; `StartLimitIntervalSec=0`
  so it never gives up.
- **`tailscale-lan-priority-reconcile.{service,timer}`** — periodic reconcile
  every 30s, **independent of the watcher's liveness**. This is the real
  convergence guarantee.

## Evolution / incident history

- **gen-1** (`8d1d8376`, Dec 2025): `Type=oneshot`, ran once at boot. Never
  re-evaluated on roam → home rule stranded the moment you left the LAN.
- **gen-2** (`2f876028`, May 31 2026): `Type=simple` + `ip monitor address | while
  read`. Two holes: (a) check-then-watch **startup race** — monitor started
  *after* the first apply, so an event during startup was missed; (b) `on_lan`
  still a loose `grep "192\.168\.1\."` substring.
- **gen-3** (2026-06-06): the week-of-2026-06-06 incident. While travelling, the
  `192.168.1.0/24 → main` rule kept getting **stranded off-LAN**, blackholing the
  nix cache (`nixcache.ablz.au` = doc1 = 192.168.1.29) out the hotel WiFi and
  making rebuilds fall back to `cache.nixos.org` (slow). **Actual root cause
  (latent since gen-1):** `manage_rule` was passed `"${toString rule.onlyOnLan}"`,
  but `toString true` is `"1"` in Nix — not `"true"` — while the bash guard
  checks `[ "$only_on_lan" = "true" ]`. So the remove branch was *never* taken;
  the home rule was only ever cleared by `ExecStop` (service stop), never by the
  running watcher/reconcile. Fixed with `lib.boolToString`. Hardened alongside:
  gateway-MAC `on_lan`, monitor-independent 30s reconcile timer,
  `StartLimitIntervalSec=0`. (The `toString`/`boolToString` trap is the lesson —
  the prior two "fixes" never touched the actually-broken line.)

## Gotchas that cost time

- **Logs go to the unit journal, not a syslog tag.** gen-3 uses `echo ... >&2`
  so `journalctl -u tailscale-lan-priority` / `-u tailscale-lan-priority-reconcile`
  show the Add/Remove/reconcile lines. (gen-1/2 used `logger -t
  tailscale-lan-priority`, visible only via `journalctl -t …` — this hid all
  activity from `-u` during a debug session.)
- **`sudo tailscale` was silently password-prompting**, not passwordless. The
  NOPASSWD rule in `base.nix` named `.../bin/tailscale`, but that's a symlink to
  the `tailscaled` multi-call binary and sudo canonicalises before matching, so
  the rule never matched. Fixed by pointing it at `.../bin/tailscaled` (see the
  blast-radius note there + issue #232).

## When to revisit

- pfSense LAN NIC replaced → update `homeGatewayMac` + the flake check fixture.
- If you ever genuinely roam onto a network whose gateway MAC equals pfSense's
  (cloned MAC), gateway-MAC detection would false-positive — add a second signal.
- The 30s reconcile means a stale rule self-heals within ≤30s of a missed event;
  shorten `OnUnitActiveSec` if that window ever matters.
