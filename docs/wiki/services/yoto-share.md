# Yoto share — books and music for Yoto MYO cards

**Last updated:** 2026-08-24
**Status:** working
**Owner:** `modules/nixos/services/yoto-share.nix` (+ `modules/nixos/services/yoto-share/yoto-prep.py`), file-server mode in `modules/nixos/services/tailscale-share.nix`
**Issue:** none — feature request from a family tailnet peer

## The problem this solves

A tailnet peer (external family member, Android, already uses the `overseer`
share to request media) wanted to turn our audiobooks into
[Yoto](https://yotoplay.com) MYO cards for her kids. Yoto's uploader is an
Android **file picker**, so the files must exist as real files in
`/sdcard/Download`.

Two independent blockers, and both have to be solved:

1. **Delivery.** Audiobookshelf's Android app — like every audiobook app —
   downloads into its own private app storage. A file picker cannot see inside
   another app's sandbox, so the files are unreachable no matter how they got
   there. Downloading through a *browser* is what puts a file somewhere the
   picker can read.
2. **Format.** The library is almost entirely single-file `.m4b` with embedded
   chapters. `Harry Potter and the Philosopher's Stone` is one file: **438 MB,
   8.4 hours**. Yoto caps a *track* at **60 min / 100 MB**. The source file is
   therefore not merely awkward to fetch — it is un-uploadable. Handing over
   the raw `.m4b` would have failed at the last step no matter how good the
   transport was.

So the answer is not "expose the library"; it is "publish pre-split,
Yoto-legal files over a browser-fetchable share".

## Yoto MYO limits

| Constraint | Value |
|---|---|
| Supported audio | MP3, AAC/M4A (**not** Opus — Yoto silently rejects it) |
| Per track | ≤ 60 min, ≤ 100 MB |
| Per card | ≤ 5 h, ≤ 500 MB, ≤ 100 tracks |

`yoto-prep` uses 58 min / 95 MB as the track ceiling. Cutting lands on the
nearest packet boundary rather than the exact chapter time, so the margin stops
a chapter that is *just* under the limit from crossing it.

## Where it lives

- **Host:** doc2 (same host as Audiobookshelf)
- **Source library:** `/mnt/data/Media/Books/Audiobooks` (NFS from tower)
- **Published tree:** `/mnt/data/Media/Yoto`
- **Prepared books:** `/mnt/data/Media/Yoto/Books`
- **Ali's music:** `/mnt/data/Media/Yoto/Music` (owned by her isolated
  Cratedigger/Beets instance; see `docs/wiki/services/ali-cratedigger.md`)
- **FQDN:** `https://yoto.ablz.au`, on its own tailscale node `yoto`

## Access model — read this before adding anything

### The node MUST carry `tag:share`

The tailnet is **default-DENY** and every share grant in `tailscale/acl.hujson`
is written against `tag:share`. A share node that is *untagged* matches no
grant except doc1's unrestricted-egress rule.

That failure mode is genuinely nasty, so know it: the share verifies
**perfectly from doc1** — 200, valid cert, correct headers — while being
unreachable from every device that actually needs it. Nothing looks broken.

It bites because `authKeySecret = null` means an interactive first-run login,
which makes the node **user-owned** (`abl030@`) rather than tag-owned.
overseer / audiobookshelf / jellyfin were tagged by hand in the admin console;
`yoto` is tagged declaratively via `homelab.tailscaleShare.<name>.tags`.

Observed 2026-08-22 before the fix:

| From | Tag | Result |
|---|---|---|
| doc1 | (unrestricted egress) | 200 |
| framework | `tag:client` | **HTTP 000 — blocked** |

With `tag:share` the existing grants give inbound 443 from `tag:client`,
`tag:server` (Kuma health checks) and `autogroup:shared` (inter-tailnet peers),
while share→fleet egress stays denied. **No bespoke ACL rule is needed** — and
adding one would punch a hole in the default-deny model for no gain.

Verified after tagging: framework → 200, doc2 → 200, doc1 → 200, and
`ts-yoto` → doc1:443 still refused.

Changing an existing node's tags replaces user ownership with tag ownership.
That can force re-authentication (`podman logs ts-yoto` prints a fresh login
URL), though an admin-owned tag was accepted here without one.

### No login on the share itself

The share has **no login**. `homelab.tailscaleShare` normally fronts an app
that authenticates its own users (Overseerr, ABS); a bare Caddy `file_server`
has nothing equivalent. Deliberate decision, 2026-08-22: the access control is
**which tailnet peers the `yoto` node is shared with**, exactly like the
`overseer` node, and nothing else.

The consequences to keep in mind:

- `serveDir` points at the curated `Media/Yoto/` publication tree, **never** at
  either source library or a parent of them. Anything placed there is readable
  by every peer the node is shared with.
- The bind mount is `:ro` and Caddy has no upload route, so the share is
  strictly pull. A peer cannot write into the media tree.
- The node is a pinhole: its own tailscale identity, `--accept-routes=false`,
  and the caddy sidecar runs as uid 2011 with `cap-drop=ALL`.

To widen or narrow access, share/unshare the `yoto` node in the tailnet admin
console. Do not add books for one peer that another peer should not see —
there is no per-peer scoping here.

## Preparing books

```bash
# One book, a whole series, or an author — path under the library, or a
# case-insensitive substring match.
yoto-prep "Enid Blyton/Famous Five/1 - Five on a Treasure Island"
yoto-prep "Enid Blyton"
yoto-prep --dry-run "J.K. Rowling/Harry Potter"    # show the card plan only
yoto-prep --jobs 3 "Enid Blyton" "J.K. Rowling/Harry Potter"
```

