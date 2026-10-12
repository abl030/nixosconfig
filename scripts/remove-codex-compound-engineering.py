#!/usr/bin/env python3
"""Remove retired Compound Engineering files from the Codex user directory."""

import re
import shutil
import sys
from pathlib import Path


def main() -> None:
    root = Path(sys.argv[1])
    instructions = root / "AGENTS.md"
    if instructions.exists():
        if instructions.is_symlink():
            raise ValueError("refusing to edit symlinked Codex instructions")
        original = instructions.read_text()
        begin = "<!-- BEGIN COMPOUND CODEX TOOL MAP -->"
        end = "<!-- END COMPOUND CODEX TOOL MAP -->"
        if original.count(begin) != original.count(end):
            raise ValueError("unbalanced Compound Engineering instruction markers")
        updated = re.sub(
            re.escape(begin) + r".*?" + re.escape(end) + r"\n?",
            "",
            original,
            flags=re.DOTALL,
        )
        if updated != original:
            instructions.write_text(updated)

    for relative in (
        "skills/compound-engineering",
        "agents/compound-engineering",
        "compound-engineering",
        "plugins/cache/compound-engineering-plugin",
        ".tmp/marketplaces/compound-engineering-plugin",
    ):
        path = root / relative
        if path.is_symlink():
            path.unlink()
        elif path.exists():
            shutil.rmtree(path)


if __name__ == "__main__":
    main()
