# Plan: Per-Host Local Proxy + Cloudflare DNS (ablz.au)

## Goals (MVP)
- Each stack declares desired hostname(s) and **proxy port(s)** in its `docker-compose.nix`.
- Each host runs a single Nginx instance (via `homelab.nginx`) on :80/:443 that reverse-proxies all stacks on that host.
- Host updates Cloudflare DNS **A** record for each stack hostname to the host **local IPv4** from `hosts.nix`.
- ACME via existing Cloudflare DNS-01 (homelab.nginx) continues to work.
- DNS updates are **stateful** to avoid Cloudflare API spam.
- DNS TTL is **60 seconds**.

## Non-Goals / Later Wishlist
- Per-stack Caddyfile overrides in stack definitions (out of scope).
- Automatic cleanup of old host records when stacks move (wishlist unless trivial).
- Multi-zone support (future; only `ablz.au` now).

## High-Level Design
- Extend `homelab.nginx` (or a sibling homelab module) to:
  - Accept a generated list of stack hostnames with backend targets per host.
  - Auto-generate Nginx vhosts for those hostnames.
  - Request ACME certs for each hostname via existing `security.acme` defaults.
- Add a Cloudflare DNS reconciler service (systemd oneshot) triggered on rebuild:
  - Reads desired hostname list for the host.
  - Compares to last-applied cache stored under `/var/lib/homelab/dns`.
  - Updates Cloudflare DNS A records only when the value changes.

## Proposed Nix Options / Data Model
### 1) Host-local IP source (in `hosts.nix`)
- Add new field for each host:
  - `localIp = "192.168.x.y";`
- Plumb to a module option:
  - `homelab.localIp = <value>;`

### 2) Stack hostname + port declaration (in stack `docker-compose.nix`)
- Extend `podman.mkService` to accept:
  - `stackHosts = [
      { host = "immich.ablz.au"; port = 2283; }
    ];`
- Each stack adds its desired hostname(s) and proxy ports here.

### 3) Aggregation point
- Add a per-host derived list:
  - `config.homelab.localProxy.hosts = [ { host = "immich.ablz.au"; port = 2283; } ... ];`
- Convert to upstreams in nginx config: `http://127.0.0.1:${port}`.

## Nginx Integration
- Extend `homelab.nginx` to accept extra vhosts:
  - `services.nginx.virtualHosts."<host>" = { useACMEHost = host; forceSSL = true; locations."/".proxyPass = "http://127.0.0.1:${port}"; }`
- Ensure `security.acme.certs` includes these hostnames.
- Avoid list-order reliance; use `lib.mkOrder` if any lists are merged.

## Cloudflare DNS Reconciler (Stateful)
### Behavior
- For each hostname in `homelab.localProxy.hosts`:
  - Ensure DNS A record exists for the hostname in zone `ablz.au`.
  - Set content to host `localIp`.
  - Set `proxied = false`, TTL **60 seconds**.
- Use a cache file to avoid updates when unchanged:
  - `/var/lib/homelab/dns/records.json`
  - Store `{ hostname: { ip: "x.x.x.x", recordId: "...", ttl: 60 } }`.

### Implementation Sketch
- Systemd oneshot service (root) triggered on rebuild.
- Script (writeTextFile) that:
  - Queries Cloudflare zone ID for `ablz.au` once (cache it in `/var/lib/homelab/dns/zone-id`).
  - Reads desired hostnames + `localIp`.
  - Compares to cache; only update if value changed or missing.
  - Writes updated cache on success.

## Files to Touch (MVP)
- `modules/nixos/services/nginx.nix` or new module under `modules/nixos/services/local-proxy.nix`.
- `modules/nixos/homelab/containers/lib/podman-compose.nix` (extend mkService to accept `stackHosts`).
- `modules/nixos/homelab/containers/stacks.nix` (aggregate stack hostnames/ports into host-wide list).
- `hosts.nix` (add `localIp` per host).
- Possibly `modules/nixos/services/default.nix` to include new module.

## Testing Plan
1) Run `check --hosts <target>`.
2) Deploy to a test host: `nixos-rebuild switch --flake .#<host>`.
3) Verify DNS entry:
   - `dig +short immich.ablz.au` should return the host local IP.
4) Verify Nginx routing:
   - `curl -k https://immich.ablz.au/` should reach the stack.
5) Validate no Cloudflare spam:
   - Re-run `nixos-rebuild switch`; ensure DNS updater reports “no change”.

## Passwordless Sudo Commands (for testing)
- `sudo nixos-rebuild switch --flake .#<host>`
- `sudo systemctl status nginx`
- `sudo journalctl -u nginx -n 100 --no-pager`
- `sudo journalctl -u homelab-dns-sync -n 200 --no-pager` (name TBD)
- `sudo systemctl status homelab-dns-sync` (name TBD)

## Open Questions / Assumptions
- None for MVP (TTL=60s, DNS sync on rebuild, port declared in stack).

