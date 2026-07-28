# Indoor Water Meter Tracker

- **Status:** Live 2026-07-28; real reed pulses, 10 L/pulse calibration, volume analytics, and estimated thermal-demand analytics confirmed
- **Wiki:** [`docs/wiki/services/indoor-water-meter.md`](../wiki/services/indoor-water-meter.md)
- **Firmware:** [`ha/esphome/water-meter.yaml`](../../ha/esphome/water-meter.yaml)

## Completed

- [x] Use GPIO27 and GND for the passive dry-contact input.
- [x] Track a current ESPHome configuration with secrets kept off-repository.
- [x] Compile and serial-flash the ESP32 through `framework:/dev/ttyUSB0`.
- [x] Join the work Wi-Fi and establish least-privilege HA API/OTA reachability.
- [x] Load the ESPHome integration and verify water-dashboard-compatible m³ metadata.
- [x] Prove one deliberate field-wire short produces exactly one raw pulse.
- [x] Prove the restored raw count survives a hardware reset and authenticated OTA.
- [x] Install independent power and connect the passive reed.
- [x] Observe two water-driven pulses without bounce.
- [x] Identify the DN25 hot meter as WMMJH-25-PN family.
- [x] Select the standard 10 L/pulse option: `pulses_per_litre: "0.1"`.
- [x] Account for the one synthetic commissioning pulse with a one-time migration.
- [x] Verify 10 ms debounce has ample margin at DN25 maximum flow.
- [x] Add native 15-minute, hourly, daily, weekly, monthly, and yearly usage helpers.
- [x] Add a restored lifetime peak-flow sensor seeded from the verified real pulse interval.
- [x] Add and deploy the fourth **Hot Water** view after the electricity Overview.
- [x] Graph 24-hour flow, hourly/daily volume, historic peak/mean flow, and hot-water electricity.
- [x] Verify live helper units, water device class, and total-increasing state class.
- [x] Prove all usage helpers and the lifetime peak survive a Home Assistant Core restart.
- [x] Observe the first hourly reset move `20 L` into the previous-period field.
- [x] Correct the six one-time unitless Recorder metadata entries and clear their Repairs.
- [x] Add a 14-day ambient-derived cold-water temperature proxy for the 50 kL tank.
- [x] Add current and lifetime-peak estimated thermal-power sensors.
- [x] Add restored lifetime thermal energy from volume deltas and temperature rise.
- [x] Add 15-minute, hourly, daily, weekly, monthly, and yearly thermal-energy helpers.
- [x] Replace the cramped four-card row with a legible two-column tile grid.
- [x] Add thermal model, total, power, and history cards to the Hot Water view.
- [x] Verify one real 10 L pulse adds exactly `0.850700 kWh` under the model.
- [x] Prove thermal totals, period helpers, proxy, and lifetime peak survive a Core restart.
- [x] Verify all thermal Recorder metadata and zero active unit/statistics Repairs.

## Follow-up

- [ ] Cross-check 10 L/pulse against a larger mechanical-register delta during normal use.
- [ ] Reserve `192.168.100.89` to ESP32 MAC `30:76:F5:F4:22:FC` in work DHCP.
- [ ] If the lease changes first, update the Tailscale host alias and HA integration host.
- [ ] Add an insulated cold-inlet or tank-outlet probe before final thermal sizing.
- [ ] Add a hot-outlet probe if the fixed 85°C setting needs measurement.
- [ ] Add cable-noise mitigation only if real logs show phantom pulses.
