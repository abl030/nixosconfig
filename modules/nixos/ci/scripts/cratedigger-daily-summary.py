#!/usr/bin/env python3
"""Reduce one Cratedigger daily-check journal invocation to an actionable alert."""

from __future__ import annotations

import argparse
import json
import re
import sys

MAX_OUTPUT = 6000
MAX_ERRORS = 20
CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
STAGE = re.compile(
    r"^(?:PASS|FAIL) (?:whole-repository Pyright|deterministic full suite|"
    r"Nix flake checks|world-model burst|generated fuzz burst|mirror-harness smoke)"
)


def clean(line: str) -> str:
    line = CONTROL.sub(" ", line).strip()
    marker = "/repo/"
    if marker in line:
        line = line.split(marker, 1)[1]
    return line


def unique_append(items: list[str], seen: set[str], value: str) -> None:
    value = value[:500]
    if value and value not in seen:
        items.append(value)
        seen.add(value)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--invocation-id", required=True)
    args = parser.parse_args()

    lines = [clean(line) for line in sys.stdin]
    stages: list[str] = []
    errors: list[str] = []
    seen_stages: set[str] = set()
    seen_errors: set[str] = set()
    fuzz = ""
    audit = ""

    lock_attempted = any("daily unstable gate: updating flake.lock" in line for line in lines)
    lock_not_committed = any("flake.lock was not committed" in line for line in lines)
    lock_current = any("flake.lock already current" in line for line in lines)
    lock_pushed = any("pushed updated flake.lock" in line for line in lines)

    for line in lines:
        if STAGE.match(line):
            unique_append(stages, seen_stages, line)
        if "fuzz burst: ALL GREEN" in line:
            fuzz = line
        if " - error:" in line or line.startswith("python: ") and "failed test IDs" in line:
            unique_append(errors, seen_errors, line)
        if line.startswith("fatal:") or line.startswith("daily unstable gate:") and line.endswith("failed"):
            unique_append(errors, seen_errors, line)
        if line.startswith("FAIL live world audit:") or (
            line.startswith("live world audit:")
            and ("invalid" in line or "mismatch" in line)
        ):
            unique_append(errors, seen_errors, line)
        if line.startswith("{") and '"strict_violations"' in line:
            try:
                data = json.loads(line)
                audit = (
                    "Live-world audit: "
                    f"{data['known_remaining']} known; "
                    f"{data['newly_converged']} converged; "
                    f"{data['new_members']} new; "
                    f"{data['changed_members']} changed; "
                    f"growth {data['growth']}"
                )
            except (json.JSONDecodeError, KeyError, TypeError):
                pass

    if lock_pushed:
        lock = "Candidate lock: committed and pushed"
    elif lock_current:
        lock = "Candidate lock: already current"
    elif lock_attempted and lock_not_committed:
        lock = "Candidate lock: updated for testing; not committed"
    elif lock_attempted:
        lock = "Candidate lock: update attempted; final disposition unavailable"
    else:
        lock = "Candidate lock: update did not start"

    output = [lock]
    if stages:
        output.extend(["", "Stage results:", *stages])
    if fuzz:
        output.extend(["", fuzz])
    if audit:
        output.extend([audit])
    if errors:
        shown = errors[:MAX_ERRORS]
        output.extend(["", "Key errors:", *shown])
        if len(errors) > len(shown):
            output.append(f"… {len(errors) - len(shown)} additional unique errors omitted")
    footer = (
        "\n\nFull journal:\n"
        "journalctl -u cratedigger-daily-checks.service "
        f"_SYSTEMD_INVOCATION_ID={args.invocation_id} --no-pager\n"
    )
    body = "\n".join(output).strip()
    truncation = "\n… summary truncated"
    body_budget = MAX_OUTPUT - len(footer)
    if len(body) > body_budget:
        body = body[: body_budget - len(truncation)].rstrip() + truncation
    result = body + footer
    sys.stdout.write(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
