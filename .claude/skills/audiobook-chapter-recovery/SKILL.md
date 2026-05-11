---
name: audiobook-chapter-recovery
description: Recover audiobook chapter titles and boundaries when source files lost them but you have a matching ebook, TOC, or Whisper transcript. Use this for "fix audiobook chapters", "recover chapter names", "match transcript to ebook", or similar ABS chapter-repair work, especially when pause-based methods fail.
version: 1.0.0
---

# Audiobook Chapter Recovery Skill

Use this when an audiobook needs chapter repair and the normal easy paths are not enough.

## Pick the least painful path first

1. If the file already has the right chapter boundaries, do a rename-only pass.
2. If Audnexus or a retailer has exact chapter times, import those.
3. If pause + short ASR clips clearly find spoken `Chapter ...` starts, use the ABS rebuild helper.
4. If you have a good full transcript plus a matching ebook or text, use the transcript + ebook path below.

The fourth path is the point of this skill. It is often the easiest path for acted or lightly adapted audiobooks where silence detection gets clever and wrong.

## Transcript + ebook path

1. Prove the edition match on one book before scaling:
   - intro, title, and narrator match
   - chapter 1 prose matches the transcript
   - at least one later chapter also matches
2. Unpack the book text:
   - `.mobi`: `nix shell nixpkgs#python313Packages.mobi --command mobiunpack <book.mobi> <outdir>`
   - `.epub`: unzip it or use an ebook tool to get the XHTML/HTML
3. Extract:
   - TOC chapter titles (often `.ncx` `<navLabel>` or `<p class="ct">` blocks — multi-line titles need to be joined)
   - chapter opening paragraphs
4. Generate a **timestamped transcript** if one doesn't already exist.
   - You need JSON (or SRT/VTT) — plain `.txt` has no timestamps and is useless for boundary placement.
   - Always check first: does the book dir already have a `.json` alongside the `.m4b`?
   - If not, run the transcribe command below before going further.
5. Flatten the transcript JSON into readable timestamped lines.
   - Do not try to "read JSON".
   - Use the JSON for timestamps, but read it as plain transcript text.
6. Read the transcript like a person and place chapter starts at topic or scene turns.
   - Use the TOC as the label source.
   - Do not insist that the first sentence of a chapter matches exactly.
   - Prefer the spoken chapter title (a short segment containing just the title) over the first prose sentence when present — that's the natural skip-to-chapter point.
7. If the adaptation rewrites or compresses the chapter opening:
   - find the nearest unmistakable passage inside that chapter
   - backtrack to the first clean narrative or scene turn that clearly belongs to it
   - prefer a slightly early boundary over a late one
8. If the audio is abridged, expect front matter (Author's Note, Acknowledgments, Preface) and back matter (Appendix, Suggested Reading) to be missing — confirm by string-searching the transcript for distinctive phrases (named people, "appendix", "preface") before assigning chapters for them.
9. Do one book first.
   - If that works, then codify the report format or helper changes for the rest of the series.

## Generating a timestamped transcript

`whisper-ctranslate2` is the standard tool here. Two non-obvious gotchas, both verified live (2026-05-11):

- **`--output_format` takes a single value**, not a repeated flag. `--output_format json --output_format txt` keeps only `txt` and silently drops the JSON. Either omit it (defaults to `all`, writes every format) or pass `all` / `json` exactly once.
- **Decode m4b → wav before passing whisper a slice**. `ffmpeg -c copy` from an m4b container with `mp4a` codec into a raw `.m4a` fails with `Tag mp4a incompatible with output codec id`. For full-book transcribes feed the m4b directly; for short test slices re-encode with `-ac 1 -ar 16000 -c:a pcm_s16le`.

Working command (full book):

```bash
nix shell nixpkgs#whisper-ctranslate2 --command \
  whisper-ctranslate2 \
    --model tiny.en --device cpu --threads "$(nproc)" \
    --language en --task transcribe \
    --output_dir <outdir> \
    --output_format all \
    "<book.m4b>"
```

Mirror the resulting `.json` (and `.txt`) back into the audiobook directory next to the `.m4b` so it persists if `/tmp` is wiped — re-transcribing a 5h+ audiobook because the JSON got lost is the avoidable pain that motivated this section.

Model picks:
- `tiny.en` — fast, fine for boundary placement (≈3-4 min per audio-hour on a modern multi-core CPU)
- `small.en` — better text fidelity, ~3-4x slower, only worth it if you need clean prose for matching adaptations
- `base.en` / `medium.en` — usually unnecessary for chapter recovery

## ABS handoff

Write recovered chapters into a report JSON compatible with `scripts/audiobook-chapter-rebuild.py`, then apply with:

```bash
python scripts/audiobook-chapter-rebuild.py \
  --manifest <manifest.json> \
  --books <n> \
  --output-dir <report-dir> \
  --reuse-reports \
  --apply
```

If you do not use the helper, post the same chapter data to ABS directly and then re-embed metadata.

Always verify both:

- ABS item chapter titles
- on-disk chapter tags with `ffprobe`

## Practical rules

- `job.log` is easier for humans; transcript JSON is better for machine timestamps.
- Exact opener matching is often too brittle on children's audio and acted performances.
- If a full transcript and matching ebook exist, this path is usually better than silence detection.
- Do not over-automate before one book is proven end to end.
- Plain `.txt` transcripts are a trap — without timestamps they're useless for chapter boundary work. Always confirm you have JSON/SRT/VTT before trusting that a book has been "transcribed."
- Mismatches between transcript phrasing and ebook openers (e.g. "Everybody"/"Everyone", "fifteen-year-old"/"fifteen year old", "I-messages"/"eye messages") are routine with `tiny.en` — search on the most distinctive 3-5 words rather than the full sentence.
