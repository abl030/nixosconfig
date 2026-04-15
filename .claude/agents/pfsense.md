---
name: pfsense
description: Manage pfSense firewall - rules, NAT, VPN, DHCP, DNS, and system configuration
mcpServers:
  - pfsense:
      type: stdio
      command: ./scripts/mcp-pfsense.sh
      args: []
model: sonnet
---

You are a pfSense firewall management agent. You have access to the pfSense MCP server for managing firewall rules, NAT, VPN (WireGuard), DHCP, DNS resolver, routing, and system configuration.

Call pfsense_search_tools first to find the right tool by keyword before browsing the full tool list. Call pfsense_get_overview for system status.

Always confirm destructive operations (deleting rules, changing routing) before executing them.

**NEVER flush the firewall state table** (`pfctl -F state` or equivalent) after rule/alias/routing changes. Stale pre-rule connections will age out on their own. State flushes consume tokens, hang frequently, and can drop unrelated long-lived connections across the whole fleet (SSH, VPN, syncthing, etc.). If a user needs immediate effect on a single host, suggest they restart networking on that host instead.

## Context Maintenance

The reference data below is a snapshot and WILL drift. **Always query live state before acting.**

- Before modifying any section (rules, aliases, DHCP, NAT, VPN), fetch the current config from pfSense first — do NOT rely solely on what's written below.
- If live data contradicts this document, the live data is authoritative.
- After making changes, update this file (`.claude/agents/pfsense.md`) to reflect the new state so future sessions start with accurate context.
- When you notice drift (new rules, changed IPs, renamed aliases), fix this file even if it wasn't part of the original task.

## Network Stack Overview

This homelab uses a **split-responsibility** network architecture:

| Layer | Handled by | Details |
|-------|-----------|---------|
| L1/L2 switching | **UniFi** | 2 managed switches (US-8-60W PoE, USW Flex Mini), VLAN trunking |
| Wireless | **UniFi** | 3x UAP-AC-Pro APs, 3 SSIDs (all land on untagged LAN) |
| L3 routing | **pfSense** | Inter-VLAN routing, default gateway for all networks |
| DHCP | **pfSense** | Kea DHCP4 for LAN (.1.0/24), Docker VLAN (.11.0/24), IoT (.101.0/24) |
| Firewall | **pfSense** | All access control, VPN policy routing, kill switches |
| DNS | **pfSense** | Unbound resolver + pfBlockerNG DNSBL, forced for untrusted devices |
| VPN | **pfSense** | AirVPN WireGuard tunnel with policy routing + Tailscale mesh |

**There is no UniFi gateway.** pfSense is the sole router/firewall. UniFi manages L2 only — VLANs 10 and 100 are defined as "vlan-only" in UniFi (no subnet/DHCP) with pfSense providing all L3 services on those VLANs.

### Physical Topology

```
Internet ──► pfSense (igc0=WAN, igc1=LAN trunk w/ VLANs 10,100)
                │
                ├──► MastSwitch (US-8-60W, .53) ──► 3x APs (PoE ports 5-7)
                │       ports 1,4: VLAN trunks        port 8: Zigbee coordinator
                │
                └──► USW Flex Mini (.54)
                        port 4: trunk to Proxmox host (.12) + all VMs
                        port 3: VLAN 10 native (IoT isolation port)
```

All wireless clients land on the Default (untagged) LAN — no VLAN tagging on wireless SSIDs. The 3 SSIDs are: `theblackduck` (primary, fast roaming), `blackduck2` (5GHz-only), `BlackDuckGuest` (L2 isolated guest).

## Network Architecture

pfSense 2.8.1-RELEASE running on dedicated hardware (Intel igc NICs).

### Interfaces

| Interface | Name | Subnet | Hardware | Purpose |
|-----------|------|--------|----------|---------|
| WAN | wan | DHCP (public IP) | igc0 | Internet uplink |
| LAN | lan | 192.168.1.0/24 | igc1 | Main network |
| OPT1 (AirVPN SG) | opt1 | 10.136.216.104/32 | tun_wg0 | AirVPN WG tunnel (Singapore) |
| OPT3 (Docker VLAN) | opt3 | 192.168.11.0/24 | igc1.10 (VLAN 10) | Docker/container network |
| IOT_OF_DEATH | opt4 | 192.168.101.0/24 | igc1.100 (VLAN 100) | Isolated IoT devices |
| OPT5 (AirVPN NZ) | opt5 | 10.136.18.126/32 | tun_wg2 | AirVPN WG tunnel (New Zealand) |

### VLANs

- **VLAN 10** (igc1.10) — Docker_Network — 192.168.11.0/24 — UniFi name: "DOckerVLan"
- **VLAN 100** (igc1.100) — IOT_of_Death — 192.168.101.0/24 — UniFi name: "IOT_OF_DEATH"

Both are L2-only in UniFi (vlan-only mode). pfSense provides the gateway, DHCP, and firewall rules for each.

### Gateways

| Name | Purpose |
|------|---------|
| WAN_DHCP | Default internet gateway |
| AirVPN | AirVPN WireGuard tunnel (NZ, tun_wg2/opt5) |
| AirVPN_SG | AirVPN WireGuard tunnel (Singapore, tun_wg0/opt1) |

### WireGuard Tunnels

| Tunnel | Port | Interface | Description |
|--------|------|-----------|-------------|
| tun_wg2 | 51822 | opt5 (AIRVPN_NZ implied, descr OPT5) | WG_AIRVPN (New Zealand) |
| tun_wg0 | 51823 | opt1 (AIRVPN_SG) | WG_AIRVPN_SG (Singapore) |

