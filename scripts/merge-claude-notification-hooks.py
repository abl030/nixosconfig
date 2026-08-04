#!/usr/bin/env python3
"""Merge the managed Claude notification hook without owning settings.json."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import shlex
import stat
import tempfile
from pathlib import Path
from typing import Any, Callable


def filter_handlers(groups: Any, remove: Callable[[dict[str, Any]], bool]) -> list[dict[str, Any]]:
    if not isinstance(groups, list):
        raise ValueError("Claude hook event must contain a list of groups")
    kept_groups: list[dict[str, Any]] = []
    for raw_group in groups:
        if not isinstance(raw_group, dict):
            raise ValueError("Claude hook group must be a JSON object")
        group = dict(raw_group)
        if "hooks" not in group:
            raise ValueError("Claude hook group is missing its hooks list")
        handlers = group["hooks"]
        if not isinstance(handlers, list):
            raise ValueError("Claude hook group must contain a hooks list")
        if not all(isinstance(handler, dict) for handler in handlers):
            raise ValueError("Claude hook handler must be a JSON object")
        group["hooks"] = [handler for handler in handlers if not remove(handler)]
        if group["hooks"]:
            kept_groups.append(group)
    return kept_groups


def merge_settings(settings: dict[str, Any], command: str) -> dict[str, Any]:
    merged = dict(settings)
    raw_hooks = merged.get("hooks", {})
    if not isinstance(raw_hooks, dict):
        raise ValueError("Claude settings hooks must be a JSON object")
    hooks = dict(raw_hooks)

    def is_legacy(handler: dict[str, Any]) -> bool:
        try:
            argv = shlex.split(str(handler.get("command", "")))
        except ValueError:
            return False
        return (
            len(argv) == 2
            and argv[0].endswith("/.claude/hooks/gotify-turn-ping.sh")
            and argv[1] in {"start", "stop"}
        )

    def is_managed(handler: dict[str, Any]) -> bool:
        try:
            argv = shlex.split(str(handler.get("command", "")))
        except ValueError:
            return False
        return (
            len(argv) == 2
            and argv[0].endswith("/bin/ai-gotify-notify")
            and argv[1] in {"claude-notification", "claude-request"}
        )

    for event in ("UserPromptSubmit", "Stop"):
        groups = filter_handlers(hooks.get(event, []), is_legacy)
        if groups:
            hooks[event] = groups
        else:
            hooks.pop(event, None)

    # Remove prior versions of our hook from every supported source while
    # retaining unrelated handlers. PermissionRequest and Elicitation are the
    # exact events that mean Claude is blocked on human input; Notification's
    # idle/agent-completed types are deliberately not used.
    for event in ("Notification", "PermissionRequest", "Elicitation"):
        groups = filter_handlers(hooks.get(event, []), is_managed)
        if groups:
            hooks[event] = groups
        else:
            hooks.pop(event, None)

    handler = {
        "type": "command",
        "command": command,
        "timeout": 15,
        "async": True,
    }
    hooks["PermissionRequest"] = hooks.get("PermissionRequest", []) + [
        {"hooks": [handler]}
    ]
    hooks["Elicitation"] = hooks.get("Elicitation", []) + [
        {"hooks": [handler]}
    ]
    hooks["Notification"] = hooks.get("Notification", []) + [
        {"matcher": "agent_needs_input", "hooks": [handler]}
    ]
    merged["hooks"] = hooks
    return merged


def merge_file(path: Path, command: str) -> bool:
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_name(f".{path.name}.homelab-ai-notifications.lock")
    with lock_path.open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if path.is_symlink():
            raise ValueError(f"refusing to replace symlinked settings: {path}")
        original_raw = path.read_text() if path.exists() else None
        parsed = json.loads(original_raw if original_raw is not None else "{}\n")
        if not isinstance(parsed, dict):
            raise ValueError("Claude settings must contain a JSON object")
        merged = json.dumps(merge_settings(parsed, command), indent=2, ensure_ascii=False) + "\n"
        if merged == original_raw:
            return False

        mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
        descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
        try:
            with os.fdopen(descriptor, "w") as handle:
                handle.write(merged)
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
    command = "/nix/store/new/bin/ai-gotify-notify claude-request"
    source = {
        "model": "opus",
        "hooks": {
            "UserPromptSubmit": [
                {"hooks": [{"type": "command", "command": "/home/test/.claude/hooks/gotify-turn-ping.sh start"}]}
            ],
            "Stop": [
                {
                    "hooks": [
                        {"type": "command", "command": "keep-me"},
                        {"type": "command", "command": "/home/test/.claude/hooks/gotify-turn-ping.sh stop"},
                    ]
                }
            ],
            "Notification": [
                {"matcher": "auth_success", "hooks": [{"type": "command", "command": "other"}]},
                {
                    "matcher": "permission_prompt",
                    "hooks": [
                        {
                            "type": "command",
                            "command": "/nix/store/old/bin/ai-gotify-notify claude-notification",
                        }
                    ],
                },
            ],
        },
    }
    merged = merge_settings(source, command)
    assert merged["model"] == "opus"
    assert "UserPromptSubmit" not in merged["hooks"]
    assert merged["hooks"]["Stop"][0]["hooks"] == [{"type": "command", "command": "keep-me"}]
    assert len(merged["hooks"]["Notification"]) == 2
    assert merged["hooks"]["Notification"][0]["matcher"] == "auth_success"
    assert merged["hooks"]["Notification"][-1]["matcher"] == "agent_needs_input"
    assert merged["hooks"]["PermissionRequest"][-1]["hooks"][0]["command"] == command
    assert merged["hooks"]["Elicitation"][-1]["hooks"][0]["command"] == command
    assert merge_settings(merged, command) == merged

    for malformed in (
        {"hooks": []},
        {"hooks": {"Stop": {}}},
        {"hooks": {"Stop": [{}]}},
        {"hooks": {"Stop": [{"hooks": "not-a-list"}]}},
        {"hooks": {"Stop": [{"hooks": ["not-an-object"]}]}},
    ):
        try:
            merge_settings(malformed, command)
        except ValueError:
            pass
        else:
            raise AssertionError("malformed hook settings were accepted")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("settings", nargs="?", type=Path)
    parser.add_argument("command", nargs="?")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        print("Claude notification hook merge self-test passed.")
        return
    if args.settings is None or args.command is None:
        parser.error("settings and command are required")
    print("updated" if merge_file(args.settings, args.command) else "already current")


if __name__ == "__main__":
    main()
