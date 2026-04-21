#!/usr/bin/env bash
# mp3-to-m4b.sh — Convert a directory of MP3 files into a single M4B with chapters
#
# Usage: mp3-to-m4b.sh <input-dir> [output-file.m4b]
#
# If output-file is omitted, writes to <input-dir>/../<dirname>.m4b
#
# Strategy:
#   - Single MP3: remux to m4b container (no re-encode, stream copy)
#   - Multiple MP3s: concatenate in sorted order, stream copy, generate
#     chapter markers from file boundaries using each filename as chapter title
#
# Requirements: ffmpeg, ffprobe (both in PATH)
#
# This does NO lossy-to-lossy transcoding. Audio data is copied bit-for-bit.
# The only change is the container (MPEG → MP4/M4B).

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

# --- Args ---
[[ $# -lt 1 ]] && die "Usage: $0 <input-dir> [output.m4b]"

INPUT_DIR="${1%/}"
[[ -d "$INPUT_DIR" ]] || die "Not a directory: $INPUT_DIR"

# Collect MP3 files sorted naturally (handles 01_foo, 02_bar etc)
mapfile -t MP3_FILES < <(find "$INPUT_DIR" -maxdepth 1 -iname '*.mp3' -print0 | sort -z | tr '\0' '\n')
[[ ${#MP3_FILES[@]} -eq 0 ]] && die "No MP3 files found in $INPUT_DIR"

# Output path
DIRNAME="$(basename "$INPUT_DIR")"
OUTPUT="${2:-${INPUT_DIR}/${DIRNAME}.m4b}"

echo "Input:  $INPUT_DIR (${#MP3_FILES[@]} MP3 files)"
echo "Output: $OUTPUT"

# --- Temp files ---
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

CONCAT_LIST="$TMPDIR/concat.txt"
CHAPTERS_META="$TMPDIR/chapters.txt"

# --- Single file: just remux ---
if [[ ${#MP3_FILES[@]} -eq 1 ]]; then
    echo "Single file — remuxing to m4b..."
    ffmpeg -y -i "${MP3_FILES[0]}" -c copy -f mp4 "$OUTPUT" 2>/dev/null
    echo "Done: $OUTPUT"
    exit 0
fi

# --- Multiple files: build concat list and chapter metadata ---
echo ";FFMETADATA1" > "$CHAPTERS_META"

# We need to probe each file for duration to build chapter timestamps
CUMULATIVE_MS=0

for f in "${MP3_FILES[@]}"; do
    # Escape special chars for ffmpeg concat demuxer
    escaped="$(echo "$f" | sed "s/'/'\\\\''/g")"
    echo "file '$escaped'" >> "$CONCAT_LIST"

    # Get duration in milliseconds
    DURATION_S="$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$f")"
    DURATION_MS="$(echo "$DURATION_S * 1000" | bc | cut -d. -f1)"

    # Chapter title from filename (strip path, extension, leading track numbers)
    TITLE="$(basename "$f" .mp3)"
    TITLE="$(basename "$TITLE" .MP3)"
    # Strip common prefixes: "01 - ", "01_", "01. ", "Track 01 - " etc
    TITLE="$(echo "$TITLE" | sed -E 's/^[0-9]+[\s]*[-_.\)]\s*//; s/^Track\s*[0-9]+\s*[-_]\s*//i')"
    # If title ended up empty, use original filename
    [[ -z "$TITLE" ]] && TITLE="$(basename "$f" .mp3)"

    # Write chapter entry
    cat >> "$CHAPTERS_META" <<EOF

[CHAPTER]
TIMEBASE=1/1000
START=$CUMULATIVE_MS
END=$((CUMULATIVE_MS + DURATION_MS))
title=$TITLE
EOF

    CUMULATIVE_MS=$((CUMULATIVE_MS + DURATION_MS))
done

echo "Concatenating ${#MP3_FILES[@]} files with chapters..."

# Concat + embed chapters in one pass
ffmpeg -y -f concat -safe 0 -i "$CONCAT_LIST" -i "$CHAPTERS_META" \
    -map 0:a -map_metadata 1 -c copy -f mp4 "$OUTPUT" 2>/dev/null

echo "Done: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
echo "Chapters: ${#MP3_FILES[@]}"
