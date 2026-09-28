# G502 scroll wheel at 1/8 speed after resume (epi)

**Status:** fixed 2026-09-28 with a post-resume driver rebind in
`hosts/epi/configuration.nix` (`powerManagement.resumeCommands`).
**Affects:** epi's Logitech G502 X Plus (`046D:4099`) on the Lightspeed
receiver (`046D:C53A`). Any hid-logitech-hidpp mouse with feature `0x2121` is
exposed the same way.

## Symptom

The scroll wheel is "super slow" everywhere in GNOME. Each notch moves about
1/8 of a normal step. Nothing changed in the config, libinput, or mutter.

## Cause

At probe time, `hid-logitech-hidpp` switches the mouse's HIRES_WHEEL feature
(`0x2121`) to high resolution. It then exports `REL_WHEEL_HI_RES` and divides
by the multiplier (8). After a suspend/resume, the mouse came back with its
wheel mode reset to low-res (`getWheelMode` = `0x00`). The receiver never
disconnected, so the driver saw no connect event and never re-sent the mode.
Each notch now arrived as 1 unit and was scaled as 1/8.

This started once epi began deep-sleeping (first suspend around 2026-09-24,
from GNOME idle suspend plus a nightly wake). The mouse's own wireless reconnect
sometimes restores it; the rebind makes that deterministic.

## Diagnose without root

`/dev/hidraw*` for the receiver carries a uaccess ACL for the seat user, so a
read-only HID++ 2.0 query works unprivileged. On the receiver's `input2` hidraw
node, device index 1:

- root `getFeature(0x2121)` → feature index (8 on this mouse)
- function 0 `getWheelCapability` → multiplier (8), flags
- function 1 `getWheelMode` → bit1 = high resolution. `0x02` is healthy,
  `0x00` is the bug.
- function 2 is **setWheelMode**. Do not call it as a probe.
- function 3 `getRatchetSwitchState`.

Manual one-off recovery: power-cycle the mouse or replug the receiver, or
`setWheelMode(0x02)` over HID++.

## Fix

After every resume, unbind and rebind each `0003:046D:4099.*` device from
`logitech-hidpp-device`. The re-probe re-sends high-res mode exactly as at boot.
The input device is recreated, and mutter picks it up as a hotplug.

Revisit if the kernel starts re-applying wheel mode on resume by itself; drop
the hook then.
