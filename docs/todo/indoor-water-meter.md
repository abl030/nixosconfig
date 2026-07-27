# Indoor Water Meter Tracker

- **Status:** Paused 2026-07-27; electronics bench-tested, meter side not connected
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

## Next session

- [ ] Install stable USB power at the meter and reconnect the ESP32.
- [ ] Connect the two loose field wires to the actual reed; polarity does not matter.
- [ ] Find the pulse constant on the meter label/datasheet, or plan a measured-volume calibration.
- [ ] Observe at least one water-driven `Reed Contact` transition and raw pulse.
- [ ] Confirm one real reed closure gives exactly one pulse without bounce.
- [ ] Calculate and set the real `pulses_per_litre`; the current value `"1"` is temporary only.
- [ ] Remove/account for the one synthetic commissioning pulse before trusting cumulative statistics.
- [ ] Compare the 10 ms debounce with the real peak-flow pulse interval.

## Follow-up

- [ ] Reserve `192.168.100.89` to ESP32 MAC `30:76:F5:F4:22:FC` in work DHCP.
- [ ] If the lease changes first, update the Tailscale host alias and HA integration host.
- [ ] Add daily, weekly, and monthly Utility Meter helpers only after calibration.
- [ ] Add cable-noise mitigation only if real logs show phantom pulses.
