# Biodynamic ("moon day") calendar — consuming the `bdday` API

**Researched:** 2026-09-08
**Status:** Working — Home Assistant banner deployed on the `ir-sensor` dashboard.
**Service:** `bdday` on doc1, `https://bd.ablz.au` — see
[`modules/nixos/services/bdday.nix`](../../../modules/nixos/services/bdday.nix)
and [cullen-bd-split-dns.md](../infrastructure/cullen-bd-split-dns.md).

This page is about *consuming* the API. The service itself is stateless,
deterministic, and loopback-only behind nginx; it has no database and no
runtime egress.

## Endpoints

The dashboard bundle only ever calls two routes:

| Route | Purpose |
|---|---|
| `GET /v1/day/{YYYY-MM-DD}?at={HH:MM}` | Day + moment data (what we use) |
| `GET /v1/visuals/{YYYY-MM-DD}?at={HH:MM}` | Geometry for the SVG figures |
| `GET /healthz` | `{"status":"ok",...}`, used by the Kuma monitor |

There is **no** `today`/`now` alias — `/v1/day/today` returns HTTP 400, and
`/v1/now`, `/v1/day`, `/v1/today`, `/openapi.json` all 404. Any consumer must
template the current date and time into the URL itself. Times are AWST
(UTC+8), matching the service's fixed Wilyabrup/Cullen locality.

## The one thing that will trip you up

**The top-level `day_type` is a whole-day descriptor, not the current type.**

On a day containing an ingress it reads `"Fruit/Leaf"` for *every* value of
`at`, so it can never answer "what day is it right now". Verified 2026-09-08
against `source_revision` `5fb42f68` by sweeping `at` across 2026-09-09, whose
ingress is at 17:43:40:

| `at` | `day_type` | `moon.sidereal_sign_at` | `ingress.next` |
|---|---|---|---|
| 00:30 | `Fruit/Leaf` | Cancer | 09-09 17:43 Leaf→Fruit |
| 09:00 | `Fruit/Leaf` | Cancer | 09-09 17:43 Leaf→Fruit |
| 17:30 | `Fruit/Leaf` | Cancer | 09-09 17:43 Leaf→Fruit |
| 17:50 | `Fruit/Leaf` | **Leo** | 09-11 21:37 Fruit→Root |
| 23:30 | `Fruit/Leaf` | **Leo** | 09-11 21:37 Fruit→Root |

`ingress.next` **is** moment-relative, and it carries both halves of the
answer:

- `ingress.next.from_day_type` / `from_sign` — the type and sign **in force at
  `at`**. This is the correct "current day type".
- `ingress.next.at` / `to_day_type` / `to_sign` — the **next** changeover.

So a single object answers "what is it now" and "when does it change".

Two nearby fields that look useful and are not:

- `ingress.within_day` is the day's own ingress whether or not it has already
  passed, so it is not a "next change".
- `dominant_day_type` is the type covering the most hours of the calendar day
  (`Leaf` on the sample above, even at 23:30 when Fruit is in force).

`moon.sidereal_sign_at` is genuinely moment-accurate and agrees with
`ingress.next.from_sign`, but it is a zodiac sign, so using it would mean
re-deriving the sign→type mapping in the consumer. Prefer `ingress.next`.

## Timestamps

Instants carry **nanosecond** precision with a numeric offset, e.g.
`2026-09-09T17:43:40.750400459+08:00` (9 fractional digits).

Home Assistant parses these fine — its `DATETIME_RE` captures
`(?P<microsecond>\d{1,6})\d{0,6}` and truncates — so `as_datetime` works
directly and a `device_class: timestamp` sensor needs no pre-munging. Verified
live: the string above renders as `2026-09-11 21:37:28.630298+08:00`.

Other consumers using a stricter ISO-8601 parser may need to trim to 6
fractional digits.

## Home Assistant integration

Defined in [`ha/biodynamic_day.yaml`](../../../ha/biodynamic_day.yaml), a
package registered from `ha/configuration.yaml`. One REST resource, polled
every 5 minutes, backing two sensors:

| Entity | State | Notes |
|---|---|---|
| `sensor.biodynamic_day` | `Root`/`Leaf`/`Flower`/`Fruit` | Templated `icon:` per type; attributes carry the sign and the next change |
| `sensor.biodynamic_day_next_change` | ISO instant | `device_class: timestamp`, so the frontend renders relative time for free |

Type→icon mapping used: Root `mdi:carrot`, Leaf `mdi:leaf`, Flower
`mdi:flower`, Fruit `mdi:fruit-cherries`, fallback `mdi:sprout`.

Notes worth keeping:

- A templated `icon:` **is** accepted on a `rest:` sensor (HA 2026.9.1) —
  confirmed by `POST /api/config/core/check_config` returning
  `{"result":"valid"}`.
- `resource_template` is re-rendered on every poll, so `now()` in the URL is
  correct and does not freeze at setup time.
- Adding the package needed a **full restart**, not `reload_all`, because it
  introduced the `rest:` domain (see the reload matrix in
  [home-assistant-deploy.md](home-assistant-deploy.md)).
- `relative_time()` only formats *past* datetimes; for a future changeover use
  `time_until()`.

Presented on the `ir-sensor` dashboard as a top markdown banner plus two
badges. Masonry views render badges as a full-width strip above all cards, so
the badges are what makes it glanceable at the very top on desktop.

Because the poll interval is 5 minutes, the banner can lag a changeover by up
to that long. Ingresses are 2-3 days apart, so this is deliberate.

## Quick checks

```bash
# What is it right now?
curl -fsS "https://bd.ablz.au/v1/day/$(date +%F)?at=$(date +%H:%M)" \
  | jq '{now: .ingress.next.from_day_type, sign: .ingress.next.from_sign,
         changes_at: .ingress.next.at, becomes: .ingress.next.to_day_type}'

# Does Home Assistant agree?
curl -fsS -H "Authorization: Bearer $HA_TOKEN" \
  https://home.ablz.au/api/states/sensor.biodynamic_day | jq '.state, .attributes'
```

## When to revisit

- If `bdday` grows a `today`/`now` alias, drop the `now()` templating from
  `resource_template`.
- If the API ever gains a genuinely moment-scoped top-level field, prefer it
  over `ingress.next.from_day_type` and simplify the templates.
- `meta.schema_version` is currently `"1"`; a bump is the signal to re-verify
  the table above.
