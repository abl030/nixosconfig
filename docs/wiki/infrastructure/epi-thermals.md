# epi thermals — fan telemetry (it87/IT8686E) and the 2026-09-07 cooler fault

**Status:** RESOLVED 2026-09-07. Driver landed, hardware fixed, verified. The
CPU fan was mounted backwards; turning it around took the box from 105.9 °C at
540 MHz to 74 °C at 4425 MHz. Fan RPM is now exported and alerted on.
**Host:** epimetheus — Gigabyte B450 I AORUS PRO WIFI, Ryzen 7 5700X, Arc A310,
in a **Dan A4-SFX** (7.2 L sandwich, no case-fan mounts by design).

## Why lm-sensors showed no fans at all

The board carries **two** ITE Super I/O chips. The in-tree `it87` binds the
secondary one and rejects the primary:

```
it87: Found IT8792E/IT8795E chip at 0xa60, revision 3
it87: Unsupported chip (DEVID=0x8686)
```

| chip | SIO port | EC base | role |
|---|---|---|---|
| IT8686E | 0x2e | **0x0a40** | owns CPU_FAN — rejected by the in-tree driver |
| IT8792E | 0x4e | 0x0a60 | binds fine, but its headers are unpopulated |

So `sensors` reported exactly one fan — `fan1` under `i915`, the Arc A310's, at
0 RPM. **A stalled CPU fan was therefore invisible to every monitoring surface we
have**, including the node-exporter metrics on doc2 (`node_hwmon_fan_rpm` only
ever carried the i915 chip). That is how this ran hot unnoticed.

Two things were needed to fix it, both in `hosts/epi/configuration.nix`:

1. The out-of-tree driver, which knows `it8686` — nixpkgs ships it as
   `config.boot.kernelPackages.it87`.
2. `ignore_resource_conflict=1`. The IT8686E's environment controller sits at
   I/O `0x0a40`, which the DSDT reserves as `PNP0C02` motherboard resources
   (visible in `/proc/ioports` as `0a40-0a4f`). Without the flag the driver
   refuses to attach even once it recognises the chip.

The module is in the binary cache, so a rebuild fetches rather than compiles it.

## Reading the EC by hand (no driver required)

Useful for break-glass, or on any kernel where the module isn't loaded. Index and
data ports are EC base + 5 / + 6, i.e. `0x0a45` / `0x0a46`:

```bash
sudo isadump -y 0x0a45 0x0a46        # full 256-byte register dump
sudo isaset  -y 0x0a45 0x0a46 <reg> <val>
```

Register map (from the out-of-tree `it87.c`):

| what | register | notes |
|---|---|---|
| fan1 tach | `0x0d` low + `0x18` high | 16-bit; **rpm = 1350000 / (raw × 2)** |
| fan2..6 tach | `0x0e/0x19`, `0x0f/0x1a`, `0x80/0x81`, `0x82/0x83`, `0x4c/0x4d` | `0xffff` = stopped or empty header, `0x0000` = channel inactive |
| PWM control | `0x15`, `0x16`, `0x17` | **bit 7 set = BIOS auto curve** |
| PWM duty | `0x63`, `0x6b`, `0x73` | 0–255, **read-only while bit 7 of `0x15` is set** |
| temps | `0x29`–`0x2e` | `0x2b` tracks the CPU |

To take manual control: clear bit 7 of `0x15` **first** (`0xd0` → `0x50`, keeping
the temp-map bits), then write duty to `0x63`. Writing `0x63` while still in auto
mode silently does nothing. Restore with `0x63` → original, then `0x15` → `0xd0`.

> Poking `0x0a40` races the BIOS, which also drives this region. Fine for
> diagnosis; the driver is the right long-term answer.

## The 2026-09-07 fault

Symptom: CPU pinned at Tjmax under a `marker-convert` batch, throttling to the
562 MHz floor. Owner had found the CPU fan stalled and reseated it.

Measured with the fan forced to 100 % duty throughout:

| load | fan | Tctl |
|---|---|---|
| idle, nothing running | 2463 rpm (max) | **75.9 °C** |
| ~8 % (1 core) | 2470 rpm | **84 °C**, flat for 3 min |
| 2 cores | 2472 rpm | 95.8 °C |
| full `marker-convert` | 2472 rpm | **105.9 °C**, 540 MHz |

