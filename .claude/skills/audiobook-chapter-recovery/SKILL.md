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
   - TOC chapter titles
   - chapter opening paragraphs
4. Flatten the transcript JSON into readable timestamped lines.
   - Do not try to "read JSON".
   - Use the JSON for timestamps, but read it as plain transcript text.
5. Read the transcript like a person and place chapter starts at topic or scene turns.
   - Use the TOC as the label source.
   - Do not insist that the first sentence of a chapter matches exactly.
6. If the adaptation rewrites or compresses the chapter opening:
   - find the nearest unmistakable passage inside that chapter
   - backtrack to the first clean narrative or scene turn that clearly belongs to it
   - prefer a slightly early boundary over a late one
7. Do one book first.
   - If that works, then codify the report format or helper changes for the rest of the series.

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
