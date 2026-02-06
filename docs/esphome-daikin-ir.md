# ESPHome Daikin IR Controller

## Problem

The existing Zigbee IR blaster (Moes UFO-R11 / Tuya TS1201) has a confirmed firmware bug ([Z2M #29701](https://github.com/koenkk/zigbee2mqtt/issues/29701)) that silently truncates long IR transmissions. Daikin uses one of the longest IR protocols (3 frames, 35 bytes with checksums), so the signal gets clipped and the AC never responds. This is unfixable from software — it's a hardware buffer limitation in the TS1201 chipset.

## Solution

A [Seeed XIAO Smart IR Mate](https://www.aliexpress.com/item/1005009561978144.html) (~$11 AUD) — a pre-built IR blaster with ESP32-C3, IR LED, and IR receiver on one board. Pre-flashed with ESPHome. Zero soldering, just plug in USB-C power.

Instead of replaying raw IR codes, ESPHome constructs protocol-correct Daikin frames directly. This gives full climate control (mode, temperature, fan speed, swing) as a proper `climate` entity in Home Assistant.

## Hardware

**Ordered:** Seeed XIAO Smart IR Mate from AliExpress

**What's included on the board:**
- ESP32-C3 with WiFi
- IR transmitter LED (940nm)
- IR receiver (for learning/state sync)
- USB-C for power and flashing

**What you need:** A USB-C cable and a USB power source (phone charger, USB extension, etc.) near the AC unit.

**No soldering. No battery. No solar panel.**

## ESPHome Config

Config will live at `ha/esphome/daikin-ir.yaml`. Key components:

- `esp32` with `board: seeed_xiao_esp32c3` and `framework: esp-idf`
- `remote_transmitter` with `carrier_duty_percent: 50%` (pin TBC — check Smart IR Mate pinout)
- `climate` with `platform: daikin`
- `remote_receiver` for tracking physical remote usage (IR receiver is built-in)

The `platform: daikin` supports: Auto/Cool/Heat/Dry/Fan modes, 10-30C temperature, fan speeds (Auto/Quiet/1-5), swing (Off/Vertical/Horizontal/Both), and Boost/Eco presets.

Since this is mains-powered (always on via USB), there's no deep sleep — the device stays connected to HA and receives commands instantly. No polling, no latency, no helpers needed.

## Daikin Remote Compatibility

Check the back of your remote to confirm the right ESPHome platform:

| Remote Model | ESPHome Platform |
|---|---|
| **ARC43xxx** (most common) | `platform: daikin` |
| ARC417xxx (Japan) | `platform: daikin_arc` |
| ARC480xxx (Japan) | `platform: daikin_arc` |
| BRC (ceiling cassette) | `platform: daikin_brc` |

## Setup Steps (once hardware arrives)

1. Flash ESPHome via USB-C: `esphome run ha/esphome/daikin-ir.yaml`
2. Device auto-discovers in HA under Settings > Devices & Services > ESPHome
3. `climate.daikin_ac` entity appears with full HVAC controls
4. Test IR transmission with the AC
5. Mount with line of sight to the AC's IR receiver (usually right side behind front panel)
6. Run a USB-C cable to the nearest power source
7. Update existing `Aircon_Off_11pm` and `Aircon_22degrees_6am` automations to use `climate.set_hvac_mode` / `climate.set_temperature` instead of MQTT IR codes

## Notes

- The built-in IR receiver means HA can track when someone uses the physical Daikin remote, keeping state in sync automatically
- The existing Zigbee IR blaster can stay for the amp control automations (short codes work fine)
- IR codes captured during debugging are recorded in `docs/ir-codes.md` for reference
- Always-on USB power means instant command response — no deep sleep polling needed
