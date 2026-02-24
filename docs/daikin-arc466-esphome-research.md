# Controlling Daikin ARC466A40 via ESPHome IR

**The most viable path to full climate control is a custom ESPHome component wrapping the IRremoteESP8266 library's `IRDaikinESP` or `IRDaikin312` class** — the library explicitly supports ARC466 variants, and a well-maintained external_components framework (mistic100/ESPHome-IRremoteESP8266) already demonstrates the exact pattern needed. No off-the-shelf, plug-and-play ESPHome component exists for the ARC466A40 today, but several approaches range from "try it in 5 minutes" to "build a proper component in a few hours." The critical first step is identifying which of two possible protocols your specific ARC466A40 uses — this determines everything else.

---

## First, identify your exact protocol variant

The ARC466 remote family spans **two different IR protocols** in the IRremoteESP8266 library, and your A40 variant isn't explicitly listed for either. ARC466A12 and ARC466A33 use the base **DAIKIN protocol** (280-bit, 35 bytes, 3 frames). ARC466A67 uses the newer **DAIKIN312 protocol** (312-bit, 39 bytes, 2 frames). Your ARC466A40 falls between these and could use either.

Flash your XIAO Smart IR Mate with this diagnostic configuration to find out:

```yaml
remote_receiver:
  pin:
    number: D2      # XIAO IR Mate receiver pin
    inverted: true
    mode:
      input: true
      pullup: true
  dump: all
  tolerance: 25%
```

Point your physical ARC466A40 remote at the receiver and press any button. The ESPHome log will either show `Received DAIKIN: ...` (280-bit) or `Received DAIKIN312: ...` (312-bit), or possibly an unrecognized raw dump. **This single test determines which of the approaches below will work.**

---

## Approach 1: ESPHome's built-in `daikin` platform (try first)

ESPHome's native `daikin` climate platform implements the **exact same protocol** as IRremoteESP8266's DAIKIN/IRDaikinESP — identical 35-byte frame structure, same `0x11, 0xDA, 0x27` header bytes, same IR timing (38 kHz carrier, 3360 µs header mark, 520 µs bit mark). The source code in `esphome/components/daikin/daikin.cpp` labels it "for Daikin ARC43XXX controllers," but **the protocol is identical** to what ARC466A12 and ARC466A33 use.

If your ARC466A40 uses the 280-bit DAIKIN protocol, this built-in platform should work:

```yaml
remote_transmitter:
  pin: D1            # XIAO IR Mate transmitter pin (3 IR LEDs)
  carrier_duty_percent: 50%

remote_receiver:
  id: rcvr
  pin:
    number: D2
    inverted: true
    mode:
      input: true
      pullup: true

climate:
  - platform: daikin
    name: "Daikin AC"
    receiver_id: rcvr
```

This gives you **temperature control** (10–30°C), **modes** (auto, cool, heat, dry, fan-only), **fan speeds** (quiet, auto, low, medium, high), and **swing** (off, vertical, horizontal, both) — plus receiver support so the climate entity stays in sync when someone uses the physical remote.

**Why might it fail?** Three possible reasons: (1) your ARC466A40 actually uses DAIKIN312, not base DAIKIN; (2) your AC unit validates specific default byte values in sections 1 and 2 that ESPHome hardcodes differently; or (3) your unit requires fields ESPHome doesn't set (eco, powerful, comfort mode bytes). If this platform doesn't work, move to Approach 2.

**Quality**: ★★★★★ if it works — native ESPHome, full climate entity, receiver support, no dependencies.

---

## Approach 2: Fork mistic100/ESPHome-IRremoteESP8266 to add Daikin

