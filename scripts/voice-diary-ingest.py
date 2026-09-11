#!/usr/bin/env python3
"""Ingest phone voice recordings into a dated inbox with transcripts.

Scans a drop directory (populated by Syncthing from the phone), transcribes
each new recording via the self-hosted whisper endpoint, and writes a
date-prefixed audio + transcript pair into an inbox directory.

Design notes — see docs/wiki/services/voice-diary.md:

* The drop directory is a Syncthing **receive-only** folder. This script must
  NEVER delete or modify anything in it: a delete here would propagate back and
  destroy the recordings on the phone. Files are copied out, never moved.
* Idempotency is by output existence, not a state database. If the target .md
  already exists the source is skipped, so a re-run after a crash is safe and
  the timer can fire as often as it likes.
* Names come from the recording's mtime, so they sort chronologically and are
  stable across re-runs. The phone's own filenames ("My recording 4.m4a") are
  useless for ordering.
* Everything is written to a temp file and renamed into place, so a partially
  written transcript is never visible to the next run (which would then skip it).

Environment:
  VOICE_DIARY_DROP_DIR    directory Syncthing writes into (read-only to us)
  VOICE_DIARY_INBOX_DIR   directory to write <stamp>.<ext> + <stamp>.md into
  VOICE_DIARY_WHISPER_URL  full transcription endpoint URL
  VOICE_DIARY_MODEL       whisper model alias (default "large")
  VOICE_DIARY_TIMEOUT     per-request timeout in seconds (default 3600)
  VOICE_DIARY_MIN_AGE     skip files modified within this many seconds
                          (default 60) so a still-syncing file is left alone
"""

from __future__ import annotations

import json
import mimetypes
import os
import re
import shutil
import sys
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path

AUDIO_SUFFIXES = {".m4a", ".mp3", ".wav", ".ogg", ".opus", ".aac", ".flac", ".mp4"}

DROP_DIR = Path(os.environ["VOICE_DIARY_DROP_DIR"])
INBOX_DIR = Path(os.environ["VOICE_DIARY_INBOX_DIR"])
WHISPER_URL = os.environ["VOICE_DIARY_WHISPER_URL"]
MODEL = os.environ.get("VOICE_DIARY_MODEL", "large")
# Sent per-request rather than set as a whisper-server flag on purpose: the
# same endpoint serves the Dictate phone keyboard, and a diary-specific
# vocabulary should not bias that. Verified honoured by the server — adding it
# corrected "Vania" to "Vanya" on a real recording. It does NOT fix every name
# (see NAME_FIXES), so treat it as a nudge, not a guarantee.
PROMPT = os.environ.get("VOICE_DIARY_PROMPT", "").strip()
TIMEOUT = int(os.environ.get("VOICE_DIARY_TIMEOUT", "3600"))
MIN_AGE = int(os.environ.get("VOICE_DIARY_MIN_AGE", "60"))

# Loop/stutter de-duplication window. whisper can repeat a segment several
# times when a decode degenerates; VAD on the server side prevents most of it,
# this is the belt-and-braces pass. See the wiki page for the measured
# before/after.
DEDUPE_WINDOW = 12

# Paragraphs are grouped by WORD COUNT, not sentence count. Grouping by
# sentences looks fine until the speaker is hesitant: false starts ("so I think
# where I finished was, I was just, yeah, that's right") become many very short
# sentences, and a fixed 5-per-paragraph then yields stubby, staccato
# paragraphs. Measured on two real recordings: a fluent one averaged 55 words
# per paragraph, a hesitant one only 39, from the same rule. Word-count
# grouping keeps the page even regardless of speaking style.
WORDS_PER_PARAGRAPH = 70

