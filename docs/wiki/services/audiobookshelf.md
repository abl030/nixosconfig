# Audiobookshelf import notes

**Last researched:** 2026-04-23
**Status:** working with a few sharp edges
**Hosts:** `doc2` (service + API), `framework`/others (can see shared media mounts but may not have ABS API env)

## What worked

- Source the ABS API env on `doc2` from `/run/secrets/mcp/audiobookshelf.env`.
- Bring new audiobooks from `/mnt/data/Media/Temp/` into `/mnt/data/Media/Books/Audiobooks/<Author>/<Series>/<N - Title>/`.
- For multi-part MP3 books, `scripts/mp3-to-m4b.sh` produced clean single-file `.m4b` outputs with chapter markers at file boundaries.
- `scripts/audio-silence-audit.py --skip-rms --json ...` was the practical validation pass for long books. It caught concat/timeline issues quickly without waiting for a full decoded-RMS scan.
- ABS `POST /api/items/<id>/match` with `provider: "audible.co.uk"` worked well for William Horwood's first three `Wind in the Willows` sequels and preserved the folder-derived series/sequence metadata.

## Filesystem / permission requirements

Audiobookshelf metadata embed only behaved reliably once the library subtree matched the intended tower-NFS permission model:

- directories: `2775`
- files: `664`
- ownership: `99:users`

Before trusting an embed, verify write access as the `audiobookshelf` user:

```bash
sudo -u audiobookshelf touch /mnt/data/Media/Books/Audiobooks/<BookDir>/.abs-write-test
sudo -u audiobookshelf dd if=/dev/zero of="<book.m4b>" bs=1 count=0 conv=notrunc status=none
```

If the copied files land `644`, ABS may update its database while leaving the on-disk `.m4b` unchanged.

## Embed is asynchronous

`POST /api/tools/item/<id>/embed-metadata` returns `OK` immediately, but the file rewrite can lag behind by tens of seconds.

Observed on 2026-04-23:

- first verification at ~8s showed only one of four books updated on disk
- second verification at ~20s showed all four `.m4b` files with embedded cover art and tags

Do not assume the first `ffprobe` check reflects the final state. Wait and re-check before declaring failure.

## Metadata fallbacks

- `audible.co.uk` may fail on some books even when ABS still creates a plausible `cover.jpg`.
- For `The Willows at Christmas`, Audible match did not populate narrator/publisher/year, but the cover was usable and the remaining metadata was patched manually.
- The HarperCollins SoundCloud page for `The Willows at Christmas` identified the narrator as Andrew Sachs and gave enough synopsis context for a short manual description.

## Audnexus caveat

The obvious Audnexus endpoints returned `404` for the William Horwood ASINs tested on 2026-04-23:

- `https://api.audnex.us/books/<asin>`
- `https://api.audnex.us/books/<asin>/chapters`

Do not block an import on Audnexus availability. If ABS metadata and local runtime look sane, continue and note that runtime/chapter enrichment could not be verified from Audnexus.
