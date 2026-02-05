# Chromecast Reliability Improvements

**Date:** 2026-02-05

## Problem

Chromecast devices unreliable on local network: phone apps losing cast sessions mid-playback, multi-minute delays initiating casts, frequent failures.

## Root Causes Identified

1. **No static DHCP for Cast/infrastructure devices** -- Chromecasts and UniFi APs were on dynamic 2-hour DHCP leases, causing IP changes that break cast session tracking.
2. **WiFi multicast handling** -- UAP-AC series APs send multicast (used by mDNS/Chromecast discovery) at the lowest basic rate with no retransmission, making discovery and keepalives unreliable.

## Changes Made

### pfSense: Static DHCP Mappings

Created static DHCP reservations for all discovered Cast and UniFi infrastructure devices.

**Cast devices:**

| Device | MAC | Static IP |
|--------|-----|-----------|
| chromecast-audio | `a4:77:33:f1:eb:bc` | 192.168.1.14 (pre-existing) |
| chromecast-ultra | `44:09:b8:4f:c1:1a` | 192.168.1.40 |
| google-home | `a4:77:33:bf:69:35` | 192.168.1.41 |

**UniFi infrastructure:**

| Device | MAC | Static IP |
|--------|-----|-----------|
| masterbedroom (AP) | `fc:ec:da:10:b5:4a` | 192.168.1.50 |
| livingroom (AP) | `fc:ec:da:10:b2:41` | 192.168.1.51 |
| hallway (AP) | `fc:ec:da:10:b5:81` | 192.168.1.52 |
| mastswitch | `fc:ec:da:d5:e0:bb` | 192.168.1.53 |
| usw-flex-mini | `f4:e2:c6:58:fc:66` | 192.168.1.54 |

IP allocation scheme: `.40-.49` for Cast devices, `.50-.59` for UniFi infrastructure.

### UniFi Controller: WiFi Optimisations

Applied the following WLAN settings to improve multicast reliability:

- **Multicast Enhancement** -- enabled (converts multicast to unicast on WiFi, preventing packet loss at low basic rates)
- **Block LAN to WLAN Multicast and Broadcast Data** -- disabled (ensures mDNS from wired devices reaches wireless clients)
- **DTIM Period** -- set to 1 for both 2.4GHz and 5GHz (prevents phones in power-save mode from missing multicast keepalives)
- **Minimum Data Rate Control** -- 2.4GHz set to 6 Mbps, 5GHz set to 12 Mbps (raises the floor rate for any remaining multicast traffic)
- **Client Isolation** -- confirmed disabled

### pfSense: Avahi (mDNS Reflector)

Avahi package was already installed. Verified configuration:

- Enabled on LAN interface
- Reflection enabled (needed for HA on IoT VLAN to discover Chromecasts on LAN)
- Supports the existing firewall rule allowing HA (`192.168.101.4`) to reach Chromecast Audio (`192.168.1.14`)

## Outstanding

- Additional Chromecast Audio and Mini devices were not online during this session. When powered on, their MACs need to be captured from DHCP leases and static mappings added in the `.42-.49` range.
- Google Cast MAC OUI prefixes to watch for: `a4:77:33`, `44:09:b8`, `54:60:09`, `f4:f5:d8`, `48:d6:d5`.

## Network Reference

| Network | Subnet | VLAN |
|---------|--------|------|
| LAN | 192.168.1.0/24 | untagged |
| OPT3 | 192.168.11.0/24 | 10 |
| IOT_OF_DEATH | 192.168.101.0/24 | 100 |

All Cast devices and phones are on LAN. Cross-VLAN mDNS is handled by Avahi for HA integration only.