# Names whisper cannot get right from audio alone. Prompt seeding helps some
# (it fixed Vania -> Vanya) but cannot reach others: "Gerlinde" is acoustically
# closer to "Galinda"/"Glinda" and the model returns those however it is
# primed. For a small, fixed cast of family and colleagues a substitution is
# simply more reliable than coaxing the decoder. Keys are matched
# case-insensitively on whole words only.
NAME_FIXES = {
    r"Ga?linda|Gelinda|Gerlinda": "Gerlinde",
    r"Dak(?:y|ie|ey)|Dacky|Dackie": "Dacre",
    r"Vania|Vanja": "Vanya",
}


def log(msg: str) -> None:
    print(msg, flush=True)


def local_dt(ts: float) -> datetime:
    """Epoch -> LOCAL wall-clock time, explicitly.

    Filenames and the entry header must match the day the user actually
    recorded on. A late-evening Perth recording is the *previous* day in UTC,
    which would file it under the wrong diary date — so local time is the
    correct behaviour here, not an oversight.
    """
    return datetime.fromtimestamp(ts, tz=timezone.utc).astimezone()


def norm(s: str) -> str:
    return re.sub(r"[^a-z0-9 ]", "", s.lower()).strip()


def is_echo(n: str, recent: list[str]) -> bool:
    """True if n repeats something recent, exactly or as a reworded stutter."""
    for r in recent:
        if not r or not n:
            continue
        if n == r:
            return True
        shorter, longer = (n, r) if len(n) <= len(r) else (r, n)
        if len(shorter) >= 12 and shorter in longer:
            return True
    return False


def tidy(raw: str) -> str:
    """Whisper emits one short line per speech segment. Turn that into prose."""
    lines = [line.strip() for line in raw.splitlines() if line.strip()]

    kept: list[str] = []
    recent: list[str] = []
    for line in lines:
        n = norm(line)
        if n and is_echo(n, recent):
            continue
        kept.append(line)
        recent.append(n)
        recent = recent[-DEDUPE_WINDOW:]

    text = re.sub(r"\s+", " ", " ".join(kept)).strip()

    # whisper occasionally emits a stray space before punctuation or a
    # contraction ("friendships ." / "she 's bought it"), an artefact of how
    # segments are joined. Cosmetic, but it is the kind of thing that makes a
    # transcript read as machine output.
    text = re.sub(r"\s+([,.!?;:])", r"\1", text)
    text = re.sub(r"\s+('(?:s|t|re|ve|ll|d|m)\b)", r"\1", text, flags=re.IGNORECASE)
    # "do n't" splits before the n, so the rule above misses it.
    text = re.sub(r"\s+(n't\b)", r"\1", text, flags=re.IGNORECASE)

    text = fix_names(text)

    # Group whole sentences until the paragraph reaches WORDS_PER_PARAGRAPH, so
    # paragraph length tracks content rather than the speaker's fluency.
    sentences = [s.strip() for s in re.split(r"(?<=[.!?])\s+", text) if s.strip()]
    paras: list[str] = []
    cur: list[str] = []
    cur_words = 0
    for s in sentences:
        cur.append(s)
        cur_words += len(s.split())
        if cur_words >= WORDS_PER_PARAGRAPH:
            paras.append(" ".join(cur))
            cur, cur_words = [], 0
    if cur:
        paras.append(" ".join(cur))

    # The remainder can leave a stranded one-liner ("See you later.") as its own
    # paragraph. Fold a short tail back into the paragraph above it.
    if len(paras) > 1 and len(paras[-1].split()) < 25:
        paras[-2] = f"{paras[-2]} {paras.pop()}"

    return "\n\n".join(paras)


def fix_names(text: str) -> str:
    """Apply the fixed-cast name corrections (see NAME_FIXES)."""
    for pattern, correct in NAME_FIXES.items():
        text = re.sub(rf"\b(?:{pattern})\b", correct, text, flags=re.IGNORECASE)
    return text


