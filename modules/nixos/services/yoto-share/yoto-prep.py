"""Prepare audiobooks from the Audiobookshelf library for Yoto MYO upload.

Audiobooks in the library are single-file .m4b with embedded chapters — often
8+ hours and hundreds of MB. Yoto MYO caps a track at 60 min / 100 MB and a
card at 5 h / 500 MB / 100 tracks, so the source file cannot be uploaded at
all. This splits a book on its chapter boundaries into Yoto-legal tracks,
packs them into card-sized folders in reading order, and zips each card so a
phone can fetch a whole card in one tap.

Splitting is a stream copy (-c copy) whenever the source codec is already one
Yoto accepts (MP3/AAC), so it is fast and lossless. Anything else is
re-encoded to AAC 128k.

See docs/wiki/services/yoto-share.md.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

# Yoto MYO hard limits. Track limits carry a safety margin because chapter
# cutting lands on the nearest packet boundary rather than the exact time.
TRACK_SECONDS = 58 * 60
TRACK_BYTES = 95 * 1024 * 1024
CARD_SECONDS = 5 * 3600
CARD_BYTES = 500 * 1024 * 1024
CARD_TRACKS = 100

AUDIO_EXTS = (".m4b", ".m4a", ".mp3")
# Codecs Yoto decodes. Anything else gets re-encoded to AAC. Opus is
# specifically NOT decoded by Yoto even though it is a valid m4b payload.
PASSTHROUGH_CODECS = {"mp3": ".mp3", "aac": ".m4a"}

MANIFEST = ".yoto-prep.json"


def run(cmd: list[str]) -> str:
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"{cmd[0]} failed: {res.stderr.strip()[:500]}")
    return res.stdout


def probe(path: str) -> dict:
    return json.loads(run([
        "ffprobe", "-v", "error", "-show_format", "-show_streams",
        "-show_chapters", "-of", "json", path,
    ]))


def safe_name(name: str) -> str:
    """Make a string safe as a filename on any filesystem the phone may see."""
    name = re.sub(r"[\\/:*?\"<>|\x00-\x1f]", "-", name)
    name = re.sub(r"\s+", " ", name).strip().strip(".")
    return name[:120] or "Untitled"


def card_label(index: int) -> str:
    """0 -> 'Card A', 25 -> 'Card Z', 26 -> 'Card AA'."""
    label = ""
    index += 1
    while index:
        index, rem = divmod(index - 1, 26)
        label = chr(ord("A") + rem) + label
    return f"Card {label}"


class Segment:
    def __init__(self, title: str, start: float, end: float):
        self.title = title
        self.start = start
        self.end = end

    @property
    def duration(self) -> float:
        return self.end - self.start


def build_segments(info: dict, duration: float) -> list[Segment]:
    """Chapters -> segments, subdividing any that breach the track limits."""
    chapters = info.get("chapters", [])
    segments: list[Segment] = []
    if chapters:
        for i, ch in enumerate(chapters, 1):
            start = float(ch["start_time"])
            end = min(float(ch["end_time"]), duration)
            if end - start < 1.0:
                continue
            title = (ch.get("tags") or {}).get("title", "").strip()
            segments.append(Segment(title or f"Chapter {i}", start, end))
    if not segments:
        # No usable chapters: fall back to fixed ~30 min slices.
        slice_len = 30 * 60
        n = max(1, int(duration // slice_len) + (1 if duration % slice_len else 0))
        for i in range(n):
            start = i * slice_len
            segments.append(Segment(f"Part {i + 1}", start, min(start + slice_len, duration)))

    bytes_per_sec = info["_bytes_per_sec"]
    out: list[Segment] = []
    for seg in segments:
        parts = 1
        while (seg.duration / parts > TRACK_SECONDS
               or (seg.duration / parts) * bytes_per_sec > TRACK_BYTES):
            parts += 1
        if parts == 1:
            out.append(seg)
            continue
        step = seg.duration / parts
        for p in range(parts):
            start = seg.start + p * step
            end = seg.start + (p + 1) * step if p < parts - 1 else seg.end
            out.append(Segment(f"{seg.title} (Part {p + 1} of {parts})", start, end))
    return out


def merge_segments(segments: list[Segment], bytes_per_sec: float) -> list[Segment]:
    """Glue consecutive chapters into the longest Yoto-legal tracks.

    A browser downloads one file per tap, so a 15-chapter card is 15 taps (or a
    zip the phone then has to extract). Merging chapters up to the 58 min /
    95 MB track ceiling turns a typical card into ~5 files, which is tappable
    directly and needs no zip at all. The trade is coarser skip points on the
    card itself.
    """
    out: list[Segment] = []
    cur: Segment | None = None
    for seg in segments:
        if cur is None:
            cur = Segment(seg.title, seg.start, seg.end)
            continue
        combined = (cur.end - cur.start) + seg.duration
        contiguous = abs(seg.start - cur.end) < 1.0
        if (contiguous and combined <= TRACK_SECONDS
                and combined * bytes_per_sec <= TRACK_BYTES):
            cur.end = seg.end
        else:
            out.append(cur)
            cur = Segment(seg.title, seg.start, seg.end)
    if cur is not None:
        out.append(cur)
    return out


def _split_evenly(segments: list[Segment], n: int) -> list[list[Segment]]:
    """Cut the (ordered) segment list into n contiguous, near-equal cards.

    Each segment goes to the card its midpoint falls in, which balances by
    duration without ever reordering chapters.
    """
    total = sum(s.duration for s in segments)
    cards: list[list[Segment]] = [[] for _ in range(n)]
    cum = 0.0
    last = 0
    for seg in segments:
        mid = cum + seg.duration / 2
        k = min(n - 1, int(mid / total * n)) if total else 0
        k = max(k, last)
        cards[k].append(seg)
        last = k
        cum += seg.duration
    return [c for c in cards if c]


def pack_cards(segments: list[Segment], bytes_per_sec: float) -> list[list[Segment]]:
    """Split into the fewest cards that fit, balanced rather than greedy-filled.

    Greedy filling strands a near-empty final card (a 9.7 h book packs to
    5.0 + 4.2 + 0.5 instead of 4.85 + 4.85), so start from the theoretical
    minimum card count and grow only if a card actually breaches a limit.
    """
    total_sec = sum(s.duration for s in segments)
    total_bytes = total_sec * bytes_per_sec

    def ceil_div(a: float, b: float) -> int:
        return max(1, int(-(-a // b)))

    n = max(
        ceil_div(total_sec, CARD_SECONDS),
        ceil_div(total_bytes, CARD_BYTES),
        ceil_div(len(segments), CARD_TRACKS),
    )
    while n <= len(segments):
        cards = _split_evenly(segments, n)
        ok = all(
            sum(s.duration for s in c) <= CARD_SECONDS
            and sum(s.duration for s in c) * bytes_per_sec <= CARD_BYTES
            and len(c) <= CARD_TRACKS
            for c in cards
        )
        if ok:
            return cards
        n += 1
    return [[s] for s in segments]


def find_cover(book_dir: str, src: str, dest_dir: str) -> None:
    """Write _artwork/cover.png (1080x1350 portrait) and icon.png."""
    os.makedirs(dest_dir, exist_ok=True)
    candidates = ["cover.jpg", "cover.png", "cover.jpeg", "folder.jpg", "folder.png"]
    source_image = None
    for c in candidates:
        p = os.path.join(book_dir, c)
        if os.path.exists(p):
            source_image = p
            break

    tmp_embedded = None
    if source_image is None:
        # Fall back to art embedded in the audio file.
        tmp_embedded = os.path.join(tempfile.mkdtemp(), "embedded.png")
        try:
            run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", src,
                 "-an", "-frames:v", "1", tmp_embedded])
            source_image = tmp_embedded
        except RuntimeError:
            return

    cover = os.path.join(dest_dir, "cover.png")
    icon = os.path.join(dest_dir, "icon.png")
    # Portrait card art: blurred, darkened copy of the cover as a backdrop with
    # the cover centred on top. Works for any aspect ratio without hand-tuning.
    vf = (
        "[0:v]split=2[bg][fg];"
        "[bg]scale=1080:1350:force_original_aspect_ratio=increase,"
        "crop=1080:1350,boxblur=40:10,eq=brightness=0.03:saturation=0.8[bgb];"
        "[fg]scale=1080:-1[fgs];"
        "[bgb][fgs]overlay=(W-w)/2:(H-h)/2"
    )
    try:
        run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", source_image,
             "-filter_complex", vf, "-frames:v", "1", cover])
        run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", source_image,
             "-vf", "scale=320:320:force_original_aspect_ratio=increase,crop=320:320",
             "-frames:v", "1", icon])
    except RuntimeError:
        pass
    finally:
        if tmp_embedded:
            shutil.rmtree(os.path.dirname(tmp_embedded), ignore_errors=True)


def cut(src: str, seg: Segment, dest: str, ext: str, passthrough: bool,
        book: str, author: str, track_no: int) -> None:
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-ss", f"{seg.start:.3f}", "-i", src, "-t", f"{seg.duration:.3f}",
        "-map", "0:a:0", "-map_chapters", "-1", "-map_metadata", "-1",
        "-metadata", f"title={seg.title}",
        "-metadata", f"album={book}",
        "-metadata", f"artist={author}",
        "-metadata", f"track={track_no}",
    ]
    if passthrough:
        cmd += ["-c:a", "copy"]
    else:
        cmd += ["-c:a", "aac", "-b:a", "128k", "-ac", "2", "-ar", "48000"]
    if ext == ".m4a":
        # Yoto's uploader stream-reads the file; moov must be at the front.
        cmd += ["-movflags", "+faststart"]
    cmd.append(dest)
    run(cmd)


def prep_book(src: str, library: str, out_root: str, make_zip: bool,
              force: bool, dry_run: bool, merge: bool = False) -> dict:
    book_dir = os.path.dirname(src)
    rel = os.path.relpath(book_dir, library)
    book = safe_name(os.path.basename(book_dir))
    author = rel.split(os.sep)[0] if os.sep in rel else "Unknown"
    dest_root = os.path.join(out_root, rel)

    info = probe(src)
    audio = next(s for s in info["streams"] if s["codec_type"] == "audio")
    duration = float(info["format"]["duration"])
    size = os.path.getsize(src)
    info["_bytes_per_sec"] = size / duration

    codec = audio["codec_name"]
    passthrough = codec in PASSTHROUGH_CODECS
    ext = PASSTHROUGH_CODECS.get(codec, ".m4a")
    # Re-encoding to AAC 128k changes the size/second; re-estimate so the
    # packer does not overfill a card.
    if not passthrough:
        info["_bytes_per_sec"] = 128_000 / 8

    segments = build_segments(info, duration)
    if merge:
        segments = merge_segments(segments, info["_bytes_per_sec"])
    cards = pack_cards(segments, info["_bytes_per_sec"])

    manifest_path = os.path.join(dest_root, MANIFEST)
    stamp = {"src": src, "size": size, "mtime": int(os.path.getmtime(src)),
             "merge": merge,
             "cards": len(cards), "tracks": len(segments)}
    if not force and os.path.exists(manifest_path):
        try:
            with open(manifest_path) as fh:
                if json.load(fh).get("stamp") == stamp:
                    return {"book": rel, "skipped": True, "cards": len(cards),
                            "tracks": len(segments), "warnings": []}
        except (OSError, ValueError):
            pass

    plan = {
        "book": rel, "skipped": False, "codec": codec, "passthrough": passthrough,
        "cards": len(cards), "tracks": len(segments),
        "hours": duration / 3600, "warnings": [],
        "card_detail": [
            {"label": card_label(i), "tracks": len(c),
             "hours": sum(s.duration for s in c) / 3600}
            for i, c in enumerate(cards)
        ],
    }
    if dry_run:
        return plan

    os.makedirs(dest_root, exist_ok=True)
    for i, card in enumerate(cards):
        label = card_label(i)
        card_dir = os.path.join(dest_root, label)
        os.makedirs(card_dir, exist_ok=True)
        # The zip lands in the phone's Downloads folder alongside every other
        # book's, so it is named for the book, not just "Card A".
        zip_stem = book if len(cards) == 1 else f"{book} - {label}"
        written: list[str] = []
        for n, seg in enumerate(card, 1):
            name = f"{n:02d} - {safe_name(seg.title)}{ext}"
            dest = os.path.join(card_dir, name)
            cut(src, seg, dest, ext, passthrough, book, author, n)
            actual = os.path.getsize(dest)
            if actual > 100 * 1024 * 1024:
                plan["warnings"].append(f"{rel}/{label}/{name}: {actual/1e6:.0f}MB > 100MB")
            written.append(dest)

        if make_zip:
            zip_path = os.path.join(dest_root, f"{zip_stem}.zip")
            tmp_zip = zip_path + ".partial"
            # Audio is already compressed; ZIP_STORED keeps this near-instant.
            with zipfile.ZipFile(tmp_zip, "w", zipfile.ZIP_STORED, allowZip64=True) as zf:
                for dest in written:
                    zf.write(dest, arcname=f"{zip_stem}/{os.path.basename(dest)}")
            os.replace(tmp_zip, zip_path)

    find_cover(book_dir, src, os.path.join(dest_root, "_artwork"))

    with open(manifest_path, "w") as fh:
        json.dump({"stamp": stamp, "plan": {k: v for k, v in plan.items()
                                            if k != "warnings"}}, fh, indent=2)
    return plan


def collect(targets: list[str], library: str) -> list[str]:
    found: list[str] = []
    for target in targets:
        base = target if os.path.isabs(target) else os.path.join(library, target)
        if os.path.isfile(base) and base.lower().endswith(AUDIO_EXTS):
            found.append(base)
            continue
        if os.path.isdir(base):
            roots = [base]
        else:
            # Treat as a case-insensitive substring match on the relative path.
            needle = target.lower()
            roots = [
                os.path.join(library, d) for d in os.listdir(library)
                if needle in d.lower()
            ]
            deeper = []
            for dirpath, dirnames, _ in os.walk(library):
                for d in dirnames:
                    full = os.path.join(dirpath, d)
                    if needle in os.path.relpath(full, library).lower():
                        deeper.append(full)
            roots = roots or deeper
            if not roots:
                print(f"warning: no match for {target!r}", file=sys.stderr)
        for root in roots:
            for dirpath, _, filenames in os.walk(root):
                for fn in filenames:
                    if fn.lower().endswith(AUDIO_EXTS):
                        found.append(os.path.join(dirpath, fn))
    # One book per directory: if a dir holds several audio files, the book is
    # multi-file and each file is already a track-sized chunk — take them all,
    # but never process the same file twice.
    return sorted(set(found))


README = """\
Audiobooks prepared for Yoto MYO cards
======================================

