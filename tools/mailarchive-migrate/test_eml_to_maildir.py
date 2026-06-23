#!/usr/bin/env python3
"""Synthetic-Maildir tests for eml-to-maildir.py.

Stdlib only, no pytest. Run directly:

    python3 tools/mailarchive-migrate/test_eml_to_maildir.py

Exercises the --dedupe-against path (issue #227): an EML export deduped
against a live Maildir must keep ONLY messages not already present live,
collapse intra-export duplicates, and preserve the nested folder layout.
"""

from __future__ import annotations

import email
import importlib.util
import logging
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("eml_to_maildir", HERE / "eml-to-maildir.py")
assert spec is not None and spec.loader is not None
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def make_eml(message_id: str | None, subject: str, body: str = "hello") -> bytes:
    headers = [
        "From: sender@example.com",
        "To: andy@cullenwines.com.au",
        f"Subject: {subject}",
        "Date: Mon, 01 Jun 2026 00:00:00 +0800",
    ]
    if message_id is not None:
        headers.append(f"Message-ID: <{message_id}>")
    return ("\r\n".join(headers) + "\r\n\r\n" + body + "\r\n").encode()


def make_mozilla_eml(message_id: str, subject: str, body: str = "hello") -> bytes:
    """Thunderbird/MailStore-style EML: X-Mozilla-* pseudo-headers followed by a
    stray UTF-8 BOM injected before the first real header — the issue #227
    corruption that masks the real Message-ID from the email parser."""
    pseudo = (
        "\r\n".join(
            [
                "X-Account-Key: account5",
                "X-UIDL: 167249",
                "X-Mozilla-Keys: " + " " * 20,
            ]
        )
        + "\r\n"
    )
    real = (
        "\r\n".join(
            [
                "Received: from mail.example.com",
                "From: sender@example.com",
                "To: andy@cullenwines.com.au",
                f"Subject: {subject}",
                "Date: Mon, 01 Jun 2026 00:00:00 +0800",
                f"Message-ID: <{message_id}>",
            ]
        )
        + "\r\n\r\n"
        + body
        + "\r\n"
    )
    return pseudo.encode() + b"\xef\xbb\xbf" + real.encode()


def write_live_message(maildir_folder: Path, eml: bytes, name: str) -> None:
    """Drop a message straight into a live-style Maildir cur/ dir."""
    cur = maildir_folder / "cur"
    cur.mkdir(parents=True, exist_ok=True)
    (cur / f"{name}:2,S").write_bytes(eml)


def write_export_eml(folder: Path, eml: bytes, name: str) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    (folder / f"{name}.eml").write_bytes(eml)


def count_messages(maildir_root: Path) -> int:
    return sum(1 for _ in mod.iter_maildir_messages(maildir_root))


def assert_eq(got, want, label: str) -> None:
    if got != want:
        raise AssertionError(f"{label}: got {got!r}, want {want!r}")
    print(f"  ok: {label} == {got!r}")


