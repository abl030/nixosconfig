# gtk-gnutella POC on doc2

Date researched: 2026-05-26
Status: working as a doc2 headless connectivity POC; GUI needed for real search/result browsing

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

Firewall exposure is limited to TCP/UDP `56346` on `ens19`.

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

Upstream shell documentation says `search add <query>` does not fully work in Topless mode because large parts of search and result handling live in the GUI. Use the headless service for connectivity/status checks. For actual search/result browsing, stop the service and run the GTK client over an attached X session or X forwarding under the same `gnutella` user and state directory.

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
