---
name: book-photo-transcription-recipe
description: Working recipe for turning Immich phone photos of a printed book into a validated epub (page markers, linked references, pandoc build), plus the safe way to add a book to the Calibre library on tower and rescan Komga.
metadata:
  type: reference
---

The proven photo-to-epub pipeline lives with its first result at
`/mnt/data/Life/Andy/Genealogy/Barrett-Lennard/Edward Pomeroy Barrett-Lennard (1985)/`
(README.md there documents conventions; `scripts/` holds the pipeline).

Key points: pull originals over the Immich API with the doc1 key
(`/run/secrets/immich/api-token`, see docs/wiki/services/immich.md); transcribe
by reading 1600 px auto-oriented copies page by page (tesseract is only a
cross-check — curved phone photos make it noisy); one Markdown file per page
with an inline `pagenum` span; pandoc + epubcheck via nix-shell; a post-pass
injects the EPUB 3 page-list.

Four titles done in `/mnt/data/Life/Andy/Genealogy/Barrett-Lennard/`: the two
booklets (photo transcriptions), the 1967 typescript autobiography (scan
transcription) and the 2020 Word memoir (docx conversion with heading
detection by formatting — see its README). Getting a finished epub into the user's Calibre: the library
is owned by the Calibre desktop GUI running in the linuxserver `calibre`
container on tower (calibre.ablz.au is its KasmVNC front end; content server
off). Never run calibredb against `/Library` while that GUI runs. Instead drop
the file in `/mnt/data/Media/Books/Unsorted/Books` (mounted as `/Import`) and
have the tower agent run the `calibre` launcher inside the container with the
file path, which hands it to the running GUI (needs `-u abc`, DISPLAY=:0,
HOME=/config, LD_LIBRARY_PATH=/opt/calibre/lib, CALIBRE_QT_PREFIX=/opt/calibre).
Then trigger a Komga scan from doc2 with the komga-sync API key
(`/run/secrets/komga-sync/env`, library id 0QFQQFTD08FRG).
