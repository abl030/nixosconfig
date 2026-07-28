# Indoor Water Meter

- **Date:** 2026-07-27 (updated 2026-07-28)
- **Status:** Live on independent power with the reed connected. Two clean
  water-driven pulses have been observed. The selected calibration is the
  WMMJH-25-PN standard 10 L/pulse option (`0.1` pulses/L).
- **Tracker:** [`docs/todo/indoor-water-meter.md`](../../todo/indoor-water-meter.md)
- **Firmware source:** [`ha/esphome/water-meter.yaml`](../../../ha/esphome/water-meter.yaml)

## Current physical state

The generic ESP32 DevKit is powered from an independent USB supply. The passive
two-wire reed is connected between the screw terminals labelled `D27` (GPIO27)
and `GND`; polarity does not matter.

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
The first persisted count of `1` was a synthetic commissioning pulse.

The count was then allowed to pass the one-minute preference flush interval. It
survived both:

- a CP2102/RTS hardware-style ESP32 reset at 15:31 AWST; and
- an authenticated ESPHome OTA upload at 15:32 AWST.

On 2026-07-28, after moving to independent power and connecting the reed, the
meter produced two clean water-driven pulses:

- first closure: 08:11:50–08:12:02 AWST;
- second pulse: approximately 38.8 seconds after the first;
- no bounce or duplicate count occurred.

With the selected 10 L/pulse calibration, that interval represents about
15.46 L/min. This is a plausible open hot-water flow and independently supports
the standard pulse option.

The red DN25 meter corresponds to Hydroflow model `WMMJH-25-PN`: the hot-water,
25 mm nominal (1-inch service) member of the WMMJ family. The manufacturer page
lists 10 L/pulse as standard and 1 L/pulse as an option:

- <https://hydroflowaus.com.au/product/multi-jet-water-meter>
- <https://hydroflowaus.com.au/downloads/multi-jet-water-meter-xgqqc-2-kigkh.pdf>

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

Data schema 1 performs a one-time migration that removes the single synthetic
commissioning pulse from the restored raw total. After allowing the globals
component to queue both changed values, boot forces a preference sync so the
migration cannot be applied twice after a later power loss. The schema marker
makes a fresh board/NVS state safe: an empty counter is not decremented.

## Home Assistant

The loaded ESPHome integration exposes:

| Entity | Purpose | HA metadata |
|---|---|---|
| `binary_sensor.indoor_water_meter_reed_contact` | Direct electrical state; `on` means GPIO27 is grounded | diagnostic |
| `sensor.indoor_water_meter_flow_rate` | Live flow | `L/min`, `volume_flow_rate`, `measurement` |
| `sensor.indoor_water_meter_lifetime_pulses` | Restored raw pulse count | `pulses`, `total_increasing`, diagnostic |
| `sensor.indoor_water_meter_total_water_litres` | Converted cumulative usage | `L`, `water`, `total_increasing` |
| `sensor.indoor_water_meter_total_water` | Water-dashboard source | `m³`, `water`, `total_increasing` |

Recorder statistics are active for the cubic-metre entity. The schema migration
and conversion change make its state and cumulative sum converge on the real
water pulses: after the migration, two real pulses equal 20 L or `0.020 m³`.
The 08:30 AWST recorder bucket was verified with both state and cumulative sum at
approximately `0.020 m³`; the synthetic pulse did not remain in recorded usage.

After a reboot, live flow is `unknown` until `pulse_meter` has a new pulse
interval. It publishes the calibrated rate on the next pair of pulses and falls
back to zero after the configured two-minute timeout.

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

## Remaining commissioning

1. Validate the 10 L/pulse selection against a larger mechanical-register delta
   during normal use; this distinguishes it from the optional 1 L/pulse version
   without wasting water.
2. Reserve the work DHCP address to the ESP32 MAC.
3. Add daily, weekly, and monthly Utility Meter helpers if desired.
4. Add cable-noise mitigation only if real logs show phantom pulses.

## Calibration and maths

The selected standard pulse setting is:

```yaml
substitutions:
  pulses_per_litre: "0.1"
```

The same meter family has an optional 1 L/pulse version, so retain the
substitution and verify the selected option against the mechanical register
during normal use.

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

The shortest expected pulse interval at peak flow `Q` L/min is:

```text
interval seconds = 60 / (Q × P)
```

At `P = 0.1`, the observed 38.8-second interval is roughly 3,880 times the
10 ms filter. Even the meter's DN25 maximum flow of 7 m³/h implies about one
pulse every 5.14 seconds, leaving over 500 times margin. The current debounce is
therefore safe for this meter.

In general, the 10 ms stable-pulse filter has a theoretical ceiling of about
100 pulses/second, or:

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

After the mechanical-register cross-check:

1. Open **Settings → Devices & services → Helpers**.
2. Select **Create helper → Utility Meter**.
3. Use `sensor.indoor_water_meter_total_water` as the source.
4. Create separate helpers with daily, weekly, and monthly reset cycles.

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

On 2026-07-28:

- independent USB power rejoined Wi-Fi with the restored count intact;
- the installed reed produced two clean water-driven pulses;
- the observed interval maps to approximately 15.46 L/min at 10 L/pulse.
- ESPHome accepted and compiled `pulses_per_litre: "0.1"` without warnings;
- authenticated OTA applied data schema 1, changing the stored count from three
  raw closures to two real meter pulses;
- an immediate second authenticated OTA/reboot restored the same two pulses,
  proving the schema migration was persisted and did not run twice;
- Home Assistant reported `2` pulses, `20 L`, and `0.020 m³`.

Revisit this page after the mechanical-register cross-check or DHCP reservation.
