# wvj-archive — Wine & Viticulture Journal archiver (one-shot)

**Date written:** 2026-05-23
**Status:** ✅ complete — journal ceased publication 2024, no further runs needed
**Script:** `scripts/wvj-archive.py`
**Output:** `/mnt/data/Media/Magazines/WVJ/<YEAR>/V<vol>-<issue>_<basename>.{pdf,json}`
**No NixOS module** — one-shot, run on demand

## Why a separate script and not a unified one

The two magazines share the same auth + form-POST mechanism (see
[gwm-archiver.md](./gwm-archiver.md)) but their URL structure and slug
format differ enough that a unified script would be more complex than
two narrow ones. Differences:

| | GAW | WVJ |
|---|---|---|
| URL base | `/gwm/articles/` | `/wvj/articles/` |
| Cadence | monthly (sometimes bi-monthly historically) | quarterly (bi-monthly for vols 26-32) |
| Slug | `<month>-<num>` (e.g. `may-748`) | `wine-viticulture-journal-volume-<V>-no-<I>-<YYYY>` |
| Numbering | issue number 492-748 | volume+issue (Vol 26-39, issue 1-6 then 1-4) |
| Date math | linear from anchor #748=May 2026 | year extracted from slug |
| Future runs | weekly via timer | none |

So `wvj-archive.py` is mostly a fork of `gwm-archiver.py` with the
slug parsing + output naming swapped. It's checked in for reproducibility
in case the publisher restores old issues later (unlikely).

## What was recovered (run 2026-05-23)

```
summary: {'downloaded': 25, 'no-pdf': 41, 'synthesised': 3}
```

| Vol range | Year range | Result |
|---|---|---|
| Vol 33 No 2 – Vol 39 No 3 | 2018 Q2 – 2024 Q3 (25 issues) | Native FULL ISSUE PDF |
| Vol 31 No 3, Vol 32 No 5, Vol 33 No 1 | 2016 Q2, 2017 Q4, 2018 Q1 (3 issues) | Synthesised from per-article PDFs (some old issues had surviving per-article PDFs even though the fail-fast probes initially looked dead) |
| Vol 26 – Vol 32 (most issues) | 2011 – 2017 (41 issues) | Server-side 0-byte (same broken pre-Jul-2017 archive symptom as GAW, see [gwm-archiver-broken-archive.md](./gwm-archiver-broken-archive.md)) |

Total: 28 issues, ~517 MB. Output mtime within `/mnt/data/Media/Magazines/WVJ/`.

## Filename pattern

`V<vol>-<issue>_<original_basename>.pdf` — e.g. `V39-3_WVJ_Winter_24_FULL_ISSUE.pdf`.
The `V<vol>-<issue>_` prefix gives a clean sort order within a year and
makes the volume/issue obvious from the filename.

JSON sidecar shape is the same as GAW's but carries `volume`/`issue` instead
of `month`/`issue_number`:

```json
{
  "publication": "Wine & Viticulture Journal",
  "volume": 39, "issue": 3, "year": 2024,
  "title": "Wine & Viticulture Journal Vol 39 No 3 (2024)",
  "issue_url": "https://winetitles.com.au/wvj/articles/wine-viticulture-journal-volume-39-no-3-2024/",
  "synthetic": false,
  "articles": [...]
}
```

## When to run again

* **Publisher restores old issues.** If you email winetitles and they bring
  the 2005-2017 PDFs back online, re-run: the script's fail-fast logic
  means it'll re-probe everything cheaply and only download what's newly
  available.
* **Publisher resumes the WVJ.** Unlikely (Vol 39 No 3 lead was
  "Farewell to the Journal"), but if so the script will pick up new issues
  with no changes — slug parsing handles any future volume/issue numbers.
* **You want a fresh sync.** `WT_USER=... WT_PASS=... python3 scripts/wvj-archive.py`
  — idempotent, skips anything already on disk.

## See also

* [magazines.md](./magazines.md) — overview hub
* [gwm-archiver.md](./gwm-archiver.md) — sibling system, deeper detail on the
  WordPress download mechanism that both scripts use
* [gwm-archiver-broken-archive.md](./gwm-archiver-broken-archive.md) — the
  pre-2017 server-side 0-byte issue that affects both magazines