The repository [mistic100/ESPHome-IRremoteESP8266](https://github.com/mistic100/ESPHome-IRremoteESP8266) is a **maintained, modern external_components collection** that wraps IRremoteESP8266 classes into proper ESPHome climate entities. It currently supports Fujitsu, Panasonic, and Electra — adding Daikin follows the identical pattern. The repo requires Arduino framework (compatible with ESP32-C3), has **10 stars and 10 forks**, and was updated as recently as July 2025 for ESPHome 2025.7 compatibility.

The implementation involves creating a `components/daikin/` directory with three files following the existing platform pattern. The C++ wrapper would map `IRDaikinESP` (or `IRDaikin312`) methods to ESPHome's `ClimateIR` interface — `setTemp()`, `setMode()`, `setFan()`, `setSwingVertical()`, etc. The IRDaikinESP class supports **temperature 10–32°C with 0.5°C steps**, 5 operating modes, 6 fan speeds including quiet, vertical and horizontal swing, plus powerful, econo, comfort, and mold prevention modes — far more than ESPHome's built-in platform exposes.

Once built, the configuration would look like:

```yaml
esp32:
  framework:
    type: arduino

external_components:
  - source:
      type: git
      url: https://github.com/YOUR_FORK/ESPHome-IRremoteESP8266
    components: [ ir_remote_base, daikin ]

remote_transmitter:
  pin: D1
  carrier_duty_percent: 50%

climate:
  - platform: daikin
    model: DAIKIN         # or DAIKIN312
    name: 'Daikin AC'
```

**Quality**: ★★★★★ — proper ESPHome external_component, full feature set, maintainable. Requires moderate C++ work to create the initial wrapper (~200 lines following existing patterns), but it's the cleanest long-term solution. You could also submit a PR upstream.

---

## Approach 3: Adapt existing custom components

Several GitHub repos already wrap IRDaikinESP into ESPHome climate entities, though all use the **deprecated `platform: custom` API** (scheduled for removal in ESPHome 2025.11.0):

**TheSnook/esphome-daikin** — The most direct match. Archived in February 2026, it wraps `IRDaikinESP` with support for cool, heat, dry, fan-only, auto modes plus swing. Originally ESP8266-only (hardcoded `D2` pin), but the C++ code is a useful reference. Configuration uses `includes:` + `libraries: "IRremoteESP8266"` + `platform: custom` lambda pattern.

**avbor/HomeAssistantConfig (daikin_ir.h)** — Similar approach from the ESPHome feature-requests #1054 discussion. Adds external temperature sensor integration. Same deprecated API.

**SodaWithoutSparkles/esphome-daikin64** — Wraps `IRDaikin64` but its README explicitly documents how to swap in `IRDaikinESP` by changing the class instantiation. Has 4 stars and 2 forks. The simplest adaptation path: change `IRDaikin64` to `IRDaikinESP`, adjust the mode/fan/temp mappings in the `control()` method.

**BogdanDIA/Daikin_brc52A6x** — Uses the proper `external_components` architecture (not deprecated) for Daikin 128-bit BRC protocol. The component structure is an excellent architectural template even though the protocol itself is different.

The **critical ESP32-C3 concern** with all IRremoteESP8266-based custom components: the library had compilation issues with ESP32 + Arduino 3.0.0+ due to RMT API changes in ESP-IDF 5.x. Testing is required. ESPHome's native `remote_transmitter` handles ESP32-C3's RMT peripheral correctly, but IRremoteESP8266's `IRsend` bypasses this layer.

**Quality**: ★★★☆☆ — functional but uses deprecated APIs, potential ESP32-C3 compatibility issues, limited maintenance.

---

## Approach 4: ESPHome HeatpumpIR platform

ESPHome's `heatpumpir` platform bridges the ToniA/arduino-heatpumpir library, which supports three Daikin protocols: `daikin` (ARC452A1), `daikin_arc417`, and `daikin_arc480`. **None of these explicitly support ARC466**, but the base `daikin` protocol or `daikin_arc480` might be close enough to work — Daikin protocols within the same generation often share encoding.

```yaml
climate:
  - platform: heatpumpir
    protocol: daikin           # also try: daikin_arc480
    horizontal_default: middle
    vertical_default: middle
    name: 'Daikin AC'
```

Worth trying as a **5-minute test** since it requires zero custom code. The `daikin_arc480` variant supports temperatures **18–30°C**, 7 fan speeds, and comfort/econo/powerful/quiet modes — a rich feature set if compatible. The main limitation of the `heatpumpir` platform is **no receiver support** (transmit-only), so the climate entity won't sync when someone uses the physical remote.

**Quality**: ★★★☆☆ if compatible — zero setup effort, but no receiver support and uncertain ARC466 compatibility.

---

## Approach 5: SmartIR with learned codes

The [SmartIR](https://github.com/smartHomeHub/SmartIR) Home Assistant integration has **120+ climate devices** with pre-built JSON code files, including several Daikin models (codes 1081, 1101, 1124, 1137, 1200). However, **ARC466 is not among the pre-built entries**. The supported Daikin models are primarily FTXS and FTXM series with ARC433/ARC443-compatible remotes.

SmartIR allows learning custom codes via Broadlink remotes, but Daikin's full-state encoding makes this approach deeply impractical. Every IR frame encodes the **complete AC state** — mode, temperature, fan speed, swing, timers, clock. To cover even a minimal useful set of 5 modes × 13 temperatures × 5 fan speeds, you'd need to capture and store **325 unique codes** manually. SmartIR also works via MQTT with ESPHome transmitters, adding network latency to an already cumbersome setup.

**Quality**: ★★☆☆☆ — no pre-built ARC466 codes, hundreds of manual captures needed, works only for fixed state combinations.

---

## Approach 6: Raw IR capture and replay

ESPHome's `remote_receiver` with `dump: raw` can capture the exact pulse timing sequence from your physical ARC466A40 remote, then `remote_transmitter.transmit_raw` can replay it. This works for any IR protocol regardless of ESPHome's built-in support.

```yaml
button:
  - platform: template
    name: "AC Cool 24C"
    on_press:
      - remote_transmitter.transmit_raw:
          carrier_frequency: 38000Hz
          code: [3400, -1750, 430, -1300, 430, -470, ...]  # captured raw code
```

**The fundamental limitation is identical to SmartIR**: Daikin remotes encode the full AC state in every transmission. Each captured code is a frozen snapshot of one specific combination of power, mode, temperature, fan speed, swing, and timer settings. You cannot extract the "set temperature to 25" portion from a raw code and combine it with "set fan to high" — each combination requires its own separately captured raw code. Some frames even embed the **current wall clock time**, meaning codes captured at different times may differ even for the same logical state.

This approach is practical only for a small set of **preset scenarios** — for example, "Summer mode" (cool, 24°C, fan auto), "Winter mode" (heat, 22°C, fan low), and "Off." For anything resembling a proper climate entity with a temperature slider, it's unworkable.

**Quality**: ★☆☆☆☆ for full climate control, ★★★☆☆ for a handful of preset buttons.

---

## Public IR databases offer little help

**IRDB** (probonopd/irdb) stores simple NEC/RC5-style toggle codes — its CSV format fundamentally cannot represent Daikin's complex multi-frame state-encoding protocol. **Flipper Zero IRDB** has a Daikin AC folder, but entries are raw timing captures representing single state snapshots with the same limitations as Approach 6. A dedicated Python library, [javierdelapuente/daikin-arc466](https://github.com/javierdelapuente/daikin-arc466), exists for the ARC466A6 variant via Broadlink — useful protocol documentation but not directly usable in ESPHome.

The protocol itself is well-documented through IRremoteESP8266's source code and [blafois/Daikin-IR-Reverse](https://github.com/blafois/Daikin-IR-Reverse), which provides byte-level mapping for the closely related ARC470A1.

---

## Recommended action plan

**Step 1** (5 minutes): Flash the diagnostic YAML with `dump: all` and capture a signal from your ARC466A40. Check whether ESPHome identifies it as `DAIKIN` (280-bit) or `DAIKIN312` (312-bit).

**Step 2** (5 minutes): If identified as DAIKIN, try `platform: daikin`. Also try `platform: heatpumpir` with `protocol: daikin` and `protocol: daikin_arc480`. One of these may work out of the box.

**Step 3** (2–4 hours): If none work, fork mistic100/ESPHome-IRremoteESP8266 and add a Daikin platform following the Fujitsu/Panasonic pattern. Use `IRDaikinESP` for DAIKIN protocol or `IRDaikin312` for DAIKIN312 protocol. This produces a clean, maintainable external_component with full climate entity support.

**Step 4** (alternative): If you need something working immediately, adapt SodaWithoutSparkles/esphome-daikin64 by swapping `IRDaikin64` for `IRDaikinESP` — this uses the deprecated custom platform API but can provide a working climate entity in under an hour.

**Escape hatch**: If your Daikin indoor unit has an **S21 serial port** (a 5-pin connector common on modern Daikin units), the [esphome-daikin-s21](https://github.com/joshbenner/esphome-daikin-s21) external component provides **bidirectional** control with actual temperature readback — far superior to any IR approach. It has 97 stars and 43 forks, and works with ESP32-C3. Worth checking even if you're committed to IR.

## Conclusion

The ARC466A40's protocol is fully decoded in IRremoteESP8266 — the technical barrier is purely the **missing bridge into ESPHome's climate framework**. ESPHome's built-in `daikin` platform implements the same base DAIKIN protocol that two ARC466 variants use, making it the obvious first test. If the A40 variant uses DAIKIN312 instead, the mistic100/ESPHome-IRremoteESP8266 framework provides the cleanest path to building a proper external_component — the pattern is proven for three other manufacturers, and adding Daikin is a mechanical exercise of mapping IRDaikinESP (or IRDaikin312) methods to ESPHome's ClimateIR interface. Raw capture and SmartIR are dead ends for anything beyond basic presets due to Daikin's full-state encoding. The XIAO Smart IR Mate's hardware (3 IR LEDs on D1, receiver on D2, ESP32-C3 with Arduino framework support) is fully compatible with all the programmatic approaches described above.