def transcribe(path: Path) -> str:
    """POST the audio as multipart/form-data and return the raw transcript."""
    boundary = f"----voicediary{uuid.uuid4().hex}"
    ctype = mimetypes.guess_type(path.name)[0] or "application/octet-stream"

    fields = [("model", MODEL), ("response_format", "json")]
    if PROMPT:
        fields.append(("prompt", PROMPT))

    head = []
    for field, value in fields:
        head.append(
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="{field}"\r\n\r\n'
            f"{value}\r\n"
        )
    head.append(
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{path.name}"\r\n'
        f"Content-Type: {ctype}\r\n\r\n"
    )

    body = "".join(head).encode() + path.read_bytes() + f"\r\n--{boundary}--\r\n".encode()

    req = urllib.request.Request(
        WHISPER_URL,
        data=body,
        method="POST",
        headers={
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Content-Length": str(len(body)),
        },
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        payload = resp.read().decode("utf-8", "replace")

    # Deliberately not json.loads-ing blindly: a proxy error page would raise a
    # confusing exception. Pull .text out and fail with the body if absent.
    try:
        data = json.loads(payload)
    except ValueError:
        raise RuntimeError(f"non-JSON response: {payload[:300]}") from None
    text = (data.get("text") or "").strip()
    if not text:
        raise RuntimeError(f"empty transcript in response: {payload[:300]}")
    return text


def stamp_for(path: Path) -> str:
    return local_dt(path.stat().st_mtime).strftime("%Y-%m-%d_%H%M%S")


def process(src: Path) -> bool:
    """Returns True if a new transcript was produced."""
    stamp = stamp_for(src)
    target_md = INBOX_DIR / f"{stamp}.md"
    target_audio = INBOX_DIR / f"{stamp}{src.suffix.lower()}"

    if target_md.exists():
        return False

    age = time.time() - src.stat().st_mtime
    if age < MIN_AGE:
        log(f"skip (still settling, {int(age)}s old): {src.name}")
        return False

    size_mb = src.stat().st_size / 1024 / 1024
    log(f"transcribing {src.name} ({size_mb:.1f} MB) -> {stamp}")

    raw = transcribe(src)
    body = tidy(raw)
    words = len(body.split())

    when = local_dt(src.stat().st_mtime)
    header = (
        f"# Voice note {when:%Y-%m-%d %H:%M}\n\n"
        f"*Recorded {when:%A %-d %B %Y, %-I:%M %p}. "
        f"{words} words. Source: `{src.name}`.*\n\n"
    )

    # Write via temp + rename so a partial file is never mistaken for done.
    tmp_md = INBOX_DIR / f".{stamp}.md.partial"
    tmp_md.write_text(header + body + "\n", encoding="utf-8")

    if not target_audio.exists():
        tmp_audio = INBOX_DIR / f".{stamp}{src.suffix.lower()}.partial"
        shutil.copy2(src, tmp_audio)
        tmp_audio.rename(target_audio)

    # Rename the transcript LAST: it is the idempotency marker, so it must only
    # appear once the audio beside it is already in place.
    tmp_md.rename(target_md)

    log(f"wrote {target_md.name} ({words} words) + {target_audio.name}")
    return True


def main() -> int:
    if not DROP_DIR.is_dir():
        log(f"drop dir missing: {DROP_DIR}")
        return 1
    INBOX_DIR.mkdir(parents=True, exist_ok=True)

    sources = sorted(
        (p for p in DROP_DIR.rglob("*") if p.is_file() and p.suffix.lower() in AUDIO_SUFFIXES),
        key=lambda p: p.stat().st_mtime,
    )
    # Syncthing keeps its own metadata and trash under dotted dirs; and the
    # recorder app leaves ".evr_recently_deleted_*" tombstones behind.
    sources = [
        p
        for p in sources
        if not any(part.startswith(".") for part in p.relative_to(DROP_DIR).parts)
    ]

    if not sources:
        log("no recordings found")
        return 0

    done = 0
    failed = 0
    for src in sources:
        try:
            if process(src):
                done += 1
        except (urllib.error.URLError, RuntimeError, OSError) as e:
            # Leave the source alone so the next timer tick retries it.
            failed += 1
            log(f"FAILED {src.name}: {e}")

    log(f"done: {done} transcribed, {failed} failed, {len(sources)} seen")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
