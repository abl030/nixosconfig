#!/usr/bin/env python3
"""Ingest YouTube captions into a durable, chunked local corpus."""

from __future__ import annotations

import argparse
import html
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any


def timestamp(seconds: float) -> str:
    total = max(0, int(seconds))
    hours, remainder = divmod(total, 3600)
    minutes, secs = divmod(remainder, 60)
    return f"{hours}:{minutes:02d}:{secs:02d}" if hours else f"{minutes}:{secs:02d}"


def clean_text(value: str) -> str:
    value = html.unescape(value).replace("\u200b", " ")
    value = re.sub(r"<[^>]+>", "", value)
    return re.sub(r"\s+", " ", value).strip()


def run_yt_dlp(url: str, language: str, output_dir: Path) -> tuple[Path, Path]:
    command = [
        "yt-dlp", "--skip-download", "--write-auto-subs", "--write-subs",
        "--sub-langs", language, "--sub-format", "json3", "--write-info-json",
        "--no-playlist", "--output", str(output_dir / "%(id)s.%(ext)s"), url,
    ]
    result = subprocess.run(command, text=True, capture_output=True)
    captions = sorted(output_dir.glob("*.json3"))
    metadata = sorted(output_dir.glob("*.info.json"))
    if result.returncode != 0 or not captions or not metadata:
        detail = (result.stderr or result.stdout).strip().splitlines()
        raise RuntimeError(detail[-1] if detail else "no matching captions were downloaded")
    return captions[0], metadata[0]


def parse_events(data: dict[str, Any]) -> list[dict[str, Any]]:
    segments: list[dict[str, Any]] = []
    for event in data.get("events", []):
        text = clean_text("".join(piece.get("utf8", "") for piece in event.get("segs") or []))
        if text:
            segments.append({
                "start": float(event.get("tStartMs", 0)) / 1000.0,
                "duration": float(event.get("dDurationMs", 0)) / 1000.0,
                "text": text,
            })
    return segments


def make_chunks(segments: list[dict[str, Any]], limit: int, overlap: int) -> list[list[dict[str, Any]]]:
    chunks: list[list[dict[str, Any]]] = []
    start = 0
    while start < len(segments):
        end = start
        used = 0
        while end < len(segments):
            size = len(segments[end]["text"]) + 16
            if end > start and used + size > limit:
                break
            used += size
            end += 1
        chunks.append(segments[start:end])
        if end >= len(segments):
            break
        rewind = 0
        next_start = end
        while next_start > start + 1 and rewind < overlap:
            next_start -= 1
            rewind += len(segments[next_start]["text"]) + 16
        start = next_start
    return chunks


def compact_metadata(info: dict[str, Any], language: str) -> dict[str, Any]:
    keys = [
        "id", "title", "description", "channel", "channel_id", "uploader",
        "upload_date", "timestamp", "duration", "webpage_url", "original_url",
        "view_count", "like_count", "categories", "tags",
    ]
    result = {key: info.get(key) for key in keys if info.get(key) is not None}
    result["caption_language"] = language
    result["caption_source"] = "YouTube subtitles/automatic captions via yt-dlp"
    return result


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url")
    parser.add_argument("--language", default="en-orig")
    parser.add_argument("--chunk-chars", type=int, default=24000)
    parser.add_argument("--overlap-chars", type=int, default=1500)
    hermes_home = Path(os.environ.get("HERMES_HOME", Path.home() / ".hermes"))
    parser.add_argument("--root", type=Path, default=hermes_home / "youtube-library")
    args = parser.parse_args()

    if shutil.which("yt-dlp") is None:
        print("error: yt-dlp is not installed", file=sys.stderr)
        return 2
    if args.chunk_chars < 2000 or not 0 <= args.overlap_chars < args.chunk_chars:
        print("error: require chunk-chars >= 2000 and 0 <= overlap < chunk size", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory(prefix="hermes-youtube-") as temporary:
        temp = Path(temporary)
        attempts = list(dict.fromkeys([args.language, "en-orig", "en"])); last_error = None
        for language in attempts:
            for child in temp.iterdir():
                child.unlink()
            try:
                caption_path, info_path = run_yt_dlp(args.url, language, temp)
                break
            except RuntimeError as error:
                last_error = error
        else:
            print(f"error: no usable captions found ({last_error})", file=sys.stderr)
            return 1

        caption_data = json.loads(caption_path.read_text(encoding="utf-8"))
        info = json.loads(info_path.read_text(encoding="utf-8"))
        segments = parse_events(caption_data)
        if not segments:
            print("error: downloaded captions contained no text", file=sys.stderr)
            return 1

        video_id = str(info.get("id") or "unknown")
        final_dir = args.root.expanduser() / video_id
        staging = final_dir.with_name(final_dir.name + ".staging")
        if staging.exists():
            shutil.rmtree(staging)
        (staging / "chunks").mkdir(parents=True)

        metadata = compact_metadata(info, language)
        write_json(staging / "metadata.json", metadata)
        shutil.copy2(caption_path, staging / "captions.json3")
        plain_text = " ".join(segment["text"] for segment in segments)
        timestamped_lines = [f"[{timestamp(segment['start'])}] {segment['text']}" for segment in segments]
        (staging / "transcript.txt").write_text(plain_text + "\n", encoding="utf-8")
        (staging / "transcript.timestamped.txt").write_text("\n".join(timestamped_lines) + "\n", encoding="utf-8")

        chunk_records = []
        for number, chunk in enumerate(make_chunks(segments, args.chunk_chars, args.overlap_chars), 1):
            filename = f"chunks/{number:04d}.txt"
            start_seconds = chunk[0]["start"]
            end_seconds = chunk[-1]["start"] + chunk[-1]["duration"]
            header = (
                f"Title: {metadata.get('title', video_id)}\nVideo: {video_id}\n"
                f"Range: {timestamp(start_seconds)}-{timestamp(end_seconds)}\n\n"
            )
            body = "\n".join(f"[{timestamp(item['start'])}] {item['text']}" for item in chunk)
            (staging / filename).write_text(header + body + "\n", encoding="utf-8")
            chunk_records.append({
                "file": filename, "start": start_seconds, "end": end_seconds,
                "start_timestamp": timestamp(start_seconds), "end_timestamp": timestamp(end_seconds),
                "characters": len(body),
            })

        duration = segments[-1]["start"] + segments[-1]["duration"]
        manifest = {
            "video_id": video_id, "title": metadata.get("title"),
            "channel": metadata.get("channel") or metadata.get("uploader"),
            "source_url": metadata.get("webpage_url") or args.url,
            "caption_language": language, "caption_source": metadata["caption_source"],
            "duration_seconds": duration, "duration": timestamp(duration),
            "segment_count": len(segments), "transcript_characters": len(plain_text),
            "estimated_tokens": math.ceil(len(plain_text) / 4),
            "chunk_characters": args.chunk_chars, "overlap_characters": args.overlap_chars,
            "chunk_count": len(chunk_records), "chunks": chunk_records,
        }
        write_json(staging / "manifest.json", manifest)
        final_dir.parent.mkdir(parents=True, exist_ok=True)
        if final_dir.exists():
            shutil.rmtree(final_dir)
        os.replace(staging, final_dir)

    print(json.dumps({"corpus": str(final_dir), **manifest}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
