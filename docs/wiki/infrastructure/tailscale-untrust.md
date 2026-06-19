# Untrusting the tailscale0 interface (fleet-wide)

**Date:** 2026-06-19
**Status:** done — `trustedInterfaces` no longer lists `tailscale0` on any host
**Trigger:** Audiobookshelf tailnet share (`audiobooks.ablz.au`) 502'd after the
#232 Tier-3 commit flipped ABS from `0.0.0.0` to `127.0.0.1`. Root cause chase
showed the *real* problem was that `tailscale0` was a blanket-trusted firewall
interface, so any `0.0.0.0`-bound service was reachable, unauthenticated, on every
host's own tailnet IP — the exact hazard the Tier-3 bind audit exists to stop.

## What changed

`modules/nixos/services/tailscale/default.nix` no longer sets
`networking.firewall.trustedInterfaces = ["tailscale0"]`. The tailnet is now
treated like any other routable network: default-drop, and each service that must
be reachable over the tailnet declares an explicit pinhole
(`networking.firewall.interfaces.tailscale0.allowed{TCP,UDP}Ports`) or rides nginx
on 443 (the `homelab.localProxy` FQDNs).

## Why it's safe — the pre-flip inventory

Before flipping, every host was inventoried with `ss -tlnH` / `ss -ulnH` and
cross-referenced against the *evaluated* `allowedTCPPorts` and `localProxy.hosts`.
Findings:

- **SSH (22)** is in the GLOBAL `allowedTCPPorts` on every host
  (`services.openssh.openFirewall = true`). Untrust **cannot** lock anyone out.
- **All web UIs / dashboards** reach via nginx on **443** (the `*.ablz.au`
  localProxy vhosts). 443/80 are global. Closing their bare backend ports on the
  tailnet is the *win*, not a regression.
- **LGTM HTTP** (Loki 3100, Mimir 9009, Tempo 3200, Grafana, gRPC 9095-9097,
  gossip 7946) is "reached exclusively through nginx on 443" (loki-server.nix) —
  the fleet pushes to `https://loki.ablz.au` / `https://mimir.ablz.au`. Bare ports
  close safely. **OTLP 4317/4318** *are* global (direct trace push) and survive.
- **pfSense syslog → doc2:1514** is NOT trust-dependent: loki.nix adds a
  **source-scoped** `iptables` accept (`-s 192.168.1.1`, the pfSense LAN IP).
  Survives untrust untouched.
- **Prometheus exporters** (pfSense 9945, ntopng 9946 on doc2) are scraped via
  `http://localhost` — never needed the tailnet.
- **nix binary cache**: `nix-serve` is `127.0.0.1:5000` behind nginx; the fleet
  substituter is `https://nixcache.ablz.au` (443). Survives.
- **node_exporter 9100, syncthing 22000** are global; **syncthing GUI 8384** was
  already correctly pinholed on tailscale0 (the pattern we followed).

### The only blanket-trust dependencies in the whole repo

A `grep -rn 'openFirewall = false'` across `modules/` + `hosts/` found exactly two
services that relied on the interface trust, both on **epi**:

- **Sunshine** game streaming (`modules/nixos/services/display/sunshine.nix`) —
  `openFirewall = false` and the manual tailscale0 port block was *commented out*.
- **wayvnc** (`modules/nixos/services/display/wayvnc.nix`, `homelab.vnc`,
  `openFirewall = false`) — port 5900 never opened.

Both now declare explicit `tailscale0` pinholes (Sunshine: 47984/47989/47990/48010
TCP + 47998/47999/48000/48002/48010 UDP; wayvnc: 5900 TCP). Without these the flip
would have *silently* broken Moonlight + VNC to epi on its next nightly — and epi
was offline during the work, so it could not have been live-verified. This is why
the flip was driven from a source-level audit, not just runtime `ss`.

## Adding a tailnet-only service after this change

Do NOT re-trust the interface. Either:
- put it behind nginx via `homelab.localProxy.hosts` (preferred for HTTP), or
- add `networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ <port> ];`
  inside the service module (see syncthing/sunshine/vnc for the pattern).

## Rollback

Re-add `trustedInterfaces = ["tailscale0"];` to
`modules/nixos/services/tailscale/default.nix` and redeploy. SSH stays up either
way, so a bad rollout is fixable forward per-host (`fleet-deploy <host>`).