def main() -> int:
    logging.basicConfig(level=logging.WARNING)
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        live = root / "live"          # simulates /mnt/.../work
        export = root / "export"      # simulates the MailStore EML staging
        dst = root / "legacy.archive"

        # --- Live tree: two filed messages that still exist on the server. ---
        write_live_message(live / "INBOX", make_eml("mid-A@x", "A filed"), "100.A")
        write_live_message(live / "INBOX" / "Barrels", make_eml("mid-B@x", "B filed"), "101.B")

        # --- Export tree (what MailStore would emit): ---
        # mid-A, mid-B : duplicates of live -> must be skipped (already-live)
        # mid-C        : deleted history, present TWICE in export -> 1 survivor
        # mid-D        : deleted history, unique -> survivor
        # (no id)      : message lacking Message-ID -> survivor (synthetic id)
        write_export_eml(export / "Cullen Work" / "INBOX", make_eml("mid-A@x", "A filed"), "a")
        write_export_eml(export / "Cullen Work" / "Barrels", make_eml("mid-B@x", "B filed"), "b")
        write_export_eml(export / "Cullen Work" / "Deleted", make_eml("mid-C@x", "C deleted"), "c1")
        write_export_eml(export / "Cullen Work" / "Archive", make_eml("mid-C@x", "C deleted"), "c2")
        write_export_eml(export / "Cullen Work" / "Deleted", make_eml("mid-D@x", "D deleted"), "d")
        write_export_eml(export / "Cullen Work" / "Deleted", make_eml(None, "no id"), "n")

        # ---- Case 1: with --dedupe-against live ----
        print("case 1: --dedupe-against live")
        rc = mod.run(export, dst, dry_run=False, dedupe_against=[live])
        assert_eq(rc, 0, "return code")
        # Survivors: mid-C (one of two), mid-D, no-id  => 3 written
        assert_eq(count_messages(dst), 3, "survivors written")
        # mid-A / mid-B must NOT appear in the archive
        all_bytes = b"".join(p.read_bytes() for p in mod.iter_maildir_messages(dst))
        assert_eq(b"mid-A@x" in all_bytes, False, "mid-A excluded")
        assert_eq(b"mid-B@x" in all_bytes, False, "mid-B excluded")
        assert_eq(b"mid-C@x" in all_bytes, True, "mid-C kept")
        assert_eq(b"mid-D@x" in all_bytes, True, "mid-D kept")
        # Nested layout preserved + Seen flag applied
        seen_flagged = list((dst / "Cullen Work" / "Deleted" / "cur").glob("*:2,S"))
        assert_eq(len(seen_flagged) >= 2, True, "Deleted/cur has :2,S messages")

        # ---- Case 2: no dedupe -> everything unique survives ----
        print("case 2: no --dedupe-against")
        dst2 = root / "legacy.nodedupe"
        rc = mod.run(export, dst2, dry_run=False, dedupe_against=None)
        assert_eq(rc, 0, "return code")
        # A, B, C(once), D, no-id => 5 unique
        assert_eq(count_messages(dst2), 5, "unique survivors written")

        # ---- Case 3: dry-run writes nothing ----
        print("case 3: --dry-run")
        dst3 = root / "legacy.dryrun"
        rc = mod.run(export, dst3, dry_run=True, dedupe_against=[live])
        assert_eq(rc, 0, "return code")
        assert_eq(dst3.exists(), False, "dry-run created no output tree")

        # ---- Case 4: nonexistent dedupe target -> rc 2, no output ----
        print("case 4: bad --dedupe-against path")
        dst4 = root / "legacy.bad"
        rc = mod.run(export, dst4, dry_run=False, dedupe_against=[root / "nope"])
        assert_eq(rc, 2, "return code for missing dedupe dir")

        # ---- Case 5: Thunderbird BOM-corrupted export (issue #227) ----
        # Each export EML carries X-Mozilla-* pseudo-headers + a BOM before the
        # real headers. The fix must (a) still extract the real Message-ID so
        # dedup works, and (b) store byte-clean, parseable messages.
        print("case 5: Thunderbird BOM export dedups + stores clean")
        # (a) Message-ID is recovered despite the BOM (not a synthetic fallback).
        assert_eq(
            mod.message_id_for(make_mozilla_eml("mid-E@x", "E")),
            "mid-E@x",
            "BOM Message-ID extracted",
        )
        live5 = root / "live5"
        export5 = root / "export5"
        dst5 = root / "legacy5"
        # live has mid-E (still filed). export has mid-E (dup) + mid-F (deleted).
        write_live_message(live5 / "INBOX", make_eml("mid-E@x", "E filed"), "200.E")
        write_export_eml(export5 / "Work" / "INBOX", make_mozilla_eml("mid-E@x", "E"), "e")
        write_export_eml(export5 / "Work" / "INBOX", make_mozilla_eml("mid-F@x", "F"), "f")
        rc = mod.run(export5, dst5, dry_run=False, dedupe_against=[live5])
        assert_eq(rc, 0, "return code")
        # mid-E is deduped against live; only mid-F (deleted history) survives.
        assert_eq(count_messages(dst5), 1, "only deleted mid-F survives BOM dedup")
        survivor = next(mod.iter_maildir_messages(dst5))
        data = survivor.read_bytes()
        assert_eq(b"\xef\xbb\xbf" in data, False, "stored survivor has BOM stripped")
        parsed = email.message_from_bytes(data)
        assert_eq(parsed.get("Subject"), "F", "stored survivor Subject parseable")
        assert_eq(parsed.get("Message-ID"), "<mid-F@x>", "stored Message-ID parseable")

    print("\nALL TESTS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
