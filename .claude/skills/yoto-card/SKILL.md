---
name: yoto-card
description: Prepare audio + artwork for a Yoto MYO (Make Your Own) card. Use this for turning TV show seasons or music albums into Yoto-uploadable track folders. Trigger phrases include "make a yoto card", "yoto card for X", "rip audio for yoto", "turn X into a yoto", or any mention of uploading to yotoplay.
version: 1.0.0
---

# Yoto MYO Card Prep Skill

Rips source media into Yoto-compatible audio tracks, extracts per-track icon frames, and builds a portrait cover image per card. Splits content across multiple cards when it exceeds Yoto's limits.

## Yoto MYO limits (hard constraints — verify before starting)

| Constraint | Value |
|---|---|
| Supported audio | **MP3, AAC/M4A only** (NOT Opus — Yoto does not decode it) |
| Per-track | ≤ 60 min, ≤ 100 MB |
| Per-card total | ≤ 5 hours, ≤ 500 MB, ≤ 100 tracks |

If a season/album exceeds the per-card cap, split evenly across cards. **Runtime is usually the binding constraint, not size.**

## Typical source locations

- TV shows: `/mnt/data/Media/TV Shows/<Show>/Season N/` — files named `SxxExx - Title <QUALITY>.mkv`
- Music: `/mnt/data/Media/Music/<Artist>/<Album>/` — beets-managed FLAC/MP3
- Specials: `/mnt/data/Media/TV Shows/<Show>/Specials/` — filenames use `S00Exx`

## Output convention

Always write to `~/Downloads/<Name>-Yoto/`. For multi-card sets, subfolders named `<Name>-CardA`, `<Name>-CardB`, etc. (e.g. `S1-CardA`, `S1-CardB`, `S2-CardA`). Each card folder contains:

- `<Track>.m4a` — audio, AAC 128k stereo
- `<Track>.png` — source image for per-track icon (Yoto auto-pixelates to 16×16 on upload)
- `_cover.png` — portrait playlist cover (1080×1350)

## Before encoding, always

1. Probe total runtime and decide the card split.
2. Confirm source audio codec and channels — re-encode needed if source is Opus, EAC3, 5.1, or anything not AAC/MP3 stereo.
3. Ask the user to confirm split / format if anything is ambiguous. For typical kids' TV at 128k AAC stereo, a full 3h+ card lands ~180 MB — well under 500 MB.

## Encoding recipe

Works for both video (extract audio) and audio-in sources:

```bash
ffmpeg -hide_banner -loglevel error -y -i "$src" \
  -vn -map 0:a:0 -c:a aac -b:a 128k -ac 2 -ar 48000 \
  -movflags +faststart \
  "$dest/<clean-name>.m4a"
```

`-ac 2` downmixes 5.1 to stereo automatically. `-movflags +faststart` puts the moov atom at the front so Yoto's upload server can stream-read it.

**Filename cleanup:** strip trailing quality tags like ` WEBDL-720p`, ` WEBRip-1080p`, ` HDTV-720p`, ` HDTV-1080p` before using the stem as the Yoto track name. Regex: `s/ (WEB(DL|Rip)|HDTV)-(720p|1080p)$//`.

## Per-track icon (video sources only)

Extract a single frame from the midpoint of each episode — this becomes the per-track icon source. Yoto auto-pixelates to 16×16 on upload, so 320px wide is plenty.

```bash
dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$src")
mid=$(awk "BEGIN{printf \"%.2f\", $dur/2}")
ffmpeg -hide_banner -loglevel error -y -ss "$mid" -i "$src" \
  -frames:v 1 -vf "scale=320:-1" "$dest/<clean-name>.png"
```

For music sources, extract embedded album art instead:

```bash
ffmpeg -hide_banner -loglevel error -y -i "$src" -an -vcodec copy "$dest/<clean-name>.png" 2>/dev/null || \
ffmpeg -hide_banner -loglevel error -y -i "$src" -an -frames:v 1 "$dest/<clean-name>.png"
```

## Portrait cover art (1080×1350)

**Yoto card covers are portrait — not square, not landscape.** The blurred-self-background technique works for any source scene without hand-tuning colors:

```bash
# $1=dest_card_dir $2=src_video $3=seek_seconds
ffmpeg -hide_banner -loglevel error -y \
  -ss "$3" -i "$2" \
  -frames:v 1 \
  -filter_complex "[0:v]split=2[bg][fg]; \
    [bg]scale=1080:1350:force_original_aspect_ratio=increase,crop=1080:1350,boxblur=40:10,eq=brightness=0.03:saturation=0.8[bgb]; \
    [fg]scale=1080:-1[fgs]; \
    [bgb][fgs]overlay=(W-w)/2:(H-h)/2" \
  "$1/_cover.png"
```

The heavy `boxblur=40:10` is important — lighter blur leaves recognizable character shapes in the backdrop.

**Alternate (sky-strip padding):** if the source has a plain-color top and bottom (e.g. an outdoor Bluey scene with blue sky), sample top/bottom edge colors and pad with solid strips — cleaner look, but only works on clean outdoor frames:

