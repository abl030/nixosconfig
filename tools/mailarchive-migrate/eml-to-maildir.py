#!/usr/bin/env python3
"""
MailStore EML export -> nested Maildir migration.

Walks a tree of .eml files (preserving MailStore's folder hierarchy) and
writes a nested Maildir tree where each folder level is a real
subdirectory containing its own cur/new/tmp triple. Layout matches
mbsync's `SubFolders Verbatim` mode so the migrated tree is structurally
compatible with the live `o365/` and `gmail/` trees the mailarchive
module produces.

Messages land in `cur/` with the `:2,S` (Seen) flag — historical mail is
treated as already-read so a future merge with live trees doesn't rewrite
flags upstream (mbsync runs Pull-only anyway, but this is defensive).

`--dedupe-against <maildir>` (repeatable) seeds the seen Message-ID set
from one or more *live* Maildir trees BEFORE walking the export, so any
message already present in the live archive is skipped. This is how the
MailStore work-only migration keeps `legacy.archive/` to just the deleted
history instead of a giant duplicate of still-filed mail (see issue #227
and the "MailStore migration" section of docs/wiki/services/mailarchive.md).

Usage:
    python3 eml-to-maildir.py --src <export-dir> --dst <maildir-root>
    python3 eml-to-maildir.py --src <export-dir> --dst <maildir-root> \
        --dedupe-against <live-maildir> [--dedupe-against <live-maildir> ...]

See: tools/mailarchive-migrate/README.md
     docs/wiki/services/mailarchive.md
"""

from __future__ import annotations

import argparse
import email.parser
import hashlib
import logging
import os
import secrets
import sys
import time
from pathlib import Path

log = logging.getLogger("eml-to-maildir")


def setup_logging(verbose: bool) -> None:
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(levelname)s %(message)s",
    )


def ensure_maildir(folder: Path) -> None:
    for sub in ("cur", "new", "tmp"):
        (folder / sub).mkdir(parents=True, exist_ok=True)


_BOM = b"\xef\xbb\xbf"


def strip_header_bom(eml_bytes: bytes) -> bytes:
    """Remove stray UTF-8 BOMs from the RFC822 header block.

    Thunderbird/MailStore EML exports inject a UTF-8 BOM partway through the
    header block (typically right before the first `Received:` line, after the
    X-Mozilla-* pseudo-headers). A BOM mid-headers makes Python's email parser
    — and mail readers like mutt — treat the headers as ended, hiding the real
    From/Subject/Message-ID. That breaks Message-ID-based dedup (every BOM
    message falls back to a synthetic id and never matches the clean live mail)
    and leaves an unreadable archive. The BOM is not valid inside mail headers,
    so stripping it from the header block restores a clean, parseable message.
    The body is left untouched — a body part may legitimately contain a BOM.
    See issue #227 and docs/wiki/services/mailarchive.md.
    """
    if _BOM not in eml_bytes:
        return eml_bytes
    idx = eml_bytes.find(b"\r\n\r\n")
    if idx == -1:
        idx = eml_bytes.find(b"\n\n")
    if idx == -1:
        # No header/body separator (e.g. a header-only slice): strip all.
        return eml_bytes.replace(_BOM, b"")
    return eml_bytes[:idx].replace(_BOM, b"") + eml_bytes[idx:]


def message_id_for(eml_bytes: bytes) -> str:
    """Return Message-ID, falling back to a stable SHA-256 prefix.

    Sanitizes a BOM-corrupted header block first so the real Message-ID is
    found rather than masked (which would force a synthetic id — see #227).
    """
    eml_bytes = strip_header_bom(eml_bytes)
    parser = email.parser.BytesParser()
    msg = parser.parsebytes(eml_bytes, headersonly=True)
    mid = msg.get("Message-ID")
    if mid:
        return mid.strip().strip("<>").strip()
    digest = hashlib.sha256(eml_bytes[:4096]).hexdigest()[:32]
    return f"synthetic-{digest}"


def deliver(folder: Path, eml_bytes: bytes) -> Path:
    """Atomically write eml_bytes into folder/cur/ with :2,S suffix."""
    ensure_maildir(folder)
    timestamp = int(time.time())
    rand = secrets.token_hex(8)
    base = f"{timestamp}.M{secrets.randbelow(1_000_000):06d}.maildir-migrate.{rand}"
    tmp_path = folder / "tmp" / base
    cur_path = folder / "cur" / f"{base}:2,S"
    with open(tmp_path, "wb") as f:
        f.write(eml_bytes)
    os.rename(tmp_path, cur_path)
    return cur_path


def read_header(path: Path, cap: int = 256 * 1024) -> bytes:
    """Read just the RFC822 header block (up to the first blank line).

    Used when seeding the seen-set from a live Maildir: we only need the
    Message-ID, so there is no point pulling multi-MB attachment bodies over
    the wire for tens of thousands of messages. Returns whatever was read
    (capped) if no blank-line separator is found.
    """
    chunks: list[bytes] = []
    size = 0
    with open(path, "rb") as f:
        while size < cap:
            chunk = f.read(65536)
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
            blob = b"".join(chunks)
            idx = blob.find(b"\r\n\r\n")
            if idx == -1:
                idx = blob.find(b"\n\n")
            if idx != -1:
                return blob[: idx + 1]
    return b"".join(chunks)


