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

## Windows wallpaper on the Cullen laptop

The work laptop (`laptop-btibh4ie`, the Windows host that also carries the WSL
VM) renders the same data as its desktop wallpaper.

**Where the day comes from:** the API, on every single run — the script holds no
ephemeris and no cached calendar. Each run fetches
`https://bd.ablz.au/v1/day/<today>?at=<now>` and reads
`ingress.next.from_day_type`, exactly like the Home Assistant sensors above. If
`bdday` is unreachable the script logs the failure, exits non-zero, and leaves
the existing wallpaper untouched. From the Cullen network this resolves through
the split-DNS path; from home or over the tailnet it resolves straight to doc1
(`192.168.1.29`). Both were observed working.

- Payload: [`tools/windows/Set-BdDayWallpaper.ps1`](../../../tools/windows/Set-BdDayWallpaper.ps1)
- Installer: [`tools/windows/Install-BdDayWallpaper.ps1`](../../../tools/windows/Install-BdDayWallpaper.ps1)
- Installed to `C:\Users\abl030\bdday-wallpaper\`, state under
  `%LOCALAPPDATA%\bdday-wallpaper\` (rendered PNG, recorded original, log).
- Deployed 2026-09-08 over `ssh wsl-laptop` (Windows OpenSSH on :2222 — see
  [wsl-tailscale-ssh.md](../infrastructure/wsl-tailscale-ssh.md)). The repo is
  the source of truth; copy with `scp` and re-run the installer.

### Why a scheduled task and not just SSH

**An SSH session cannot set the visible wallpaper.** It gets its own
non-interactive window station, so `SystemParametersInfo` there does not reach
the logged-on desktop, and `[System.Windows.Forms.Screen]` reports a
placeholder 1024x768 rather than the real display. Both symptoms were observed
directly.

The task therefore runs with an `InteractiveToken` principal in the user's own
session, at logon, on session unlock, and every 15 minutes. It runs at
`LeastPrivilege`: setting a wallpaper needs no elevation, and the script writes
only under `%LOCALAPPDATA%` and `HKCU`. Confirmation that it really ran in the
right session is the log line recording `[1920x1080]` rather than `[1024x768]`.

### Gotchas that cost time

- **`$env:USERDOMAIN` is `WORKGROUP` on this laptop.** Building the task
  principal as `$env:USERDOMAIN\$env:USERNAME` makes `Register-ScheduledTask`
  fail with *"No mapping between account names and security IDs was done"*
  (`0x80070534`). Use
  `[System.Security.Principal.WindowsIdentity]::GetCurrent().Name`, which
  yields `LAPTOP-BTIBH4IE\abl030`.
- **Windows caches the wallpaper by path**, so the script alternates between
  `wallpaper-a.png` and `wallpaper-b.png` to guarantee a redraw.
- **PowerShell 5.1 reads a BOM-less `.ps1` as ANSI**, so any non-ASCII glyph
  (the middle-dot separator) is built from a code point in code rather than
  typed as a literal.
- **GDI+ renders colour emoji as monochrome tofu**, and Windows has no MDI
  font, so the four day-type icons are drawn as GDI+ vector paths. They scale
  to any resolution and take their colour from the day's palette.
- The script re-applies only when the rendered content actually changes (type,
  sign, element, changeover wording, or resolution). A re-run inside the same
  day is a verified no-op, so the desktop does not flicker every 15 minutes.
  This is also why the wallpaper carries an absolute changeover time and no
  live countdown.

### Removing it

**One command, from doc1, no repo checkout needed.** The installer keeps a copy
of itself next to the payload precisely so that removal is self-contained:

```bash
ssh wsl-laptop
powershell -ExecutionPolicy Bypass -File C:\Users\abl030\bdday-wallpaper\Install-BdDayWallpaper.ps1 -Uninstall
```

That restores the original wallpaper, unregisters both scheduled tasks, deletes
both scripts, and removes `C:\Users\abl030\bdday-wallpaper\`. It deliberately
leaves `%LOCALAPPDATA%\bdday-wallpaper\` (the log, the recorded original, the
last rendered PNG) so a removal can still be audited afterwards; delete that
directory too for a completely clean slate.

Verified end-to-end on 2026-09-08 — uninstalled and reinstalled on the live
laptop. Expected output:

```
Restoring the original wallpaper in the interactive session...
Restore task result = 0 (0 = success)
Unregistered scheduled task 'BdDay-Wallpaper'.
Unregistered scheduled task 'BdDay-Wallpaper-Restore'.
Removed C:\Users\abl030\bdday-wallpaper\Set-BdDayWallpaper.ps1
Removed C:\Users\abl030\bdday-wallpaper\Install-BdDayWallpaper.ps1
Removed empty C:\Users\abl030\bdday-wallpaper
```

Rollback works *remotely* only because the installer also registers a
triggerless on-demand `BdDay-Wallpaper-Restore` task. Starting that task runs
the restore inside the interactive session; calling the script with `-Restore`
directly over SSH would update the registry but never repaint the live desktop.

The pre-existing wallpaper (`Dynabook_Option6.png`, style 10) is recorded once
in `original-wallpaper.txt` and never re-captured, so reinstall/uninstall cycles
cannot cause it to "remember" one of our own images as the original.

#### If the installer is missing

Everything above is just three primitives, so removal never depends on any file
being present:

```powershell
Start-ScheduledTask -TaskName BdDay-Wallpaper-Restore   # repaint the original
Unregister-ScheduledTask -TaskName BdDay-Wallpaper -Confirm:$false
Unregister-ScheduledTask -TaskName BdDay-Wallpaper-Restore -Confirm:$false
Remove-Item C:\Users\abl030\bdday-wallpaper -Recurse -Force
```

If even the restore task is gone, set any wallpaper by hand — the original path
is the first line of
`%LOCALAPPDATA%\bdday-wallpaper\original-wallpaper.txt` (`path|style`).

### Pausing instead of removing

```powershell
Disable-ScheduledTask -TaskName BdDay-Wallpaper    # freeze on the current image
Enable-ScheduledTask  -TaskName BdDay-Wallpaper
```

### Other operations

```powershell
# preview any day type without touching the desktop (safe over SSH)
powershell -File C:\Users\abl030\bdday-wallpaper\Set-BdDayWallpaper.ps1 `
  -RenderOnly C:\Temp\x.png -PreviewType Flower

# force a redraw now
Start-ScheduledTask -TaskName BdDay-Wallpaper

# what has it been doing?
Get-Content "$env:LOCALAPPDATA\bdday-wallpaper\bdday-wallpaper.log" -Tail 20
```

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
