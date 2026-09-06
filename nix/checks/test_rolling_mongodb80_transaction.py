#!/usr/bin/env python3
"""Replay source transaction functions with mocked external boundaries.

No real git command, commit, push, Nix build, network or credentials are used.
The package updater itself is independently exercised by test_mongodb80_update.
"""
import os
import re
import shlex
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(os.environ.get("ROLLING_UPDATE_SOURCE", ROOT / "scripts/rolling_flake_update.sh"))


def main():
    source = SOURCE.read_text()
    names = ("restore_group_state", "record_group_update_failure", "finish_updated_group", "try_group")
    functions = []
    for name in names:
        match = re.search(r"^" + name + r"\(\) \{\n.*?^}", source, re.M | re.S)
        assert match, name
        functions.append(match.group())
    final_gate = re.search(r'^if \[ "\$FATAL_TRANSACTION" -eq 1 \]; then\n.*?^fi', source, re.M | re.S)
    assert final_gate
    bash = shutil.which("bash")
    assert bash
    # Faults are injected at boundaries, not in a copied transaction algorithm.
    cases = [
        ("success", {}),
        ("no change", {"NO_CHANGE": 1}),
        ("update failure", {"UPDATE_RC": 9}),
        ("flake check failure", {"CHECK_RC": 9}),
        ("cache build failure", {"CACHE_RC": 9}),
        ("stage failure", {"ADD_RC": 9}),
        ("commit failure", {"COMMIT_RC": 9}),
        ("reset failure poisons", {"CHECK_RC": 9, "RESET_RC": 9}),
        ("checkout failure poisons", {"CHECK_RC": 9, "CHECKOUT_RC": 9}),
    ]
    with tempfile.TemporaryDirectory(prefix="mongodb80-transaction-fixture-") as temp:
        root = Path(temp)
        (root / "scripts").mkdir()
        (root / "nix/pkgs").mkdir(parents=True)
        (root / "bin").mkdir()
        # Minimal PATH makes accidental real git/nix/network calls impossible.
        for command in ("cp", "cmp"):
            resolved = shutil.which(command)
            assert resolved, command
            (root / "bin" / command).symlink_to(resolved)
        for name, body in {
            "update_mongodb80.sh": 'printf "update\\n" >> calls\n[ "$NO_CHANGE" -eq 1 ] || printf candidate > nix/pkgs/mongodb80.nix\nexit "$UPDATE_RC"\n',
            "populate_cache.sh": 'printf "cache\\n" >> calls\nexit "$CACHE_RC"\n',
        }.items():
            path = root / "scripts" / name
            # NixOS has no /bin/bash. Every executable fixture uses the actual
            # discovered interpreter, including scripts executed by production.
            path.write_text(f"#!{bash}\n" + body)
            path.chmod(0o700)
        prelude = r'''
set -euo pipefail
GROUP_MONGODB80=mongodb80
ONLY_GROUP=
WORK_DIR=$PWD
DATE=fixture
log() { printf '%s\n' "$*" >> messages; }
triage() { printf fixture; }
persist_group_failure() { printf 'persist %s\n' "$1" >> calls; }
send_rca_notification() { printf 'notify\n' >> calls; }
send_summary_notification() { printf 'fallback-notify\n' >> calls; }
nix() {
  printf 'nix %s\n' "$*" >> calls
  [ "$*" = 'flake check --impure --print-build-logs' ] || return 98
  [ "$FULL_CHECK" = 1 ] || return 97
  return "$CHECK_RC"
}
git() {
  printf 'git %s\n' "$*" >> calls
  case "$1" in
    diff) [ "$*" = 'diff --quiet -- nix/pkgs/mongodb80.nix' ] || return 96
          cmp -s baseline nix/pkgs/mongodb80.nix ;;
    add) [ "$*" = 'add -- nix/pkgs/mongodb80.nix' ] || return 95
         return "$ADD_RC" ;;
    commit) return "$COMMIT_RC" ;;
    reset) return "$RESET_RC" ;;
    checkout)
      [ "$CHECKOUT_RC" -eq 0 ] || return "$CHECKOUT_RC"
      if [ "$3" = nix/pkgs/mongodb80.nix ]; then cp baseline "$3"; fi ;;
    *) return 94 ;;
  esac
}
'''
        for label, overrides in cases:
            values = dict.fromkeys(("UPDATE_RC", "CHECK_RC", "CACHE_RC", "ADD_RC", "COMMIT_RC", "RESET_RC", "CHECKOUT_RC", "NO_CHANGE"), 0)
            values.update(overrides)
            failed = any(value for key, value in values.items() if key != "NO_CHANGE")
            poisoned = bool(values["RESET_RC"] or values["CHECKOUT_RC"])
            committed = not failed and not values["NO_CHANGE"]
            for name in ("baseline", "nix/pkgs/mongodb80.nix"):
                (root / name).write_text("baseline")
            for name in ("calls", "messages"):
                (root / name).write_text("")
            body = f'''
ANY_FAIL=0; ANY_COMMIT=0; FATAL_TRANSACTION=0; SUMMARY_LINES=()
rc=0
try_group mongodb80 mongodb80 || rc=$?
test "$rc" -eq {int(failed)}
test "$ANY_FAIL" -eq {int(failed)}
test "$ANY_COMMIT" -eq {int(committed)}
test "$FATAL_TRANSACTION" -eq {int(poisoned)}
'''
            if poisoned:
                body += '''
printf 'before-poison-gate\n' >> calls
# A later group must not update anything after rollback poisoning.
try_group core nixpkgs || true
# Also prove that previously accumulated successful commits cannot escape.
ANY_COMMIT=1
''' + final_gate.group() + "\nprintf 'escaped-poison-gate\\n' >> calls\n"
            script = root / "replay.sh"
            script.write_text(prelude + f"\nexport PATH={shlex.quote(str(root / 'bin'))}\n" + "\n".join(functions) + body)
            environment = {"PATH": str(root / "bin"), "HOME": str(root), "LC_ALL": "C", **{key: str(value) for key, value in values.items()}}
            result = subprocess.run([bash, "--noprofile", "--norc", str(script)], cwd=root, env=environment,
                                    text=True, capture_output=True, timeout=10)
            calls = (root / "calls").read_text().splitlines()
            messages = (root / "messages").read_text()
            assert result.returncode == int(poisoned), (label, result.stdout, result.stderr, calls, messages)
            assert calls[0] == "update", (label, calls)
            if failed:
                for path in ("flake.lock", "nix/overlay.nix", "nix/pkgs/mongodb80.nix"):
                    assert f"git reset -q -- {path}" in calls, (label, calls)
                    assert f"git checkout -- {path}" in calls, (label, calls)
                if not values["CHECKOUT_RC"]:
                    assert (root / "nix/pkgs/mongodb80.nix").read_text() == "baseline"
            if committed:
                assert calls == ["update", "git diff --quiet -- nix/pkgs/mongodb80.nix",
                                 "nix flake check --impure --print-build-logs", "cache",
                                 "git add -- nix/pkgs/mongodb80.nix", "git commit -q -m rolling: mongodb80 (fixture)"], calls
                assert (root / "nix/pkgs/mongodb80.nix").read_text() == "candidate"
            if values["NO_CHANGE"]:
                assert calls == ["update", "git diff --quiet -- nix/pkgs/mongodb80.nix"]
            if values["UPDATE_RC"] or values["CHECK_RC"]:
                assert "cache" not in calls
            if values["UPDATE_RC"] or values["CHECK_RC"] or values["CACHE_RC"] or values["ADD_RC"]:
                assert not any(call.startswith("git commit") for call in calls)
            if poisoned:
                assert calls[calls.index("before-poison-gate") + 1:] == ["notify"], calls
                assert "no commits were pushed or deployed" in messages
            print(f"PASS source rolling MongoDB transaction: {label}")
    print(f"{len(cases)} transaction cases passed; no real git/Nix/network commands")


if __name__ == "__main__":
    main()
