#!/usr/bin/env python3
"""Audit: every flake input must FOLLOW the fleet nixpkgs, not carry its own.

An input that pins its own nixpkgs creates a duplicate, usually-stale nixpkgs
node in flake.lock. The rolling-flake-update only advances the ROOT pin, so a
duplicate node drifts off on its own and goes stale silently (this is the
"why does our nixpkgs look like it's from April" orphan that motivated the
check). It also bloats every closure that pulls the input and makes tooling and
agents that read flake.lock misreport the fleet nixpkgs version.

Deny-by-default: any input whose locked `nixpkgs` edge is its OWN node (rather
than a `follows`) fails the audit, UNLESS flake.nix carries a justification
marker for it:

    # NIXPKGS-OWN-OK: <input-name> — <why it genuinely cannot follow root>

Mechanics: in flake.lock a `follows` is recorded as a LIST (e.g. ["nixpkgs"]);
an input carrying its own nixpkgs records a STRING node-ref to a node other than
the root nixpkgs node. That list-vs-string distinction is the whole signal — no
node-type heuristics needed (an own nixpkgs can be a github ref OR a
releases.nixos.org channel tarball; nixos-hardware used the latter).

Usage: nixpkgs-follows-audit.py <flake.lock> <flake.nix>
Exit 0 = clean (or every exception justified); exit 1 = unjustified violation.
"""
import datetime
import json
import re
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: nixpkgs-follows-audit.py <flake.lock> <flake.nix>", file=sys.stderr)
        return 2
    lock_path, flake_nix_path = sys.argv[1], sys.argv[2]

    with open(lock_path) as f:
        lock = json.load(f)
    with open(flake_nix_path) as f:
        flake_nix = f.read()

    nodes = lock["nodes"]
    root = lock["root"]
    rinputs = nodes[root]["inputs"]
    root_np = rinputs.get("nixpkgs")
    if not isinstance(root_np, str):
        print("nixpkgs-follows audit: root has no direct nixpkgs input — nothing to anchor against.", file=sys.stderr)
        return 1

    # A top-level input "carries its own nixpkgs" when its locked nixpkgs edge is
    # a direct node-ref (string) to a node OTHER than the root nixpkgs node.
    violations = []
    for name, lbl in sorted(rinputs.items()):
        if not isinstance(lbl, str):
            continue
        npref = (nodes.get(lbl, {}).get("inputs") or {}).get("nixpkgs")
        if isinstance(npref, str) and npref != root_np:
            loc = nodes.get(npref, {}).get("locked", {})
            rev = (loc.get("rev") or "")[:12]
            lm = loc.get("lastModified")
            date = (
                datetime.datetime.fromtimestamp(lm, datetime.timezone.utc).strftime("%Y-%m-%d")
                if lm
                else "?"
            )
            violations.append((name, npref, rev, date))

    # Exception marker:  # NIXPKGS-OWN-OK: <input> — <reason>   (em-dash, colon or hyphen ok)
    def justification(name: str):
        pat = re.compile(
            r"NIXPKGS-OWN-OK:\s*" + re.escape(name) + r"\b\s*[—:\-]+\s*(\S.*)"
        )
        for line in flake_nix.splitlines():
            m = pat.search(line)
            if m and m.group(1).strip():
                return m.group(1).strip()
        return None

    unjustified = []
    for name, lbl, rev, date in violations:
        reason = justification(name)
        if reason:
            print(f"OK (justified): '{name}' carries its own nixpkgs ({rev}, {date}) — {reason}")
        else:
            unjustified.append((name, lbl, rev, date))

    if unjustified:
        print()
        print("UNJUSTIFIED: flake input(s) carry their own nixpkgs instead of following the fleet pin:")
        for name, lbl, rev, date in unjustified:
            print(f"  - {name}: pins nixpkgs node '{lbl}' ({rev}, {date})")
        print()
        print("WHY THIS IS BLOCKED:")
        print("  The rolling-flake-update only advances the ROOT nixpkgs pin. A duplicate")
        print("  nixpkgs node drifts off on its own and goes stale silently, bloats every")
        print("  closure that pulls the input, and makes tooling/agents misread the fleet")
        print("  nixpkgs version (the 'nixpkgs looks like it's from April' orphan).")
        print()
        print("FIX (preferred) — make the input follow root nixpkgs in flake.nix:")
        print('    <input> = { url = "..."; inputs.nixpkgs.follows = "nixpkgs"; };')
        print("  then re-lock:  nix flake lock")
        print()
        print("EXCEPTION (only with a real reason) — add a marker line in flake.nix:")
        print("    # NIXPKGS-OWN-OK: <input> — <why it genuinely cannot follow root>")
        print()
        print("See docs/wiki/infrastructure/nixpkgs-follows-policy.md")
        return 1

    print(
        "nixpkgs-follows audit: all "
        f"{len(rinputs)} top-level flake inputs follow the fleet nixpkgs "
        "(or carry a justified NIXPKGS-OWN-OK exception)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
