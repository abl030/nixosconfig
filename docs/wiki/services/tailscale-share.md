# tailscaleShare

**Last updated:** 2026-05-14
**Status:** working, hardened for issue #232 Tier 2; automatic Kuma monitoring added with #216 follow-up
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

## Operational notes

- Do not put a share `dataDir` under an upstream service-owned directory. Use a root-owned parent so the upstream app cannot replace sidecar state.
- Do not enable Caddy admin, Caddy reload sockets, or Tailscale access to Caddy state unless the threat model is rewritten first.
- `NET_ADMIN` remains scoped to the Tailscale sidecar for `/dev/net/tun`; Caddy should not have it.
- Image pinning remains separate Tier 4 work in issue #232.
