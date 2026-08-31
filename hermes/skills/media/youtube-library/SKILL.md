---
name: youtube-library
description: Summarize YouTube videos with grounded follow-up chat.
version: 0.1.0
author: Andy (abl030), Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [YouTube, Video, Transcripts, Summarization]
    related_skills: []
---

# YouTube Library Skill

Ingest a video's captions into a durable, chunked local corpus, then produce a cited summary and answer follow-up questions from saved evidence. Prefer `yt-dlp` captions; do not download video or audio unless captions are unavailable and the user approves transcription.

## When to Use

- A user shares a YouTube URL and asks for a summary, chapters, claims, quotes, or discussion.
- A user asks follow-up questions about a previously ingested video.
- A transcript may be too large to place in one model context.

Don't use for visual analysis when the answer depends on slides, demonstrations, or on-screen text absent from captions; obtain frames or the video for that separate task.

## Prerequisites

- `yt-dlp` must be available. Prefer its current git tip when maintaining the installation.
- The ingestion helper uses only Python's standard library.

## How to Run

Use `terminal` to ingest captions without downloading media:

    python3 SKILL_DIR/scripts/ingest_video.py "YOUTUBE_URL"

Optional controls:

    python3 SKILL_DIR/scripts/ingest_video.py "URL" --language en-orig --chunk-chars 24000 --overlap-chars 1500

The helper writes a corpus under `$HERMES_HOME/youtube-library/<video-id>/` (falling back to `~/.hermes`) containing:

- `manifest.json`: title, source, duration, transcript size, chunk list, and rough token estimate.
- `metadata.json`: compact video metadata.
- `transcript.txt`: clean untimestamped text.
- `transcript.timestamped.txt`: evidence lines with timestamps.
- `captions.json3`: raw downloaded captions.
- `chunks/*.txt`: bounded timestamped transcript slices with overlap.

## Procedure

1. Ingest: run `scripts/ingest_video.py` and require a zero exit status plus a printed corpus path.
2. Size the task: read `manifest.json`. Never paste a long raw transcript into the conversation. For small corpora, read chunks sequentially; if `estimated_tokens` exceeds 60,000, use `delegate_task` to map independent chunk groups into compact timestamped notes, then synthesize only those notes in the parent context.
3. Ground each chunk: capture topic, material claims, evidence or examples, named people or organizations, caveats, and timestamp ranges. Treat automatic captions as fallible, especially names, numbers, and technical terms.
4. Synthesize: write `notes.md` in the corpus with source metadata, concise synopsis, timestamped chapters, key claims and evidence, important terms and names, uncertainties, and a topic-to-chunk index. Every chunk must be accounted for.
5. Answer the initial request: default to a concise synopsis, chapter outline, and key takeaways. Distinguish what speakers claim from independently established fact. Cite timestamps as `https://youtu.be/<video-id>?t=<seconds>` when useful.
6. Support follow-up chat: read `notes.md` first. Search `chunks/` with `search_files` for relevant names or terms, then read only matching chunks. If keyword search is weak, use the topic-to-chunk index. State when an answer is not supported by the captions.

## Context Strategy

- Chunking protects the parent context; it does not require lossy truncation.
- Keep raw captions on disk and compact notes in context.
- Overlap prevents sentence loss at chunk boundaries; deduplicate overlap during synthesis.
- Do not claim a whole-video summary after reading only selected chunks. Cover every chunk directly or through a delegated map summary.
- A 272k-token context is not a target. Reserve most of it for reasoning and follow-up rather than loading evidence that can be retrieved from disk.

## Pitfalls

- Prefer creator subtitles, then original-language automatic captions. Translated automatic captions are weaker evidence.
- Caption timestamps can drift, automatic captions can merge speakers, and names or numbers may be wrong.
- A transcript cannot establish visual details that were never spoken.
- If captions are disabled or absent, report that clearly. Ask before downloading audio for speech-to-text because it is a materially heavier operation.
- Do not silently treat a speaker's prediction, marketing statement, or causal claim as verified fact.

## Verification

- `manifest.json` reports nonzero segments, characters, duration, and chunks.
- Every listed chunk exists and the first/last timestamp ranges cover the transcript.
- `notes.md` accounts for every chunk exactly once, ignoring overlap.
- Summary timestamps resolve within the video's duration.
- Follow-up answers cite retrieved evidence or explicitly say the captions do not support an answer.
