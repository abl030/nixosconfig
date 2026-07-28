# Indoor Water Meter

- **Date:** 2026-07-27 (updated 2026-07-28)
- **Status:** Live on independent power with the reed connected. Clean
  water-driven pulse operation and 16 real lifetime pulses are confirmed. The
  selected calibration is the
  WMMJH-25-PN standard 10 L/pulse option (`0.1` pulses/L). Volume and estimated
  thermal-demand analytics are live.
- **Tracker:** [`docs/todo/indoor-water-meter.md`](../../todo/indoor-water-meter.md)
- **Firmware source:** [`ha/esphome/water-meter.yaml`](../../../ha/esphome/water-meter.yaml)
- **HA analytics source:** [`ha/water_meter.yaml`](../../../ha/water_meter.yaml)
- **Dashboard source:** [`ha/dashboards/ir-sensor.yaml`](../../../ha/dashboards/ir-sensor.yaml)

## Current physical state

The generic ESP32 DevKit is wall-mounted and powered from an independent USB
supply. The passive two-wire reed is connected between the screw terminals
labelled `D27` (GPIO27) and `GND`; polarity does not matter.

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
By the final thermal-model verification, the restored counter had reached
16 real pulses, `160 L`, and approximately `0.160 m³`.

After a reboot, live flow is `unknown` until `pulse_meter` has a new pulse
interval. It publishes the calibrated rate on the next pair of pulses and falls
back to zero after the configured two-minute timeout.

## Demand analytics and dashboard

Home Assistant loads `ha/water_meter.yaml` as a package. It uses native Utility
Meter helpers, sourced from the restored cumulative litres sensor, for these
periods:

| Entity | Period | Sizing use |
|---|---|---|
| `sensor.winery_hot_water_this_15_minutes` | 15 minutes | Short demand bursts and storage drawdown |
| `sensor.winery_hot_water_this_hour` | Hour | Time-of-day demand |
| `sensor.winery_hot_water_today` | Day | Daily storage and heating requirement |
| `sensor.winery_hot_water_this_week` | Week | Production-week comparison |
| `sensor.winery_hot_water_this_month` | Month | Seasonal trend |
| `sensor.winery_hot_water_this_year` | Year | Long-term demand |

The source is lifetime cumulative and never resets, so every helper sets
`periodically_resetting: false`, `delta_values: false`, and
`always_available: true`. Utility Meter state is restored across Home Assistant
restarts. The initial current hour/day/week/month/year were calibrated to the
known two real pulses (`20 L`); the then-current 15-minute period was correctly
zero. Future resets and `last_period` values are automatic.

On their first-ever load, the helpers started before ESPHome had republished the
source attributes. Home Assistant therefore created their Recorder metadata as
unitless, then raised six `units_changed` Repairs after the helpers acquired
`L`. The ESPHome config entry was reloaded to initialize the live helpers, and
only those six statistics metadata records were corrected to unit `L` and unit
class `volume` through Home Assistant's Recorder WebSocket API. Statistics
validation then removed all six Repairs. A later Core restart restored the
helpers with their units intact, so this is a one-time creation-order issue
rather than ongoing drift.

`sensor.winery_hot_water_peak_flow_ever` is a restored trigger-based template
sensor because the native Statistics helper requires a bounded sample count or
time window and cannot represent an unbounded lifetime maximum. It is seeded at
`15.459 L/min`, calculated from the verified real-pulse interval after applying
the final 10 L/pulse conversion. Later production flow raised the live maximum
to `29.107 L/min`; only a still-higher valid flow can raise it again.

The fourth view at **IR Sensor → Hot Water** follows the electricity Overview
and contains:

- readable two-column tile summaries for current flow, lifetime peak,
  current-hour usage, and today's usage on both phone and desktop;
- a native table for current and previous 15-minute/hour/day periods plus
  week, month, year, and lifetime totals;