A healthy 5700X idles at 35–45 °C. Board sensors read 52–75 °C and the NVMe hit
74.8 °C.

**The fan is healthy.** It swept linearly 871 → 2472 rpm under PWM control, and
2472 rpm is the rated maximum of the NF-A9x14 used on an NH-L9a. It was running
at spec the whole time.

Diagnosis, ranked:

1. **Fan orientation** — dominant. In an A4-SFX the CPU fan must draw fresh air
   through the side mesh. Reversed, it recirculates 55–75 °C interior air, which
   shifts every CPU temperature up ~35 °C in one step. This also explains why
   temperature barely responded to fan speed: pushing more 65 °C air through the
   fins achieves little.
2. **Paste/contact** — secondary. Even allowing for hot intake there was ~10 °C
   more delta than an L9a should show at this power. It ran stalled for some
   period, which cooks paste.
3. **Cooler is marginal anyway** for a 5700X in 7.2 L under sustained AVX
   inference.

### Gotcha: BIOS auto duty is not the applied duty

While in auto mode the duty register read `110/255` (43 %) — but the fan was
turning 2454 rpm, which manual mode only reached at **100 %** duty. In auto mode
`0x63` reflects the *curve's configured value*, not what is applied. Do not
conclude "the BIOS is only asking for 43 %" from that register; cross-check
against actual RPM.

### Outcome (2026-09-07, same evening)

The owner turned the CPU fan around and repasted. Measured before/after, same
`marker-convert` workload:

| | before | after |
|---|---|---|
| Tctl under load | **105.9 °C** | **74.0 °C** |
| all-core clock | 540 MHz (the 562 MHz floor) | **4425 MHz** |
| Tctl idle | 75.9 °C | 47.8 °C |
| CPU fan | 2463 rpm, 100 % duty, still losing | 2410 rpm on the BIOS curve |
| NVMe | 74.8 °C | 43.9 °C |

Roughly **8x** the sustained CPU, from turning one fan around. That confirms
diagnosis (1): the cooler was inhaling its own exhaust, and the die-to-heatsink
path was fine all along. Note the fan now sits at ~27 % duty at idle with
headroom to spare, where before it was pinned at 100 % and still losing.

The lesson worth keeping: temperature being *insensitive to fan speed* looked
like a contact problem, but it was actually a hot-intake problem. Both present
that way. What discriminated them was the board sensors — 55–75 °C interior air
meant the fan had nothing cold to push.

### Verifying a future hardware fix

Boot with the fan on the BIOS curve and read idle temperature:

- **Under ~45 °C idle** → airflow was the problem.
- **Still 70 °C+ idle** → it is contact/paste, not airflow.

A measurement rig is on the box at `~/stress-logs/` (`thermal-monitor.sh` — 5 s
CSV, journal mirror, fsynced; `fan-sweep.sh` — PWM dose-response;
`cooldown.sh`). Run them with
`systemd-run --user --unit=<name> -E PATH="$PATH" <script>`.

## Follow-ups

- **DONE** — alert on CPU fan RPM. `homelab.services.alerting.fanStallAlert` in
  `modules/nixos/services/alerting.nix`, enabled for epi's `fan1` in
  `hosts/doc2/configuration.nix`. Deliberately an explicit per-fan list: a
  blanket `node_hwmon_fan_rpm == 0` fires forever on empty headers and
  zero-RPM-idle GPU fans, gets muted, and is then worse than no alert.
- **WON'T DO** — capping PPT/cTDP in BIOS, and adding a `CPUQuota` to
  `marker-convert`. Both were sensible while the cooler could not dissipate
  65 W. With airflow fixed the box boosts to 4.4 GHz at 74 °C, so throttling it
  would cost performance for no thermal benefit. Revisit only if temps regress.
- **OPEN (Forgejo #211)** — the secondary/exhaust fan fitted below the PSU does
  not turn. Every non-CPU PWM channel was driven to 255 with all tachs still
  reading 0, so it is a connection or fan fault, not a curve problem. Once it
  runs, add it to `fanStallAlert.fans` too.
- **OPEN** — doc2 Mimir cannot answer long-range queries:
  `err-mimir-bucket-index-too-old`, bucket index last updated 2026-08-26.
  Compactor likely wedged. This blocked the "has it always run this hot?"
  question during diagnosis, which is exactly when history was most useful.
