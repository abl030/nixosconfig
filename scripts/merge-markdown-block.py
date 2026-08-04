#!/usr/bin/env python3
"""Idempotently install one managed Markdown block in a mutable file."""

from __future__ import annotations

import argparse
import fcntl
import os
import re
import stat
import tempfile
from pathlib import Path


def merge_text(original: str, name: str, body: str) -> str:
    begin = f"<!-- BEGIN {name} -->"
    end = f"<!-- END {name} -->"
    block = f"{begin}\n{body.strip()}\n{end}"

    begin_count = original.count(begin)
    end_count = original.count(end)
    if begin_count != end_count:
        raise ValueError(f"unbalanced managed-block markers for {name}")

    if begin_count:
        pattern = re.compile(
            rf"{re.escape(begin)}.*?{re.escape(end)}(?:\n)?", re.DOTALL
        )
        matches = list(pattern.finditer(original))
        if len(matches) != begin_count:
            raise ValueError(f"nested or out-of-order managed-block markers for {name}")

        pieces: list[str] = []
        cursor = 0
        for index, match in enumerate(matches):
            pieces.append(original[cursor : match.start()])
            if index == 0:
                pieces.append(block + "\n")
            cursor = match.end()
        pieces.append(original[cursor:])
        merged = "".join(pieces)
    else:
        merged = original.rstrip()
        if merged:
            merged += "\n\n"
        merged += block

    return merged.rstrip() + "\n"


def merge_file(path: Path, name: str, source: Path) -> bool:
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_name(f".{path.name}.homelab-ai-notifications.lock")
    with lock_path.open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if path.is_symlink():
            raise ValueError(f"refusing to replace symlinked file: {path}")
        original = path.read_text() if path.exists() else ""
        merged = merge_text(original, name, source.read_text())
        if merged == original:
            return False

        mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
        descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
        try:
            with os.fdopen(descriptor, "w") as handle:
                handle.write(merged)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary, mode)

            # Refuse to overwrite an unrelated update made after our read. The
            # lock serializes our own activations; the exact-content comparison
            # also detects clients/plugins that do not honor that lock.
            current = path.read_text() if path.exists() else ""
            if current != original or path.is_symlink():
                raise RuntimeError(f"concurrent update detected for {path}")
            os.replace(temporary, path)
            directory = os.open(path.parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    return True


def self_test() -> None:
    body = "## Notifications\nDo the thing.\n"
    original = "# Keep\n\n<!-- BEGIN TEST -->\nold\n<!-- END TEST -->\n\nTail\n"
    merged = merge_text(original, "TEST", body)
    assert "old" not in merged
    assert "# Keep" in merged and "Tail" in merged
    assert merged.count("<!-- BEGIN TEST -->") == 1
    assert merge_text(merged, "TEST", body) == merged

    duplicate = (
        "before\n<!-- BEGIN TEST -->\none\n<!-- END TEST -->\nmiddle\n"
        "<!-- BEGIN TEST -->\ntwo\n<!-- END TEST -->\nafter\n"
    )
    collapsed = merge_text(duplicate, "TEST", body)
    assert collapsed.count("<!-- BEGIN TEST -->") == 1
    assert "middle" in collapsed and "after" in collapsed

    for malformed in (
        "<!-- BEGIN TEST -->\nmissing end\n",
        "<!-- END TEST -->\nmissing begin\n",
        "<!-- BEGIN TEST -->\n<!-- BEGIN TEST -->\n<!-- END TEST -->\n<!-- END TEST -->\n",
    ):
        try:
            merge_text(malformed, "TEST", body)
        except ValueError:
            pass
        else:
            raise AssertionError("malformed marker layout was accepted")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", nargs="?", type=Path)
    parser.add_argument("name", nargs="?")
    parser.add_argument("source", nargs="?", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        print("Markdown block merge self-test passed.")
        return
    if args.path is None or args.name is None or args.source is None:
        parser.error("path, name, and source are required")
    print("updated" if merge_file(args.path, args.name, args.source) else "already current")


if __name__ == "__main__":
    main()
