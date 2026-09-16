"""Browse source audiobooks and stream Yoto card ZIPs without a second library.

Only one temporary track exists per download. ZIP bytes go straight to the
response; the source and publication trees are mounted read-only by systemd.
See docs/wiki/services/yoto-share.md for the access and storage model.
"""

from __future__ import annotations

import concurrent.futures
from dataclasses import dataclass
from functools import lru_cache
import hashlib
import importlib.util
import io
import json
import logging
import math
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import time
from urllib.parse import quote
import zipfile

from flask import Flask, Response, abort, render_template, request, send_file, url_for
from werkzeug.exceptions import HTTPException


spec = importlib.util.spec_from_file_location(
    "yoto_prep", Path(__file__).with_name("yoto-prep.py")
)
prep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prep)

AUDIO_EXTS = {*prep.AUDIO_EXTS, ".mp4", ".aac", ".flac", ".ogg", ".opus", ".wav",
              ".wma", ".aif", ".aiff", ".ape", ".wv"}
# Decimal MB, with room for container overhead and packet-boundary rounding.
TRACK_BYTES = 95_000_000
CARD_BYTES = 490_000_000
DOWNLOAD_SECONDS = 30 * 60
LOG = logging.getLogger("yoto")


def media_run(cmd: list[str]) -> str:
    # Media can contain network references. ffmpeg may only read local files.
    cmd = [cmd[0], "-protocol_whitelist", "file,pipe", *cmd[1:]]
    if cmd[0] == "ffmpeg":
        cmd[1:1] = ["-nostdin", "-threads", "2", "-filter_threads", "1",
                    "-filter_complex_threads", "1"]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    if result.returncode:
        raise RuntimeError(f"{cmd[0]} failed: {result.stderr[-500:]}")
    return result.stdout


# Reuse the established chapter splitting, stream-copy and artwork operations,
# with bounded execution for the HTTP service. The CLI keeps its own defaults.
prep.run = media_run


def natural_key(value: Path | str) -> list:
    return [int(part) if part.isdigit() else part.casefold()
            for part in re.split(r"(\d+)", str(value))]


def beneath(root: Path, relative: str) -> Path:
    """No dotfiles, parent traversal, or symlinks outside the allowed tree."""
    parts = Path(relative).parts
    if Path(relative).is_absolute() or any(p.startswith(".") for p in parts):
        abort(404)
    candidate = (root / relative).resolve()
    if not candidate.is_relative_to(root):
        abort(404)
    return candidate


def children(root: Path, directory: Path) -> list[Path]:
    return sorted((p for p in directory.iterdir()
                   if not p.name.startswith(".") and not p.is_symlink()
                   and p.resolve().is_relative_to(root)), key=natural_key)


def audio_filename(name: str) -> bool:
    # ABS/import tools can leave an unfinished sibling such as book.tmp.m4b.
    # It is not an additional track, even though it has an audio extension.
    return (Path(name).suffix.lower() in AUDIO_EXTS
            and not any(marker in name.lower() for marker in (".tmp.", ".partial.")))


def is_audio(path: Path) -> bool:
    return audio_filename(path.name) and path.is_file()


def scan_catalogue(root: Path) -> list[tuple[str, str]]:
    catalogue = []
    pending = [root]
    while pending:
        parent = pending.pop()
        names = []
        # DirEntry uses directory-read file types, avoiding an extra stat of
        # every track across the large virtiofs library. Never follow symlinks.
        with os.scandir(parent) as entries:
            for entry in entries:
                if entry.name.startswith("."):
                    continue
                if entry.is_dir(follow_symlinks=False):
                    pending.append(Path(entry.path))
                elif entry.is_file(follow_symlinks=False) and audio_filename(entry.name):
                    names.append(entry.name)
        if names:
            relative = str(parent.relative_to(root))
            catalogue.append((relative, (relative + " " + " ".join(names)).casefold()))
    return catalogue


