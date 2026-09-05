#!/usr/bin/env python3
"""Tests for the narrow Forgejo-auth source ratchet."""

from __future__ import annotations

import importlib.util
import itertools
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


MODULE = Path(
    os.environ.get(
        "FORGEJO_AUTH_SOURCE_AUDIT",
        Path(__file__).with_name("forgejo-auth-source-audit.py"),
    )
)
spec = importlib.util.spec_from_file_location("forgejo_auth_source_audit", MODULE)
assert spec is not None and spec.loader is not None
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class ForgejoAuthSourceAuditTests(unittest.TestCase):
    def test_generated_quoting_whitespace_and_url_assignment_grammar(self) -> None:
        count = 0
        for var, space, template, command in itertools.product(
            ("$TOKEN", "${TOKEN}", "$PUSH_TOKEN", "${PUSH_TOKEN}"),
            (" ", "\t", " \\\n  "), ('"http.extraHeader=Authorization: token {var}"', 'http.extraHeader="Authorization: token {var}"'), ("git", '"git"', "'git'")
        ):
            fixture = f'{command}{space}-c{space}{template.format(var=var)} push origin master'
            with self.subTest(fixture=fixture):
                self.assertTrue(audit.find_violations(fixture))
            count += 1
        for var, space, command, option in itertools.product(
            ("$TOKEN", "${TOKEN}"), (" ", "\t", " \\\n  "),
            ("curl", '"curl"', "'curl'"), ("-H", "-H ", "--header ", "--header=")
        ):
            fixture = f'URL=https://git.ablz.au/api/v1/repos/x/y/issues\n{command}{space}{option}"Authorization: token {var}" "$URL"'
            with self.subTest(fixture=fixture):
                self.assertTrue(audit.find_violations(fixture))
            count += 1
        print(f"qualified {count} generated unsafe grammar cases")

    def test_known_unsafe_forgejo_shapes_are_rejected(self) -> None:
        fixtures = {
            "rolling argv": 'PUSH_TOKEN=$(<token); git -c "http.extraHeader=Authorization: token $PUSH_TOKEN" push origin master',
            "rolling auth array": 'auth=(-c "http.extraHeader=Authorization: token ${PUSH_TOKEN}"); git "${auth[@]}" push origin master',
            "curl header": 'curl -fsS -H "Authorization: token $TOKEN" https://git.ablz.au/api/v1/repos/abl030/nixosconfig/issues',
            "credential URL": 'git push https://oauth2:$TOKEN@git.ablz.au/abl030/nixosconfig.git master',
            "trace export": 'set -x\nexport GIT_TRACE2_EVENT=/tmp/trace\ngit push origin master # https://git.ablz.au',
            "curl trace": 'curl --trace-ascii /tmp/curl.trace https://git.ablz.au/api/v1/repos/abl030/nixosconfig/pulls',
        }
        for name, fixture in fixtures.items():
            with self.subTest(name=name):
                self.assertTrue(audit.find_violations(fixture), name)

    def test_backslash_newline_variants_are_normalized(self) -> None:
        fixture = 'curl -s \\\n  --header "Authorization: token $TOKEN" \\\n  "https://git.ablz.au/api/v1/repos/abl030/nixosconfig/issues"'
        self.assertTrue(audit.find_violations(fixture))

    def test_boundary_invocations_and_unrelated_credentials_pass(self) -> None:
        safe = """
        ./scripts/forgejo-auth.sh git-push --token-file /run/secrets/forgejo/nixbot-token
        ./scripts/forgejo-auth.sh rest --token-file /run/secrets/forgejo/hermes-token \\
          --url https://git.ablz.au/api/v1/repos/abl030/nixosconfig/pulls
        curl -H \"Authorization: Bearer $TOKEN\" https://unrelated.example.invalid/api
        git -c gpg.ssh.allowedSignersFile=/etc/fleet-update/allowed_signers verify-commit HEAD
        """
        self.assertEqual(audit.find_violations(safe), [])

    def test_attached_header_separate_url_scan_and_cli(self) -> None:
        for host, rejected in (("git.ablz.au", True), ("unrelated.example.invalid", False)):
            with self.subTest(host=host), tempfile.TemporaryDirectory(prefix="forgejo-attached-header-") as temp:
                path = Path(temp) / "fixture.sh"
                path.write_text(f'URL=https://{host}/api/v1/repos/x/y/issues\ncurl -H"Authorization: token $TOKEN" "$URL"\n')
                violations = audit.scan_paths([path])
                result = subprocess.run([sys.executable, str(MODULE), str(path)], text=True, capture_output=True, check=False)
                self.assertEqual(result.returncode, 1 if rejected else 0, result.stdout + result.stderr)
                self.assertEqual(bool(violations), rejected)
        self.assertEqual(audit.find_violations('URL=https://git.ablz.au/api/v1/repos/x/y/issues\ncurl -H"Authorization: Bearer $OTHER_SERVICE_TOKEN" https://unrelated.example.invalid/api'), [])

    def test_hidden_and_nested_sources_have_only_exact_path_exemptions(self) -> None:
        from unittest.mock import patch
        with tempfile.TemporaryDirectory(prefix="forgejo-source-scope-") as temp:
            root = Path(temp)
            files = [root / name for name in ("scripts/forgejo-auth.sh", "scripts/nested/forgejo-auth.sh", ".claude/skills/fixture.md", "docs/wiki/fixture.md")]
            for path in files:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('git -c "http.extraHeader=Authorization: token $TOKEN" push origin master')
            with patch.dict(os.environ, {"FORGEJO_AUTH_SOURCE_EXCLUDE": str(files[0])}):
                violations = audit.scan_paths([root])
            self.assertEqual(len(violations), 3)
            for path in files[1:]:
                self.assertTrue(any(str(path) in violation for violation in violations))

    def test_source_scan_reports_path_and_category(self) -> None:
        with tempfile.TemporaryDirectory(prefix="forgejo-source-audit-") as temp:
            path = Path(temp) / "fixture.sh"
            path.write_text('curl -H "Authorization: token $TOKEN" https://git.ablz.au/api/v1/repos/abl030/nixosconfig/issues\n')
            violations = audit.scan_paths([path])
        self.assertEqual(len(violations), 1)
        self.assertIn("fixture.sh", violations[0])
        self.assertIn("curl header", violations[0])


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(ForgejoAuthSourceAuditTests)
    result = unittest.TextTestRunner(verbosity=1).run(suite)
    if not result.wasSuccessful():
        raise SystemExit(1)
    raw_paths = os.environ.get("FORGEJO_AUTH_SOURCE_PATHS", "")
    if raw_paths:
        failures = audit.scan_paths([Path(path) for path in raw_paths.split(os.pathsep) if path])
        for failure in failures:
            print(f"{failure}: forbidden raw Forgejo auth/trace shape")
        raise SystemExit(1 if failures else 0)
