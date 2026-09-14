# Dad NAS login proxy

- Date: 2026-09-14
- Status: configured and validated; operational checks below
- URL: `https://dadnas.ablz.au/` (home LAN or the existing Tailscale home route)
- NAS: `zarepath`, shared by Ian; recipient-side address `100.103.36.101:5000`
- Source: `modules/nixos/services/dadnas-proxy.nix`, `legacy-edge-caddy.nix`, `tailscale/acl.hujson`

## Connection and access

The existing wildcard DNS record resolves `dadnas.ablz.au` to Caddy's LAN address.
Caddy terminates HTTPS and proxies to doc1's fixed TCP relay on port 15000. The
relay runs `tailscale nc 100.103.36.101 5000` through a separate userspace daemon.
Doc1 can also use `http://127.0.0.1:15000/` for diagnostics.

Doc1 and Caddy are tagged servers. Even doc1's unrestricted egress grant cannot
make them eligible to consume a normal incoming machine share: [Tailscale shares
belong to the recipient user](https://tailscale.com/docs/features/sharing).
The separate `dadnas-proxy` identity (`100.93.176.58`) was enrolled as the account
that accepted Dad's share. **Do not tag it.** The fleet hosts retain their tags.

Only doc1 itself and Caddy may connect to the relay: it binds loopback and doc1's
LAN address, with a source-specific host firewall rule and socket IP filters.
The relay destination is fixed; it exposes no forward proxy, SOCKS listener,
SSH service, or NAS file share. Tailscaled and relay processes run under the
dedicated dynamic user `dadnas-tailnet`, with no capabilities or host filesystem
write access beyond Tailscale state. Only Unix sockets may be opened by each
relay worker. Caddy receives no Tailscale credentials.

The Cullen laptop reaches the same HTTPS URL using its existing exact
`192.168.1.6:443` route grant. The [personal-device policy](../infrastructure/tailscale-personal-devices.md)
also permits trusted clients and Cullen directly to NAS TCP 5000 and 5252 once
reauthenticated as the share recipient. Port 5252 is the Tailscale web interface;
the shared recipient receives `canManageNode:false`, not ownership of Dad's NAS.
Other NAS ports and doc1's relay port remain denied to Cullen. DSM requires its
own login. Upstream HTTP crosses Dad's connection inside the Tailscale tunnel.

## State and recovery

Persistent login state is `/var/lib/dadnas-tailnet` (systemd DynamicUser stores it
under `/var/lib/private/dadnas-tailnet`), mode 0700. No auth key is committed or
distributed. The daemon uses userspace networking, leaving doc1's primary
Tailscale daemon, routes, and DNS intact. Initial enrollment uses:

```sh
sudo tailscale --socket=/run/dadnas-tailnet/tailscaled.sock login \
  --hostname=dadnas-proxy --accept-dns=false --accept-routes=false --shields-up
```

If login expires, rerun this command and authenticate as the share recipient.
If the node is deleted/recreated, update its pinned address in `tailscale/acl.hujson`
and validate/apply the policy. If Dad re-shares a recreated NAS, verify the
recipient-side address before updating the relay and policy. Revisit this setup
if Tailscale's normal sharing gains support for tagged consumers.

The `Dad NAS` monitor fetches the real HTTPS login page, exercising the entire
path. Authentication failures also have a log alert. There is no local NAS data
to migrate or deep-probe.

Immediate rollback: `sudo systemctl stop dadnas-relay.socket dadnas-tailnet.service`.
For a persistent rollback, disable `homelab.services.dadnasProxy`, remove the
Caddy vhost and dedicated ACL grant, then deploy the signed revert. Preserve
the state directory unless the Tailscale identity is deliberately being retired.

## Verification

The enrolled identity sees `zarepath`; the upstream and the sandboxed socket
relay both returned HTTP 200 with the `zarepath - Synology DiskStation` page.
Tailscale's policy validation API accepted the full policy including the new
accept/deny tests. Both host toplevels built and `nix flake check` passed.

For the final deployed path, fetch `https://dadnas.ablz.au/` from doc1 and from
`ssh wsl` (Cullen), confirm the DSM page and its script assets, and check that
doc2 cannot connect directly to `192.168.1.29:15000` while Caddy can.