Each book folder holds one or more "Card" folders. One Card folder = one Yoto
card: it is already within Yoto's limits (max 5 hours, 500 MB, 100 tracks per
card, and no single track over 60 minutes or 100 MB).

To make a card:

1. Open the book folder and tap the .zip. It downloads to your Downloads
   folder in one go, instead of tapping every track separately.
2. Extract the zip with your file manager. You get a folder of numbered
   tracks.
3. In the Yoto app or my.yotoplay.com, create a MYO playlist and add the
   tracks from that folder. They are numbered so they stay in the right order.
4. Optional: _artwork/cover.png is a portrait cover for the card, and
   icon.png works as the per-track icon.

If a book has Card A and Card B, that book is too long for a single Yoto card
- make one card per folder, in order.

Individual tracks are also browsable inside each Card folder if you would
rather not use the zip.
"""


def main() -> int:
    ap = argparse.ArgumentParser(description="Prepare audiobooks for Yoto MYO upload.")
    ap.add_argument("targets", nargs="+",
                    help="Book/series path under the library, or a search term.")
    ap.add_argument("--library",
                    default=os.environ.get("YOTO_LIBRARY",
                                           "/mnt/data/Media/Books/Audiobooks"))
    ap.add_argument("--out",
                    default=os.environ.get("YOTO_OUT", "/mnt/data/Media/Books/Yoto"))
    ap.add_argument("--no-zip", action="store_true", help="Skip per-card zips.")
    ap.add_argument("--merge-chapters", action="store_true",
                    help="Glue chapters into the longest Yoto-legal tracks "
                         "(~5 files per card instead of ~15), so a phone can "
                         "tap each file directly instead of unzipping.")
    ap.add_argument("--force", action="store_true", help="Re-prep already-done books.")
    ap.add_argument("--dry-run", action="store_true", help="Show the plan only.")
    ap.add_argument("--jobs", type=int, default=3, help="Books to process in parallel.")
    args = ap.parse_args()

    for tool in ("ffmpeg", "ffprobe"):
        if shutil.which(tool) is None:
            print(f"error: {tool} not found on PATH", file=sys.stderr)
            return 1

    sources = collect(args.targets, args.library)
    if not sources:
        print("error: nothing to do", file=sys.stderr)
        return 1

    print(f"{len(sources)} book(s) to prepare -> {args.out}")
    if not args.dry_run:
        os.makedirs(args.out, exist_ok=True)
        readme = os.path.join(args.out, "README.txt")
        if not os.path.exists(readme):
            with open(readme, "w") as fh:
                fh.write(README)

    results = []
    failures = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {
            pool.submit(prep_book, src, args.library, args.out,
                        not args.no_zip, args.force, args.dry_run,
                        args.merge_chapters): src
            for src in sources
        }
        for done in concurrent.futures.as_completed(futures):
            src = futures[done]
            try:
                res = done.result()
            except Exception as exc:  # noqa: BLE001 - report and keep going
                failures.append((os.path.relpath(src, args.library), str(exc)))
                print(f"  FAIL {os.path.relpath(src, args.library)}: {exc}", file=sys.stderr)
                continue
            results.append(res)
            if res.get("skipped"):
                print(f"  skip {res['book']} (already prepared)")
            else:
                detail = ", ".join(
                    f"{c['label']}: {c['tracks']}tr {c['hours']:.1f}h"
                    for c in res.get("card_detail", [])
                )
                mode = "copy" if res.get("passthrough") else "re-encode"
                print(f"  ok   {res['book']} [{mode}] {detail}")

    warnings = [w for r in results for w in r.get("warnings", [])]
    print(f"\ndone: {len(results)} book(s), {len(failures)} failed, "
          f"{len(warnings)} warning(s)")
    for w in warnings:
        print(f"  WARN {w}")
    for book, err in failures:
        print(f"  FAIL {book}: {err}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
