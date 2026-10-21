#!/usr/bin/env python3
"""Replay the rolling updater's package-hold logic with a mocked nix.

The hold functions are taken from the real script source. `nix` is a shell
function that answers from fixture files, so no build, network or store access
happens. Covers release, auto-hold (including every refusal guard), the
nixpkgs-held re-pin, and the nightly hold summary.
"""
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(os.environ.get("ROLLING_UPDATE_SOURCE", ROOT / "scripts/rolling_flake_update.sh"))
FUNCTIONS = (
    "locked_input_ref", "valid_hold_name", "held_names", "drv_name", "drv_pname",
    "drv_is_fixed_output", "build_failures", "release_holds", "auto_hold_failures",
    "hold_summary",
)
BASE_REV = "a" * 40
CAND_REV = "b" * 40
OLD_HELD_REV = "c" * 40
CAND = f"github:NixOS/nixpkgs/{CAND_REV}"


def lock(nixpkgs, held):
    def node(rev):
        return {"locked": {"type": "github", "owner": "NixOS", "repo": "nixpkgs", "rev": rev}}
    return json.dumps({"root": "root", "version": 7, "nodes": {
        "root": {"inputs": {"nixpkgs": "nixpkgs", "nixpkgs-held": "nixpkgs-held"}},
        "nixpkgs": node(nixpkgs), "nixpkgs-held": node(held)}})


def failure(drv, reason):
    return f"error: Cannot build '/nix/store/{'0' * 32}-{drv}.drv'.\n       Reason: {reason}\n       Output paths:\n"


ROOT_FAIL = "builder failed with exit code 1."
DEP_FAIL = "1 dependency failed."

PRELUDE = r'''
set -euo pipefail
HELD_FILE=nix/held-packages.json
HELD_INPUT=nixpkgs-held
HOLD_MAX_AUTO=3
HOLD_STALE_DAYS=30
HOLD_NOTIFY=0
TAG=nix-rolling
DATE=2026-10-14
WORK_DIR=$PWD/work
SUMMARY_LINES=()
log() { printf '%s\n' "$*" >> messages; }
nix() {
  printf 'nix %s\n' "$*" >> calls
  case "$1 $2" in
    "derivation show")
      local f="drvs/${3##*/}.json"
      [ -f "$f" ] && cat "$f" && return 0
      return 1 ;;
    "eval --raw")
      local v
      v="$(jq -er --arg k "$3" '.[$k]' evals.json)" || return 1
      printf '%s' "$v" ;;
    "build --no-link")
      local attr="${4##*#}"
      grep -Fxq -- "$attr" buildable ;;
    "flake lock")
      local rev
      rev="$(sed -nE 's|^    nixpkgs-held\.url = "github:NixOS/nixpkgs/([0-9a-f]{40})";$|\1|p' flake.nix)"
      jq --arg r "$rev" '.nodes["nixpkgs-held"].locked.rev = $r' flake.lock > flake.lock.tmp && mv flake.lock.tmp flake.lock ;;
    *) return 97 ;;
  esac
}
'''


def drv_json(pname=None, fod=False, structured=False):
    env = {"name": "x"}
    if pname:
        env["pname"] = pname
    if fod:
        env["outputHash"] = "sha256-x"
    if structured:
        # __structuredAttrs: .env holds only output paths; pname moves under .structuredAttrs.
        return json.dumps({"derivations": {"x.drv": {
            "env": {"out": "/nix/store/x"}, "outputs": {"out": {"path": "/nix/store/x"}},
            "structuredAttrs": {**env, "env": {}}}}})
    return json.dumps({"/nix/store/x.drv": {"env": env, "outputs": {"out": {"path": "/nix/store/x"}}}})


