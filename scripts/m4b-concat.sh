#!/usr/bin/env bash
# m4b-concat.sh — Concatenate multiple m4b/m4a files into a single m4b with chapters
#
# Usage: m4b-concat.sh <input-dir> [output-file.m4b]
#
# If output-file is omitted, writes <dirname>.m4b inside the input directory.
#
# Strategy:
#   - Finds all .m4b/.m4a files in the input directory
#   - Sorts them naturally (version sort for numeric ordering)
#   - Concatenates with stream copy (no re-encode)
#   - Generates chapter markers from file boundaries, using filenames as titles
#   - Strips Audible cruft from chapter titles (ASINs, track numbers, etc.)
#
# Requirements: ffmpeg, ffprobe, bc (all in PATH or via nix shell)
#
# On NixOS:
#   nix shell nixpkgs#ffmpeg nixpkgs#bc --command bash m4b-concat.sh <dir>
#
# This does NO transcoding. Audio data is copied bit-for-bit.

set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

# --- Args ---
[[ $# -lt 1 ]] && die "Usage: $0 <input-dir> [output.m4b]"

INPUT_DIR="${1%/}"
[[ -d "$INPUT_DIR" ]] || die "Not a directory: $INPUT_DIR"

# Collect m4b/m4a files sorted naturally
mapfile -t AUDIO_FILES < <(find "$INPUT_DIR" -maxdepth 1 \( -iname '*.m4b' -o -iname '*.m4a' \) -print0 | sort -zV | tr '\0' '\n')
[[ ${#AUDIO_FILES[@]} -eq 0 ]] && die "No m4b/m4a files found in $INPUT_DIR"

# Output path
DIRNAME="$(basename "$INPUT_DIR")"
OUTPUT="${2:-${INPUT_DIR}/${DIRNAME}.m4b}"

echo "Input:  $INPUT_DIR (${#AUDIO_FILES[@]} files)"
echo "Output: $OUTPUT"

# --- Single file: just copy/rename ---
if [[ ${#AUDIO_FILES[@]} -eq 1 ]]; then
    echo "Single file — copying as m4b..."
    cp "${AUDIO_FILES[0]}" "$OUTPUT"
    echo "Done: $OUTPUT"
    exit 0
fi

# --- Temp files ---
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

CONCAT_LIST="$TMPDIR/concat.txt"
CHAPTERS_META="$TMPDIR/chapters.txt"

# --- Build concat list and chapter metadata ---
echo ";FFMETADATA1" > "$CHAPTERS_META"

CUMULATIVE_MS=0

for f in "${AUDIO_FILES[@]}"; do
    # Escape special chars for ffmpeg concat demuxer
    escaped="$(printf '%s' "$f" | sed "s/'/'\\\\''/g")"
    echo "file '$escaped'" >> "$CONCAT_LIST"

    # Get duration in milliseconds
    DURATION_S="$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$f")"
    DURATION_MS="$(echo "$DURATION_S * 1000" | bc | cut -d. -f1)"

    # Chapter title from filename
    TITLE="$(basename "$f")"
    # Strip extension
    TITLE="${TITLE%.*}"
    # Strip Audible-style prefixes: "Title꞉ Series, Book N [ASIN] - NN - "
    TITLE="$(echo "$TITLE" | sed -E 's/^.*\[[A-Z0-9]+\][[:space:]]*-[[:space:]]*[0-9]+[[:space:]]*-[[:space:]]*//')"
    # Strip generic numbered prefixes: "001 - ", "01 - ", "1 - " etc
    TITLE="$(echo "$TITLE" | sed -E 's/^[0-9]+[[:space:]]*[-_.)[[:space:]]*//')"
    # Strip "DW27 - The Last Hero - NN" style prefixes
    TITLE="$(echo "$TITLE" | sed -E 's/^DW[0-9]+[[:space:]]*-[[:space:]]*[^-]+[[:space:]]*-[[:space:]]*[0-9]+[[:space:]]*//')"
    # Strip trailing " (enhanced)" or similar tags
    TITLE="$(echo "$TITLE" | sed -E 's/[[:space:]]*\([^)]*\)[[:space:]]*$//')"
    # If title is just a number or empty, use "Part N"
    if [[ -z "$TITLE" ]] || [[ "$TITLE" =~ ^[0-9]+$ ]]; then
        # Extract the number for "Part N" naming
        NUM="$(basename "$f" | grep -oE '[0-9]+' | head -1)"
        TITLE="Part ${NUM:-$((CUMULATIVE_MS > 0 ? 2 : 1))}"
    fi
    # Strip "Opening Credits" / "End Credits" prefix numbers but keep the title
    # (these are valid chapter names, keep as-is)

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

echo "Concatenating ${#AUDIO_FILES[@]} files with chapters..."

# Concat audio only (skip cover art/video streams) + embed chapters
ffmpeg -y -f concat -safe 0 -i "$CONCAT_LIST" -i "$CHAPTERS_META" \
    -map 0:a -map_metadata 1 -c copy -f mp4 "$OUTPUT" 2>/dev/null

echo "Done: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
echo "Chapters: ${#AUDIO_FILES[@]}"
