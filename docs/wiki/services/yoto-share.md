# Yoto share — audiobook cards on demand

**Last updated:** 2026-09-16
**Status:** live; generated-copy migration completed
**Owner:** `modules/nixos/services/yoto-share.nix`, `yoto-share/server.py`
**Issue:** none — family request to remove manual preparation and duplicate storage

## User workflow

Open `https://yoto.ablz.au`, choose Audiobooks, browse by author/series or search,
then open a book. Each card has a **Download Card A · ZIP** link. Extract the
ZIP in the phone's Downloads folder and add its numbered audio files to a new
Yoto Make Your Own playlist. Artwork is inside `_artwork/` so selecting all
audio files does not include images.

The catalogue follows the source filesystem. New books appear automatically;
there is no publication step, scheduled copying, or permanent ZIP cache.
Multi-file books are grouped by directory and naturally sorted before packing
cards. Metadata probes are cached in memory by source path, size and nanosecond
mtime. Only the book being opened is probed.

The existing `/Music/` URLs serve Ali's music. Open an album for its prominent
**Download album · ZIP** button; albums that exceed a card's limits get a link
per card instead. Albums use the same on-demand generation and cleanup as
audiobooks. The old `ali-yoto-zip` timer and stored album ZIPs are retired;
acquisition remains described in [Ali Cratedigger](ali-cratedigger.md).

## Andy's music

The third section, **Andy's music** at `/AndysMusic/`, offers the canonical
Beets collection as a read-only source for quick Yoto downloads. It is separate
from Ali's `/Music/` library: searching or downloading here does not import an
album into her library or start an acquisition request.

`homelab.services.yotoShare.andysMusicDir` is optional and enabled on doc2 as
`/mnt/virtio/Music/Beets`. This is the current library from the system Beets
configuration; `/mnt/data/Media/Music` is an older collection, not that source.
The initial inventory found 8,576 album folders and 94,515 audio files, mostly
Opus. The mount is listed in `BindReadOnlyPaths` and `RequiresMountsFor`, and
`/healthz` checks it. No Beets database, credentials or write path is granted.
All existing Yoto share recipients can browse this newly shared collection.

Search matches words across artist/album paths and track filenames. Each
music section has its own search. A metadata-only in-memory index refreshes
on searches after 60 seconds, so new imports appear within a minute of the
next search; normal folder browsing reads the current filesystem directly.
Broad searches show the first 200 matches and ask for a narrower query.
Symlinks, hidden files and incomplete import siblings are excluded.

Album ZIPs use the same bounded streaming workspace as other downloads.
MP3/AAC are copied; Opus, FLAC, WMA and other supported source codecs are
converted to AAC for Yoto. Opus/Vorbis stream tags are read as well as format
tags, and albums are ordered by disc and track tags before packing cards.
Original audio remains unchanged. Only generated ZIPs are downloadable from
this section, avoiding raw Opus links that Yoto cannot use.

## Storage and generation

The old workflow ran `yoto-prep` manually and retained both split tracks and
per-card ZIPs. On 2026-09-16 the canonical audiobook library occupied 86 GiB;
119 prepared books occupied another 52 GiB (27,295,028,809 bytes of ZIPs plus
27,284,462,331 bytes of audio, and artwork). All 119 manifests matched their
existing source files by size and mtime; no unmanaged prepared audio was found.

The new service reads the originals and reuses `yoto-prep`'s chapter splitter,
stream-copy and artwork operations. ZIPs use `ZIP_STORED` because the audio is
already compressed. The ZIP central directory is generated only at the end of
a successful response. ZIP data is never written to disk.

Each download creates **one temporary track at a time**, validates it, streams
it into the response, and deletes it before preparing the next. The entire
temporary directory is removed on completion, error or client disconnect.
Two downloads are admitted concurrently; further requests receive a retry
message. A private 512 MiB tmpfs, a 110 MiB single-file limit, 1 GiB memory
limit and two-core CPU quota bound resource consumption. Restarting the unit
discards the scratch filesystem, including anything left by a killed worker.

MP3 and AAC tracks are stream-copied; unsupported codecs are converted to
AAC 128k. A card can take longer to download if conversion is needed. Downloads
are streamed without Content-Length and cannot resume with HTTP Range: retry
from the book page if interrupted. Changed source stamps invalidate old links;
a source that changes during streaming aborts the ZIP instead of silently
serving a partial book. FFmpeg/probe calls time out after 180 seconds and an
individual download has a 30-minute processing/streaming deadline.

## Limits