def run_case(root, bash, functions, *, held, body, log_text="", drvs=None, evals=None,
             buildable=(), held_rev=OLD_HELD_REV):
    for name in ("calls", "messages"):
        (root / name).write_text("")
    shutil.rmtree(root / "drvs", ignore_errors=True)
    (root / "drvs").mkdir()
    shutil.rmtree(root / "work", ignore_errors=True)
    (root / "work").mkdir()
    for drv, data in (drvs or {}).items():
        (root / "drvs" / f"{'0' * 32}-{drv}.drv.json").write_text(data)
    (root / "evals.json").write_text(json.dumps(evals or {}))
    (root / "buildable").write_text("".join(f"{b}\n" for b in buildable))
    (root / "build.log").write_text(log_text)
    (root / "nix/held-packages.json").write_text(json.dumps(held))
    (root / "work/held.start.json").write_text(json.dumps(held))
    (root / "flake.lock").write_text(lock(CAND_REV, held_rev))
    (root / "base.lock").write_text(lock(BASE_REV, held_rev))
    (root / "flake.nix").write_text(f'  inputs = {{\n    nixpkgs-held.url = "github:NixOS/nixpkgs/{held_rev}";\n  }};\n')
    script = root / "replay.sh"
    script.write_text(PRELUDE + "\n".join(functions) + "\n" + body
                      + '\nprintf "%s\\n" "${SUMMARY_LINES[@]:-}" > summary\necho "$HOLD_NOTIFY" > notify\n')
    env = {"PATH": str(root / "bin"), "HOME": str(root), "LC_ALL": "C.UTF-8"}
    result = subprocess.run([bash, "--noprofile", "--norc", str(script)], cwd=root, env=env,
                            text=True, capture_output=True, timeout=20)
    assert result.returncode == 0, (body, result.stderr, (root / "messages").read_text())
    return {
        "held": json.loads((root / "nix/held-packages.json").read_text()),
        "flake": (root / "flake.nix").read_text(),
        "lock_held": json.loads((root / "flake.lock").read_text())["nodes"]["nixpkgs-held"]["locked"]["rev"],
        "messages": (root / "messages").read_text(),
        "summary": (root / "summary").read_text().splitlines(),
        "notify": (root / "notify").read_text().strip(),
    }


