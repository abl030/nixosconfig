# Indoor Water Meter

- **Date:** 2026-07-27
- **Status:** Paused after bench commissioning. The ESP32 input, Home Assistant
  integration, persistence, and OTA path work. The reed is not connected to the
  two loose field wires, and no water-driven pulse or flow has been observed.
- **Tracker:** [`docs/todo/indoor-water-meter.md`](../../todo/indoor-water-meter.md)
- **Firmware source:** [`ha/esphome/water-meter.yaml`](../../../ha/esphome/water-meter.yaml)

## Current physical state

The generic ESP32 DevKit is powered temporarily from `framework` over USB. Its
two screw-terminal field wires are connected to the board terminals labelled
`D27` (GPIO27) and `GND`, but their far ends are loose. The passive two-wire reed
must eventually connect across those two wires. Polarity does not matter.

Unplugging the USB cable is safe after the 2026-07-27 persistence tests, but it
removes the board's only current power source. At installation, move it directly
to a stable USB power supply; do not expect it to remain online while unplugged.

## What was proved

At 15:29 AWST, touching the two loose field wires together for about one second
produced one clean diagnostic sequence:

1. `Reed Contact` changed from `off` to `on`.
2. `Lifetime Pulses` changed from `0` to `1`.
3. Separating the wires changed `Reed Contact` back to `off`.
4. No contact bounce or duplicate pulse was recorded with the 10 ms filter.

This proves the GPIO27 input, internal pull-up, inversion, GND path, screw
terminals, field wires, firmware input logic, and debounce. It does **not** prove
the reed, its meter mounting/position, the meter's pulse constant, or real flow.
The persisted count of `1` is a synthetic commissioning pulse, not one litre of
measured water.

The count was then allowed to pass the one-minute preference flush interval. It
survived both:

- a CP2102/RTS hardware-style ESP32 reset at 15:31 AWST; and
- an authenticated ESPHome OTA upload at 15:32 AWST.

## Firmware and persistence

The tracked ESPHome configuration uses:

- GPIO27 with input pull-up and inversion, so a dry contact to GND is `on`;
- `pulse_meter` in `PULSE` filter mode with a 10 ms filter;
- live flow in L/min;
- an NVS-restored `uint64_t` raw lifetime pulse count;
- derived lifetime litres and cubic metres;
- encrypted native API, authenticated OTA, Wi-Fi secrets, and a secured fallback
  access point.

`pulse_meter`'s own total is session-only. Each session delta is therefore added
to the restored raw global. ESPHome checks the global for changes once per
second, while `preferences.flash_write_interval: 1min` coalesces flash writes.
A graceful reboot or OTA shutdown also synchronizes preferences. This bounds
flash wear to at most one scheduled write per minute, with a roughly one-minute
worst-case pulse-loss window during sudden power loss.

## Home Assistant

The loaded ESPHome integration exposes:

| Entity | Purpose | HA metadata |
|---|---|---|
| `binary_sensor.indoor_water_meter_reed_contact` | Direct electrical state; `on` means GPIO27 is grounded | diagnostic |
| `sensor.indoor_water_meter_flow_rate` | Live flow | `L/min`, `volume_flow_rate`, `measurement` |
| `sensor.indoor_water_meter_lifetime_pulses` | Restored raw pulse count | `pulses`, `total_increasing`, diagnostic |
| `sensor.indoor_water_meter_total_water_litres` | Converted cumulative usage | `L`, `water`, `total_increasing` |
| `sensor.indoor_water_meter_total_water` | Water-dashboard source | `m³`, `water`, `total_increasing` |

Recorder statistics are active for the cubic-metre entity. Its current
`0.001 m³` state comes only from the synthetic test pulse and the temporary
one-pulse-per-litre conversion; it is not authoritative water usage. Before
using it for reporting, settle the real conversion and account for/reset the
commissioning pulse and its initial statistic.

