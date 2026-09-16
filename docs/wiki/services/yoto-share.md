# Yoto share — audiobook cards on demand

**Last updated:** 2026-09-16
**Status:** implementation and live migration in progress
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

The existing `/Music/` URLs still serve Ali's music and album ZIPs. That separate
acquisition/ZIP timer remains described in [Ali Cratedigger](ali-cratedigger.md).

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
and publication roots are rebound read-only. IP egress is restricted to the
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

Rollback is a signed revert of the catalogue change followed by
`fleet-deploy doc2`. Recreate any removed prepared book with
`yoto-prep --force <book-path>`; the canonical sources are unchanged. Until
generated copies are removed, the previous static service can be restored
without regeneration.