def main():
    source = SOURCE.read_text()
    functions = []
    for name in FUNCTIONS:
        match = re.search(r"^" + name + r"\(\) \{\n.*?^}", source, re.M | re.S)
        assert match, name
        functions.append(match.group())
    bash = shutil.which("bash")
    assert bash
    zotero = {"since": "2026-10-14", "added_by": "manual", "reason": "r", "tracking": "t"}
    leaf_log = failure("zotero-10.0.4", ROOT_FAIL) + failure("home-manager-path", DEP_FAIL) \
        + failure("zotero-10.0.4-fish-completions", DEP_FAIL)
    leaf_drvs = {"zotero-10.0.4": drv_json("zotero"), "home-manager-path": drv_json(),
                 "zotero-10.0.4-fish-completions": drv_json()}
    leaf_evals = {f"{CAND}#zotero.name": "zotero-10.0.4",
                  f"github:NixOS/nixpkgs/{BASE_REV}#zotero.name": "zotero-10.0.2"}
    auto = 'rc=0; auto_hold_failures build.log base.lock || rc=$?; echo "$rc" > rc\n'

    with tempfile.TemporaryDirectory(prefix="rolling-holds-fixture-") as temp:
        root = Path(temp)
        (root / "nix").mkdir()
        (root / "bin").mkdir()
        for command in ("awk", "cat", "cp", "date", "grep", "jq", "mv", "sed", "sort"):
            resolved = shutil.which(command)
            assert resolved, command
            (root / "bin" / command).symlink_to(resolved)

        def rc():
            return (root / "rc").read_text().strip()

        # Release: a held package that builds on the candidate is dropped.
        out = run_case(root, bash, functions, held={"zotero": zotero}, buildable=["zotero"],
                       body="release_holds build.log\n")
        assert out["held"] == {}, out
        out = run_case(root, bash, functions, held={"zotero": zotero}, body="release_holds build.log\n")
        assert out["held"] == {"zotero": zotero}, out

        # Auto-hold of a leaf with no hold active re-pins nixpkgs-held to the base rev.
        out = run_case(root, bash, functions, held={}, body=auto, log_text=leaf_log, drvs=leaf_drvs,
                       evals=leaf_evals)
        assert rc() == "0", out["messages"]
        assert list(out["held"]) == ["zotero"] and out["held"]["zotero"]["added_by"] == "rolling-flake-update", out
        assert BASE_REV in out["flake"] and out["lock_held"] == BASE_REV, out

        # With a hold already active, the existing nixpkgs-held pin is kept.
        other = {"other": zotero}
        evals = {**leaf_evals, f"github:NixOS/nixpkgs/{OLD_HELD_REV}#zotero.name": "zotero-10.0.1"}
        out = run_case(root, bash, functions, held=other, body=auto, log_text=leaf_log, drvs=leaf_drvs,
                       evals=evals)
        assert rc() == "0" and set(out["held"]) == {"other", "zotero"}, out
        assert out["lock_held"] == OLD_HELD_REV and BASE_REV not in out["flake"], out

        # Refusals: each leaves the hold list and pin untouched.
        refusals = {
            "library": (failure("openssl-3.5", ROOT_FAIL) + failure("curl-8.1", DEP_FAIL),
                        {"openssl-3.5": drv_json("openssl"), "curl-8.1": drv_json("curl")},
                        {f"{CAND}#openssl.name": "openssl-3.5"}, "depends on"),
            "fetch": (failure("source", ROOT_FAIL), {"source": drv_json("zotero", fod=True)},
                      {f"{CAND}#zotero.name": "source"}, "fixed-output"),
            "not top-level": (leaf_log, leaf_drvs, {f"{CAND}#zotero.name": "zotero-10.0.5"}, "not nixpkgs"),
            "too many": ("".join(failure(f"p{i}-1", ROOT_FAIL) for i in range(4)), {}, {}, "only 1-3"),
            "nothing": (failure("home-manager-path", DEP_FAIL), {}, {}, "0 root"),
            "no pname": (failure("weird", ROOT_FAIL), {"weird": drv_json()}, {}, "no usable pname"),
            "structured attrs": (failure("python3.14-foo-1.0-post9", ROOT_FAIL),
                                 {"python3.14-foo-1.0-post9": drv_json("foo", structured=True)}, {},
                                 "not nixpkgs' top-level foo"),
        }
        for label, (log_text, drvs, evals, why) in refusals.items():
            out = run_case(root, bash, functions, held={}, body=auto, log_text=log_text, drvs=drvs,
                           evals={**leaf_evals, **evals} if label != "not top-level" else evals)
            assert rc() == "1", (label, out["messages"])
            assert why in out["messages"], (label, out["messages"])
            assert out["held"] == {} and out["lock_held"] == OLD_HELD_REV, (label, out)

        # Already held and still failing: refuse (the hold did not fix it).
        out = run_case(root, bash, functions, held={"zotero": zotero}, body=auto, log_text=leaf_log,
                       drvs=leaf_drvs, evals=leaf_evals)
        assert rc() == "1" and "already held" in out["messages"], out["messages"]

        # Summary: added and released notify; a fresh hold lists its age quietly.
        body = 'hold_summary\n'
        out = run_case(root, bash, functions, held={"zotero": zotero},
                       body='printf "{}\\n" > work/held.start.json\n' + body)
        assert any(line.startswith("🧊 hold added — zotero") for line in out["summary"]), out
        assert out["notify"] == "1", out
        out = run_case(root, bash, functions, held={}, body='printf \'{"zotero": {}}\\n\' > work/held.start.json\n' + body)
        assert "🔓 hold released — zotero builds on current nixpkgs" in out["summary"] and out["notify"] == "1", out
        out = run_case(root, bash, functions, held={"zotero": {**zotero, "since": "2026-10-10"}}, body=body)
        assert out["summary"] == ["🧊 held zotero 4d (t)"] and out["notify"] == "0", out
        # Stale holds warn every night and notify on day 30, 37, 44, ...
        out = run_case(root, bash, functions, held={"zotero": {**zotero, "since": "2026-09-14"}}, body=body)
        assert out["summary"][0].startswith("⚠️ held zotero 30d") and out["notify"] == "1", out
        out = run_case(root, bash, functions, held={"zotero": {**zotero, "since": "2026-09-13"}}, body=body)
        assert out["summary"][0].startswith("⚠️ held zotero 31d") and out["notify"] == "0", out
    print("rolling package-hold replay: ok")


if __name__ == "__main__":
    main()
