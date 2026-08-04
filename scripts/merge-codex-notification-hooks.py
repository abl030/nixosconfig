#!/usr/bin/env python3
"""Merge the managed Codex PermissionRequest hook into hooks.json."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import shlex
import stat
import tempfile
from pathlib import Path
from typing import Any


def merge_hooks(document: dict[str, Any], command: str) -> dict[str, Any]:
    merged = dict(document)
    raw_hooks = merged.get("hooks", {})
    if not isinstance(raw_hooks, dict):
        raise ValueError("Codex hooks must be a JSON object")
    hooks = dict(raw_hooks)

    groups = hooks.get("PermissionRequest", [])
    if not isinstance(groups, list):
        raise ValueError("Codex PermissionRequest must be a list")

    kept_groups: list[dict[str, Any]] = []
    for raw_group in groups:
        if not isinstance(raw_group, dict):
            raise ValueError("Codex hook group must be a JSON object")
        group = dict(raw_group)
        if "hooks" not in group:
            raise ValueError("Codex hook group is missing its hooks list")
        handlers = group["hooks"]
        if not isinstance(handlers, list):
            raise ValueError("Codex hook group must contain a hooks list")
        if not all(isinstance(handler, dict) for handler in handlers):
            raise ValueError("Codex hook handler must be a JSON object")
        def is_managed(handler: dict[str, Any]) -> bool:
            try:
                argv = shlex.split(str(handler.get("command", "")))
            except ValueError:
                return False
            return (
                len(argv) == 2
                and argv[0].endswith("/bin/ai-gotify-notify")
                and argv[1] == "codex-permission"
            )

        group["hooks"] = [handler for handler in handlers if not is_managed(handler)]
        if group["hooks"]:
            kept_groups.append(group)

    kept_groups.append(
        {
            "hooks": [
                {
                    "type": "command",
                    "command": command,
                    "timeout": 5,
                }
            ]
        }
    )
    hooks["PermissionRequest"] = kept_groups
    merged["hooks"] = hooks
    return merged


def merge_file(path: Path, command: str) -> bool:
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_name(f".{path.name}.homelab-ai-notifications.lock")
    with lock_path.open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if path.is_symlink():
            raise ValueError(f"refusing to replace symlinked hooks: {path}")
        original_raw = path.read_text() if path.exists() else None
        parsed = json.loads(original_raw if original_raw is not None else "{}\n")
        if not isinstance(parsed, dict):
            raise ValueError("Codex hooks file must contain a JSON object")
        rendered = json.dumps(merge_hooks(parsed, command), indent=2, ensure_ascii=False) + "\n"
        if rendered == original_raw:
            return False

        mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
        descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
        try:
            with os.fdopen(descriptor, "w") as handle:
                handle.write(rendered)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary, mode)

            current_raw = path.read_text() if path.exists() else None
            if current_raw != original_raw or path.is_symlink():
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
    old_command = "/nix/store/old/bin/ai-gotify-notify codex-permission"
    command = "/nix/store/new/bin/ai-gotify-notify codex-permission"
    source = {
        "hooks": {
            "SessionStart": [{"hooks": [{"type": "command", "command": "session"}]}],
            "PermissionRequest": [
                {
                    "matcher": "Bash",
                    "hooks": [
                        {"type": "command", "command": "keep-me"},
                        {"type": "command", "command": old_command},
                    ],
                }
            ],
        },
        "other": True,
    }
    merged = merge_hooks(source, command)
    assert merged["other"] is True
    assert merged["hooks"]["SessionStart"] == source["hooks"]["SessionStart"]
    assert merged["hooks"]["PermissionRequest"][0]["matcher"] == "Bash"
    assert merged["hooks"]["PermissionRequest"][0]["hooks"] == [
        {"type": "command", "command": "keep-me"}
    ]
    assert merged["hooks"]["PermissionRequest"][-1]["hooks"][0]["command"] == command
    assert merge_hooks(merged, command) == merged

    for malformed in (
        {"hooks": []},
        {"hooks": {"PermissionRequest": {}}},
        {"hooks": {"PermissionRequest": [{}]}},
        {"hooks": {"PermissionRequest": [{"hooks": "not-a-list"}]}},
        {"hooks": {"PermissionRequest": [{"hooks": ["not-an-object"]}]}},
    ):
        try:
            merge_hooks(malformed, command)
        except ValueError:
            pass
        else:
            raise AssertionError("malformed Codex hook settings were accepted")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("hooks", nargs="?", type=Path)
    parser.add_argument("command", nargs="?")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        print("Codex notification hook merge self-test passed.")
        return
    if args.hooks is None or args.command is None:
        parser.error("hooks and command are required")
    print("updated" if merge_file(args.hooks, args.command) else "already current")


if __name__ == "__main__":
    main()