[Yoto's current MYO page](https://uk.yotoplay.com/make-your-own) lists MP3 or
AAC/M4A, 100 tracks per card, one hour and 100 MB per track, and 500 MB per
card. The app plans with 95 MB tracks and 490 MB cards, then verifies actual
generated durations and decimal-byte sizes. Chapter boundaries determine
tracks; long chapters are subdivided, and missing chapters get 30-minute
slices. The previous conservative five-hour card grouping is retained; the
current Yoto page does not list five hours as a hard per-card limit.

## Location and access

| Item | Location |
|---|---|
| Host | doc2 |
| Source library (read-only) | `/mnt/data/Media/Books/Audiobooks` |
| Andy's music (read-only) | `/mnt/virtio/Music/Beets` |
| Existing music/publication tree (read-only) | `/mnt/data/Media/Yoto` |
| Application | `yoto-library.service`, private bridge `10.88.0.1:13381` |
| HTTPS | `https://yoto.ablz.au`, existing `yoto` Tailscale node |
| Temporary tracks | private `/tmp` tmpfs inside the service |

There is no application login. **Every peer who can reach the Yoto share can
browse and download the entire source audiobook library.** This replaces the
old curated-only book scope at the owner's request. Metadata JSON, scripts,
ebooks and arbitrary source files are not exposed; the app serves generated
audio ZIPs. Music files retain attachment downloads.

The existing `tag:share`, DNS records, node identity and recipient grants are
retained. The service binds only the podman bridge gateway and its firewall
port is admitted on `podman0`. It runs as a dynamic user without credentials,
capabilities or source write access. `/mnt` is blanked and only the audiobook
and publication roots, plus the configured Andy's music root, are rebound read-only. IP egress is restricted to the
private bridge and localhost; FFmpeg is restricted to file/pipe protocols.
Path traversal, dotfiles and symlinks outside the allowed roots are denied.

The Caddy sidecar now reverse-proxies this service instead of mounting the
publication tree. See [tailscale-share](tailscale-share.md) for the pinhole
model, IPv6 publication and recipient-side IPv4 remapping. Test from a
`tag:client` node as well as doc1: doc1's broad egress is not proof that a
recipient grant works.

## WebDAV and offline exports

`https://yotodav.ablz.au` remains a read-only view of the publication tree.
It can serve Music and explicitly prepared offline exports. On-demand cards
are available through the browser catalogue; they are not persistent WebDAV
files. After duplicate cleanup the Books README points users to the catalogue.

The CLI remains available for an explicitly requested offline export:

```bash
yoto-prep --dry-run "J.K. Rowling/Harry Potter"
yoto-prep --out /path/to/offline-export "Enid Blyton/Famous Five"
```

Do not use the CLI to publish every library book again. Its default
`/mnt/data/Media/Yoto/Books` is for manual exports, not the web catalogue.

## Verification and operations

`nix build .#checks.x86_64-linux.yotoLibraryCheck` exercises actual ffmpeg audio
through HTTP ZIP generation, complete decoding, multi-file ordering, resource
admission, cancellation cleanup, stale links, traversal and source integrity.

Uptime Kuma checks `/healthz` through the real tailnet URL. The endpoint reads
both mounted roots and writes a temporary file. There is no persistent app
database. `YOTO_REQUEST_FAILED` and `YOTO_DOWNLOAD_FAILED` emit targeted Loki
alerts; the latter is essential because a streaming failure can occur after
HTTP 200 headers. The NFS watchdog restarts `yoto-library.service` for stale
source handles; WebDAV retains its own watchdog.

```bash
ssh doc2 'systemctl status yoto-library --no-pager'
ssh doc2 'sudo journalctl -u yoto-library -n 50 --no-pager'
curl -fsS https://yoto.ablz.au/healthz
```

Before deleting any old output, verify real book/card downloads and archive
decoding through HTTPS. Cleanup must recheck each manifest against its
canonical source, retain a small manifest inventory for reconstruction, and
delete only known generated output. Never delete originals or Ali's music.

### Live verification and cleanup, 2026-09-16

- Full `nix flake check`, doc2 toplevel build, twelve behavioral tests, Python
  lint and the touched Nix format/deadnix/statix checks passed.
- A Chromium session at a 390px phone viewport searched for The Secret Seven,
  opened the book, and downloaded its ZIP in 3.3 seconds without overflow or
  browser errors. The archive contained all 12 AAC tracks and artwork.
- Both Harry Potter and the Philosopher's Stone cards downloaded through the
  public share hostname in 4.9 / 4.6 seconds from doc1: 9 + 8 MP3 tracks.
  All 29 tracks across the three archives fully decoded. Durations matched
  the source books within packet-rounding tolerance; all actual track/card
  sizes were below the limits. These are LAN/tailnet test speeds, not a
  prediction of a recipient's internet download speed.
- The live service's private scratch directory was empty after the downloads.
  Kuma independently reached the tailnet health URL. Framework and epimetheus
  were offline, so a fresh `tag:client` probe was unavailable; the existing
  share identity and grants were unchanged.
- Rechecked all 119 source stamps, then removed 3,226 generated files totaling
  **54,764,619,055 bytes (51.00 GiB)**. The prepared Books directory is now a
  4 KiB README pointing to the catalogue; the original library remains 86 GiB.
- Reconstruction inventory, including every original manifest and the old
  README, is root-only at
  `/var/lib/yoto-migration/prepared-books-2026-09-16.json` on doc2. No canonical
  audio or artwork was removed.
- Gunicorn 26 enables a control socket by default and tried to create
  `/.gunicorn` under the dynamic user. Disable it with `--no-control-socket`;
  systemd owns process control and the app needs no writable control state.
- The complete catalogue scan opened 215 of 216 books initially. The remaining
  book had a valid source plus a zero-byte `*.tmp.m4b` left by an import.
  Ignoring unfinished `.tmp.`/`.partial.` siblings restored its card links;
  all 216 book pages have now been checked. The source files were preserved.
- All four real music albums streamed successfully (Dolly Parton and three
  Taylor Swift albums); all 66 tracks fully decoded and the artwork was
  present. The album button was visible without overflow at a 390px viewport.
  Removed the four owned, digest-verified archives after retiring the timer,
  freeing another **477,039,583 bytes**. All 66 original music tracks remain.
  The inventory is `/var/lib/yoto-migration/music-zips-2026-09-16.json`.
  A fresh 20-track Dolly Parton ZIP also passed integrity verification after
  the stored archives were gone, and service scratch was empty afterward.

Rollback is a signed revert of the catalogue change followed by
`fleet-deploy doc2`. Recreate any removed prepared book with
`yoto-prep --force <book-path>`; the canonical sources are unchanged. Until
generated copies are removed, the previous static service can be restored
without regeneration.