- the raw flow trace for the last 24 hours;
- clean helper-based hourly-volume bars for seven days and daily-volume bars
  for 90 days;
- hourly maximum and mean flow for 30 days;
- estimated current/lifetime-peak thermal power, period/lifetime thermal
  energy, temperature-model inputs, and thermal history;
- the existing Solar Analytics hot-water electrical-energy estimate and its
  daily 90-day history.

The first raw Recorder buckets predate final calibration: the 08:10–08:15 flow
maximum is 10 times low, and the 08:30–08:35 total-litres change includes the
calibration/migration transition. The final lifetime total is correct, but
those first buckets do not have trustworthy physical timing. The dashboard
therefore uses the new Utility Meter helpers for hourly/daily usage history and
calls out the one stale point on the 24-hour raw flow graph.

Recorder produces five-minute and hourly statistics for these sensors. The
fine-grained statistics follow Recorder retention, while hourly long-term
statistics are retained indefinitely:

- <https://www.home-assistant.io/dashboards/statistics-graph/>
- <https://www.home-assistant.io/integrations/utility_meter/>
- <https://www.home-assistant.io/integrations/template/>

For solar hot-water sizing, accumulate several representative production weeks,
including cleaning and vintage peaks. Volume is the strongest storage-capacity
input; 15-minute/hourly draw, peak flow, thermal demand, and electrical input
describe delivery, collection, storage, and backup-heating requirements.

## Estimated thermal demand

No tank, cold-inlet, or hot-outlet temperature probe is present. The only
suitable on-site proxy is `sensor.imarga43_temperature`, the winery Weather
Underground outdoor-temperature observation. Its long-term Recorder history has
good coverage, but instantaneous outdoor air is too volatile to represent a
50 kL tank.

Home Assistant therefore implements a deliberately slow planning model:

1. `sensor.winery_outdoor_temperature_24h_mean` calculates a time-weighted
   average from the preceding 24 hours of Recorder samples.
2. `sensor.winery_cold_water_estimated_temperature` updates once daily with a
   14-day e-folding exponential low-pass:
   `new = 0.931 × previous + 0.069 × daily mean`.
3. The cold-water estimate was seeded at `11.853°C`, the measured 14-day
   outdoor mean ending 2026-07-28. An update is skipped unless the 24-hour
   statistics buffer spans at least 90% of the day.
4. Delivery temperature is explicitly assumed constant at `85°C`.

The resulting quantities are:

```text
temperature rise °C = 85°C - estimated inlet temperature
thermal kW = flow L/min × temperature rise °C × 0.06978
thermal kWh = volume litres × temperature rise °C × 0.001163
```

At commissioning, the modelled rise was `73.147°C`. This is an engineering
estimate for comparative system sizing, not a measured tank temperature,
delivered heat, or appliance efficiency.

The first model load backfilled the then-known `150 L` as `12.760494 kWh`.
One subsequent real 10 L reed pulse added exactly `0.850700 kWh`, producing a
restored lifetime total of `13.611194 kWh` at `160 L`. The existing
`29.107 L/min` lifetime flow peak maps to an estimated `148.568 kW` thermal
peak at the commissioning temperature rise.

`sensor.winery_hot_water_total_thermal_energy` is a restored
`total_increasing` template sensor. It adds energy only when the restored
lifetime-litres counter increases, applying the temperature rise valid for that
increment. It deliberately does not integrate the live flow sensor because
ESPHome holds the last interval-derived flow until its two-minute timeout;
integrating that held value would over-count thermal energy. A lower/replaced
volume counter re-baselines without subtracting accumulated energy.

Six native Utility Meter helpers split the cumulative thermal total into
15-minute, hourly, daily, weekly, monthly, and yearly estimated kWh. The same
restored-state pattern retains the unbounded lifetime thermal-power peak. These
entities record thermal demand even when not every series is displayed:

| Entity | Meaning |
|---|---|
| `sensor.winery_hot_water_thermal_power` | Current estimated thermal delivery rate |
| `sensor.winery_hot_water_peak_thermal_power_ever` | Restored lifetime estimated peak |
| `sensor.winery_hot_water_total_thermal_energy` | Restored lifetime estimated heat delivered |
| `sensor.winery_hot_water_thermal_this_15_minutes` | Current 15-minute estimated energy |
| `sensor.winery_hot_water_thermal_this_hour` | Current hourly estimated energy |
| `sensor.winery_hot_water_thermal_today` | Current daily estimated energy |
| `sensor.winery_hot_water_thermal_this_week` | Current weekly estimated energy |
| `sensor.winery_hot_water_thermal_this_month` | Current monthly estimated energy |
| `sensor.winery_hot_water_thermal_this_year` | Current yearly estimated energy |

Solar Analytics' hot-water electrical sensor remains separate. It estimates
electrical input, while this model estimates heat carried by the metered water;
their ratio must not be presented as verified efficiency.

An insulated contact probe on the tank outlet or cold inlet pipe, sampled while
water is flowing, is the preferred next measurement. It can replace the proxy
without changing the volume counter or losing accumulated demand history. A
hot-outlet probe would additionally verify the fixed 85°C assumption.

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
3. Install an insulated cold-inlet/tank-outlet probe before final equipment
   selection and compare it with the ambient-derived proxy; add a hot-outlet
   probe if the fixed 85°C setting also needs verification.
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
- Home Assistant Core accepted the tracked demand-analytics package and created
  six persistent, water-class Utility Meter sensors plus the restored lifetime
  peak sensor.
- The helpers were baselined against the known `20 L`, acquired `L`,
  `device_class: water`, and `state_class: total_increasing`, and remained
  `collecting`.
- A second Core restart restored the same six helper values and metadata plus
  the `15.459 L/min` lifetime peak; no count or peak reset.
- The first natural hourly boundary reset the current-hour helper to `0 L` and
  moved its verified `20 L` into `last_period`.
- Six one-time unit-change Repairs caused by unitless first-start statistics
  metadata were corrected to `L`/`volume`; a fresh validation reported zero
  remaining water-unit Repairs and no winery statistics errors.
- The `ir-sensor` dashboard gained the fourth **Hot Water** view; live dashboard
  structure and all referenced entities were verified against the tracked YAML.
- Home Assistant Core accepted the thermal-demand package with a Recorder-backed
  24-hour outdoor mean, restored inlet-temperature proxy, current and lifetime
  peak thermal power, cumulative thermal energy, and six thermal Utility Meter
  periods.
- The commissioning proxy was `11.853°C`, the assumed delivery temperature was
  `85.0°C`, and the resulting rise was `73.147°C`; the 24-hour source statistics
  had full age coverage.
- The then-known `150 L` backfilled to `12.760494 kWh`. A later real pulse
  advanced the counters to `160 L` and `13.611194 kWh`, an exact
  `0.850700 kWh` increment under the model.
- The natural 10:00 boundary paired `10 L` with `0.850700 kWh` for the previous
  15 minutes and `140 L` with `11.909795 kWh` for the previous hour.
- Recorder assigned `kW`/power metadata to the thermal-rate sensors,
  `kWh`/energy metadata to the cumulative and period sensors, and
  `°C`/temperature metadata to the model sensors. There were zero active
  Repairs and no thermal unit or statistics issues.
- A subsequent Core restart restored `160 L`, `13.611194 kWh`, the
  `148.568 kW` thermal peak, all six current/previous period values, and every
  temperature-model state without reset.
- The Hot Water dashboard now uses readable two-column tile grids for volume
  and thermal summaries. Its 16-card live structure exactly matched the tracked
  YAML and all 23 referenced entities resolved.

Revisit this page after the mechanical-register cross-check or DHCP reservation.