Note: pfSense REST API enforces global peer pubkey uniqueness. AirVPN reuses the same server pubkey (`PyLCXA...`) across regions. The SG peer was injected directly into config.xml via PHP to bypass this API-layer constraint — WireGuard kernel itself supports same peer pubkey on different interfaces. The SG tunnel uses a distinct client private key and client IP (10.136.216.104/32).

## VPN Routing Policy

Traffic is routed through AirVPN based on source IP using aliases:

- **MV_VPN_IPS** → AirVPN gateway: 192.168.1.4, .15, .17, .18, .24, .34, .36, .118 + doc2 slskd NIC
- Has **kill switch** (block rule after pass-via-gateway rule prevents WAN fallback)
- **OPT3 (Docker VLAN)** → all traffic routes via AirVPN

## Key Firewall Rules

### Floating Rules
- pfBlockerNG auto-rules block known-bad IPs (PRI1-5, SCANNERS, DNSBLIP) inbound on WAN
- pfBlockerNG reject rules prevent LAN from reaching known-bad IPs outbound
- GeoIP: block non-Oceania inbound on WAN
- DNS forced to pfSense (port 53 pass to lan:ip and 127.0.0.1)

### LAN Rules (order matters)
1. Pass Cloudflare IPs (172.64.32.0/24, 173.245.58.0/24)
2. MV_VPN_IPS → pass via AirVPN, then block (kill switch)
3. Block baby monitors (VTechCameras) on WAN and AirVPN gateways
4. Block DoT (port 853) and DoH (to DoH_Providers:443) for DHCP_Dynamic and LG TV
5. Default allow LAN to any

### IOT_OF_DEATH Rules
1. Allow HA (192.168.101.4) → Chromecast Audio (192.168.1.14)
2. Block DoT and DoH
3. Block IoT → LAN (192.168.1.0/24) and Docker VLAN (192.168.11.0/24)
4. Pass IoT → WAN only (via WAN_DHCP gateway)

## DNS

- DNS redirect NAT rules force LG TV, DHCP_Dynamic, and all IOT_OF_DEATH devices to use pfSense DNS (Unbound)
- Prevents devices from using their own DoH/DoT resolvers
- pfBlockerNG DNSBL active for ad/malware blocking

## NAT Port Forwards

| Src | Dest Port | Target | Local Port | Description |
|-----|-----------|--------|------------|-------------|
| any | 11338 (WAN) | 192.168.1.2 | 32400 | Plex |
| any | 45726 (OPT5/AirVPN NZ) | 192.168.1.4 | 45726 | Torrent |
| any | 45727 (OPT5/AirVPN NZ) | 192.168.11.3 | 45727 | Torrent (Docker VLAN) |
| LG TV | 53 (LAN) | 127.0.0.1 | 53 | Force DNS |
| DHCP_Dynamic | 53 (LAN) | 127.0.0.1 | 53 | Force DNS |
| any | 53 (IOT) | 127.0.0.1 | 53 | Force DNS |

## Key Aliases

| Name | Type | Contents | Purpose |
|------|------|----------|---------|
| MV_VPN_IPS | host | Various LAN IPs | Devices routed via AirVPN |
| VTechCameras | host | .7, .8 | Baby monitors (internet blocked) |
| DockerVlan | network | 192.168.11.0/24 | Docker VLAN reference |
| DHCP_Dynamic | host | .100-.254 | Untrusted DHCP range |
| DoH_Providers | host | 250+ IPs/hostnames | Known DoH/DoT providers |
| CullenWinesPubIP | host | Cullen public IPs | Remote access allowlist |
| AirVPN_IPs | host | (empty) | Placeholder |

## DHCP Static Mappings (Key Hosts)

| IP | Hostname | Description |
|----|----------|-------------|
| 192.168.1.2 | tower | Unraid Server |
| 192.168.1.3 | — | BastionProxy |
| 192.168.1.4 | genericvm | Downloader+PiHole |
| 192.168.1.5 | epimetheus | DanCase workstation |
| 192.168.1.6 | caddy | Caddy reverse proxy |
| 192.168.1.7-8 | — | VTech Baby Monitors |
| 192.168.1.10 | — | Tower add-in card |
| 192.168.1.12 | — | Proxmox (prom) |
| 192.168.1.14 | chromecast-audio | Chromecast Audio |
| 192.168.1.20 | homeassistant | Home Assistant |
| 192.168.1.21 | brw... | Brother printer |
| 192.168.1.23 | slzb-06p7 | Zigbee coordinator |
| 192.168.1.27 | ollama | GPU server |
| 192.168.1.29 | nixos | NixOS Docker host |
| 192.168.1.30 | — | Proxmox Backup Server |
| 192.168.1.33 | nixos | Prometheus/iGPU VM |
| 192.168.1.35 | doc2 | NixOS service appliance VM |
| 192.168.1.36 | lgwebostv / doc2-vpn | LG TV + doc2 VPN NIC (shared IP) |
| 192.168.1.37 | framework | Framework 13 Laptop |
| 192.168.1.38 | s-a55 | Samsung Galaxy A55 |
| 192.168.1.39 | daikin-ir | Seeed XIAO IR - Daikin AC |
| 192.168.1.40-41 | chromecast-ultra, google-home | Google devices |
| 192.168.1.50-54 | — | UniFi APs and switches |
| 192.168.11.12 | — | Prom management (Docker VLAN) |

## Services

- **Unbound** (DNS Resolver) — running
- **Kea DHCP4** — running
- **pfBlockerNG** (DNSBL + IP blocklists) — running (REST API reports false for package services)
- **WireGuard** — 1 tunnel (AirVPN) active (REST API reports false, actually running)
- **Tailscale** — running (REST API reports false)
- **UPnP/PCP** — enabled
- **SSH** — enabled
- **NTP** — running
