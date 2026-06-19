# tailscaleShare

**Last updated:** 2026-05-22
**Status:** working, hardened for issue #232 Tier 2; automatic Kuma monitoring added with #216 follow-up; "logged out" alert pattern narrowed 2026-05-22 (see [lgtm-stack.md](./lgtm-stack.md#per-service-errorpattern-alerts--startup-noise-trap))
**Owner:** `modules/nixos/services/tailscale-share.nix`
**Issues:** [#232](https://github.com/abl030/nixosconfig/issues/232), [#216](https://github.com/abl030/nixosconfig/issues/216)

## Purpose

`homelab.tailscaleShare` exposes a single service to another tailnet without sharing the host-wide reverse proxy or the whole VM. Each instance gets:

- a dedicated Tailscale sidecar node and IP
- a Caddy sidecar sharing that network namespace
- a repo-owned FQDN and Cloudflare DNS A record
- Caddy-managed ACME certs through the Cloudflare DNS challenge
- a Uptime Kuma monitor for the tailnet-served HTTPS URL

This is a least-privilege sharing pattern: one pinhole per application, not a broad host proxy.

## Monitoring

Every enabled `tailscaleShare` instance registers a `homelab.monitoring.monitors`
entry for `https://<fqdn><monitorPath>`. Use `monitorPath` for application
health endpoints such as Jellyfin's `/System/Info/Public` or Overseerr's
`/api/v1/status`; otherwise the default `/` is fine. Do not add a separate
manual tailnet monitor in the service module unless the central monitor is
deliberately disabled in a future module change.

## Security boundary

Runtime verification on 2026-05-14 corrected the original concern: Caddy does not inherit `CAP_NET_ADMIN` from the Tailscale sidecar. Linux capabilities are per process/container.

The real boundary risk is shared loopback. Because Caddy joins the Tailscale container's network namespace, anything Caddy exposes on `127.0.0.1` is reachable from the Tailscale sidecar. Caddy's admin API used to listen on `localhost:2019`, so a compromised Tailscale sidecar could fetch or mutate Caddy config.

Current hardening:

- generated Caddyfiles include `admin off`
- Caddy runs as dedicated host identity `tailscale-share-caddy` (`2011:2011`)
- Caddy uses `--security-opt=no-new-privileges`
- Caddy drops default capabilities and retains only `NET_BIND_SERVICE`
- Tailscale auth/state and Caddy Cloudflare/cert state remain separate mounts/env
- share state should live under a root-owned parent, not inside a service-owned app data directory

### Network model vs. per-service isolation (#232, 2026-06-19)

The fleet now auto-isolates every registered OCI container onto its own
`isolated-<name>` bridge (see `docs/wiki/nixos-service-modules.md` →
*Container network isolation*). The tailscale-share sidecars are a **deliberate
`CONTAINER-NETWORK-OK` exception**, registered with `isolate = false`:

- the **caddy** sidecar must share the **ts** sidecar's netns
  (`--network=container:ts-<name>`) — that pairing is the whole point;
- the **ts** sidecar stays on the **default `podman` bridge** because it reaches
  the local upstream via `host.docker.internal` (host-gateway) over a
  `podman0`-scoped firewall rule; moving it to an isolated bridge breaks that
  host-upstream path.

Consequence: after isolation, the **only** containers left on the default
`podman` bridge are these ts sidecars. They can reach each other but **not** the
now-isolated production services (immich, paperless, jellystat, …). Auto-injecting
`--network=isolated-*` here is a footgun — it conflicts with `--network=container:`
and kills the caddy sidecar (it briefly took down overseer/audiobookshelf/jellyfinn
on 2026-06-19 before the `isolate = false` opt-out was added). Keep `isolate = false`.

## Active instances

| Service | Host | FQDN | Data path |
|---|---|---|---|
| Overseerr | `doc2` | `overseer.ablz.au` | `/mnt/virtio/tailscale-share/overseerr` |
| Audiobookshelf | `doc2` | `audiobooks.ablz.au` | `/mnt/virtio/tailscale-share/audiobookshelf` |
| Jellyfin | `igpu` | `jellyfinn.ablz.au` | `/mnt/virtio/jellyfin/ts` |

The Overseerr share state was moved on 2026-05-14 from `/mnt/virtio/overseerr/ts` because `/mnt/virtio/overseerr` is owned by `seerr`. Keeping share state there would let a compromised Overseerr process rename or replace the sidecar state directory.

## Verification Evidence

### Builds and deploys

- Local builds passed for `.#nixosConfigurations.doc2.config.system.build.toplevel`.
- Local builds passed for `.#nixosConfigurations.igpu.config.system.build.toplevel`.
- doc2 deployed from `github:abl030/nixosconfig#doc2 --refresh` at commit `834e943c`.
- igpu deployed from `github:abl030/nixosconfig#igpu --refresh` at commit `834e943c`.

### Reachability

| FQDN | Result |
|---|---|
| `overseer.ablz.au` | `HTTP/2 307`, `location: /login`, `via: 1.1 Caddy` |
| `jellyfinn.ablz.au/System/Info/Public` | Jellyfin `10.11.8`, server `Andy_Jellyfin` |

Public DNS resolved to Tailscale-sidecar IPs during verification:

- `overseer.ablz.au` -> `100.70.211.51`
- `jellyfinn.ablz.au` -> `100.79.179.77`

### Caddy admin API

doc2 direct sidecar probe from `ts-overseerr`:

```text
Connecting to 127.0.0.1:2019 (127.0.0.1:2019)
wget: can't connect to remote host (127.0.0.1): Connection refused
```

igpu verification used the live Caddy netns socket table and Caddy logs because the current SSH account cannot run arbitrary sudo there. The Caddy process netns showed listeners on `:80` and `:443` only, with no `:2019`, and Caddy logged:

```text
admin endpoint disabled
```

The deployed Jellyfin Caddyfile contains:

```caddyfile
{
  admin off
  acme_dns cloudflare {env.CLOUDFLARE_DNS_API_TOKEN}
}
```

### Runtime posture

Both live Caddy processes had:

```text
Uid:        2011    2011    2011    2011
Gid:        2011    2011    2011    2011
CapEff:     0000000000000400
CapBnd:     0000000000000400
NoNewPrivs: 1
```

`0x400` is `CAP_NET_BIND_SERVICE`, the authority needed to bind 80/443.

### State ownership

doc2:

```text
root:root 0:0 755 /mnt/virtio/tailscale-share/overseerr
root:root 0:0 700 /mnt/virtio/tailscale-share/overseerr/ts-state
tailscale-share-caddy:tailscale-share-caddy 2011:2011 750 /mnt/virtio/tailscale-share/overseerr/caddy-data
tailscale-share-caddy:tailscale-share-caddy 2011:2011 750 /mnt/virtio/tailscale-share/overseerr/caddy-config
```

igpu:

```text
root:root 0:0 755 /mnt/virtio/jellyfin/ts
root:root 0:0 750 /mnt/virtio/jellyfin/ts/ts-state
tailscale-share-caddy:tailscale-share-caddy 2011:2011 750 /mnt/virtio/jellyfin/ts/caddy-data
tailscale-share-caddy:tailscale-share-caddy 2011:2011 750 /mnt/virtio/jellyfin/ts/caddy-config
```

### Secret and mount split

doc2 runtime env-name inspection showed:

- `ts-overseerr`: `TS_AUTHKEY`, `TS_EXTRA_ARGS`, `TS_HOSTNAME`, `TS_STATE_DIR`
- `caddy-overseerr`: `CLOUDFLARE_DNS_API_TOKEN`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`

doc2 runtime mounts:

- `ts-overseerr`: `/var/lib/tailscale` from `ts-state`, plus `/dev/net/tun`
- `caddy-overseerr`: `/etc/caddy/Caddyfile`, `/data` from `caddy-data`, `/config` from `caddy-config`

igpu generated systemd start scripts showed the same split:

- `podman-ts-jellyfin`: Tailscale env and `/run/secrets/tailscale-share/jellyfin/authkey`
- `podman-caddy-jellyfin`: Cloudflare env and Caddy-only mounts

## "logged out" alert — false positives and the narrowed pattern

**2026-05-22 RCA.** The `homelab.monitoring.errorPatterns` entry registered by this module used to fire on `(?i)logged out\.|fetch control key.*context canceled`. Both substrings appear in **normal** tailscale-daemon startup output — `health(warnable=login-state): error: You are logged out. The last login error was: fetch control key: ... context canceled` is what a fresh `tailscale` process prints between boot and its first successful key fetch. Every podman auto-update pull-and-restart of a `ts-*` sidecar therefore looked like a real coordinator rejection until 2026-05-22.

The narrowed pattern (committed `modules/nixos/services/tailscale-share.nix:260-280`) matches only operational failure signatures:

```regex
(?i)control:.*(401|unauthorized)|key (expired|rejected|invalid)|auth.*rejected|control: logout
```

…plus `threshold = 1, window = "10m"` as belt-and-suspenders — fires only if 2+ matches land within 10 min, so any remaining one-off won't page. Real auth loss repeats on every coordinator poll; transient startup chatter does not. See [lgtm-stack.md#per-service-errorpattern-alerts--startup-noise-trap](./lgtm-stack.md#per-service-errorpattern-alerts--startup-noise-trap) for the general lesson on errorPattern startup-noise traps.

## Operational notes

- Do not put a share `dataDir` under an upstream service-owned directory. Use a root-owned parent so the upstream app cannot replace sidecar state.
- Do not enable Caddy admin, Caddy reload sockets, or Tailscale access to Caddy state unless the threat model is rewritten first.
- `NET_ADMIN` remains scoped to the Tailscale sidecar for `/dev/net/tun`; Caddy should not have it.
- Image pinning remains separate Tier 4 work in issue #232.
