# Magazine PDF → EPUB pipeline

**Date written:** 2026-05-23
**Status:** ⏳ batch grinding through the back catalogue (~30 hour ETA on epi)
**Scripts:**
  - `scripts/marker-batch.py` — orchestrator (parallel workers, resume-safe)
  - `scripts/marker-to-epub.py` — Marker markdown → clean EPUB post-processor
**No NixOS module yet** — see "Future" below

## Why an EPUB pipeline

PDFs are hostile on phone. They're a *layout* format ("put glyph G at
coordinate (x, y)") not a *content* format ("this is paragraph 3 of
section 2"). Multi-column magazine PDFs make it worse: a designer wrote
"drop a pull-quote here" and the PDF dutifully captured those glyphs at
those pixels with zero structural metadata. Calibre's `ebook-convert`
produces garbage on these. We need actual ML layout detection plus
domain-specific cleanup.

KOReader (the user's phone reader) handles reflowable EPUB beautifully.
Komga also reads EPUB OPF metadata natively (unlike PDF), so an EPUB
with rich OPF gives us a no-PATCH metadata path going forward.

## Architecture — two-stage pipeline

```
   <basename>.pdf                  ┐
   <basename>.json (sidecar)       │
                                   │
   marker_single                   ▼      (15-30 min CPU per 80pg, 14 GB RAM)
   ├── PdfProvider (text layer)    │
   ├── Layout detection (Surya)    │
   ├── Text recognition (Surya)    │      The slow phases. Surya = ML models.
   ├── Table detection (Surya)     │
   └── Markdown rendering          │
                                   ▼
   <basename>.md  (Marker's "raw" markdown — 1600+ lines, 23% noise)
                                   │
                                   │   marker-to-epub.py — post-processor
                                   │   ├── fuzzy-match sidecar article titles
                                   │   ├── inject ## H2 boundaries (16/16 hit rate)
                                   │   ├── strip front matter (cover/contents/masthead)
                                   │   ├── strip back matter (classifieds)
                                   │   ├── group short-line runs → <pre> blocks
                                   │   ├── collapse drop-cap orphans
                                   │   └── pandoc → EPUB with rich OPF metadata
                                   ▼
   <basename>.epub   (~80 KB, real per-article TOC, mobile-readable)
```

## marker-to-epub.py — the post-processor

Marker alone produces *readable* markdown for magazine PDFs but with
significant problems:

* **Only 8 H2 boundaries** detected for ~16-25 actual articles in a typical
  issue. KOReader's TOC is useless.
* **Cover + contents + masthead** (first ~150 lines) bleed into the body.
* **Classifieds + advertiser index + calendar** (last ~100 lines) ditto.
* **Single-letter drop-cap orphans** (`W\n\nelcome to the...`) appear as
  standalone paragraphs.
* **Pricing tables** appear as one-word-per-line runs.
* **23% of lines are 1-2 words** — ad slogans, masthead bleed, column
  headers split mid-flow.

The post-processor fixes all of this using the JSON sidecar's
`articles[]` titles as ground truth:

1. **Fuzzy-match each sidecar article title** against a normalised
   two-line-merged view of Marker's body using `rapidfuzz.partial_ratio +
   token_set_ratio` averaged, plus a head-match boost so contents-page
   hits don't outscore body hits, plus an early-document penalty driven
   by a TOC-density window scan.
2. **First match per title anchors start-of-body** — cover/contents/
   masthead get dropped.
3. **Inject `## <Title>`** at every matched location → proper per-article
   TOC.
4. **Strip back matter** via the "sustained drop in average paragraph
   length toward the tail" heuristic.
5. **Group runs of ≤3-word lines** into fenced code blocks (pricing
   table debris).
6. **Collapse drop-cap orphans** into the following paragraph.
7. **Strip 2 invalid XML control chars** (BEL/0x07) Marker leaks from
   PDF text extraction — without this fix the EPUB was unparseable.
8. **pandoc → EPUB** with rich OPF: `dc:title`, `dc:date`,
   `dc:publisher`, `belongs-to-collection`, `group-position`, ~150
   deduped `dc:subject` tags from per-article keywords, `dc:identifier`,
   `dc:language`. Komga + KOReader pick these up natively.

Calibration sample (March 2025 issue):

* 16/16 article H2s injected (sidecar had 16 articles; Marker had 8 wrong)
* 1635 markdown lines → 1000 (~39% noise removed)
* 82 KB final EPUB
* `epubcheck` clean (0 fatals / 0 errors / 0 warnings)

## marker-batch.py — the orchestrator

Walks `/mnt/data/Media/Magazines/{GAW,WVJ}/<YEAR>/*.pdf`, skips any PDF
that already has a `.epub` sibling, runs `marker_single` then
`marker-to-epub.py` for each, drops the EPUB next to the PDF.

Tuning ENV vars:

| Var | Default | Why |
|---|---|---|
| `WORKERS` | `3` | `ProcessPoolExecutor` size. Each marker_single uses ~7 effective cores + ~14 GB RAM at peak. On a 16-core / 64 GB host, 2-3 is the sweet spot. |
| `ENABLE_OCR` | `0` (off) | InDesign PDFs have a real text layer; OCR is redundant. ~30% faster off. |
| `ARCHIVE_ROOT` | `/mnt/data/Media/Magazines` | Where to walk |
| `LIMIT` | `0` (unlimited) | Cap for testing |
| `ONLY` | unset | Regex on filename to restrict the set |

Sort order: **newest issue first** by `(year_from_parent_dir, basename)`
descending. So May 2026 → April 2026 → ... → April 2018. Important UX
choice — the user reads recent issues first, so they should land in
Komga first.

mtime-based sort was tried first and was wrong (it put just-downloaded
older issues ahead of older-but-archive-newer GAW issues).

## Performance characteristics — what to expect

On epi (AMD Ryzen 7 5700X, 8 cores / 16 threads, 64 GB RAM, no GPU):

| Config | Per-issue wall | 123-issue total | Notes |
|---|---|---|---|
| WORKERS=1, OCR on | ~30+ min | ~3 days | Single-process baseline |
| WORKERS=1, `--disable_ocr` | ~19 min | ~2 days | Saves ~30% on text-recog phase |
| **WORKERS=2, `--disable_ocr`** | **~35 min/pair** | **~30 hours** | **Production config.** ~14 cores active, 50 GB RAM peak. Smoke confirmed 19-min single-worker case works end-to-end. |
| WORKERS=3, `--disable_ocr` | (untested) | (~24 hours guess) | RAM constraint: 14 GB × 3 = 42 GB. Tight on 64 GB if you want headroom for other work. |

The subagent's initial 8-15 min/issue quote was based on partial-page-range
tests, not full issues. Real number is 25-40 min single-worker with all
phases enabled.

`--disable_ocr` is real but partial — it skips Marker's OCR fallback path
but the `Recognizing Text` step (a non-OCR text recognition Surya model)
still runs. ~30% saving, not 50-66%.

GPU would 10-50× this but Marker's CUDA backend doesn't support our Intel
Arc A310 out of the box (would need Intel Extension for PyTorch / IPEX-LLM
setup). Cloud GPU rental could batch the whole archive for ~$5-10.

## Running the batch

```bash
# Inspect the venv (already set up)
source /tmp/marker-test/.venv/bin/activate

# Sanity check what's pending
WORKERS=1 LIMIT=1 python3 scripts/marker-batch.py    # converts just the first
# OR dry-listing:
python3 -c "import sys; sys.path.insert(0,'scripts'); import importlib.util as u; \
  s=u.spec_from_file_location('m','scripts/marker-batch.py'); m=u.module_from_spec(s); \
  s.loader.exec_module(m); from pathlib import Path; \
  print('\n'.join(str(p) for p in m.pdfs_to_convert(Path('/mnt/data/Media/Magazines'),None)[:10]))"

# Run the full batch in the background
LOG=/tmp/marker-batch.log
nohup nice -n 19 ionice -c idle \
  env WORKERS=2 python3 -u scripts/marker-batch.py >> "$LOG" 2>&1 &
disown

# Watch
tail -F "$LOG"                          # raw output (carriage returns from tqdm)
grep -E '^\[|OK |ERR ' "$LOG"           # just per-issue start/done lines
find /mnt/data/Media/Magazines -name '*.epub' | wc -l   # progress count

# Stop cleanly
pkill -INT -f marker-batch.py
pkill -INT -f marker_single             # kills the workers
```

The batch is resume-safe — re-running picks up where it left off via
`<basename>.epub` existence checks. So `Ctrl+C` and restart is fine.

## When EPUBs land — the rest of the pipeline picks them up

1. **Komga's DAILY auto-scan** (within 24 h) indexes each new `.epub` as
   a separate book entry alongside the existing PDF entry. Komga reads
   the EPUB's OPF natively → title, series, tags all populated without
   our intervention.
2. **`komga-sync.service` (04:29 AWST daily)** PATCHes the EPUB book's
   metadata from the JSON sidecar too (probably a no-op since the OPF
   already matches, but the lock-fields step is harmless).

## Failure modes hit (date-stamped)

* **2026-05-23, `marker-to-epub.py` CLI mismatch** — initial marker-batch
  invoked it with `--md / --sidecar / --out`; real signature is positional
  `<markdown> <sidecar>` + `-o <output>`. Caught at the 19-min mark of the
  first smoke test (post-marker, mid-post-processor). Fixed.
* **2026-05-23, mtime-based newest-first sort was wrong** — just-downloaded
  WVJ 2018 PDFs had newer mtimes than archive-newer GAW issues. Switched
  to `(year_from_parent_dir, basename)` descending.
* **2026-05-23, `--page_range 0-9999` rejected** — Marker asserts the range
  is within `[0, page_count)` and bails. Dropped the flag entirely so
  Marker defaults to "all pages".
* **2026-05-23, expectation gap on speed** — subagent quoted 8-15 min/issue
  based on partial-page tests; real number is 25-40 min single-worker.
  Tuned via WORKERS=2 + `--disable_ocr` for ~30-hour total.

## Open caveats (acknowledged, not yet fixed)

* **Marker duplicates pull-quotes** — the magazine's pull-quote callouts
  appear both inline in the body AND as a separate block. Marker emits
  both. Fixing would need semantic dedup of near-duplicate paragraphs
  within an article. Out of scope.
* **Magazine section labels become orphan paragraphs** — `news`,
  `grapegrowing`, `winemaking`, `business & technology`, `sales &
  marketing`, `regulars` — these appear as standalone single-word
  paragraphs between articles. Could be killed with a stop-list but
  risks false positives in body prose.
* **Author fields mostly empty** — most GAW sidecars have empty
  `articles[].author`. winetitles.com.au filled it in inconsistently
  over the years; it's mostly populated for the older synthetic-merge
  range (2017-2018) and patchy for the FULL-ISSUE range (2018+).

## Future — automate new-issue conversion

Currently the marker batch is a manual one-shot. New GAW issues (1/month)
need EPUB conversion too. Plan once the back-catalogue grind finishes:

* `modules/nixos/services/marker-converter.nix` — wraps `marker-batch.py`
  in a oneshot timer that fires every 30-60 min, processes ONE PDF per
  fire (`LIMIT=1`), then exits. Self-paced, low-priority, automatically
  picks up new issues from gwm-archiver.
* OR fold the conversion directly into `gwm-archiver.py` as a step after
  download. Simpler but couples two responsibilities.

Decision pending until we see how the batch performs and how often the
user actually wants a new-issue EPUB to land (next-day vs same-week).

## Tooling notes

* Marker is `marker-pdf` from PyPI, installed in `/tmp/marker-test/.venv/`.
  Reinstall with `uv pip install --upgrade marker-pdf` if needed.
* `rapidfuzz` for fuzzy matching, `pandoc` for the EPUB assembly (via
  `nix-shell -p pandoc` from marker-to-epub.py).
* Model weights download to `~/.cache/datalab` on first use, ~3 GB total.
  Don't blow away that cache mid-batch or every marker_single re-downloads.

## See also

* [magazines.md](./magazines.md) — overview hub
* [komga.md](./komga.md) — where EPUBs land
* Marker source / docs: https://github.com/datalab-to/marker
* The original calibration EPUB notes are in this session's transcript
  (subagent run 2026-05-23) — search for "V2.epub" + "82 KB"
