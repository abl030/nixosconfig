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

Usage:
    python3 eml-to-maildir.py --src <export-dir> --dst <maildir-root>

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


def message_id_for(eml_bytes: bytes) -> str:
    """Return Message-ID, falling back to a stable SHA-256 prefix."""
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


def walk_eml(src: Path):
    """Yield (eml_path, relative_folder_parts) for every .eml under src."""
    for dirpath, _, files in os.walk(src):
        rel = Path(dirpath).relative_to(src)
        rel_parts = [] if rel == Path(".") else list(rel.parts)
        for f in files:
            if f.lower().endswith(".eml"):
                yield Path(dirpath) / f, rel_parts


def run(src: Path, dst: Path, dry_run: bool) -> int:
    if not src.is_dir():
        log.error("source %s does not exist or is not a directory", src)
        return 2
    seen_ids: set[str] = set()
    folders_seen: set[Path] = set()
    written = 0
    skipped_dup = 0
    skipped_corrupt = 0

    for eml_path, parts in walk_eml(src):
        try:
            eml_bytes = eml_path.read_bytes()
        except OSError as e:
            log.warning("read failed: %s (%s)", eml_path, e)
            skipped_corrupt += 1
            continue

        try:
            mid = message_id_for(eml_bytes)
        except Exception as e:
            log.warning("parse failed: %s (%s)", eml_path, e)
            skipped_corrupt += 1
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
        "done: %d written, %d duplicates skipped, %d corrupt/failed, %d folders touched",
        written,
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
    p.add_argument("--dry-run", action="store_true",
                   help="Walk the tree and report stats; do not write")
    p.add_argument("-v", "--verbose", action="store_true")
    args = p.parse_args()
    setup_logging(args.verbose)
    return run(args.src.resolve(), args.dst.resolve(), args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
