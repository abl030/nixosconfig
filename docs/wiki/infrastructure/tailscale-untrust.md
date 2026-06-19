# Gating the tailnet with nixos-fw (netfilter-mode=off) + per-service bind

**Date:** 2026-06-19/20
**Status:** done — servers run `tailscale --netfilter-mode=off` so nixos-fw gates
the tailnet; epi/framework stay tailscale-managed. ABS bound to the podman bridge.
**Trigger:** Audiobookshelf tailnet share (`audiobooks.ablz.au`) 502'd after the
#232 Tier-3 commit flipped ABS `0.0.0.0` → `127.0.0.1`. Chasing it uncovered how
tailnet exposure on this fleet is *actually* controlled.

## The key discovery — `trustedInterfaces` was a red herring

We first assumed `networking.firewall.trustedInterfaces = ["tailscale0"]` was what
exposed every `0.0.0.0`-bound service to the tailnet, and removed it fleet-wide.
**That did nothing**, because of how the live `INPUT` chain is ordered:

```
-A INPUT -j ts-input        # tailscaled's chain runs FIRST
-A INPUT -j nixos-fw
# inside ts-input (netfilter-mode=on, tailscale's default):
-A ts-input -i tailscale0 -j ACCEPT      # blanket-accepts the ENTIRE tailnet
```

`tailscaled` installs `ts-input`, jumped from `INPUT` **before** `nixos-fw`, with a
blanket `-i tailscale0 -j ACCEPT`. So tailnet→host traffic is accepted by
tailscale's own rules and **nixos-fw never sees it**. Proof: with the NixOS trust
removed, doc1's bare `rpcbind` port 111 was *still* reachable over tailscale even
though nixos-fw had no tailscale0 accept and no 111 rule. `trustedInterfaces` was
redundant all along — `ts-input` is the real gate.

## The fix — two complementary layers

### B. `netfilter-mode=off` on servers (the real lever)

`homelab.tailscale.netfilterMode` (default `"off"`) runs
`tailscale set --netfilter-mode=off` via `tailscaled-set.service`. tailscaled then
stops installing the `ts-input` blanket accept, so **nixos-fw becomes the real
gate**: bare ports on the tailnet are dropped; services reach the tailnet via an
explicit `interfaces.tailscale0.allowed{TCP,UDP}Ports` pinhole (syncthing 8384,
sunshine, vnc) or via nginx:443 (the `localProxy` FQDNs).

Why it's safe (verified pre-flip):
- **SSH 22** is in the GLOBAL `allowedTCPPorts` (`openssh.openFirewall`) → no host
  can be locked out.
- nixos-fw accepts `RELATED,ESTABLISHED` early → all outbound tailnet connections
  stay two-way without any tailscale-added rule.
- The tailscale listen UDP port (55500) is globally open.
- **No NixOS host advertises subnet routes or is an exit node** (checked
  `tailscale debug prefs` on doc1/doc2/igpu: `AdvertiseRoutes:null`). The only
  subnet router is **Tower** (Unraid, not NixOS-managed), so turning off
  tailscale's netfilter management breaks no forwarding. A host that DID advertise
  routes / serve as exit node would need its FORWARD + masquerade rules added by
  hand before using `off`.

**Workstations stay `on`.** `epi` and `framework` set `netfilterMode = "on"`
(`hosts/{epi,framework}/configuration.nix`): they roam, reach sunshine/vnc over the
tailnet, and aren't service hosts, so letting tailscaled blanket-accept is simpler
and lower-risk than maintaining per-port pinholes there. (wsl is a non-standard /
roaming dev box — revisit whether it should also be `"on"`.)

### C. Per-service bind off tailscale0 (defence-in-depth)

Even with B, a service can avoid listening on any routable interface. ABS is bound
to the **podman bridge gateway** `10.88.0.1` (`services.audiobookshelf.host`), not
loopback and not `0.0.0.0`:
- the share's caddy sidecar reaches it via `host.docker.internal` (= 10.88.0.1);
- nginx reaches it via `homelab.localProxy.hosts[].upstreamHost = "10.88.0.1"`
  (host-local loopback routing);
- it listens on NO tailnet/LAN IP, so the bare port simply doesn't exist there —
  independent of firewall correctness.
- `boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1` lets ABS bind 10.88.0.1
  before podman0 is up at boot.

`localProxy.upstreamHost` (default `127.0.0.1`) is the reusable knob for any
bridge-bound service.

## Why both, and what `trustedInterfaces` removal still does

`trustedInterfaces` no longer lists tailscale0 (kept that way): with B making
nixos-fw the gate, re-adding the nixos-fw blanket accept would defeat the point.
B is the systematic control; C removes ABS from routable interfaces entirely.

## Gotcha — firewall reload vs the live ruleset

A `nixos-rebuild switch` *reloads* (not restarts) `firewall.service`. During the
ABS work, the reload on a fleet-deploy'd host did not always reconcile a removed
rule in the live ruleset (doc1, via local `fleet-update`, did; doc2 via the
async trigger left a stale rule until the change settled / a reboot). If the live
firewall looks stale after a deploy, a `systemctl restart firewall.service`
(or the host's nightly reboot) reconciles it. Locked siblings can't restart
firewall via sudo, so they reconcile on the nightly reboot.

## Tailscale ACLs (separate, in progress)

Tailnet-level ACLs (admin console / policy file) are the coordination-layer
control over which peers may reach which ports — complementary to B/C and being
set up separately. Not managed in this repo yet.

## Adding a tailnet-reachable service after this change

Server (netfilterMode=off): either put it behind nginx via
`homelab.localProxy.hosts`, or add
`networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ <port> ];` in the
module (see syncthing/sunshine/vnc). Do NOT re-add `trustedInterfaces`.

## Rollback

Per-host: set `homelab.tailscale.netfilterMode = "on";` and redeploy (restores
tailscale's blanket accept). SSH stays up either way, so a bad rollout is fixable
forward with `fleet-deploy <host>`.
