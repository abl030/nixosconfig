# komga-sync — JSON sidecar → Komga REST metadata

**Date written:** 2026-05-23
**Status:** ✅ deployed daily on doc2 at 04:29 AWST
**Module:** `modules/nixos/services/komga-sync.nix`
**Script:** `scripts/komga-sync.py`
**Secret:** `secrets/hosts/doc2/komga-sync.env` — `KOMGA_API_KEY`
**Schedule:** `*-*-* 04:15:00 Australia/Perth` + 15 min jitter

## Why this exists

Komga reads ZERO metadata from PDF files. We have rich per-issue
metadata in JSON sidecars (article TOC, authors, keywords, page numbers,
links to the publisher's website), and Komga's REST API accepts metadata
PATCHes with field-level `*Lock=true` so library refreshes don't stomp
them. This script is the bridge — see the field mapping below.

It also owns a small side-task: **ensure every library has
`hashKoreader=true`** so KOReader cross-device progress sync keeps working.
See [koreader-sync.md](./koreader-sync.md) for why this matters and the
client-side setup. The `ensure_hashkoreader()` step in `komga-sync.py` is
a no-op when the flag is already set; on a brand-new library it flips the
flag and triggers an analyze so the partial-MD5 index gets built.

## Field mapping — JSON sidecar → Komga

### Per-book (`PATCH /api/v1/books/{id}/metadata`)

| Sidecar | Komga `BookMetadataUpdateDto` | Notes |
|---|---|---|
| `title` | `title` (+ `titleLock=true`) | "Grapegrower & Winemaker May 2026 (#748)" |
| `issue_number` (GAW) | `number`, `numberSort` (float) | Direct |
| `volume`+`issue` (WVJ) | `number=Vol{V}-{I:02d}`, `numberSort=V*100+I` | e.g. `Vol39-03`, sort `3903` |
| `year`+`month` | `releaseDate` (`YYYY-MM-01`) | Day always 1 |
| `articles[]` | `summary` (markdown TOC) | `1. [Title](url) — author (pp. X-Y)` per line |
| `articles[].keywords` (flatten + dedup, lowercased, capped) | `tags[]` | Capped at ~60 tags / 500 chars total — Komga UI shows tag chips |
| `articles[].author` (dedup) | `authors[{name, role: "writer"}]` | Most GAW articles have empty author; mostly populated for synthetics |
| `issue_url` | `links[{label: "Issue page", url}]` | Clickable chip on the book detail page |

`page_numbers`, `articles[].url`, `articles[].merged_pages` (synthetic only)
all DROPPED — no Komga field maps. They survive in the JSON sidecar for
future indexers.

### Per-series (`PATCH /api/v1/series/{id}/metadata`)

| | Series field |
|---|---|
| `title` | "Grapegrower & Winemaker (2024)" — Komga creates one series per year directory |
| `summary` | invented one-sentence description |
| `publisher` | "Winetitles Media" |
| `genres` | `["Magazine", "Wine industry"]` (Komga lowercases on store) |
| `language` | `"en"` |

## Idempotency

* Lists all books once at startup, caches by file URL (the `url` field
  on Komga's book object is the filesystem path — stable across title
  rewrites).
* GETs current metadata before PATCHing; only PATCHes when something
  actually changes.
* Series syncs are also diff-then-PATCH.
* Locks every set field via `<field>Lock: true` so a library refresh
  (or user metadata-refresh action) doesn't stomp our values.
* Lowercases tag/genre values to match Komga's storage normalisation.

Smoke test on 2026-05-23:

```
first run:  135 books patched, 19 series patched, 0 errors
second run: 0 patches, 135 books skipped, 19 series skipped, 0 errors, exit 0
```

## Two gotchas we hit

### 1. Komga's book `?search=...` matches on title, not filename

After the first run our titles became "Grapegrower & Winemaker May 2026
(#748)" — search by `04_GW_APR_2026-WEB` returns nothing. The script
**lists all books in a library once, caches by `url` field** (which IS
the filesystem path and IS stable) and looks up sidecars by filename
stem against that cache. Don't switch to `?search=` lookups.

### 2. Komga lowercases genres / tags on store

If we POST `Magazine` and then GET to compare, Komga returns `magazine`.
The naive equality check thrashes. The script lowercases the desired
values before comparing — only PATCHes when meaningfully different.

## What Komga underuses

* **Tags** show up as chips on the book detail page but **Komga has no
  cross-library tag search** — you have to enter a library scope. With
  ~36 tags per issue the chip cloud is busy; tune `MAX_TAG_CHARS_TOTAL`
  in the script if you find it noisy.
* **Per-article `page_numbers`** has no Komga schema. We encode it in
  the markdown summary as `(pp. X-Y)` — readers can use Komga's PDF page
  jumper to navigate, but it's manual.
* **`numberSort` is per-series** — within one year-series GAW issues
  600-748 sort correctly, but cross-year sorting is the year-series
  order, not the issue-number order. Fine for our drill-down UX.

## Notifications

* **OnFailure** → root oneshot dumps last 50 journal lines to Gotify at
  priority 5 (warning — failures here mean new issues might lack metadata
  for a day, not user-visible breakage)
* No OnSuccess — this is a silent maintenance task. Manually check via
  `journalctl -u komga-sync` if curious.

## Tooling notes

* Pure stdlib (`urllib.request`, `json`, `pathlib`) — no requests / no
  third-party deps. Keeps the systemd unit minimal.
* Reads `KOMGA_URL` (default `https://magazines.ablz.au`), `KOMGA_API_KEY`
  (required), `SIDECAR_ROOT` (default `/mnt/data/Media/Magazines`),
  `DRY_RUN` (default off — set to `1` to see what would change).

## When to run manually

```bash
# Force a sync after editing JSON sidecars by hand
ssh doc2 sudo systemctl start komga-sync && \
  ssh doc2 journalctl -fu komga-sync

# Dry-run from a workstation (without writing)
KOMGA_API_KEY=$(sops -d secrets/hosts/doc2/komga-sync.env | grep KOMGA_API_KEY | cut -d= -f2-) \
KOMGA_URL=https://magazines.ablz.au \
DRY_RUN=1 \
python3 scripts/komga-sync.py
```

## See also

* [magazines.md](./magazines.md) — overview hub
* [komga.md](./komga.md) — the Komga deploy
* [koreader-sync.md](./koreader-sync.md) — cross-device progress sync (this
  script ensures the server-side `hashKoreader` flag for it)
* Komga REST OpenAPI: https://komga.org/docs/openapi/