def source_stamp(path: Path) -> tuple[str, int, int]:
    stat = path.stat()
    return str(path), stat.st_size, stat.st_mtime_ns


@lru_cache(maxsize=2048)
def source_info(stamp: tuple[str, int, int]) -> dict:
    return prep.probe(stamp[0])


@dataclass
class Track:
    source: Path
    stamp: tuple[str, int, int]
    segment: object
    ext: str
    passthrough: bool
    estimated_bytes: float

    @property
    def duration(self) -> float:
        return self.segment.duration


@dataclass
class Book:
    title: str
    author: str
    cards: list[list[Track]]
    version: str


def audio_tags(info: dict) -> dict:
    # Vorbis/Opus put their tags on the audio stream, MP3 often on the format.
    audio = next(s for s in info["streams"] if s["codec_type"] == "audio")
    return {k.lower(): v for tags in (info["format"].get("tags", {}), audio.get("tags", {}))
            for k, v in tags.items()}


def music_order(source: Path, info: dict) -> tuple:
    tags = audio_tags(info)

    def number(*names):
        value = next((str(tags[n]) for n in names if n in tags), "")
        match = re.match(r"\d+", value)
        return int(match[0]) if match else 0

    return number("disc", "discnumber"), number("track", "tracknumber"), natural_key(source.name)


def plan_book(directory: Path, sources: list[Path], music: bool = False) -> Book:
    stamps = tuple(source_stamp(p) for p in sources)
    # Multi-file books must be one ordered book, never competing writes to the
    # same Card A directory. Probe concurrently, then restore source order.
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        infos = list(pool.map(source_info, stamps))
    ordered = list(zip(sources, stamps, infos))
    if music:
        ordered.sort(key=lambda item: music_order(item[0], item[2]))
    tracks = []
    author = ""
    for src, stamp, raw in ordered:
        audio = next(s for s in raw["streams"] if s["codec_type"] == "audio")
        duration = float(raw["format"]["duration"])
        if not math.isfinite(duration) or duration <= 0:
            raise ValueError("Audio duration is missing or invalid")
        tags = audio_tags(raw)
        author = author or tags.get("artist", "")
        codec = audio["codec_name"]
        passthrough = codec in prep.PASSTHROUGH_CODECS
        rate = stamp[1] / duration if passthrough else 128_000 / 8
        # Use the CLI splitter with a conservative rate to respect decimal MB.
        info = dict(raw, _bytes_per_sec=rate * prep.TRACK_BYTES / TRACK_BYTES)
        if music or (not info.get("chapters") and len(sources) > 1):
            info["chapters"] = [{"start_time": 0, "end_time": duration,
                                 "tags": {"title": tags.get("title", src.stem)}}]
        for segment in prep.build_segments(info, duration):
            tracks.append(Track(src, stamp, segment,
                                prep.PASSTHROUGH_CODECS.get(codec, ".m4a"),
                                passthrough, segment.duration * rate))
    # Retain the existing five-hour grouping. Use actual per-source rates for
    # mixed-bitrate books rather than pretending every track has the same rate.
    count = max(1, math.ceil(sum(t.duration for t in tracks) / prep.CARD_SECONDS),
                math.ceil(sum(t.estimated_bytes for t in tracks) / CARD_BYTES),
                math.ceil(len(tracks) / prep.CARD_TRACKS))
    for n in range(count, len(tracks) + 1):
        cards = prep._split_evenly(tracks, n)
        if all(len(c) <= prep.CARD_TRACKS
               and sum(t.duration for t in c) <= prep.CARD_SECONDS - 10
               and sum(t.estimated_bytes for t in c) <= CARD_BYTES for c in cards):
            break
    else:
        cards = [[t] for t in tracks]
    version = hashlib.sha256(json.dumps(stamps).encode()).hexdigest()[:24]
    return Book(prep.safe_name(directory.name), author, cards, version)


