# gtk-gnutella POC on doc2

Date researched: 2026-05-26
Status: browser GUI in progress via Xpra at `gnutella.ablz.au`

## Choice

Options considered:

- `gtk-gnutella`: best fit. Current release in pinned nixpkgs is 1.3.1, Linux-native, packaged, and supports Gnutella plus G2.
- GBun: small CLI Gnutella client, but Gnutella-only and not in nixpkgs.
- Shareaza/Wireshare family: broader protocol support historically, but Linux use is awkward or stale compared with gtk-gnutella.

Use `gtk-gnutella` unless the goal becomes protocol archaeology rather than a quick live-network check.

## NixOS Shape

Module: `modules/nixos/services/gnutella.nix`

Host enablement: `homelab.services.gnutella` on doc2.

The service runs as a dedicated `gnutella` system user with:

- `GTK_GNUTELLA_DIR=/mnt/virtio/gtk-gnutella`
- no shared directories by default (`shared_dirs = ""`)
- listen port `56346`
- browser GUI on loopback port `14546`, proxied as `https://gnutella.ablz.au/`
- Xpra HTML5 transport, because Xpra can run a single X11 app and serve it to a browser
- tailnet-only localProxy exposure; the GUI has no separate app auth
- IPv4 only, because the VPN policy route is IPv4 on `ens19`
- leaf peer mode
- G2 enabled
- UPnP and NAT-PMP disabled

The unit sandboxes `/mnt` with `TemporaryFileSystem=/mnt` and binds only its state directory back in. This keeps the POC from seeing the rest of the virtiofs/NFS tree.

## VPN Routing

doc2 has two NICs:

- `ens18`: main LAN address, `192.168.1.35`
- `ens19`: VPN-policy address, `192.168.1.36`

pfSense policy-routes `192.168.1.36` through the AirVPN WireGuard tunnel via the `MV_VPN_IPS` alias.

The module adds an `ip rule` for the `gnutella` UID into routing table 100. That table routes via `ens19`, matching the existing slskd pattern. The service does not force gtk-gnutella's advertised IP to `192.168.1.36`; advertising a private RFC1918 address would break incoming peer reachability. Let gtk-gnutella infer the external address from the network, especially if a VPN provider port forward is added later.

gtk-gnutella is configured IPv4-only. On first boot before this was set, it discovered doc2's Tailscale IPv6 address and attempted IPv6 bootstrap paths that are not covered by the AirVPN IPv4 policy route. IPv4-only keeps the POC aligned with the known VPN route.

Firewall exposure is limited to TCP/UDP `56346` on `ens19`.

The GUI is exposed through `homelab.localProxy` with websocket support. The vhost is `tailscaleOnly = true`, so nginx binds it only on doc2's Tailscale address and the Cloudflare A record points at that tailnet IP.

## Port Forwarding

Port forwarding is not required for a basic leaf-mode connectivity check, but it improves peer reachability and search/result flow.

If adding an AirVPN/pfSense forward later, forward TCP and UDP port `56346` to `192.168.1.36:56346`. Keep UPnP/NAT-PMP disabled; make the mapping explicit on the VPN side.

## Operations

Check service health:

```bash
systemctl status gtk-gnutella --no-pager
```

Open the local shell:

```bash
sudo -u gnutella env \
  GTK_GNUTELLA_DIR=/mnt/virtio/gtk-gnutella \
  HOME=/mnt/virtio/gtk-gnutella \
  gtk-gnutella --shell
```

Useful shell commands:

```text
status
nodes
horizon
stats
shutdown
```

Upstream shell documentation says `search add <query>` does not fully work in Topless mode because large parts of search and result handling live in the GUI. The service now runs the GTK client under Xpra instead of Topless so real search/result browsing happens in the browser.

Use harmless test searches only, for example `ubuntu`, `debian`, `linux`, `creative commons`, and `public domain`. Do not download copyrighted material during network activity checks.

## Verification

Verified on 2026-05-26 after deploying commit `9a403d34`.

- `gtk-gnutella.service` started and stayed active.
- The process listened on TCP and UDP `56346`.
- The `gnutella` UID had an `ip rule` into table 100.
- `ip route get 1.1.1.1 uid <gnutella-uid>` selected table 100 via `ens19` with source `192.168.1.36`.
- Public IPv4 differed between normal doc2 traffic and `sudo -u gnutella curl`: normal traffic used `61.245.133.220`; gnutella-UID traffic used `203.209.219.82`.
- gtk-gnutella bootstrapped to 4 ultrapeers and 2 G2 hubs within about 2 minutes.
- `horizon` showed live HSEP data, including about 671 nodes / 1.45M files at 2 hops and larger projected horizons beyond that.
- `search add ubuntu` through the Topless shell returned `400 The search could not be created`, matching the upstream note that search creation/result handling is GUI-side.
