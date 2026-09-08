# Home Assistant — sunburn / sunscreen advisory

**Researched:** 2026-09-08
**Status:** Live on the Overview dashboard. Package `ha/sunburn.yaml`.
**Question it answers:** "if we go out in the sun today, should we lather up?"

## What it is

Four template sensors, fed by one `weather.get_forecasts` call, that turn the
hourly UV forecast into a plain-English verdict:

| Entity | Example | Notes |
|---|---|---|
| `sensor.sunscreen` | `Only for a long stint` | The verdict. `headline` attribute holds the full sentence the dashboard shows. |
| `sensor.uv_index` | `4.0` | UV right now (UVI), `state_class: measurement` so it graphs. |
| `sensor.peak_uv_today` | `6.3` | Highest UV **still to come** today — see caveat below. |
| `sensor.time_to_sunburn` | `45 min` | Continuous unprotected exposure from now until you'd redden. `won't burn` when the dose never gets there. |

Three verdicts only, deliberately: `No sunscreen needed`, `Only for a long
stint`, `Lather up`. The design brief was explicitly *not* to be conservative —
a spring day where you'd need 35 minutes of bare skin to redden should say so,
not nag.

## The model

Adapted from the idea behind [jondcallahan/sunburntimer](https://github.com/jondcallahan/sunburntimer)
(read for the physics; the Jinja here is our own).

- **Dose accrual:** UV index maps to erythemal irradiance, so damage accrues at
  `120 × UVI / MED` percent per minute. 100% = sunburn.
- **MED** (Minimal Erythemal Dose, J/m², the dose that just reddens skin) by
  Fitzpatrick skin type: I 200, II 250, III 350, IV 450, V 600, VI 1000.
  **We use type II (MED 250)** — "usually burns, tans with difficulty". That is
  the one knob; change `med` at the top of the `burn` variable in
  `ha/sunburn.yaml` to retune for a different household.
- **Low-UV smoothstep:** UV under 1 contributes nothing, ramping to full weight
  at UV 3. Without it, dawn and dusk accumulate a fictional burn.
- **Trapezoid integration** across the hourly forecast rather than assuming UV
  is flat, so a rising or falling curve is handled honestly. Integration runs
  from now to local midnight; the first slice is synthesised at `t_now` so the
  gap between now and the next forecast hour is not silently treated as dark.

Sanity numbers for skin type II: UV 2.5 → ~100 min to burn; UV 6.3 → ~33 min;
UV 12.6 → ~17 min. That matches lived experience of a Margaret River summer.

## Data source

`weather.forecast_home` (met.no, HA's built-in default weather integration).
Its **hourly forecast already carries `uv_index`**, cloud-adjusted — no external
API, no API key, no HACS integration. This was the surprise of the build: an
Open-Meteo REST sensor was the expected path and turned out to be unnecessary.

Do not build on `sensor.imarga43_uv_index` (the Weather Underground station
entity). As of 2026-09-08 it had been pinned at `0` for over 24 hours — it looks
broken, not merely nocturnal.

The trigger-based template refreshes every 15 minutes, on HA start, and on
template reload.

### Caveat: "peak today" means "peak still to come"

met.no's hourly forecast starts at the current hour, so `sensor.peak_uv_today`
is the highest UV *remaining*, not the true daily maximum. Asked in the morning
those are the same number. Asked at 4pm it correctly reports what's left, which
is what you actually want for "should I put cream on before going out now" — but
don't mistake it for a daily-max statistic. `weather.forecast_home`'s *daily*
forecast carries a real daily `uv_index` if a true max is ever needed.

## Gotchas worth keeping

1. **YAML folded scalars (`>-`) preserve newlines on more-indented lines.** A
   sentence split across two lines for readability, indented deeper than the
   block's first line, kept its line break and leaked a newline into the sensor
   attribute. Keep each literal text run on one line, or align it exactly with
   the block's base indent. Jinja `{%- -%}` trim markers hide this for
   single-line branches, which is why it only showed up in the one long one.
2. **`homeassistant.reload_all` DID pick up a brand-new package file.** The
   reload matrix in [home-assistant-deploy.md](home-assistant-deploy.md) says
   new package files need a full restart. That holds for a package introducing a
   *new domain*; this one only added `template:` entities to an already-loaded
   domain, and `reload_all` registered all four sensors with no restart. Try
   the reload first, verify the entities exist, and only restart if they don't.
3. **Testing Jinja without deploying:** `POST /api/template` with a long-lived
   token renders arbitrary templates against live HA. Inline the forecast JSON
   as a `{% set fc = ... %}` prelude and you can exercise the real template text
   — including fabricated summer/winter/evening UV curves — before it ever
   touches `/config`. Much faster than deploy-reload-look.
4. Skin type is hardcoded, not an `input_select`. One household, one knob, and
   the brief was "as simple as possible". If it ever needs per-person answers,
   an `input_select` plus a MED lookup dict is the obvious next step.

## Cross-references

- Package: `ha/sunburn.yaml` — commented with the model and the MED table.
- Deploy procedure: [home-assistant-deploy.md](home-assistant-deploy.md).
- Dashboard: cards live in `ha/dashboards/overview.yaml`.