def iter_maildir_messages(root: Path):
    """Yield every message file under cur/ and new/ Maildir subdirs of root.

    Walks nested Maildirs (SubFolders Verbatim layout) — any directory named
    `cur` or `new`, at any depth, contributes its files. `tmp/` is skipped
    (in-flight delivery only).
    """
    for dirpath, _, files in os.walk(root):
        if Path(dirpath).name in ("cur", "new"):
            for f in files:
                yield Path(dirpath) / f


def seed_from_maildir(root: Path, into: set[str]) -> int:
    """Add every Message-ID found under live Maildir `root` to `into`.

    Returns the number of NEW ids added (ignores ids already present).
    """
    added = 0
    for msg_path in iter_maildir_messages(root):
        try:
            mid = message_id_for(read_header(msg_path))
        except OSError as e:
            log.warning("dedupe read failed: %s (%s)", msg_path, e)
            continue
        except Exception as e:
            log.warning("dedupe parse failed: %s (%s)", msg_path, e)
            continue
        if mid not in into:
            into.add(mid)
            added += 1
    return added


def walk_eml(src: Path):
    """Yield (eml_path, relative_folder_parts) for every .eml under src."""
    for dirpath, _, files in os.walk(src):
        rel = Path(dirpath).relative_to(src)
        rel_parts = [] if rel == Path(".") else list(rel.parts)
        for f in files:
            if f.lower().endswith(".eml"):
                yield Path(dirpath) / f, rel_parts


def run(src: Path, dst: Path, dry_run: bool,
        dedupe_against: list[Path] | None = None) -> int:
    if not src.is_dir():
        log.error("source %s does not exist or is not a directory", src)
        return 2

    # Seed the seen-set from live Maildir(s) FIRST so anything already present
    # in the live archive is skipped from the export. live_ids is kept separate
    # so we can report already-live skips distinctly from intra-export dups.
    live_ids: set[str] = set()
    for d in dedupe_against or []:
        if not d.is_dir():
            log.error("dedupe-against %s does not exist or is not a directory", d)
            return 2
        n = seed_from_maildir(d, live_ids)
        log.info("dedupe: seeded %d Message-IDs from live %s", n, d)

    seen_ids: set[str] = set(live_ids)
    folders_seen: set[Path] = set()
    written = 0
    skipped_dup = 0
    skipped_live = 0
    skipped_corrupt = 0

    for eml_path, parts in walk_eml(src):
        try:
            eml_bytes = eml_path.read_bytes()
        except OSError as e:
            log.warning("read failed: %s (%s)", eml_path, e)
            skipped_corrupt += 1
            continue

        # Sanitize once: the same clean bytes feed both the Message-ID dedup
        # key and what we store, so the archive is byte-clean and browsable.
        eml_bytes = strip_header_bom(eml_bytes)

        try:
            mid = message_id_for(eml_bytes)
        except Exception as e:
            log.warning("parse failed: %s (%s)", eml_path, e)
            skipped_corrupt += 1
            continue

        if mid in live_ids:
            log.debug("already-live: %s (mid=%s)", eml_path, mid)
            skipped_live += 1
            continue
        if mid in seen_ids:
            log.debug("dup: %s (mid=%s)", eml_path, mid)
            skipped_dup += 1
            continue
        seen_ids.add(mid)

        folder = dst.joinpath(*parts) if parts else dst
        folders_seen.add(folder)

        if dry_run:
            written += 1
            continue

        try:
            deliver(folder, eml_bytes)
        except Exception as e:
            log.error("deliver failed: %s -> %s (%s)", eml_path, folder, e)
            skipped_corrupt += 1
            continue
        written += 1

    log.info(
        "done: %d written, %d already-live skipped, %d intra-export dups, "
        "%d corrupt/failed, %d folders touched",
        written,
        skipped_live,
        skipped_dup,
        skipped_corrupt,
        len(folders_seen),
    )
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--src", required=True, type=Path,
                   help="Root of MailStore EML export tree")
    p.add_argument("--dst", required=True, type=Path,
                   help="Maildir root (e.g. /mnt/data/Life/Andy/Email/legacy.archive)")
    p.add_argument("--dedupe-against", action="append", type=Path, default=None,
                   metavar="MAILDIR",
                   help="Seed the seen-Message-ID set from this live Maildir "
                        "before converting, skipping any export message already "
                        "present there. Repeatable.")
    p.add_argument("--dry-run", action="store_true",
                   help="Walk the tree and report stats; do not write")
    p.add_argument("-v", "--verbose", action="store_true")
    args = p.parse_args()
    setup_logging(args.verbose)
    dedupe = [d.resolve() for d in (args.dedupe_against or [])]
    return run(args.src.resolve(), args.dst.resolve(), args.dry_run, dedupe)


if __name__ == "__main__":
    sys.exit(main())