class ZipBuffer(io.RawIOBase):
    """Unseekable sink drained after every write, not an in-memory ZIP."""

    def __init__(self):
        self.pending = bytearray()

    def writable(self):
        return True

    def write(self, data):
        self.pending.extend(data)
        return len(data)

    def drain(self):
        data = bytes(self.pending)
        self.pending.clear()
        return data


def card_zip(book: Book, index: int, scratch: str | None = None):
    """Stream a card, cleaning tracks on success, failure and disconnect."""
    card = book.cards[index]
    stem = book.title if len(book.cards) == 1 else f"{book.title} - {prep.card_label(index)}"
    sink = ZipBuffer()
    archive = zipfile.ZipFile(sink, "w", zipfile.ZIP_STORED, allowZip64=True)
    deadline = time.monotonic() + DOWNLOAD_SECONDS
    total_bytes = 0
    total_duration = 0.0
    try:
        with tempfile.TemporaryDirectory(prefix="yoto-", dir=scratch) as temp:
            # A small first entry starts the browser download immediately.
            archive.writestr(f"{stem}/_artwork/instructions.txt",
                             "Extract this ZIP, then add the numbered audio tracks "
                             "to a new Yoto Make Your Own playlist.\n")
            yield sink.drain()
            for number, track in enumerate(card, 1):
                if time.monotonic() > deadline:
                    raise TimeoutError("Card download exceeded 30 minutes")
                if source_stamp(track.source) != track.stamp:
                    raise RuntimeError("Source changed during download; reload the book")
                name = f"{number:03d} - {prep.safe_name(track.segment.title)}{track.ext}"
                dest = Path(temp) / name
                prep.cut(str(track.source), track.segment, str(dest), track.ext,
                         track.passthrough, book.title, book.author, number)
                info = prep.probe(str(dest))
                duration = float(info["format"]["duration"])
                size = dest.stat().st_size
                total_bytes += size
                total_duration += duration
                if (not math.isfinite(duration) or duration <= 0 or duration > 3600
                        or size > 100_000_000 or total_bytes > 500_000_000
                        or total_duration > prep.CARD_SECONDS):
                    raise RuntimeError("Generated audio exceeds Yoto card limits")
                with archive.open(f"{stem}/{name}", "w", force_zip64=True) as entry:
                    with dest.open("rb") as audio:
                        while chunk := audio.read(1024 * 1024):
                            if time.monotonic() > deadline:
                                raise TimeoutError("Card download exceeded 30 minutes")
                            entry.write(chunk)
                            yield sink.drain()
                yield sink.drain()
                dest.unlink()
            artwork = Path(temp) / "_artwork"
            prep.find_cover(str(card[0].source.parent), str(card[0].source), str(artwork))
            for picture in sorted(artwork.glob("*.png")):
                archive.write(picture, f"{stem}/_artwork/{picture.name}")
                yield sink.drain()
            archive.close()
            yield sink.drain()
    finally:
        # Do not emit a central directory after a failure: the client must see
        # an incomplete download, never a valid ZIP with silently missing tracks.
        archive.close()


