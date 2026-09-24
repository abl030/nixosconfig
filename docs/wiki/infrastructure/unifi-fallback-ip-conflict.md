# UniFi fallback IP (192.168.1.20) conflict — Home Assistant outages

**Date:** 2026-09-24
**Status:** Fixed, and the fix was verified by a controlled test the same day.
Forgejo #223 closed.
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

## Mechanism and controlled test (2026-09-24)

About 100 s after the Flex Mini loses its controller, it restarts its network
stack and re-announces its address with a gratuitous ARP. While its management
IP was DHCP, that announcement used the factory fallback `.20` first. It then
asked for its real `.54` from `.20`.

**Test after the switch to a static IP (Flex at `.54`):**
- `unifi.service` on doc2 was stopped for 3 minutes (08:56:35–08:59:28 AWST),
  with doc1 watching ARP from all five UniFi MACs and any frame mentioning `.20`.
- At 08:58:16, 101 s into the outage, the Flex sent `who-has 192.168.1.54 tell
  192.168.1.54` and then asked for the gateway from `.54`. This is the same event
  as the incident, now on its own static address.
- Nothing claimed `.20`, during the outage or in the 3.5 minutes after the
  controller came back.
- All five devices reconnected without rebooting.

The switch's internal logic is still unknown: the firmware is closed and there is
no syslog. Earlier controller restarts probably flipped it unnoticed, because a
flip only broke something when a device held `.20`. To re-test, stop
`unifi.service` on doc2 for more than 2 minutes while running this on doc1:

```bash
tcpdump -i ens18 -nn -e arp and ether src f4:e2:c6:58:fc:66
```

## Missed dependency: zigbee2mqtt

The repo sweep missed tower's zigbee2mqtt container (ipvlan `.22`).
`/mnt/user/appdata/zigbee2mqtt/configuration.yaml` pointed `mqtt.server` at
`mqtt://192.168.1.20:1883`, HA's Mosquitto add-on. After the move it failed
with `EHOSTUNREACH` and dropped Zigbee sensor updates from 07:43 until it was
repointed at `.25` at about 09:05. The watch caught it as `.22` broadcasting
`who-has .20` every second. **When moving HA again, check z2m's `mqtt.server`.**

## Tools used

The Prom ARP capture (`prom-arp-capture@{in,out}`, commits `73cd43be`,
`e9b7c7b2`) caught this recurrence and was then retired. See
[prom-hypervisor.md](prom-hypervisor.md#lan-boundary-arp-capture-retired-2026-09-24).
The same capture also showed doc2's `.35` being answered from both of its NIC
MACs (ARP flux from dual-homing). pfSense logs `.35/.36 moved` every 15–20
minutes. That is unrelated and harmless.
