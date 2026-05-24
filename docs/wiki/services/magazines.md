# Magazine archive system (overview)

**Date written:** 2026-05-23
**Status:** ✅ working end-to-end. EPUB conversion batch grinding the back catalogue.

This is the breadcrumb hub for the whole wine-magazine archive pipeline. Each
component has its own deep-dive page — start here, follow the links.

## What it does, in one paragraph

We're a subscriber to two magazines on winetitles.com.au:
**Grapegrower & Winemaker** (GAW, monthly, still publishing) and the
**Wine & Viticulture Journal** (WVJ, quarterly, ceased 2024). Every issue is
downloaded as a PDF, enriched with a JSON sidecar carrying the per-article
table of contents (title, author, keywords, page numbers), then served via a
self-hosted **Komga** library at https://magazines.ablz.au. PDFs are
converted to EPUBs by Marker (ML-based PDF → markdown) plus a custom
post-processor that uses the JSON sidecars to inject proper per-article
chapter boundaries, so KOReader on phone gets a real reflowable per-article
TOC instead of horrible multi-column raster scroll.

## Components — start at the top, drill into each

| Component | Where | What | Doc |
|---|---|---|---|
| **GAW archiver** | doc2 weekly oneshot | Walks winetitles, downloads PDFs + writes JSON sidecars | [gwm-archiver.md](./gwm-archiver.md) |
| **WVJ archiver** | one-shot (publication ended 2024) | Same flow for the WVJ archive | [wvj-archive.md](./wvj-archive.md) |
| **The broken pre-2017 winetitles archive** | upstream | 150 GAW + 41 WVJ issues are 0-byte server-side; documented for the publisher follow-up | [gwm-archiver-broken-archive.md](./gwm-archiver-broken-archive.md) |
| **Komga library** | doc2, magazines.ablz.au | Web UI + OPDS + reader for the PDF/EPUB tree | [komga.md](./komga.md) |
| **Komga metadata sync** | doc2 daily oneshot | PATCHes Komga book/series metadata from the JSON sidecars via REST | [komga-sync.md](./komga-sync.md) |
| **KOReader cross-device sync** | client-side (phone/Boox) | Read-position sync via Komga's `/koreader` endpoint, auto-pull on open, auto-push on close | [koreader-sync.md](./koreader-sync.md) |
| **PDF → EPUB pipeline** | epi background batch | Marker + post-processor + batch orchestrator. Produces per-issue EPUBs from the magazine PDFs | [magazine-epub-pipeline.md](./magazine-epub-pipeline.md) |

## Daily flow (no human action needed)

1. **Sun 03:30 AWST** — `gwm-archiver.service` wakes on doc2, walks winetitles,
   downloads any new GAW issue as PDF + sidecar. Gotify pings if new.
2. **Komga DAILY auto-scan** (next fire within 24 h) — indexes the new PDF as
   a book entry under the appropriate year-series.
3. **Mon–Sat 04:29 AWST** — `komga-sync.service` walks the JSON sidecars,
   PATCHes the new book's metadata via REST (title, summary as markdown TOC,
   tags, links). Idempotent on subsequent days.
4. **(Once `marker-batch` finishes the back-catalogue and is wired as a
   permanent timer)** — new PDFs get an EPUB next to them too. Komga indexes
   it as a second book entry; same metadata gets PATCHed onto it.

## Where stuff lives

* **PDFs + JSON sidecars + EPUBs:** `/mnt/data/Media/Magazines/{GAW,WVJ}/<YEAR>/<basename>.{pdf,json,epub}` (NFS share, mounted on doc2 + epi)
* **Komga DB + thumbnails:** `/mnt/virtio/komga/` (virtio mount on doc2; SQLite, ~MBs)
* **Secrets:** `secrets/hosts/doc2/{gwm-archiver,komga-sync}.env` (sops)
* **All systemd units on doc2:** `systemctl list-unit-files | grep -E 'gwm-|komga'`

## Surprising / load-bearing facts (read at least once)

* **Komga doesn't merge `<name>.pdf` + `<name>.epub` into one book** — they
  appear as two separate cards in the same year-series. By design, since the
  user explicitly wanted both formats visible ("epub is always going to be
  flakey").
* **Komga reads zero metadata from PDFs.** No internal dict, no bookmarks,
  no loose sidecars next to a PDF. We use the REST API to PATCH every book's
  metadata from the JSON sidecar, with `*Lock=true` so library refreshes
  don't stomp it. EPUBs are different — Komga reads OPF metadata natively,
  so EPUBs created by our pipeline carry rich OPF and don't need the REST
  PATCH (though it runs anyway and is a no-op).
* **`gwm-archiver`'s slug → year/month math is anchored at #748 = May 2026.**
  If the magazine ever skips an issue or changes cadence, the formula breaks
  for everything beyond. See [gwm-archiver.md](./gwm-archiver.md).
* **Marker is slow.** ~15-30 min per 80-page issue on epi's 5700X with
  WORKERS=2 and `--disable_ocr`. Full back-catalogue batch is ~30 hours of
  background grind. Documented in [magazine-epub-pipeline.md](./magazine-epub-pipeline.md).
* **The bootstrap Komga API key is in shell history.** Rotate it in the
  Komga UI when convenient, then `sops edit secrets/hosts/doc2/komga-sync.env`
  to update the daily sync.

## Operator quick-ref

```bash
# What ran when
journalctl -u gwm-archiver -u komga -u komga-sync --since=yesterday

# What's in the library
find /mnt/data/Media/Magazines -type f \( -name '*.pdf' -o -name '*.epub' -o -name '*.json' \) | wc -l

# Force a Komga scan after editing/deleting files
curl -X POST -H "X-API-Key: $KEY" https://magazines.ablz.au/api/v1/libraries/{libraryId}/scan

# Force a metadata re-sync
ssh doc2 sudo systemctl start komga-sync

# Open the Komga UI
xdg-open https://magazines.ablz.au

# Tail the in-progress marker batch (only if running)
tail -F /tmp/marker-batch.log
```

## Failure modes we've actually hit (date-stamped)

* **2026-05-23, Komga port collision** — picked 8085 without checking, ran
  into cratedigger. Moved to 8089. Caught at deploy because Komga
  crash-looped 13× with SQLite `[SQLITE_CANTOPEN]` (the *symptom*; the cause
  was the second bug, below).
* **2026-05-23, Komga sandbox masked its own stateDir** — `TemporaryFileSystem=/mnt`
  in the unit replaced `/mnt` with a tmpfs in the namespace, hiding
  `/mnt/virtio/komga/`. The systemd-tmpfiles rule had created the dir on
  the host but the unit couldn't see it. Fixed by adding `BindPaths=[cfg.dataDir]`
  per the [Sandbox patterns rule](../nixos-service-modules.md).
* **2026-05-23, OnSuccess notify-script failed on empty grep** — the
  `journalctl | grep NEW_ISSUE:` pipeline exited 1 under `set -euo pipefail`
  when there were no new issues to match. Fixed with `{ grep -E ... || true; }`.
* **2026-05-23, `pdfunite` produced exiftool-unwritable PDFs** — used qpdf
  instead. See [gwm-archiver.md](./gwm-archiver.md) §"PDF metadata embedding".
* **2026-05-23, Marker `--disable_ocr` not as fast as hoped** — flag is real
  but Marker's `Recognizing Text` model still runs (it's a non-OCR text
  recognition step that fires regardless). Saves ~30%, not 50-66%. See
  [magazine-epub-pipeline.md](./magazine-epub-pipeline.md).
