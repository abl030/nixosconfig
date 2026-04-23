#!/usr/bin/env python3
"""
Detect suspicious audiobook timeline corruption, silence spans, and duration drift.

This script can catch two different failure modes:
- real decoded silence in the audio payload
- bogus packet timestamps / container duration drift that make a file appear
  much longer than the audio it actually contains
"""

from __future__ import annotations

import argparse
import json
import math
import os
import struct
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


AUDIO_SUFFIXES = {".m4b", ".m4a", ".mp3", ".aac", ".flac", ".ogg", ".opus", ".wav"}


@dataclass
class SilenceRun:
    start_s: float
    end_s: float
    duration_s: float


def format_hms(seconds: float) -> str:
    total = int(round(seconds))
    hours, rem = divmod(total, 3600)
    minutes, secs = divmod(rem, 60)
    return f"{hours:02d}:{minutes:02d}:{secs:02d}"


def ffprobe_duration(path: Path) -> float | None:
    proc = subprocess.run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=nw=1:nk=1",
            str(path),
        ],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return None
    value = proc.stdout.strip()
    if not value:
        return None
    try:
        return float(value)
    except ValueError:
        return None


def scan_packet_timeline(path: Path, min_gap_s: float) -> dict:
    proc = subprocess.Popen(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "a:0",
            "-show_packets",
            "-show_entries",
            "packet=pts_time,duration_time",
            "-of",
            "csv=p=0",
            str(path),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    timestamp_gaps: list[SilenceRun] = []
    packet_count = 0
    packet_audio_duration_s = 0.0
    prev_end: float | None = None
    timeline_end_s = 0.0

    assert proc.stdout is not None
    for raw_line in proc.stdout:
        line = raw_line.strip()
        if not line:
            continue

        parts = line.split(",")
        if len(parts) < 2 or not parts[0] or not parts[1]:
            continue

        try:
            pts_s = float(parts[0])
            duration_s = float(parts[1])
        except ValueError:
            continue

        if prev_end is not None:
            gap_s = pts_s - prev_end
            if gap_s >= min_gap_s:
                timestamp_gaps.append(
                    SilenceRun(
                        start_s=prev_end,
                        end_s=pts_s,
                        duration_s=gap_s,
                    )
                )

        packet_audio_duration_s += duration_s
        prev_end = pts_s + duration_s
        timeline_end_s = prev_end
        packet_count += 1

    stderr = proc.stderr.read() if proc.stderr else ""
    rc = proc.wait()
    if rc != 0:
        raise RuntimeError(f"ffprobe packet scan failed for {path}: {stderr.strip()}")

    return {
        "packet_count": packet_count,
        "packet_audio_duration_s": packet_audio_duration_s,
        "packet_audio_duration_hms": format_hms(packet_audio_duration_s),
        "timeline_end_s": timeline_end_s,
        "timeline_end_hms": format_hms(timeline_end_s),
        "timestamp_gap_runs": [
            {
                "start_s": run.start_s,
                "start_hms": format_hms(run.start_s),
                "end_s": run.end_s,
                "end_hms": format_hms(run.end_s),
                "duration_s": run.duration_s,
                "duration_hms": format_hms(run.duration_s),
            }
            for run in timestamp_gaps
        ],
        "timestamp_gap_total_s": sum(run.duration_s for run in timestamp_gaps),
        "timestamp_gap_total_hms": format_hms(sum(run.duration_s for run in timestamp_gaps)),
    }


def iter_audio_files(paths: list[Path], recursive: bool) -> list[Path]:
    files: list[Path] = []
    for path in paths:
        if path.is_file() and path.suffix.lower() in AUDIO_SUFFIXES:
            files.append(path)
            continue
        if not path.is_dir():
            continue
        walker = path.rglob("*") if recursive else path.glob("*")
        for entry in walker:
            if entry.is_file() and entry.suffix.lower() in AUDIO_SUFFIXES:
                files.append(entry)
    return sorted(files)


def scan_file(
    path: Path,
    sample_rate: int,
    threshold_dbfs: float,
    min_silence_s: float,
    min_timestamp_gap_s: float,
    max_duration_drift_s: float,
    skip_rms: bool,
) -> dict:
    header_duration_s = ffprobe_duration(path)
    packet_info = scan_packet_timeline(path=path, min_gap_s=min_timestamp_gap_s)

    decoded_duration_s = None
    duration_drift_s = None
    silence_runs: list[SilenceRun] = []
    total_windows = 0

    if not skip_rms:
        decoded_duration_s, silence_runs, total_windows = scan_decoded_audio(
            path=path,
            sample_rate=sample_rate,
            threshold_dbfs=threshold_dbfs,
            min_silence_s=min_silence_s,
        )
        if header_duration_s is not None:
            duration_drift_s = header_duration_s - decoded_duration_s

    packet_duration_drift_s = None
    if header_duration_s is not None:
        packet_duration_drift_s = header_duration_s - packet_info["packet_audio_duration_s"]

    suspicious = bool(
        silence_runs
        or packet_info["timestamp_gap_runs"]
        or (
            duration_drift_s is not None
            and abs(duration_drift_s) >= max_duration_drift_s
        )
        or (
            packet_duration_drift_s is not None
            and abs(packet_duration_drift_s) >= max_duration_drift_s
        )
    )

    return {
        "path": str(path),
        "decoded_duration_s": decoded_duration_s,
        "decoded_duration_hms": format_hms(decoded_duration_s) if decoded_duration_s is not None else None,
        "header_duration_s": header_duration_s,
        "header_duration_hms": format_hms(header_duration_s) if header_duration_s is not None else None,
        "duration_drift_s": duration_drift_s,
        "duration_drift_hms": format_hms(abs(duration_drift_s)) if duration_drift_s is not None else None,
        "packet_audio_duration_s": packet_info["packet_audio_duration_s"],
        "packet_audio_duration_hms": packet_info["packet_audio_duration_hms"],
        "timeline_end_s": packet_info["timeline_end_s"],
        "timeline_end_hms": packet_info["timeline_end_hms"],
        "packet_duration_drift_s": packet_duration_drift_s,
        "packet_duration_drift_hms": (
            format_hms(abs(packet_duration_drift_s))
            if packet_duration_drift_s is not None
            else None
        ),
        "timestamp_gap_runs": packet_info["timestamp_gap_runs"],
        "timestamp_gap_total_s": packet_info["timestamp_gap_total_s"],
        "timestamp_gap_total_hms": packet_info["timestamp_gap_total_hms"],
        "silence_runs": [
            {
                "start_s": run.start_s,
                "start_hms": format_hms(run.start_s),
                "end_s": run.end_s,
                "end_hms": format_hms(run.end_s),
                "duration_s": run.duration_s,
                "duration_hms": format_hms(run.duration_s),
            }
            for run in silence_runs
        ],
        "suspicious": suspicious,
        "windows_scanned": total_windows,
        "packet_count": packet_info["packet_count"],
    }


def scan_decoded_audio(path: Path, sample_rate: int, threshold_dbfs: float, min_silence_s: float) -> tuple[float, list[SilenceRun], int]:
    samples_per_window = sample_rate
    bytes_per_window = samples_per_window * 2  # mono s16le

    proc = subprocess.Popen(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(path),
            "-map",
            "0:a:0",
            "-ac",
            "1",
            "-ar",
            str(sample_rate),
            "-f",
            "s16le",
            "-",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    silence_runs: list[SilenceRun] = []
    current_silence_start: float | None = None
    current_time = 0.0
    total_windows = 0

    assert proc.stdout is not None
    while True:
        chunk = proc.stdout.read(bytes_per_window)
        if not chunk:
            break

        sample_count = len(chunk) // 2
        if sample_count == 0:
            break

        samples = struct.unpack(f"<{sample_count}h", chunk[: sample_count * 2])
        energy = sum(sample * sample for sample in samples) / sample_count
        rms = math.sqrt(energy) / 32768.0
        dbfs = -120.0 if rms == 0 else 20 * math.log10(rms)

        window_s = sample_count / sample_rate
        if dbfs <= threshold_dbfs:
            if current_silence_start is None:
                current_silence_start = current_time
        elif current_silence_start is not None:
            duration_s = current_time - current_silence_start
            if duration_s >= min_silence_s:
                silence_runs.append(
                    SilenceRun(
                        start_s=current_silence_start,
                        end_s=current_time,
                        duration_s=duration_s,
                    )
                )
            current_silence_start = None

        current_time += window_s
        total_windows += 1

    if current_silence_start is not None:
        duration_s = current_time - current_silence_start
        if duration_s >= min_silence_s:
            silence_runs.append(
                SilenceRun(
                    start_s=current_silence_start,
                    end_s=current_time,
                    duration_s=duration_s,
                )
            )

    stderr = proc.stderr.read().decode("utf-8", "replace") if proc.stderr else ""
    rc = proc.wait()
    if rc != 0:
        raise RuntimeError(f"ffmpeg failed for {path}: {stderr.strip()}")

    return current_time, silence_runs, total_windows


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="+", help="Audio files or directories to scan")
    parser.add_argument("--recursive", action="store_true", help="Recurse into directories")
    parser.add_argument("--sample-rate", type=int, default=8000, help="Downsample rate for scan (default: 8000)")
    parser.add_argument(
        "--threshold-dbfs",
        type=float,
        default=-52.0,
        help="Treat windows at or below this RMS dBFS as silence (default: -52)",
    )
    parser.add_argument(
        "--min-silence",
        type=float,
        default=300.0,
        help="Minimum contiguous silence in seconds to report (default: 300)",
    )
    parser.add_argument(
        "--min-timestamp-gap",
        type=float,
        default=60.0,
        help="Minimum packet timeline gap in seconds to report (default: 60)",
    )
    parser.add_argument(
        "--max-duration-drift",
        type=float,
        default=120.0,
        help="Flag files whose header/playable duration drift is at least this many seconds (default: 120)",
    )
    parser.add_argument(
        "--skip-rms",
        action="store_true",
        help="Skip decoded-audio RMS scan and only inspect packet timeline / duration drift",
    )
    parser.add_argument(
        "--only-suspicious",
        action="store_true",
        help="Only print or emit files flagged as suspicious",
    )
    parser.add_argument("--json", action="store_true", help="Emit JSON instead of plain text")
    args = parser.parse_args()

    targets = iter_audio_files([Path(p) for p in args.paths], recursive=args.recursive)
    if not targets:
        print("No audio files found", file=sys.stderr)
        return 1

    results = [
        scan_file(
            path=target,
            sample_rate=args.sample_rate,
            threshold_dbfs=args.threshold_dbfs,
            min_silence_s=args.min_silence,
            min_timestamp_gap_s=args.min_timestamp_gap,
            max_duration_drift_s=args.max_duration_drift,
            skip_rms=args.skip_rms,
        )
        for target in targets
    ]

    if args.only_suspicious:
        results = [result for result in results if result["suspicious"]]

    if args.json:
        json.dump(results, sys.stdout, indent=2)
        print()
        return 0

    for result in results:
        print(result["path"])
        if result["decoded_duration_hms"] is not None:
            print(f"  decoded: {result['decoded_duration_hms']}")
        if result["header_duration_hms"] is not None:
            drift = result["duration_drift_s"]
            drift_text = (
                f"+{result['duration_drift_hms']}"
                if drift is not None and drift >= 0
                else f"-{result['duration_drift_hms']}"
            )
            if result["decoded_duration_hms"] is not None:
                print(f"  header : {result['header_duration_hms']} (decoded drift {drift_text})")
            else:
                print(f"  header : {result['header_duration_hms']}")
        if result["packet_audio_duration_hms"] is not None:
            packet_drift = result["packet_duration_drift_s"]
            if packet_drift is not None:
                packet_drift_text = (
                    f"+{result['packet_duration_drift_hms']}"
                    if packet_drift >= 0
                    else f"-{result['packet_duration_drift_hms']}"
                )
                print(
                    "  packet :"
                    f" {result['packet_audio_duration_hms']}"
                    f" (header drift {packet_drift_text}, timeline end {result['timeline_end_hms']})"
                )
            else:
                print(
                    "  packet :"
                    f" {result['packet_audio_duration_hms']}"
                    f" (timeline end {result['timeline_end_hms']})"
                )
        if result["timestamp_gap_runs"]:
            for run in result["timestamp_gap_runs"]:
                print(
                    "  gap    :"
                    f" {run['start_hms']} -> {run['end_hms']}"
                    f" ({run['duration_hms']})"
                )
        else:
            print("  gap    : none above threshold")
        if result["silence_runs"]:
            for run in result["silence_runs"]:
                print(
                    "  silence:"
                    f" {run['start_hms']} -> {run['end_hms']}"
                    f" ({run['duration_hms']})"
                )
        else:
            print("  silence: none above threshold")
        print()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