def create_app(library=None, published=None, scratch=None, andys_music=None):
    app = Flask(__name__)
    library = Path(library or os.environ.get("YOTO_LIBRARY",
                   "/mnt/data/Media/Books/Audiobooks")).resolve()
    published = Path(published or os.environ.get("YOTO_SHARE", "/mnt/data/Media/Yoto")).resolve()
    andys_music = andys_music or os.environ.get("YOTO_ANDYS_MUSIC")
    andys_music = Path(andys_music).resolve() if andys_music else None
    downloads = threading.BoundedSemaphore(2)
    planners = threading.BoundedSemaphore(2)
    catalogue_cache = {}
    catalogue_lock = threading.Lock()

    def page(title, entries=(), book=None, relative="", message="", status=200, section="books"):
        music = section != "books"
        endpoint, download_endpoint = {
            "books": ("books", "download"), "music": ("music", "music_download"),
            "andys": ("andys_music_page", "andys_download"),
        }[section]
        parent_link = None
        if relative:
            parent = Path(relative).parent
            parent_relative = "" if parent == Path(".") else parent.as_posix() + "/"
            parent_name = parent.name or {
                "books": "Audiobooks", "music": "Music", "andys": "Andy's music",
            }[section]
            parent_link = (parent_name, url_for(endpoint, relative=parent_relative))
        return render_template("browse.html", title=title, entries=entries,
                               book=book, relative=relative, message=message,
                               parent_link=parent_link,
                               card_label=prep.card_label, music=music,
                               search_endpoint=endpoint, download_endpoint=download_endpoint,
                               andys_enabled=andys_music is not None,
                               query=request.args.get("q", "")[:100]), status

    def search_entries(root, endpoint, query, max_age=60):
        # Only paths and filenames are cached. No database credentials, media
        # copying or whole-library ffprobe work is needed for a fast search.
        cached = catalogue_cache.get(root)
        if cached is None or time.monotonic() - cached[0] >= max_age:
            if catalogue_lock.acquire(blocking=False):
                try:
                    catalogue = scan_catalogue(root)
                    cached = (time.monotonic(), catalogue)
                    catalogue_cache[root] = cached
                finally:
                    catalogue_lock.release()
            elif cached is None:
                abort(503, "The library search is loading. Please try again in a moment.")
        words = query.casefold().split()
        matches = sorted((relative for relative, haystack in cached[1]
                          if all(word in haystack for word in words)), key=natural_key)
        entries = [(rel, url_for(endpoint, relative=rel) + "/", "") for rel in matches[:200]]
        message = f"Showing 200 of {len(matches)} matches. Add another word to narrow the search." if len(matches) > 200 else ""
        return entries, message

    @app.after_request
    def headers(response):
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Content-Security-Policy"] = (
            "default-src 'none'; style-src 'self'; img-src 'self'; "
            "base-uri 'none'; form-action 'self'; frame-ancestors 'none'"
        )
        response.headers["Referrer-Policy"] = "no-referrer"
        response.headers["Cache-Control"] = "no-store"
        return response

    @app.errorhandler(HTTPException)
    def http_error(error):
        return page(error.name, message=error.description, status=error.code)

    @app.errorhandler(Exception)
    def unexpected_error(error):
        LOG.exception("YOTO_REQUEST_FAILED")
        return page("This book could not be prepared", status=503,
                    message="Please retry shortly. If it keeps failing, let Andy know.")

    @app.get("/healthz")
    def health():
        # No persistent application state. Exercise both real mounts and the
        # ephemeral write path, rather than only reporting a living process.
        next(library.iterdir(), None)
        next(published.iterdir(), None)
        if andys_music is not None:
            next(andys_music.iterdir(), None)
        with tempfile.TemporaryFile(dir=scratch) as test:
            test.write(b"yoto")
        return {"status": "ok"}

    @app.get("/")
    def home():
        entries = [
            ("Audiobooks", url_for("books"), "Browse all books and download cards"),
            ("Music", "/Music/", "Albums for your cards"),
        ]
        if andys_music is not None:
            entries.append(("Andy's music", url_for("andys_music_page"),
                            "Search Andy's collection and download an album for Yoto"))
        return page("Yoto library", entries=entries)

    def get_book(relative, root=library, music=False):
        directory = beneath(root, relative)
        if not directory.is_dir():
            abort(404)
        sources = [p for p in children(root, directory) if is_audio(p)]
        if not sources:
            abort(404)
        if not planners.acquire(blocking=False):
            abort(503, "Other books are being opened. Please try again in a moment.")
        try:
            return plan_book(directory, sources, music=music)
        finally:
            planners.release()

    @app.get("/Books/", defaults={"relative": ""})
    @app.get("/Books/<path:relative>")
    def books(relative):
        directory = beneath(library, relative)
        if not directory.is_dir():
            abort(404)
        items = children(library, directory)
        entries = [(p.name, url_for("books", relative=str(p.relative_to(library))) + "/", "")
                   for p in items if p.is_dir()]
        query = request.args.get("q", "").strip().casefold()[:100]
        if query:
            entries, message = search_entries(library, "books", query, max_age=0)
            return page(f"Search: {request.args['q'][:100]}", entries=entries, message=message)
        book = get_book(relative) if any(is_audio(p) for p in items) else None
        return page(directory.name if relative else "Audiobooks", entries=entries,
                    book=book, relative=relative.rstrip("/"))

    def download_card(relative, index, root, music=False):
        if request.headers.get("Range"):
            abort(416, "Generated ZIPs cannot resume. Start a new download from the book page.")
        book = get_book(relative, root, music=music)
        if index >= len(book.cards):
            abort(404)
        if request.args.get("v") != book.version:
            abort(409, "This book has changed. Reopen its page for current download links.")
        stem = book.title if len(book.cards) == 1 else f"{book.title} - {prep.card_label(index)}"
        headers = {"Content-Disposition": f"attachment; filename=card.zip; filename*=UTF-8''{quote(stem + '.zip')}",
                   "Accept-Ranges": "none", "X-Accel-Buffering": "no"}
        if request.method == "HEAD":
            return Response(headers=headers, mimetype="application/zip")
        if not downloads.acquire(blocking=False):
            abort(503, "Two cards are downloading. Please try again when one finishes.")

        def stream():
            try:
                yield from card_zip(book, index, scratch)
            except GeneratorExit:
                raise
            except Exception:
                LOG.exception("YOTO_DOWNLOAD_FAILED")
                raise
            finally:
                downloads.release()

        return Response(stream(), headers=headers, mimetype="application/zip")

    @app.get("/cards/<path:relative>/<int:index>.zip")
    def download(relative, index):
        return download_card(relative, index, library)

    @app.get("/music-cards/<path:relative>/<int:index>.zip")
    def music_download(relative, index):
        return download_card(relative, index, published / "Music", music=True)

    @app.get("/andys-music-cards/<path:relative>/<int:index>.zip")
    def andys_download(relative, index):
        if andys_music is None:
            abort(404)
        return download_card(relative, index, andys_music, music=True)

    # Preserve existing Music links. Never expose
    # source metadata, scripts, sidecars or arbitrary files from the library.
    @app.get("/Music/", defaults={"relative": ""})
    @app.get("/Music/<path:relative>")
    def music(relative):
        return music_page(published / "Music", relative, "music", "music")

    @app.get("/AndysMusic/", defaults={"relative": ""})
    @app.get("/AndysMusic/<path:relative>")
    def andys_music_page(relative):
        if andys_music is None:
            abort(404)
        return music_page(andys_music, relative, "andys_music_page", "andys")

    def music_page(root, relative, endpoint, section):
        path = beneath(root, relative)
        if path.is_dir():
            query = request.args.get("q", "").strip()[:100]
            if query:
                entries, message = search_entries(root, endpoint, query)
                return page(f"Search: {query}", entries=entries, message=message, section=section)
            items = children(root, path)
            book = get_book(relative, root, music=True) if any(is_audio(p) for p in items) else None
            entries = [(p.name, url_for(endpoint, relative=str(p.relative_to(root))) + ("/" if p.is_dir() else ""), "")
                       for p in items if p.is_dir() or (section == "music" and (
                           is_audio(p) or p.suffix.lower() in {".jpg", ".jpeg", ".png"}))]
            title = path.name if relative else ("Andy's music" if section == "andys" else "Music")
            return page(title, entries=entries, book=book,
                        relative=relative.rstrip("/"), section=section)
        # Andy's section delivers Yoto-compatible ZIPs rather than links to
        # Opus/FLAC originals that the uploader cannot use.
        if section == "andys":
            abort(404)
        if not path.is_file() or path.suffix.lower() not in AUDIO_EXTS | {".zip", ".jpg", ".jpeg", ".png", ".txt"}:
            abort(404)
        return send_file(path, as_attachment=True)

    return app


app = create_app()
