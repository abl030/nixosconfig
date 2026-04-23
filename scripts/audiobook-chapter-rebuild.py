#!/usr/bin/env python3

"""Rebuild audiobook chapter boundaries from TOCs and spoken headings."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable
from urllib.parse import urlencode
from urllib.request import Request, urlopen


FADEDPAGE_SEARCH_URL = "https://www.fadedpage.com/csearc2.php"
FADEDPAGE_TXT_URL = "https://www.fadedpage.com/books/{pid}/{pid}.txt"
MINOR_WORDS = {
    "a",
    "an",
    "and",
    "as",
    "at",
    "but",
    "by",
    "for",
    "from",
    "if",
    "in",
    "into",
    "nor",
    "of",
    "off",
    "on",
    "or",
    "out",
    "over",
    "per",
    "the",
    "to",
    "up",
    "via",
    "with",
}
WORD_NUMBERS = {
    "one": 1,
    "two": 2,
    "three": 3,
    "four": 4,
    "five": 5,
    "six": 6,
    "seven": 7,
    "eight": 8,
    "nine": 9,
    "ten": 10,
    "eleven": 11,
    "twelve": 12,
    "thirteen": 13,
    "fourteen": 14,
    "fifteen": 15,
    "sixteen": 16,
    "seventeen": 17,
    "eighteen": 18,
    "nineteen": 19,
    "twenty": 20,
    "twenty one": 21,
    "twenty-one": 21,
}
ROMAN_NUMERALS = {
    "i": 1,
    "ii": 2,
    "iii": 3,
    "iv": 4,
    "v": 5,
    "vi": 6,
    "vii": 7,
    "viii": 8,
    "ix": 9,
    "x": 10,
    "xi": 11,
    "xii": 12,
    "xiii": 13,
    "xiv": 14,
    "xv": 15,
    "xvi": 16,
    "xvii": 17,
    "xviii": 18,
    "xix": 19,
    "xx": 20,
    "xxi": 21,
    "xxii": 22,
}


@dataclass(frozen=True)
class Book:
    number: int
    title: str
    folder: str
    filename: str
    root: Path
    search_title: str | None = None
    chapter_titles: tuple[str, ...] | None = None

    @property
    def dir_path(self) -> Path:
        return self.root / self.folder

    @property
    def file_path(self) -> Path:
        return self.dir_path / self.filename

    @property
    def toc_title(self) -> str:
        return self.search_title or self.title


@dataclass(frozen=True)
class TocSource:
    type: str
    author: str


@dataclass(frozen=True)
class SeriesConfig:
    slug: str
    name: str
    root: Path
    toc_source: TocSource
    books: dict[int, Book]


def load_manifest(path: Path) -> SeriesConfig:
    data = json.loads(path.read_text())
    root = Path(data["series_root"])
    toc_source = TocSource(**data["toc_source"])
    books = {
        int(entry["number"]): Book(
            number=int(entry["number"]),
            title=entry["title"],
            folder=entry["folder"],
            filename=entry["filename"],
            root=root,
            search_title=entry.get("search_title"),
            chapter_titles=tuple(entry["chapter_titles"]) if entry.get("chapter_titles") else None,
        )
        for entry in data["books"]
    }
    slug = data.get("slug") or path.stem
    return SeriesConfig(
        slug=slug,
        name=data.get("name", slug),
        root=root,
        toc_source=toc_source,
        books=books,
    )


def log(message: str) -> None:
    print(message, flush=True)


def run(cmd: list[str], *, check: bool = True, capture_stderr: bool = False) -> subprocess.CompletedProcess[str]:
    stderr = subprocess.STDOUT if capture_stderr else subprocess.PIPE
    return subprocess.run(cmd, check=check, text=True, stdout=subprocess.PIPE, stderr=stderr)


def fetch_json(url: str, data: dict[str, str] | None = None, headers: dict[str, str] | None = None) -> dict:
    body = urlencode(data).encode() if data else None
    req = Request(url, data=body, headers=headers or {"User-Agent": "Mozilla/5.0"})
    with urlopen(req, timeout=30) as response:
        return json.loads(response.read().decode())


def fetch_text(url: str) -> str:
    req = Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urlopen(req, timeout=30) as response:
        return response.read().decode("utf-8", "ignore")


def title_case(raw: str) -> str:
    pieces: list[str] = []
    tokens = re.split(r"(\s+|[-—/:!?.])", raw.strip().lower())
    word_index = 0
    word_total = len([t for t in tokens if t and re.search(r"[a-z0-9]", t)])
    prev_token = ""
    for token in tokens:
        if not token:
            continue
        if re.fullmatch(r"\s+|[-—/:!?.]", token):
            pieces.append(token)
            prev_token = token
            continue
        word_index += 1
        if token in MINOR_WORDS and 1 < word_index < word_total and prev_token not in {"-", "—", ":", "/", "!", "?"}:
            pieces.append(token)
        else:
            pieces.append(token[0].upper() + token[1:])
        prev_token = token
    result = "".join(pieces)
    result = re.sub(r"\b([A-Z][A-Za-z]+)'S\b", r"\1's", result)
    return result


def clean_toc_title(raw: str) -> str:
    cleaned = raw.replace("_", " ")
    cleaned = (
        cleaned.replace("’", "'")
        .replace("‘", "'")
        .replace("“", '"')
        .replace("”", '"')
    )
    cleaned = re.sub(r"(?:\s[-.]\s*){2,}$", "", cleaned)
    cleaned = re.sub(r"\s+", " ", cleaned).strip(" -. ")
    return cleaned


def clean_manual_title(raw: str) -> str:
    cleaned = (
        raw.replace("’", "'")
        .replace("‘", "'")
        .replace("“", '"')
        .replace("”", '"')
        .replace("—", "-")
        .replace("–", "-")
    )
    return re.sub(r"\s+", " ", cleaned).strip()


def parse_toc(text: str) -> list[str]:
    start_match = re.search(r"(?im)^\s*(?:contents|the chapters|c\s+o\s+n\s+t\s+e\s+n\s+t\s+s)\s*$", text)
    if not start_match:
        raise RuntimeError("Could not find CONTENTS block")
    tail = text[start_match.start() :]
    end_match = re.search(r"(?im)^\s*chapter[ \t]+(?:one|i|1)\b", tail)
    if not end_match:
        raise RuntimeError("Could not find first chapter marker after CONTENTS")
    block = tail[: end_match.start()]
    titles: list[tuple[int, str]] = []
    for line in block.splitlines():
        match = re.match(r"^\s*(\d+)\.?\s+(.+?)\s+(?:_?p\.?_?\s*)?\d+\s*$", line, flags=re.IGNORECASE)
        if not match:
            continue
        number = int(match.group(1))
        raw_title = clean_toc_title(match.group(2).strip())
        titles.append((number, title_case(raw_title)))
    if not titles:
        raise RuntimeError("No chapter titles parsed from CONTENTS")
    numbers = [number for number, _ in titles]
    if numbers != list(range(1, len(numbers) + 1)):
        raise RuntimeError(f"Unexpected chapter numbering in TOC: {numbers}")
    return [title for _, title in titles]


def fadedpage_titles(book: Book, *, author: str) -> tuple[str, list[str]]:
    data = fetch_json(
        FADEDPAGE_SEARCH_URL,
        data={
            "title": book.toc_title,
            "author": author,
            "plang": "--",
            "category": "--",
            "publisher": "",
            "pubdate": "",
            "pcountry": "--",
            "tags": "",
            "bookid": "",
            "sort": "auto",
        },
    )
    rows = data.get("rows", [])
    if not rows:
        raise RuntimeError(f"No FadedPage result for {book.title}")
    pid = rows[0]["pid"]
    text = fetch_text(FADEDPAGE_TXT_URL.format(pid=pid))
    return pid, parse_toc(text)


def book_titles(series: SeriesConfig, book: Book) -> tuple[list[str], dict[str, str]]:
    if book.chapter_titles:
        return [clean_manual_title(title) for title in book.chapter_titles], {"title_source": "manifest"}
    if series.toc_source.type == "fadedpage":
        pid, titles = fadedpage_titles(book, author=series.toc_source.author)
        return titles, {"title_source": "fadedpage", "fadedpage_pid": pid}
    raise RuntimeError(f"Unsupported TOC source: {series.toc_source.type}")


def existing_titles(path: Path) -> list[str]:
    probe = run(
        [
            "ffprobe",
            "-v",
            "error",
            "-print_format",
            "json",
            "-show_chapters",
            str(path),
        ]
    )
    data = json.loads(probe.stdout)
    return [chapter.get("tags", {}).get("title", "") for chapter in data.get("chapters", [])]


def needs_rebuild(path: Path) -> bool:
    titles = existing_titles(path)
    if not titles:
        return True
    return bool(re.match(r"^(?:\d+\s*-|chapter\b)", titles[0], flags=re.IGNORECASE))


def duration_seconds(path: Path) -> float:
    probe = run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=nw=1:nk=1",
            str(path),
        ]
    )
    return float(probe.stdout.strip())


def silencedetect(path: Path, minimum_silence: float) -> list[float]:
    result = run(
        [
            "ffmpeg",
            "-hide_banner",
            "-nostats",
            "-i",
            str(path),
            "-af",
            f"silencedetect=noise=-30dB:d={minimum_silence}",
            "-f",
            "null",
            "-",
        ],
        capture_stderr=True,
    )
    return [float(match.group(1)) for match in re.finditer(r"silence_end:\s*([0-9.]+)", result.stdout)]


def transcribe_candidate(book_path: Path, candidate_time: float, workdir: Path) -> str:
    stem = f"{candidate_time:.3f}".replace(".", "_")
    clip = workdir / f"{stem}.wav"
    out_dir = workdir / f"out-{stem}"
    clip_start = max(0.0, candidate_time - 1.5)
    run(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-ss",
            f"{clip_start:.3f}",
            "-t",
            "16",
            "-i",
            str(book_path),
            "-ac",
            "1",
            "-ar",
            "16000",
            str(clip),
        ]
    )
    if out_dir.exists():
        shutil.rmtree(out_dir)
    run(
        [
            "whisper-ctranslate2",
            "--model",
            "tiny.en",
            "--device",
            "cpu",
            "--threads",
            "8",
            "--language",
            "en",
            "--task",
            "transcribe",
            "--output_dir",
            str(out_dir),
            "--output_format",
            "txt",
            str(clip),
        ]
    )
    transcript_path = out_dir / f"{clip.stem}.txt"
    return transcript_path.read_text().strip()


def parse_chapter_number(transcript: str) -> int | None:
    if not transcript.strip():
        return None
    line = transcript.splitlines()[0].strip().lower()
    line = re.sub(r"[^a-z0-9 -]", " ", line)
    line = re.sub(r"\s+", " ", line)
    match = re.match(r"chapter\s+(.+)$", line)
    if not match:
        return None
    remainder = match.group(1).strip()
    for token in sorted(WORD_NUMBERS, key=len, reverse=True):
        if remainder == token or remainder.startswith(token + " "):
            return WORD_NUMBERS[token]
    token_match = re.match(r"([ivxlcdm]+|\d+)\b", remainder)
    if not token_match:
        return None
    token = token_match.group(1)
    if token.isdigit():
        return int(token)
    return ROMAN_NUMERALS.get(token)


def candidate_title_words(title: str) -> set[str]:
    return {word for word in re.findall(r"[a-z]+", title.lower()) if word not in MINOR_WORDS and len(word) > 2}


def choose_boundaries(book: Book, titles: list[str], candidates: list[tuple[float, str]]) -> tuple[list[dict], list[dict]]:
    accepted: dict[int, dict] = {}
    debug: list[dict] = []
    next_chapter = 2
    for candidate_time, transcript in sorted(candidates, key=lambda item: item[0]):
        chapter_number = parse_chapter_number(transcript)
        cleaned = " ".join(transcript.split())
        row = {
            "time": round(candidate_time, 3),
            "chapter_number": chapter_number,
            "transcript": cleaned[:240],
            "accepted": False,
        }
        if chapter_number != next_chapter:
            debug.append(row)
            continue
        row["accepted"] = True
        row["reason"] = "spoken"
        debug.append(row)
        accepted[next_chapter] = {"time": candidate_time, "transcript": cleaned}
        next_chapter += 1
        if next_chapter > len(titles):
            break

    def unused_rows() -> list[dict]:
        return [row for row in debug if not row["accepted"]]

    known_numbers = [1] + sorted(accepted)
    for left, right in zip(known_numbers, known_numbers[1:]):
        if right - left <= 1:
            continue
        start_time = 0.0 if left == 1 else accepted[left]["time"]
        end_time = accepted[right]["time"]
        candidates_in_gap = [row for row in unused_rows() if start_time < row["time"] < end_time]
        needed = right - left - 1
        if len(candidates_in_gap) < needed:
            continue
        for chapter_number, row in zip(range(left + 1, right), sorted(candidates_in_gap, key=lambda item: item["time"])):
            row["accepted"] = True
            row["reason"] = "gap-fill"
            accepted[chapter_number] = {"time": row["time"], "transcript": row["transcript"]}

    if accepted:
        last_explicit = max(accepted)
        if last_explicit < len(titles):
            trailing = [row for row in unused_rows() if row["time"] > accepted[last_explicit]["time"]]
            needed = len(titles) - last_explicit
            if len(trailing) >= needed:
                for chapter_number, row in zip(
                    range(last_explicit + 1, len(titles) + 1),
                    sorted(trailing, key=lambda item: item["time"])[:needed],
                ):
                    row["accepted"] = True
                    row["reason"] = "gap-fill-tail"
                    accepted[chapter_number] = {"time": row["time"], "transcript": row["transcript"]}

    if len(accepted) != len(titles) - 1:
        raise RuntimeError(f"Accepted {len(accepted)} boundaries for {book.title}, expected {len(titles) - 1}")

    return debug, [
        {"id": index, "start": start, "end": end, "title": title}
        for index, (start, end, title) in enumerate(
            zip(
                [0.0] + [accepted[number]["time"] for number in range(2, len(titles) + 1)],
                [accepted[number]["time"] for number in range(2, len(titles) + 1)] + [0.0],
                titles,
            )
        )
    ]


def finalize_chapters(chapters: list[dict], duration: float) -> list[dict]:
    fixed: list[dict] = []
    for index, chapter in enumerate(chapters):
        start = float(chapter["start"])
        end = duration if index == len(chapters) - 1 else float(chapters[index + 1]["start"])
        fixed.append(
            {
                "id": index,
                "start": round(start, 3),
                "end": round(end, 3),
                "title": chapter["title"],
            }
        )
    return fixed


def auth_headers() -> dict[str, str]:
    base = os.environ.get("AUDIOBOOKSHELF_URL")
    token = os.environ.get("AUDIOBOOKSHELF_TOKEN")
    if not base or not token:
        raise RuntimeError("AUDIOBOOKSHELF_URL and AUDIOBOOKSHELF_TOKEN must be set for --apply")
    return {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }


def abs_get(path: str) -> dict:
    base = os.environ["AUDIOBOOKSHELF_URL"]
    headers = {"Authorization": f"Bearer {os.environ['AUDIOBOOKSHELF_TOKEN']}"}
    req = Request(f"{base}{path}", headers=headers)
    with urlopen(req, timeout=30) as response:
        return json.loads(response.read().decode())


def abs_post(path: str, payload: dict | None = None) -> str:
    base = os.environ["AUDIOBOOKSHELF_URL"]
    headers = auth_headers()
    body = json.dumps(payload or {}).encode()
    req = Request(f"{base}{path}", data=body, headers=headers, method="POST")
    with urlopen(req, timeout=60) as response:
        return response.read().decode()


def abs_items_by_path() -> dict[str, str]:
    library_id = os.environ.get("AUDIOBOOKSHELF_LIBRARY_ID")
    if not library_id:
        raise RuntimeError("AUDIOBOOKSHELF_LIBRARY_ID must be set for --apply")
    data = abs_get(f"/api/libraries/{library_id}/items?limit=500")
    return {result["path"]: result["id"] for result in data.get("results", [])}


def verify_file_titles(book: Book) -> tuple[str, str]:
    titles = existing_titles(book.file_path)
    if not titles:
        raise RuntimeError(f"No chapters found in {book.file_path}")
    return titles[0], titles[-1]


def analyze_book(
    series: SeriesConfig,
    book: Book,
    output_dir: Path,
    *,
    minimum_silence: float = 3.5,
    keep_workdir: bool = False,
) -> dict:
    titles, title_metadata = book_titles(series, book)
    duration = duration_seconds(book.file_path)
    thresholds: list[float] = []
    for value in [minimum_silence, 3.0, 2.6, 2.2]:
        if value not in thresholds:
            thresholds.append(value)

    last_error: Exception | None = None
    workdir = Path(tempfile.mkdtemp(prefix=f"{series.slug}-{book.number:02d}-"))
    transcribed_by_time: dict[float, str] = {}
    seen_times: list[float] = []
    for threshold in thresholds:
        candidates = silencedetect(book.file_path, threshold)
        if not candidates:
            last_error = RuntimeError(f"No silence candidates found for {book.title} at d={threshold}")
            continue
        try:
            for candidate_time in candidates:
                if any(abs(candidate_time - seen) < 0.75 for seen in seen_times):
                    continue
                transcribed_by_time[candidate_time] = transcribe_candidate(book.file_path, candidate_time, workdir)
                seen_times.append(candidate_time)
            debug, chapter_seed = choose_boundaries(
                book,
                titles,
                sorted(transcribed_by_time.items(), key=lambda item: item[0]),
            )
            chapters = finalize_chapters(chapter_seed, duration)
            report = {
                "book_number": book.number,
                "title": book.title,
                "file": str(book.file_path),
                "minimum_silence": threshold,
                "duration": round(duration, 3),
                "chapter_count": len(chapters),
                "chapters": chapters,
                "candidates": debug,
            }
            report.update(title_metadata)
            output_path = output_dir / f"{book.number:02d}.json"
            output_path.write_text(json.dumps(report, indent=2) + "\n")
            if not keep_workdir:
                shutil.rmtree(workdir, ignore_errors=True)
            return report
        except Exception as exc:
            last_error = exc
            debug_report = {
                "book_number": book.number,
                "title": book.title,
                "file": str(book.file_path),
                "minimum_silence": threshold,
                "duration": round(duration, 3),
                "toc_titles": titles,
                "workdir": str(workdir),
                "candidates": [
                    {"time": round(candidate_time, 3), "transcript": " ".join(transcript.split())[:240]}
                    for candidate_time, transcript in sorted(transcribed_by_time.items(), key=lambda item: item[0])
                ],
            }
            debug_report.update(title_metadata)
            (output_dir / f"{book.number:02d}-debug.json").write_text(json.dumps(debug_report, indent=2) + "\n")
            continue

    if not keep_workdir:
        shutil.rmtree(workdir, ignore_errors=True)
    assert last_error is not None
    raise last_error


def apply_report(report: dict, item_map: dict[str, str]) -> None:
    book_dir = str(Path(report["file"]).parent)
    item_id = item_map.get(book_dir)
    if not item_id:
        raise RuntimeError(f"No ABS item for {book_dir}")
    payload = {"chapters": report["chapters"]}
    abs_post(f"/api/items/{item_id}/chapters", payload)
    abs_post(f"/api/tools/item/{item_id}/embed-metadata")
    time.sleep(4)


def parse_numbers(values: Iterable[str], books: dict[int, Book]) -> list[int]:
    selected: list[int] = []
    for value in values:
        if value == "all":
            return sorted(books)
        if "-" in value:
            start, end = value.split("-", 1)
            selected.extend(range(int(start), int(end) + 1))
        else:
            selected.append(int(value))
    return sorted(dict.fromkeys(selected))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, help="Series manifest JSON")
    parser.add_argument("--books", nargs="+", default=["all"], help="Book numbers, ranges, or 'all'")
    parser.add_argument("--output-dir", help="Directory for JSON reports")
    parser.add_argument("--minimum-silence", type=float, default=3.5, help="Minimum silence duration for candidate detection")
    parser.add_argument("--force", action="store_true", help="Rebuild even if the file already has named chapters")
    parser.add_argument("--apply", action="store_true", help="Write rebuilt chapters into ABS and re-embed metadata")
    parser.add_argument("--keep-workdirs", action="store_true", help="Keep temporary ASR workdirs for debugging")
    parser.add_argument("--keep-going", action="store_true", help="Continue past individual book failures")
    parser.add_argument(
        "--reuse-reports",
        action="store_true",
        help="Load existing JSON reports from --output-dir instead of re-running analysis",
    )
    args = parser.parse_args()

    if not args.reuse_reports:
        required = ["ffmpeg", "ffprobe", "whisper-ctranslate2"]
        missing = [name for name in required if shutil.which(name) is None]
        if missing:
            parser.error(f"Missing required tools in PATH: {', '.join(missing)}")

    manifest_path = Path(args.manifest)
    series = load_manifest(manifest_path)

    output_dir = Path(args.output_dir or f"/tmp/{series.slug}-chapters")
    output_dir.mkdir(parents=True, exist_ok=True)

    reports: list[dict] = []
    failures: list[tuple[int, str, str]] = []
    for number in parse_numbers(args.books, series.books):
        book = series.books[number]
        try:
            report_path = output_dir / f"{book.number:02d}.json"
            if args.reuse_reports:
                if not report_path.exists():
                    raise RuntimeError(f"Missing report for {book.title}: {report_path}")
                report = json.loads(report_path.read_text())
                log(
                    f"reuse {book.number:02d} {book.title}: {report['chapter_count']} chapters "
                    f"({report['chapters'][0]['title']} -> {report['chapters'][-1]['title']})"
                )
            else:
                if not book.file_path.exists():
                    raise RuntimeError(f"Missing file for {book.title}: {book.file_path}")
                if not args.force and not needs_rebuild(book.file_path):
                    log(f"skip {book.number:02d} {book.title}: already has named chapters")
                    continue
                log(f"analyze {book.number:02d} {book.title}")
                report = analyze_book(
                    series,
                    book,
                    output_dir,
                    minimum_silence=args.minimum_silence,
                    keep_workdir=args.keep_workdirs,
                )
                log(
                    f"ok {book.number:02d} {book.title}: {report['chapter_count']} chapters "
                    f"({report['chapters'][0]['title']} -> {report['chapters'][-1]['title']})"
                )
            reports.append(report)
        except Exception as exc:
            failures.append((book.number, book.title, str(exc)))
            log(f"fail {book.number:02d} {book.title}: {exc}")
            if not args.keep_going:
                raise

    if args.apply:
        item_map = abs_items_by_path()
        for report in reports:
            book = series.books[report["book_number"]]
            log(f"apply {book.number:02d} {book.title}")
            apply_report(report, item_map)
            first_title, last_title = verify_file_titles(book)
            log(f"verified {book.number:02d} {book.title}: {first_title} -> {last_title}")

    if failures:
        summary = "; ".join(f"{number:02d} {title}: {error}" for number, title, error in failures)
        raise RuntimeError(summary)

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # pragma: no cover - operational script
        print(f"error: {exc}", file=sys.stderr)
        raise
