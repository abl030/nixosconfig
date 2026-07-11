#!/usr/bin/env python3
"""Merge managed table keys into a mutable TOML file without rewriting it."""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import tempfile
import tomllib
from pathlib import Path
from typing import Any


TABLE_RE = re.compile(r"^\s*\[\[?([^]]+)\]\]?\s*(?:#.*)?$")


def toml_value(value: Any) -> str:
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return str(value)
    if isinstance(value, list):
        return "[" + ", ".join(toml_value(item) for item in value) + "]"
    if isinstance(value, dict):
        entries = [f"{json.dumps(str(key))} = {toml_value(item)}" for key, item in value.items()]
        return "{ " + ", ".join(entries) + " }"
    raise ValueError(f"unsupported TOML value: {value!r}")


def table_bounds(lines: list[str], section: str) -> tuple[int, int] | None:
    start = None
    for index, line in enumerate(lines):
        match = TABLE_RE.match(line.rstrip("\n"))
        if start is None:
            if match and match.group(1) == section:
                start = index
        elif match:
            return start, index
    return None if start is None else (start, len(lines))


def merge_text(text: str, settings: dict[str, dict[str, Any]]) -> str:
    lines = text.splitlines(keepends=True)
    for section, values in settings.items():
        if not isinstance(values, dict):
            raise ValueError(f"section {section!r} must contain an object")
        bounds = table_bounds(lines, section)
        if bounds is None:
            if lines and lines[-1].strip():
                lines.append("\n")
            lines.append(f"[{section}]\n")
            bounds = (len(lines) - 1, len(lines))

        for key, value in values.items():
            start, end = table_bounds(lines, section) or bounds
            key_re = re.compile(rf"^\s*{re.escape(key)}\s*=")
            replacement = f"{key} = {toml_value(value)}\n"
            for index in range(start + 1, end):
                if key_re.match(lines[index]):
                    lines[index] = replacement
                    break
            else:
                if end > start and not lines[end - 1].endswith(("\n", "\r")):
                    lines[end - 1] += "\n"
                lines.insert(end, replacement)
    return "".join(lines)


def merge_file(config_path: Path, settings_path: Path) -> bool:
    if config_path.is_symlink():
        raise ValueError(f"refusing to replace symlinked config: {config_path}")
    original = config_path.read_text() if config_path.exists() else ""
    settings = json.loads(settings_path.read_text())
    if not isinstance(settings, dict):
        raise ValueError("managed settings must be a JSON object")
    merged = merge_text(original, settings)
    tomllib.loads(merged)
    if merged == original:
        return False

    config_path.parent.mkdir(parents=True, exist_ok=True)
    mode = stat.S_IMODE(config_path.stat().st_mode) if config_path.exists() else 0o600
    descriptor, temporary = tempfile.mkstemp(prefix=f".{config_path.name}.", dir=config_path.parent)
    try:
        with os.fdopen(descriptor, "w") as handle:
            handle.write(merged)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, config_path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return True


def self_test() -> None:
    source = "# keep me\nmodel = \"test\"\n\n[features]\nother = true\n\n[tail]\nvalue = 1\n"
    settings = {
        "features": {"memories": True},
        "memories": {
            "generate_memories": True,
            "use_memories": True,
            "disable_on_external_context": True,
        },
    }
    merged = merge_text(source, settings)
    parsed = tomllib.loads(merged)
    assert parsed["features"] == {"other": True, "memories": True}
    assert parsed["memories"]["disable_on_external_context"] is True
    assert "# keep me" in merged and parsed["tail"]["value"] == 1
    assert merge_text(merged, settings) == merged
    no_final_newline = merge_text("[features]", {"features": {"memories": True}})
    assert tomllib.loads(no_final_newline)["features"]["memories"] is True


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("config", nargs="?", type=Path)
    parser.add_argument("settings", nargs="?", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        print("TOML merge self-test passed.")
        return
    if args.config is None or args.settings is None:
        parser.error("config and settings paths are required")
    changed = merge_file(args.config, args.settings)
    print("updated" if changed else "already current")


if __name__ == "__main__":
    main()
