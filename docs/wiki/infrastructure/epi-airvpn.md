# AirVPN on epi

Date: 2026-10-05. Status: deployed and live verified.

`hosts/epi/airvpn.nix` defines an on-demand NetworkManager WireGuard profile
from the owner's AirVPN Asia UDP/1637 configuration. It has no boot autoconnect.
IPv4 and IPv6 use NetworkManager's WireGuard policy routing, with mark/table
51820. LAN and the existing Tailscale routes remain available.

Use `airvpn on`, `airvpn off`, and `airvpn status`. On/off use the existing
interactive sudo policy; no new passwordless root grant is added. The pre-up
dispatcher also starts the guard for a desktop activation. Prefer the helper:
it checks guard startup before activating the connection.

The independent `airvpn-lock.service` installs a dedicated nftables table.
It survives unexpected disconnects and desktop disconnects. **Use `airvpn off`
to deliberately restore direct WAN access.** It permits LAN destinations
192.168.1.0/24 and 10.20.0.0/24, tailnet traffic, marked encrypted VPN transport,
root-owned Tailscale transport, DHCP and IPv6 neighbour discovery. Both local
output and forwarded internet traffic are guarded. Reboot returns to the
normal direct connection because the VPN and guard do not autostart.

Public DNS uses AirVPN's 10.128.0.1 / fd7d:76ee:e68f:a993::1 resolvers through
a loopback-only Unbound instance at 127.0.0.55. It forwards ablz.au, local.com
and LAN reverse DNS to pfSense; tail13796.ts.net goes to Tailscale MagicDNS.
The guard blocks direct DNS/DoT except the resolver's internal forwards and
DNS inside AirVPN. This avoids public queries escaping through Tailscale's
competing systemd-resolved `~.` route. The local resolver has only bind-service
capability, no raw sockets, no LAN listener and no root-control socket.

The endpoint is resolved, not pinned (since 2026-10-17). `airvpn-prepare`
(run by `airvpn on` and the pre-up dispatcher) resolves asia3.vpn.airdns.org
while direct DNS still works, i.e. only when the guard is not yet active, and
records the IPv4 in `/run/airvpn/endpoint`. `airvpn-apply-endpoint` (guard
`ExecStartPost`, the helper after activation, and the `up` dispatcher) adds it
to the guard's `endpoints` nft set and runs `wg set ... endpoint`. If the
lookup fails, the recorded address or the fallback 185.200.117.133 is used.
A forged DNS answer can only admit one extra IP for marked kernel WireGuard
UDP/1637 packets, which are encrypted to AirVPN's key, so the worst case is no
tunnel rather than a leak.

If the gateway rotates while the guard is up, DNS is blocked and the old
address is kept: run `airvpn off && airvpn on` to re-resolve. Regenerate the
profile if changing AirVPN keys or region.
Keys are in `secrets/hosts/epimetheus/airvpn.env`, encrypted only to epi, the
editor and break-glass recipients. Runtime env/profile files are root-only.
The downloaded plaintext configuration remains owner-controlled in Downloads.

Verification must cover handshake, changed public IPv4 and working tunneled
IPv6, public DNS, internal hostnames, LAN and MagicDNS access. Deliberately
disconnect the interface while leaving the guard active and verify that
direct IPv4/IPv6 and public DNS are blocked, then use `airvpn off` to confirm
direct internet/DNS recovery. Normal NixOS inbound firewall policy stays in
effect; the VPN interface does not grant blanket inbound trust.

Rollback: `airvpn off`, remove the import in `hosts/epi/configuration.nix`,
land the signed rollback and deploy it through the verified fleet path.
Never remove an active guard before deliberately disconnecting the VPN.

## 2026-10-05 activation fix

The original guard required `meta skuid 0` on WireGuard transport. Kernel
WireGuard packets have no socket UID, so the guard rejected the handshake
itself. Match the privileged mark 51820, pinned endpoint 103.230.144.102 and
UDP port 1637 instead. No general WAN exception is needed.

The profile also needs explicit routing domains for the internal zones above:
Tailscale's domain otherwise wins over the VPN's `~.` for MagicDNS, sending
systemd-resolved directly into the DNS guard. Unbound's internal forwarding
already worked; the missing routing domains prevented resolved from using it.

Live checks confirmed a WireGuard handshake, public IPv4 103.230.144.105,
tunneled IPv6, public and internal DNS, and continued SSH access. Disconnecting
the interface with the guard active blocked direct IPv4, IPv6 and public DNS;
`airvpn off` restored normal WAN access.

## 2026-10-17 gateway rotation: SERVFAIL on every public name

Symptom: `airvpn on` succeeded but public DNS returned SERVFAIL. The cause was
not DNS. `asia3.vpn.airdns.org` had rotated from 103.230.144.102 to
185.200.117.133/.130; the old IP still answered ping but ignored WireGuard, so
`wg show airvpn` showed bytes sent, 0 received and no handshake. Unbound had no
reachable 10.128.0.1 and answered SERVFAIL; internal zones still resolved.

Diagnose with `sudo wg show airvpn` first: no `latest handshake` means fix the
tunnel, not the resolver. AirVPN uses one server public key for every gateway,
so only the endpoint changes. The first fix re-pinned the new IP; the
follow-up replaced pinning with activation-time resolution (above).

Gotchas seen while testing live:

- `airvpn-lock` had `Requires=unbound.service`, so stopping or restarting
  unbound also stopped or reloaded the guard: fail-open on stop, and it
  discarded runtime nft additions. It is now `Wants=`. Flush Unbound with
  `systemctl kill -s HUP unbound` anyway; it avoids a cold cache.
- After the tunnel recovers, Unbound keeps its cached upstream failure briefly;
  HUP it rather than waiting.
- Tailscale names resolve as `<tailnet-name>.tail13796.ts.net`; doc1 is
  `proxmox-vm`, not `doc1`.