The device is on the work LAN at the DHCP-assigned address
`192.168.100.89`. Home Assistant reaches only TCP 6053 (encrypted ESPHome API)
and TCP 3232 (authenticated OTA) over the existing routed work subnet. The
Tailscale policy deliberately does not grant the rest of that subnet or the
fallback captive portal. Reserve this address to ESP32 MAC
`30:76:F5:F4:22:FC`; if DHCP changes it first, update the `water-meter` alias in
`tailscale/acl.hujson` and the HA integration host.

Secrets remain only in `/config/esphome/secrets.yaml` on Home Assistant OS. Do
not put the Wi-Fi password, API encryption key, OTA password, or fallback-AP
password in this repository.

## Resume procedure

1. Power the ESP32 from its intended stable USB supply near the meter and verify
   that the integration becomes available.
2. Inspect the meter label, pulse-output plate, and manufacturer datasheet for
   markings such as `1 pulse = X L`, `X imp/L`, or `X imp/m³`.
3. Connect the two loose field wires to the passive reed. Polarity does not
   matter. Secure the cable so movement cannot pull on the screw terminals.
4. Watch `Reed Contact` and `Lifetime Pulses` while passing enough measured water
   to guarantee at least several pulses for the documented constant.
5. If the direct short still works but no meter pulse appears, inspect reed
   continuity with a magnet/meter and correct its mounting over the meter's
   magnet before changing firmware.
6. Confirm one real reed closure produces exactly one raw pulse.
7. Determine `pulses_per_litre`, update the substitution, validate, compile, and
   upload over authenticated OTA.
8. Remove or account for the one synthetic commissioning pulse before treating
   cumulative water statistics as authoritative.

## Calibration and maths

The temporary setting is:

```yaml
substitutions:
  pulses_per_litre: "1"
```

It exists only so the pipeline can be tested. Do not infer the real value from
the synthetic pulse.

For a label expressed as pulses per cubic metre:

```text
P = impulses per m³ / 1000
```

For measured calibration, record the raw count, pass an accurately measured
volume `V` litres, then record the new count. With `N` new pulses:

```text
P = N / V
L/min = pulses/min / P
total litres = total pulses / P
total m³ = total litres / 1000
```

Use a larger measured volume so one-pulse quantization is a small fraction of
the result.

## Debounce and cable noise

Once `P` is known, the shortest expected pulse interval at peak flow `Q` L/min
is:

```text
interval seconds = 60 / (Q × P)
```

The current 10 ms stable-pulse filter has a theoretical ceiling of about 100
pulses/second, or:

```text
maximum indicated flow ≈ 6000 / P L/min
```

Require comfortable margin between the real pulse interval and 10 ms; five to
ten times is preferable. Reduce the filter only if the documented pulse width or
plausible peak household flow requires it.

For a short, clean cable, the internal pull-up is sufficient. Add mitigation
only if logs show phantom pulses: start with a twisted GPIO27/GND pair routed
away from mains and pump wiring, then consider a 4.7–10 kΩ external pull-up and
a small capacitor at the ESP32 end. Very long or exposed runs may justify
isolation and surge protection.

## Optional Utility Meter helpers

After calibration and commissioning cleanup:

1. Open **Settings → Devices & services → Helpers**.
2. Select **Create helper → Utility Meter**.
3. Use `sensor.indoor_water_meter_total_water` as the source.
4. Create separate helpers with daily, weekly, and monthly reset cycles.

Do not create these while the conversion remains temporary; their histories
would inherit the synthetic value.

## Validation receipts

On 2026-07-27:

- ESPHome add-on 2026.7.2 reported the configuration valid and compiled it.
- The initial factory image was serial-flashed through the CP2102 on
  `framework:/dev/ttyUSB0`.
- Encrypted API and authenticated OTA both worked over the narrow Tailscale
  grant.
- Home Assistant Core 2026.7.4 loaded the ESPHome config entry and materialized
  recorder statistics for the cubic-metre entity.
- `nix flake check` passed with only existing repository warnings.

Revisit this page when the reed is physically attached, the meter label or
measured calibration is available, or the DHCP lease is reserved.
