# UniFi fallback IP (192.168.1.20) conflict — Home Assistant outages

**Date:** 2026-09-24
**Status:** Fixed. Forgejo #223 closed.
**Revisit:** if HA, or anything else on the LAN, logs an IPv4 address conflict
naming a Ubiquiti MAC.

## Summary

`192.168.1.20` is the Ubiquiti factory fallback address. The USW Flex Mini
(`f4:e2:c6:58:fc:66`, real address `.54`) came up on it briefly each time its
UniFi controller on doc2 went away. Home Assistant OS held `.20`, so its
NetworkManager conflict detection (RFC 5227 ACD) saw a second owner. It
declined the address and dropped IPv4 entirely. HAOS 18.x ships NetworkManager
1.50.2, whose DHCP retry bug (home-assistant/operating-system#5028) left it
without an address for hours.

## Evidence

**Packet capture on Prom `enp8s0`, 2026-09-24 (AWST):**
- At 04:40:59.343, a broadcast `who-has 192.168.1.20 tell 192.168.1.20` arrived
  *inbound* from the Flex side, Ethernet source `f4:e2:c6:58:fc:66`.
- At 04:40:59.352, a unicast `Reply 192.168.1.20 is-at f4:e2:c6:58:fc:66`
  arrived for HA (`52:54:00:1e:59:c6`).
- Straight after, the same MAC sent `who-has .40/.155/.54/.106 tell .20`. It was
  asking for its own real address, `.54`, from the fallback address.
- No frame claiming `.20` with any MAC other than HA's left Prom, so Prom and its
  guests were not the source.
- HA answered for `.20` until 04:47. It then stopped, and by 06:34 its only
  address was the internal `172.30.232.1` hassio bridge.

**pfSense kernel log:**
- `2026-09-24 04:40:59 arp: 192.168.1.20 moved from 52:54:00:1e:59:c6 to
  f4:e2:c6:58:fc:66 on igc1`, reverted at 04:48:52.
- Also `2026-09-22 03:28:16`, reverted at 03:38:02.

**What set it off each time — the controller was unavailable:**
- **2026-09-24:** doc2's nightly `nixos-upgrade` restarted `unifi.service` at
  about 04:39, 04:40:51 and 04:42:39 (10.6.101 to 10.6.106). The flip came 8 s
  after the 04:40:51 start. UniFi then reprovisioned MastSwitch at 04:43:04 and
  the Flex Mini re-informed at 04:44:47. Neither switch rebooted.
- **2026-09-22:** the flip came during Prom's vzdump snapshot backup of doc2
  (VM 114, 03:25:38–03:35:01), when the guest filesystem freeze stalls the
  controller. HA's own backup did not trigger it on either night.

The Flex Mini runs its own microcontroller firmware, not Linux. Firmware 2.1.6.762
was the latest and only build as of September 2026. No DHCP guard, snooping or
ARP-inspection setting exists for this hardware, and Ubiquiti documents none of
this behaviour.

## Fix (2026-09-24)

- **HA moved to `192.168.1.25`:** pfSense Kea static mapping id 15, the caddy
  upstream in `modules/nixos/services/legacy-edge-caddy.nix`, and the tower
  `VMBackups` NFS rw rule.
- **`.20` is held by a pfSense Kea static mapping** on placeholder MAC
  `00:00:00:00:00:04`. pfSense rejects duplicate static IPs, so `.20` cannot be
  handed out again. **Never assign `192.168.1.20` on this LAN.**
- **Every UniFi device now has a static management IP** in UniFi: the Flex Mini
  `.54`, MastSwitch `.53`, and the APs `.50`–`.52`. They no longer depend on DHCP,
  and the pfSense reservations stay as a matching record. None of them rebooted.
  The procedure is in `.claude/agents/unifi.md`.
- **HA conflict detection is off:** `ipv4.dad-timeout 0` on HA's `Supervisor
  enp6s18` NetworkManager connection. A stray ARP can no longer make HA drop its
  address. The Supervisor owns this connection; if `ha network update` or the UI
  network page rewrites it, reapply the setting:

  ```bash
  ssh abl030@192.168.1.25 'sudo docker run --rm -v /run/dbus:/run/dbus alpine:3 sh -c \
    "apk add -q networkmanager-cli && nmcli con mod \"Supervisor enp6s18\" ipv4.dad-timeout 0 && \
     nmcli -f ipv4.dad-timeout con show \"Supervisor enp6s18\""'
  ```

  The SSH add-on has no `nmcli` and cannot enter the host namespace. The
  throwaway container above uses the host D-Bus socket instead.

## Open question: why the Flex Mini fell back

The trigger is established, since both flips happened while the controller was
unavailable. The mechanism inside the switch is not, because its firmware is
closed and it keeps no syslog.

- **When:** on 2026-09-24 the flip came about 95 s into a controller outage. On
  2026-09-22 it came about 2.5 minutes into doc2's backup freeze.
- **What it did:** the Flex announced `.20`, then asked for its own real `.54`
  from `.20`. That looks like its network setup running again with the
  factory default applied first, before the DHCP address was reconfirmed.
- **What stays unknown:**
  - whether it actually sent DHCP (Kea's per-packet log is not exposed through
    the pfSense API);
  - why earlier controller restarts caused no flip that anyone noticed. A flip
    only broke something if a device held `.20`, and HA did. Many past flips
    may have gone unseen.
- **Current exposure:** every device now has a static IP, and `.20` is held by
  a pfSense placeholder with nothing live on it. A future flip should either not
  happen or have nothing to collide with.
- **How to test:** restart `unifi.service` on doc2 while running `tcpdump -nn -e
  arp and ether src f4:e2:c6:58:fc:66` on doc1. doc1 sees the broadcast
  gratuitous ARP.

## Tools used

The Prom ARP capture (`prom-arp-capture@{in,out}`, commits `73cd43be`,
`e9b7c7b2`) caught this recurrence and was then retired. See
[prom-hypervisor.md](prom-hypervisor.md#lan-boundary-arp-capture-retired-2026-09-24).
The same capture also showed doc2's `.35` being answered from both of its NIC
MACs (ARP flux from dual-homing). pfSense logs `.35/.36 moved` every 15–20
minutes. That is unrelated and harmless.
