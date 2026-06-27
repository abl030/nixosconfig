# gwm-archiver — Grapegrower & Winemaker PDF archiver

**Status:** ✅ working in production on doc2 since 2026-05-23
**Module:** `modules/nixos/services/gwm-archiver.nix`
**Script:** `scripts/gwm-archiver.py`
**Secret:** `secrets/hosts/doc2/gwm-archiver.env` — `WT_USER` + `WT_PASS`
**Output:** `/mnt/magazines/GAW/<YYYY>/<MM>_<basename>.{pdf,json}` (dedicated single-disk NFS share — moved off `/mnt/data` 2026-06-28 to escape the shfs-union ESTALE that failed this service's namespace bind; see [../infrastructure/unraid-nfs-shfs-estale.md](../infrastructure/unraid-nfs-shfs-estale.md))
**Schedule:** weekly, Sun 03:30 AWST + 1 h jitter

> 📂 Part of the magazine archive system. Start at
> [magazines.md](./magazines.md) for the overall picture.
> Siblings: [wvj-archive.md](./wvj-archive.md), [komga.md](./komga.md),
> [komga-sync.md](./komga-sync.md), [magazine-epub-pipeline.md](./magazine-epub-pipeline.md).

## What this does

Weekly oneshot that walks `https://winetitles.com.au/gwm/articles/` while
logged in as our subscriber account, downloads every issue's FULL ISSUE PDF,
and writes a JSON sidecar with the table of contents (per-article title,
author, keywords, page numbers).

Where a FULL ISSUE PDF isn't published but per-article PDFs are, the script
**synthesises** a full-issue PDF by downloading every article PDF and merging
them with `qpdf`. The sidecar then carries an extra `merged_pages: [start, end]`
per article so consumers can map back to print-page numbers from the print
edition.

## Server-side reality (as of 2026-05-23)

The /gwm/articles/ archive index lists 256 magazine issues (#492 Jan 2005 →
#748 May 2026), but they're not all reachable:

| Issue range | Date range | What's available |
|-------------|-----------|------------------|
| #492 – #641 | Jan 2005 – Jun 2017 (150 issues) | "Download PDF" buttons exist on every article page, but `POST tmp.php` returns `200 application/pdf` with `0 bytes`. Files appear to have been purged server-side. We email the publisher to ask for a restore — see `docs/wiki/services/gwm-archiver-broken-archive.md`. |
| #642 – #650 | Jul 2017 – Mar 2018 (9 issues) | Per-article PDFs work (1–3 MB each), but no FULL ISSUE PDF is published. We synthesise via `qpdf` merge. |
| #651 – #748 | Apr 2018 – May 2026 (98 issues) | FULL ISSUE PDF published directly; we just download it. |

Total recoverable today: **107 issues (~2.2 GB)**.

## Mechanics — the WordPress download flow

The site is a WP install. Each article has an "Article Details" panel with a
form pointing at `/wp-content/uploads/tmp.php` with two hidden inputs:

```html
<input type="hidden" name="docid"  value="270436" />
<input type="hidden" name="dockey" value="1779510345-1988576611" />
```

* `docid` — the WP post ID. Stable per article/issue.
* `dockey` — server-issued nonce, format `<unix_ts>-<random>`. Bound to the
  current logged-in session; expires after some interval.

The flow per issue is:

1. POST `wp-login.php` with `log=$WT_USER&pwd=$WT_PASS&testcookie=1` plus a
   pre-seeded `wordpress_test_cookie`.
2. GET `/gwm/articles/` to enumerate issue slugs (`/gwm/articles/<month>-<num>/`).
3. GET the issue page, look for `/gwm/articles/<slug>/<...>-full-issue/`.
4. If found, GET that page and scrape `docid` + `dockey`, then POST
   `tmp.php` — response is the PDF.
5. If no FULL ISSUE link, walk every article subpage on the issue page,
   scrape + POST per article, then `qpdf --empty --pages a.pdf 1-z b.pdf 1-z
   ... -- out.pdf` to merge.

The slug → year/month mapping is linear (one issue per month, anchored at
#748 = May 2026): `idx = (2026*12+4) - (748-N)`.

## PDF metadata embedding — quirks of `pdfunite` vs `qpdf`

Initial implementation used `pdfunite` from poppler-utils to merge per-article
PDFs. The resulting file evaluated as a valid PDF (`pdfinfo` happy, viewers
render fine), but `exiftool` refused to write trailer metadata into it because
poppler emits an unusual xref structure ("Objects in xref table exceed trailer
dictionary Size").

Switched to `qpdf --empty --pages a.pdf 1-z b.pdf 1-z ... -- out.pdf` — clean
xref, exiftool writes Title/Subject/Keywords without complaint, and file
sizes are comparable. The module pulls in qpdf via `path` rather than
poppler's pdfunite.

`exiftool -overwrite_original -Title=… -Keywords=…` then bakes the issue
title and a concatenated keyword set across all articles into the PDF
dictionary. JSON sidecar carries the full structured TOC.

## Idempotency + auto-heal

* `existing_artifacts()` checks for `<YYYY>/<MM>_*.pdf` + `<YYYY>/<MM>_*.json`
  and short-circuits with `skip-complete` if both exist. Default weekly run
  on a populated archive does zero work for the 107 known issues.
* No "unavailable" marker for the 150 dead issues — we re-probe them every
  week so we auto-heal if the publisher restores the files.
* Fail-fast in `synthesise_from_articles()`: after 2 consecutive empty
  per-article PDFs (no-form / 0-byte), the function returns. Caps each dead
  issue at ~9 s of probe time (1 issue page + 2 article pages + 2 tmp.php
  POSTs + sleeps).

A no-op weekly run takes ~24 minutes wall clock, ~3 s CPU, ~38 MB inbound
traffic — almost entirely the 149 dead-issue probes. If you'd rather skip
the probes, you could add an explicit lower-bound floor to `list_issues()`,
but the cost is low and the auto-heal is worth it.

## Notifications — `OnSuccess=` + `OnFailure=` siblings

The Python script doesn't talk to Gotify itself. Instead it prints a
`NEW_ISSUE:` marker line to stderr for any newly-downloaded issue, and the
module wires two sibling systemd units:

* `gwm-archiver-notify-success.service` — `OnSuccess=`, runs as root, greps
  the last 45 minutes of the main service's journal for `NEW_ISSUE:` lines.
  If any, posts a priority-4 Gotify push with the summary. Silent on no-op
  weeks. **Note:** the grep must be `{ grep -E … || true; }` to swallow the
  empty-match exit-1 under `set -euo pipefail`, otherwise the unit fails on
  no-op weeks.
* `gwm-archiver-notify-failure.service` — `OnFailure=`, dumps the last 50
  journal lines at priority 7.

Both helpers read the shared `gotify/token` (mode 0400, root-owned) directly
because they run without a `User=`. Same pattern as `rtrfm-nowplaying` and
`kopia`.

## First-run audit (2026-05-23)

Smoke test on a fresh deployment with the archive already fully populated:

```
summary: {'skip-complete': 107, 'no-pdf': 149}
23 min 32 s wall, 2.79 s CPU, 38.5 MB in, 2.2 MB out, 24 MB RSS peak
OnSuccess fired → notify-success exited 0 with no Gotify push (no NEW_ISSUE lines)
OnFailure inactive
```

Note: only 149 no-pdf reported even though the dead range is 150 issues
(#492–#641 inclusive). The archive index lists 256 magazine slugs but the
publisher has skipped some numbers in the very old archive; the missing
slug is one of those.

## Why we don't archive into Paperless instead

Paperless is for documents you want OCR'd + tagged + searchable as a
personal archive. These PDFs already carry embedded text from InDesign and
the JSON sidecar gives us per-article search. Dropping a 96-page magazine
into Paperless would balloon its index for low return, and the magazine
already lives on the media share where the household reads it directly.
