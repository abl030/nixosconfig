#!/usr/bin/env python3
"""Replay the rolling updater's all-groups-at-once pass with mocked boundaries.

try_all_groups and its helpers are taken from the real script source. git, nix,
the MongoDB updater and populate_cache.sh are fixtures, so no real commit,
build, network or credential is used.
"""
import json
import os
import re
import shlex
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(os.environ.get("ROLLING_UPDATE_SOURCE", ROOT / "scripts/rolling_flake_update.sh"))


def lock(revs):
    nodes = {"root": {"inputs": {name: name for name in revs}}}
    for name, rev in revs.items():
        nodes[name] = {"locked": {"rev": rev}}
    return json.dumps({"nodes": nodes, "root": "root", "version": 7})


BASE = {"nixpkgs": "a", "yt-dlp-src": "a", "claude-code-nix": "a", "nvchad4nix": "a", "other-input": "a"}


def main():
    source = SOURCE.read_text()
    functions = []
    for name in ("restore_group_state", "lock_inputs_changed", "try_all_groups"):
        match = re.search(r"^" + name + r"\(\) \{\n.*?^}", source, re.M | re.S)
        assert match, name
        functions.append(match.group())
    bash = shutil.which("bash")
    assert bash
    cases = [
        # label, overrides, new lock revs, expected rc, expected commit message
        ("combined success", {}, {**BASE, "nixpkgs": "b", "other-input": "b"}, 0, "rolling: core rest (fixture)"),
        ("no change", {}, BASE, 0, None),
        ("update failure", {"UPDATE_RC": 9}, {**BASE, "nixpkgs": "b"}, 1, None),
        ("build failure falls back", {"CACHE_RC": 9}, {**BASE, "nixpkgs": "b"}, 1, None),
        ("commit failure falls back", {"COMMIT_RC": 9}, {**BASE, "nixpkgs": "b"}, 1, None),
        ("rollback failure poisons", {"CACHE_RC": 9, "CHECKOUT_RC": 9}, {**BASE, "nixpkgs": "b"}, 1, None),
    ]
    with tempfile.TemporaryDirectory(prefix="rolling-combined-fixture-") as temp:
        root = Path(temp)
        (root / "scripts").mkdir()
        (root / "nix/pkgs").mkdir(parents=True)
        (root / "bin").mkdir()
        for command in ("cp", "cmp", "jq", "tr", "sed"):
            resolved = shutil.which(command)
            assert resolved, command
            (root / "bin" / command).symlink_to(resolved)
        for name, body in {
            "update_mongodb80.sh": 'printf "mongodb-update\\n" >> calls\nexit 0\n',
            "populate_cache.sh": 'printf "cache\\n" >> calls\nexit "$CACHE_RC"\n',
        }.items():
            path = root / "scripts" / name
            path.write_text(f"#!{bash}\n" + body)
            path.chmod(0o700)
        prelude = r'''
set -euo pipefail
GROUP_CORE=nixpkgs
GROUP_YTDLP=yt-dlp-src
GROUP_LLM=claude-code-nix
GROUP_NVCHAD=nvchad4nix
GROUP_REST=" other-input"
WORK_DIR=$PWD
DATE=fixture
log() { printf '%s\n' "$*" >> messages; }
nix() {
  printf 'nix %s\n' "$*" >> calls
  [ "$1 $2" = 'flake update' ] || return 98
  cp new.lock flake.lock
  return "$UPDATE_RC"
}
git() {
  printf 'git %s\n' "$*" >> calls
  case "$1" in
    diff)
      # The MongoDB package file never changes in these cases.
      if [ "$#" -eq 4 ] && [ "$4" = nix/pkgs/mongodb80.nix ]; then return 0; fi
      cmp -s base.lock flake.lock ;;
    add) return 0 ;;
    commit) return "$COMMIT_RC" ;;
    reset) return 0 ;;
    checkout)
      [ "$CHECKOUT_RC" -eq 0 ] || return "$CHECKOUT_RC"
      if [ "$3" = flake.lock ]; then cp base.lock flake.lock; fi ;;
    *) return 94 ;;
  esac
}
'''
        for label, overrides, new_revs, want_rc, want_message in cases:
            values = dict.fromkeys(("UPDATE_RC", "CACHE_RC", "COMMIT_RC", "CHECKOUT_RC"), 0)
            values.update(overrides)
            (root / "base.lock").write_text(lock(BASE))
            (root / "flake.lock").write_text(lock(BASE))
            (root / "new.lock").write_text(lock(new_revs))
            for name in ("calls", "messages"):
                (root / name).write_text("")
            poisoned = bool(values["CHECKOUT_RC"])
            body = f'''
ANY_FAIL=0; ANY_COMMIT=0; FATAL_TRANSACTION=0; SUMMARY_LINES=()
rc=0
try_all_groups || rc=$?
test "$rc" -eq {want_rc}
test "$FATAL_TRANSACTION" -eq {int(poisoned)}
test "$ANY_COMMIT" -eq {int(want_message is not None)}
printf '%s\\n' "${{SUMMARY_LINES[@]:-}}" > summary
'''
            script = root / "replay.sh"
            script.write_text(prelude + f"\nexport PATH={shlex.quote(str(root / 'bin'))}\n" + "\n".join(functions) + body)
            environment = {"PATH": str(root / "bin"), "HOME": str(root), "LC_ALL": "C.UTF-8",
                           **{key: str(value) for key, value in values.items()}}
            result = subprocess.run([bash, "--noprofile", "--norc", str(script)], cwd=root, env=environment,
                                    text=True, capture_output=True, timeout=10)
            calls = (root / "calls").read_text().splitlines()
            summary = (root / "summary").read_text().splitlines() if (root / "summary").exists() else []
            assert result.returncode == 0, (label, result.stderr, calls)
            commits = [c for c in calls if c.startswith("git commit")]
            if want_message:
                assert commits == [f"git commit -q -m {want_message}"], (label, calls)
                assert "✅ core — nixpkgs" in summary and "✅ rest — other-input" in summary, (label, summary)
                assert "➖ yt-dlp — no changes" in summary and "➖ mongodb80 — no changes" in summary, (label, summary)
            elif label == "commit failure falls back":
                assert len(commits) == 1, (label, calls)
            else:
                assert not commits, (label, calls)
            if label == "no change":
                assert "cache" not in calls and len(summary) == 6, (label, calls, summary)
            if values["UPDATE_RC"]:
                assert "cache" not in calls, (label, calls)
            if want_rc:
                # Every failure restores all transaction paths for the fallback.
                for path in ("flake.lock", "nix/overlay.nix", "nix/pkgs/mongodb80.nix"):
                    assert f"git checkout -- {path}" in calls, (label, calls)
                if poisoned:
                    assert summary == ["❌ all — rollback failed; no commits will be pushed"], (label, summary)
                else:
                    # The fallback, not this pass, reports the night's results.
                    assert summary == [""] or not summary, (label, summary)
                    assert (root / "flake.lock").read_text() == lock(BASE), label
            print(f"PASS rolling combined pass: {label}")
    print(f"{len(cases)} combined-pass cases passed; no real git/Nix/network commands")


if __name__ == "__main__":
    main()
