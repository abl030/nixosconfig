# Dad NAS login proxy

- Date: 2026-09-15
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

## SSH from doc1

On 2026-09-15, NAS TCP 22 was added only for doc1's existing `dadnas-proxy`
identity. Personal clients still have only TCP 5000/5252, and Caddy's fixed relay
still forwards only to DSM. No subnet route or network SSH relay is needed.

SSH is enabled on port 22 in DSM's **Control Panel > Terminal & SNMP > Terminal**.
From doc1, connect as `ibl` using its resident fleet identity:

```sh
ssh dadnas
```

The doc1-only alias is declared in `hosts/proxmox-vm/home.nix`; it selects the
account, fleet key and private Tailscale socket and disables agent forwarding.
For diagnosis before Home Manager installs the alias, the equivalent command is:

```sh
ssh -a -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -o 'ProxyCommand=sudo -n -u dadnas-tailnet tailscale --socket=/run/dadnas-tailnet/tailscaled.sock nc 100.103.36.101 22' ibl@100.103.36.101
```

The proxy process runs as the existing daemon user. Its socket directory is
mode 0700, so access requires doc1's existing sudo privileges. SSH authentication
still belongs to DSM; no NAS credentials are stored by this change. The command
disables SSH agent forwarding so Dad's NAS cannot use doc1's agent. The dedicated
identity now has SSH reachability as well as DSM, so compromise of that daemon
could attempt NAS SSH authentication. It still has no network grant into the fleet.
To revoke this access, remove `tcp:22` from the `dadnas-proxy` grant, restore its
deny test, and deploy the signed policy correction through doc1's fleet update.

Verified at 07:54 AWST: signed commit `e9c90fd1` is running on doc1, the deployed
policy file and live control-plane policy match, and `nix flake check` plus the
server-side policy tests passed. Doc1's proxy reached NAS port 22 and received
`connection was refused`; DSM SSH was not yet accepting connections. The HTTPS
login remained HTTP 200. Personal-device SSH deny tests passed; Framework was
unreachable for a separate live negative probe. No NAS login was attempted.

At 08:04 AWST, Andrew installed doc1's fleet public key with `ssh-copy-id` as
`ibl`. Both the installed public key and the private key's derived public half
were checked against `fleetIdentity` in `hosts.nix`. A subsequent SSH command
with `BatchMode=yes`, public-key-only authentication, strict host-key checking
and agent forwarding disabled returned user `ibl` and hostname `zarepath`.
The private key remains on doc1. Andrew accepted the NAS ED25519 host fingerprint
`SHA256:+hx9jA45kZpcQW3w768MMQUtRSL2Rdz8e8cM+AWMe+w` during installation.

## Subnet routing

2026-09-15 preflight: DSM 7.4 build 90075; NAS LAN address `192.168.2.174/24`
on `eth0`, gateway `192.168.2.1`. Tailscale 1.58.2 is installed at
`/var/packages/Tailscale/target/bin/tailscale`, outside `ibl`'s normal PATH.
At preflight, no routes were advertised. `accept-routes=true`, `accept-dns=true`,
SNAT enabled, shields down, no tags, and Tailscale SSH disabled were observed.

Status: advertised and approved in Dad's tailnet at 08:15 AWST; cross-tailnet
LAN access is unavailable through machine sharing. Andrew ran the command below
and approved the route in Dad's console. `ibl` can log in with the fleet key but
`sudo -n` requires a password; the unprivileged `tailscale set` attempt returned
`checkprefs access denied` and made no change. Run from doc1 and enter the NAS
password interactively:

```sh
ssh -t dadnas 'sudo /var/packages/Tailscale/target/bin/tailscale set --advertise-routes=192.168.2.0/24'
```

Approve `192.168.2.0/24` on `zarepath` in Dad's console. This command changes
only the advertised routes, preserving other preferences and adding no exit route.
Rollback uses the same command with `--advertise-routes=`.

The package currently runs in userspace mode without `/dev/net/tun`. Synology's
subnet forwarding uses Tailscale's network stack, so enabling kernel IP forwarding
or restarting the daemon to create a TUN device is unnecessary for this operation.
See the [version-matched routing implementation](https://github.com/tailscale/tailscale/blob/v1.58.2/cmd/tailscaled/tailscaled.go#L563-L580)
and [forwarding check](https://github.com/tailscale/tailscale/blob/v1.58.2/ipn/ipnlocal/local.go#L4748-L4757).

The route belongs to Dad's tailnet. [Machine sharing does not export subnet
routes](https://tailscale.com/docs/features/sharing#sharing-and-subnets-subnet-routers)
into Andrew's tailnet. Our existing `192.168.2.0/24` route belongs to the separate
[Raspberry Pi](../infrastructure/raspberrypi-dad-pizero.md); approving this NAS in
Dad's console does not replace that route. Verify forwarding from a client joined
to Dad's tailnet after approval, using a known LAN TCP service rather than relying
only on ping. Re-read advertised routes and confirm SSH/DSM still work.

Live verification at 08:15 AWST: `AdvertiseRoutes`, `Self.PrimaryRoutes` and
`Self.AllowedIPs` contain `192.168.2.0/24`; backend state is `Running`, health
has no warnings, and the SSH connection remains functional. The NAS's native
address in Dad's tailnet is `100.103.36.102`; its shared address in ours remains
`100.103.36.101`. Keep the SSH alias and relay pinned to the recipient address.
Our Raspberry Pi still has `192.168.2.0/24` assigned but is offline, last seen
2026-06-21. No forwarding test from a client joined to Dad's tailnet has been run.

The recipient-side peer map was also checked: the NAS has only its own IPv4/IPv6
host prefixes in `AllowedIPs`, with no `PrimaryRoutes`. A local OS route cannot
make the shared peer carry the LAN prefix. An initial SSH forwarding probe,
`ssh -W 192.168.2.1:80 dadnas`, was rejected with `administratively prohibited`.
DSM's SSH configuration disabled forwarding for `ibl`.

At 08:31 AWST, Andrew enabled local TCP forwarding for `ibl` by appending this
block to `/etc/ssh/sshd_config`, validating with `sudo /usr/bin/sshd -t`, and
running `sudo systemctl reload sshd.service`:

```sshconfig
Match User ibl
    AllowTcpForwarding local
    AllowAgentForwarding no
```

Verified afterward: a fresh `ssh -W 192.168.2.1:80 dadnas` connection carried an
HTTP HEAD request to Dad's router and returned `HTTP/1.0 200 OK`. Normal key-only
SSH still returned `ibl` / `zarepath`, and `sshd.service` was active with a
successful reload. This provides TCP access from doc1 through the NAS to LAN
destinations; it does not export Dad's subnet route into our tailnet. No persistent
tunnel or listener was created. Agent forwarding remains disabled. To revoke
this forwarding permission, remove the `Match User ibl` block, validate, and reload
SSHD. A pre-change backup exists at `/etc/ssh/sshd_config.backup.20260915-082158`.

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