Useful flags: `--dry-run`, `--force` (re-prep an already-done book),
`--no-zip`, `--jobs N`, `--library`, `--out`.

Re-runs are cheap: each book gets a `.yoto-prep.json` manifest stamped with the
source size+mtime, and a book whose stamp still matches is skipped. Change the
source file and it re-preps automatically.

### What it does

1. Reads chapters with `ffprobe`. No chapters → falls back to 30-minute slices.
2. Subdivides any chapter over the track ceiling into equal parts
   (`Title (Part 1 of 2)`).
3. Packs tracks into the **fewest cards that fit**, balanced rather than
   greedy-filled, always in reading order. Greedy filling strands a near-empty
   final card — a 9.7 h book packs to 5.0 + 4.2 + 0.5 h instead of 4.85 + 4.85.
4. Cuts with `-c copy` when the source codec is already MP3 or AAC, so it is
   fast and lossless. Anything else re-encodes to AAC 128k stereo.
5. Zips each card (`ZIP_STORED` — audio is already compressed).
6. Builds `_artwork/cover.png` (1080×1350 portrait, blurred-self backdrop) and
   `icon.png` (320×320) from the book's `cover.jpg`, or from embedded art.

### Output layout

```
Yoto/
  Books/
    README.txt                            <- instructions for the peer
    Enid Blyton/The Secret Seven/1 - The Secret Seven/
      1 - The Secret Seven.zip            <- one tap on the phone
      Card A/01 - Plans for an S. S. Meeting.m4a
      Card A/02 - The Secret Seven Society.m4a
      ...
      _artwork/cover.png
      _artwork/icon.png
      .yoto-prep.json                     <- hidden from the listing
  Music/
    Artist/2026 - Album/
      01 Song.mp3
      2026 - Album.zip                    <- one tap for Ali
```

One `Card X/` folder = one Yoto card, already within all three per-card limits.
Multi-card books get `Card A`, `Card B`, … and the zips are named
`<Book> - Card A.zip` so they do not collide in a phone's single flat Downloads
folder. Each zip contains a folder named for the book for the same reason.

Artwork lives in `_artwork/` rather than beside the tracks so that
"select all" in the Yoto uploader cannot sweep a PNG in as a track.

## The two non-obvious delivery details

**`Content-Disposition: attachment`.** Android Chrome opens audio in an inline
media viewer instead of saving it. Tapping a track would play it and write
nothing to disk — the whole workflow fails silently at the final step. The
Caddyfile matches `downloadExtensions` and forces a real download. If someone
"cleans up" that header, the share will look fine and be useless.

**Zip per card.** Without it the peer taps ~17 links per card, one at a time,
on a phone. The zip is the intended path; individual tracks stay browsable as a
fallback.

## The peer's workflow

1. Connect to the tailnet, open `https://yoto.ablz.au`.
2. Browse to the book, tap the `.zip` → lands in Downloads.
3. Extract with any file manager.
4. Yoto app / my.yotoplay.com → new MYO playlist → add the tracks from that
   folder. They are zero-padded and numbered, so order is preserved.
5. Optional: `_artwork/cover.png` as the card cover, `icon.png` as track icons.

## Operations

- Availability: Uptime Kuma monitor **"Yoto Share (Tailnet)"**, registered
  automatically by `homelab.tailscaleShare`, hitting the listing at `/`.
- NFS: `homelab.nfsWatchdog.yoto-share` restarts `podman-caddy-yoto.service` on
  a stale handle. The caddy unit also carries `RequiresMountsFor` on the share
  dir — without it, a boot before the NFS mount would serve an empty listing
  that reads as "the books disappeared" rather than as an outage.
- First deploy needs an interactive tailscale login (`authKeySecret = null`,
  matching the audiobookshelf share): `podman logs ts-yoto` prints a URL. State
  then persists in `/mnt/virtio/tailscale-share/yoto/ts-state`.
- Disk: prepared tracks are ~1× the source (stream copy) and the zips ~1× again,
  so budget **~2× the source size**. The initial 93-book seed (all Enid Blyton +
  the 7 Harry Potter books, 17.1 GB of source) came to ~34 GB.

## Verifying a prep

Duration of the split tracks should match the source to well under a second;
the delta is packet-boundary rounding.

```bash
# per track: must decode, and be under 60 min / 100 MB
ffmpeg -v error -i "<track>" -t 1 -f null -
```

Failure modes worth catching:

- `moov atom not found` → truncated m4a; re-run that book with `--force`.
- A track over 100 MB → `yoto-prep` prints a `WARN` line; it does not fail the
  run, so read the summary.
- Empty directory listing on the share → NFS, not Caddy. Check `mnt-data.mount`
  on doc2.

## When to revisit

- If Yoto changes its limits, they are constants at the top of `yoto-prep.py`
  (`TRACK_SECONDS`, `TRACK_BYTES`, `CARD_*`).
- Any NEW `tailscaleShare` instance must set `tags = ["tag:share"]`, or it will
  be silently reachable only from doc1. Test from a `tag:client` node, never
  from doc1 alone.
- If the share ever needs per-peer scoping or a login, the file-server mode
  would need a real auth story — at that point prefer a second `serveDir`
  instance with its own node over bolting auth onto this one.

## See also

- `.claude/skills/yoto-card/SKILL.md` — TV/music sources for Yoto cards
- `docs/wiki/services/audiobookshelf.md`
- `modules/nixos/services/tailscale-share.nix` — the pinhole share model
