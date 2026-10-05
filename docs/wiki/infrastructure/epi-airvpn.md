# AirVPN on epi

Date: 2026-10-05. Status: implementation and live verification in progress.

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

The endpoint is pinned to 103.230.144.102:1637, resolved from
asia3.vpn.airdns.org on 2026-10-05. Pinning avoids a DNS bootstrap dependency
after enabling the guard. Revisit if the gateway stops responding: resolve the
Asia hostname with the VPN deliberately off, update the endpoint and verify
the new handshake. Regenerate the profile if changing AirVPN keys or region.
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
