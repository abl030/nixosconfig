#!/usr/bin/env python3
"""Reject credential-to-argv shapes in rendered units and targeted service sources."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

PATTERNS = (
    (
        "password-bearing PostgreSQL DSN",
        re.compile(
            r"postgres(?:ql)?://[^\s/@:'\"]+:[^@\s/'\"]+@|--dsn[^\n]{0,300}\bpassword\s*=",
            re.IGNORECASE,
        ),
    ),
    (
        "Kopia server credential option",
        re.compile(r"--server-(?:user(?:name)?|password)(?:\s|=)", re.IGNORECASE),
    ),
    (
        "curl user/password option",
        re.compile(
            r"\b(?:curl|\S*/curl)\b[^\n]*(?:\s-[A-Za-z]*u(?:\s|=|(?=[^\s-]))|\s--user(?:\s|=))",
            re.IGNORECASE,
        ),
    ),
)


def find_violations(text: str) -> list[str]:
    # Nix and shell sources commonly split commands with backslash-newline.
    normalized = re.sub(r"\\\s*\n\s*", " ", text)
    return [name for name, pattern in PATTERNS if pattern.search(normalized)]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="+", type=Path)
    args = parser.parse_args()

    failed = False
    for path in args.paths:
        violations = find_violations(path.read_text())
        for violation in violations:
            print(f"{path}: forbidden secret-to-argv shape: {violation}")
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