```bash
# sample top and bottom 5x5 patches
ffmpeg -hide_banner -loglevel error -y -ss "$seek" -i "$src" -frames:v 1 -vf "crop=5:5:0:0,scale=1:1" /tmp/top.png
ffmpeg -hide_banner -loglevel error -y -ss "$seek" -i "$src" -frames:v 1 -vf "crop=5:5:0:$(($SRC_H-5)),scale=1:1" /tmp/bot.png
# read RGB, then build
ffmpeg -ss "$seek" -i "$src" \
  -f lavfi -i "color=0x<TOP_HEX>:s=1080x371" \
  -f lavfi -i "color=0x<BOT_HEX>:s=1080x372" \
  -filter_complex "[0:v]scale=1080:-1,trim=end_frame=1,setpts=PTS-STARTPTS[fg]; \
    [1:v]trim=end_frame=1[top]; [2:v]trim=end_frame=1[bot]; \
    [top][fg][bot]vstack=inputs=3" \
  -frames:v 1 "$dest/_cover.png"
```

**Pick a different scene per card** in a multi-card set so covers are visually distinct — each card's mini-icon in the Yoto app should be recognisable at a glance.

## Full pipeline script template

For a season of a TV show:

```bash
#!/usr/bin/env bash
set -euo pipefail

SRC="/mnt/data/Media/TV Shows/<Show>/Season N"
OUT="$HOME/Downloads/<Show>-Yoto"
CARDA="$OUT/S<N>-CardA"
CARDB="$OUT/S<N>-CardB"
SPLIT_AT=26  # episode number at which to switch cards

mkdir -p "$CARDA" "$CARDB"

for f in "$SRC"/S*E*.mkv; do
    base=$(basename "$f" .mkv)
    clean=$(echo "$base" | sed -E 's/ (WEB(DL|Rip)|HDTV)-(720p|1080p)$//')
    ep=$(echo "$clean" | grep -oP 'E\K[0-9]+')
    ep_num=$((10#$ep))
    dest=$([ "$ep_num" -le "$SPLIT_AT" ] && echo "$CARDA" || echo "$CARDB")

    out_audio="$dest/$clean.m4a"
    out_icon="$dest/$clean.png"
    [ -f "$out_audio" ] && [ -f "$out_icon" ] && { echo "[skip] $clean"; continue; }

    dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$f")
    mid=$(awk "BEGIN{printf \"%.2f\", $dur/2}")

    echo "  $clean -> $(basename "$dest")"

    ffmpeg -hide_banner -loglevel error -y -i "$f" \
        -vn -map 0:a:0 -c:a aac -b:a 128k -ac 2 -ar 48000 \
        -movflags +faststart "$out_audio"

    ffmpeg -hide_banner -loglevel error -y -ss "$mid" -i "$f" \
        -frames:v 1 -vf "scale=320:-1" "$out_icon"
done
```

Run it in the background with `run_in_background: true` for long batches — a full season of ~52 episodes takes ~4 min on modern hardware.

## Music-album variant

For beets-managed albums, tracks are already AAC/MP3 and correctly named. Usually you only need to:

1. Copy (if MP3 ≤128k or AAC) or re-encode (if FLAC/high-bitrate) to AAC 128k M4A.
2. Extract embedded album art as `_cover.png` — reshape to 1080×1350 portrait.
3. Use embedded art as per-track icon too (same image for every track).

```bash
# re-encode + faststart
ffmpeg -i "$src" -vn -c:a aac -b:a 128k -ac 2 "$dest/<track>.m4a"

# extract embedded cover once
ffmpeg -i "$src" -an -vcodec copy /tmp/album_cover.png
# then portrait-pad into _cover.png using the blurred-backdrop filter
```

## Verification after batch

Always validate before declaring done:

```bash
python3 -c "
import subprocess, glob, os
for card in ['<card1>','<card2>']:
    d = os.path.expanduser(f'~/Downloads/<Name>-Yoto/{card}')
    files = sorted(glob.glob(f'{d}/*.m4a'))
    total = 0; total_bytes = 0
    for f in files:
        t = subprocess.check_output(['ffprobe','-v','error','-show_entries','format=duration','-of','default=noprint_wrappers=1:nokey=1', f]).decode().strip()
        total += float(t); total_bytes += os.path.getsize(f)
    print(f'{card}: {len(files)} tracks, {total/60:.1f}min ({total/3600:.2f}h), {total_bytes/1024/1024:.1f}MB')
"
```

Fail states to catch:
- `moov atom not found` → m4a was truncated (batch still running or crashed — re-run that one file).
- Per-track duration > 60 min → exceeds Yoto per-track limit; split the episode or drop it.
- Card total > 5 h or > 500 MB → rebalance split.

## Gotchas learned

- **Do not suggest Opus.** Yoto silently rejects it. Default is AAC 128k stereo M4A.
- **Downmix 5.1 to stereo.** Many TV rips have EAC3 5.1 audio — always pass `-ac 2`.
- **Title-card frames aren't always the series title.** Mid-frame (`dur/2`) is a better default than seeking to a fixed `00:00:15`.
- **Yoto upload shows the cover as portrait** in the app library. Landscape 16:9 looks wrong — always portrait (1080×1350 is a good default; anything 4:5 or 3:4 works).
- **When checking a background batch, `ps aux | grep ffmpeg` is more reliable than tailing the log** — a finished log doesn't mean all files are flushed yet.
