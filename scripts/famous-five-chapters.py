#!/usr/bin/env python3

"""Compatibility wrapper for the Famous Five manifest."""

from __future__ import annotations

import os
import sys
from pathlib import Path


HERE = Path(__file__).resolve().parent
TARGET = HERE / "audiobook-chapter-rebuild.py"
MANIFEST = HERE / "series-manifests" / "enid-blyton-famous-five.json"


def main() -> int:
    argv = [sys.executable, str(TARGET), "--manifest", str(MANIFEST), *sys.argv[1:]]
    os.execv(sys.executable, argv)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
