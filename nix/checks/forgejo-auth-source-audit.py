#!/usr/bin/env python3
"""Ratchet raw Forgejo credential and trace plumbing out of authored sources."""

from __future__ import annotations

import re
import os
from pathlib import Path


# These patterns intentionally own only the Forgejo auth grammar. Other service
# API headers and unrelated Git signing options are outside this ratchet.
PATTERNS = (
    (
        "credential URL",
        re.compile(r"https?://[^\s/@]+(?::[^\s/@]*)?@git\.ablz\.au/", re.IGNORECASE),
    ),
    (
        "git -c credential header",
        re.compile(
            r"\bgit\b[^\n]{0,300}\s(?:-c|--config)\s+[^\n]*(?:extraHeader|authorization\s*:\s*token)"
            r"[^\n]*(?:\$\{?[A-Za-z_][A-Za-z0-9_]*TOKEN\}?|nixbot-token|hermes-token)",
            re.IGNORECASE,
        ),
    ),
    (
        "git auth array credential",
        re.compile(
            r"\b(?:auth|git_auth|git_args)\s*=\s*\([^\n]*(?:extraHeader|authorization\s*:\s*token)"
            r"[^\n]*(?:\$\{?[A-Za-z_][A-Za-z0-9_]*TOKEN\}?|nixbot-token|hermes-token)",
            re.IGNORECASE,
        ),
    ),
    (
        "curl header",
        re.compile(
            r"\bcurl\b(?=[^\n]*(?:git\.ablz\.au|/run/secrets/forgejo/))"
            r"(?=[^\n]*(?:\s(?:-H|--header)\s*[^\n]*"
            r"(?:authorization\s*:\s*token|\$[A-Za-z_][A-Za-z0-9_]*TOKEN|nixbot-token|hermes-token)))",
            re.IGNORECASE,
        ),
    ),
    (
        "GIT_CONFIG credential export",
        re.compile(
            r"\bGIT_CONFIG_(?:KEY|VALUE)_\d+\s*=\s*[^\n]*(?:git\.ablz\.au|"
            r"authorization\s*:\s*token|nixbot-token|hermes-token|\$[A-Za-z_][A-Za-z0-9_]*TOKEN)",
            re.IGNORECASE,
        ),
    ),
    (
        "token interpolation in Forgejo URL",
        re.compile(
            r"https?://[^\s]*\$(?:\{)?[A-Za-z_][A-Za-z0-9_]*TOKEN(?:\})?[^\s]*git\.ablz\.au|"
            r"https?://[^\s]*oauth2:[^\s]*git\.ablz\.au",
            re.IGNORECASE,
        ),
    ),
)

TRACE_PATTERNS = (
    (
        "xtrace export",
        re.compile(r"(?:^|[;\n])\s*(?:set\s+-[^\n]*x|export\s+GIT_TRACE\S*\s*=)", re.IGNORECASE),
    ),
    (
        "Git Trace2 export",
        re.compile(r"\bGIT_TRACE2(?:_[A-Z0-9_]+)?\s*=", re.IGNORECASE),
    ),
    (
        "Git curl verbosity export",
        re.compile(r"\bGIT_CURL_VERBOSE\s*=", re.IGNORECASE),
    ),
    (
        "curl trace or verbosity",
        re.compile(r"\bcurl\b[^\n]*(?:\s-v\b|--verbose\b|--trace(?:-ascii|-config)?\b)", re.IGNORECASE),
    ),
)


def normalize(text: str) -> str:
    """Join shell continuation lines without changing authored tokens."""

    return re.sub(r"\\\s*\n\s*", " ", text).replace('"', '').replace("'", '')


def find_violations(text: str) -> list[str]:
    normalized = normalize(text)
    violations = [name for name, pattern in PATTERNS if pattern.search(normalized)]
    forgejo_context = re.search(
        r"git\.ablz\.au|/run/secrets/forgejo/|nixbot-token|hermes-token",
        normalized,
        re.IGNORECASE,
    )
    if forgejo_context:
        violations.extend(name for name, pattern in TRACE_PATTERNS if pattern.search(normalized))
        # URL variables assigned before curl are common in runbooks. Scope to
        # Forgejo-bearing files, not only the command's own physical line.
        if re.search(r"\bcurl\b[^\n]*\s(?:-H\s*|--header(?:\s|=))[^\n]*authorization\s*:\s*token\b", normalized, re.I):
            violations.append("curl header")
    # Detect the header itself, independent of a token variable's spelling.
    # This also owns literal headers in documentation (not just interpolation).
    if re.search(r"\bgit\b[^\n]*\s(?:-c|--config)(?:\s|=)[^\n]*extraheader\s*=\s*authorization\s*:\s*token\b", normalized, re.I):
        violations.append("git -c credential header")
    if re.search(r"\b(?:auth|git_auth|git_args)\s*=\s*\([^\n]*extraheader\s*=\s*authorization\s*:\s*token\b", normalized, re.I):
        violations.append("git auth array credential")
    return list(dict.fromkeys(violations))


def _files(paths: list[Path]) -> list[Path]:
    result: list[Path] = []
    for path in paths:
        if path.is_file():
            result.append(path)
        elif path.is_dir():
            result.extend(candidate for candidate in path.rglob("*") if candidate.is_file())
    return result


def scan_paths(paths: list[Path]) -> list[str]:
    failures: list[str] = []
    # Exact paths supplied by the gate; no basename or subtree exemptions.
    excluded = {Path(p).resolve() for p in os.environ.get("FORGEJO_AUTH_SOURCE_EXCLUDE", "").split(os.pathsep) if p}
    for path in _files(paths):
        if path.resolve() in excluded:
            continue
        violations = find_violations(path.read_text())
        failures.extend(f"{path}: {violation}" for violation in violations)
    return failures


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="+", type=Path)
    args = parser.parse_args()
    failures = scan_paths(args.paths)
    for failure in failures:
        print(f"{failure}: forbidden raw Forgejo auth/trace shape")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
