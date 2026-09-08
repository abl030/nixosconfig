# Home Assistant — sunburn / sunscreen advisory

**Researched:** 2026-09-08
**Status:** Live on the Overview dashboard. Package `ha/sunburn.yaml`.
**Question it answers:** "if we go out in the sun today, should we lather up?"

## What it is

Four template sensors, fed by one `weather.get_forecasts` call, that turn the
hourly UV forecast into a plain-English verdict:

| Entity | Example | Notes |
|---|---|---|
| `sensor.sunscreen` | `Only for a long stint` | The verdict. `headline` and `spf_note` attributes hold the sentences the dashboard shows. |
| `sensor.uv_index` | `4.0` | UV right now (UVI), `state_class: measurement` so it graphs. |
| `sensor.peak_uv_today` | `6.3` | Highest UV **still to come** today — see caveat below. |
| `sensor.time_to_sunburn` | `40 min` | Continuous **unprotected** exposure from now until you'd redden. `won't burn` when the dose never gets there. |
| `sensor.time_to_sunburn_spf50` | `3.5 h` | Same, with one realistic coat of SPF 50 and no top-ups. |

The `worst_burn_minutes` attribute on `sensor.sunscreen` is the shortest bare-skin
burn time over **every remaining start time today** — the day-scale worst case,
and what drives the verdict tier.

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
  **Every** number here is integrated — there is no constant-UV shortcut.
- **Sunscreen**, two independent and equally real effects:
  - *Under-application.* Labelled SPF assumes 2 mg/cm²; people apply about half
    that, and effective SPF goes as `SPF^(applied fraction)`. So a real coat of
    SPF 50 behaves like SPF ~7 (`50 ** 0.5`). Half-rate is the **generous** end
    of the 25–50% range in the literature.
  - *Wash/rub-off.* Full strength for an hour, then decaying linearly to bare
    skin over the following six — sunburntimer's "profuse sweating" profile,
    i.e. swimming or a hot beach day.

Sanity numbers for skin type II, bare skin: UV 2.5 → ~110 min to burn;
UV 6.3 → ~35 min; UV 12.6 → ~17 min. That matches lived experience of a
Margaret River summer.

## Data source

`weather.forecast_home` (met.no, HA's built-in default weather integration).
Its **hourly forecast already carries `uv_index`** — no external API, no API
key, no HACS integration. This was the surprise of the build: an Open-Meteo
REST sensor was the expected path and turned out to be unnecessary.

### That UV is clear-sky, and we correct it ourselves

**Verified against api.met.no on 2026-09-08:** the only UV field met.no
publishes is `ultraviolet_index_clear_sky`, and the HA `met` integration
surfaces it unchanged as `uv_index`. It is *not* cloud-adjusted, whatever the
name in HA suggests. An earlier revision of this page claimed otherwise; it was
wrong.

Switching data source does not fix it. Open-Meteo's `uv_index` (documented as
"considering clouds") and its `uv_index_clear_sky` came back **identical to two
decimal places for all 21 daylight hours tested** at this location — including
a morning at 88% cloud. Both providers hand you clear sky here.

So the package applies its own cloud modification factor from the
`cloud_coverage` already present in each forecast entry:

```
CMF = 1 - 0.7 * C^3          (C = cloud fraction, 0-1)
```

| Cloud | Factor | Rationale |
|---|---|---|
| 10% | 0.999 | nothing |
| 50% (broken) | 0.91 | broken cloud barely dents UV — it scatters as much as it blocks |
| 90% | 0.49 | |
| 100% (overcast) | 0.30 | heavy overcast leaves roughly a third |

The cube deliberately keeps the curve flat through the broken-cloud range.
Under scattered cloud, ground-level UV can briefly *exceed* the clear-sky value
(the broken-cloud enhancement effect), so aggressively discounting there would
be both wrong and unsafe. Worked effect on a midsummer day: UV 12.6 → 11.5 at
50% cloud (verdict unchanged, "Lather up"), but 12.6 → 3.8 at full overcast,
which correctly downgrades the day to "Only for a long stint". The constant
`0.7` and the exponent are the tuning knobs if this ever reads wrong.

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

## Two findings worth not re-deriving

**A properly applied coat of SPF 50 cannot burn you here, in a whole day.**
Measured against the real met.no curve, one perfect 2 mg/cm² coat accumulates
15% of a burn dose today, 32% at UV 12.6, and 42% at UV 16.4 — and 23%/54%/73%
respectively once sweat decay is included. It never reaches 100%. That is why
the package models under-application: with a nominal SPF 50 the sensor would
read `won't burn` on every day of the year and tell you nothing. The practical
reading is the one the user put best — *SPF 50 works, if you reapply and get
good coverage.*

**The UV peak is not the worst time to head out.** For a short exposure it is,
but for anything over ~90 minutes, leaving mid-morning into the rising limb
burns you sooner than leaving at noon into the falling one. On a UV-2.5 winter
day: 2 h if you leave now (10am), 2.5 h if you leave at the 12pm peak. So
`worst_burn_minutes` is a genuine minimum over every remaining start time, not
a burn time evaluated at the peak hour. An earlier version of this package
quoted a constant-UV-at-peak number, which was both a different question and
consistently pessimistic.

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
4. **A field called `uv_index` is not necessarily the UV you'd get.** Two
   independent providers both served clear-sky values under that name here.
   Check the upstream field name (`api.met.no` calls it
   `ultraviolet_index_clear_sky`) rather than trusting the integration's
   normalised attribute name.
5. **Entity IDs follow the friendly name, not `unique_id`.** `name: "Time to
   Sunburn SPF 50"` becomes `sensor.time_to_sunburn_spf_50` — note `spf_50`,
   not `spf50`. Cost one round of "entity not found" on the dashboard. Same
   trap is recorded in [home-assistant-deploy.md](home-assistant-deploy.md).
6. Skin type is hardcoded, not an `input_select`. One household, one knob, and
   the brief was "as simple as possible". If it ever needs per-person answers,
   an `input_select` plus a MED lookup dict is the obvious next step.

## Cross-references

- Package: `ha/sunburn.yaml` — commented with the model and the MED table.
- Deploy procedure: [home-assistant-deploy.md](home-assistant-deploy.md).
- Dashboard: cards live in `ha/dashboards/overview.yaml`.
