# Indoor Water Meter Tracker

- **Status:** Live 2026-07-28; real reed pulses confirmed, standard 10 L/pulse calibration selected
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

## Follow-up

- [ ] Cross-check 10 L/pulse against a larger mechanical-register delta during normal use.
- [ ] Reserve `192.168.100.89` to ESP32 MAC `30:76:F5:F4:22:FC` in work DHCP.
- [ ] If the lease changes first, update the Tailscale host alias and HA integration host.
- [ ] Add cold-inlet and hot-outlet temperature probes before final thermal sizing.
- [ ] Add cable-noise mitigation only if real logs show phantom pulses.
