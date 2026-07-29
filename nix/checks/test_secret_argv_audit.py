#!/usr/bin/env python3
import importlib.util
import os
import unittest
from pathlib import Path

MODULE = Path(
    os.environ.get("SECRET_ARGV_AUDIT", Path(__file__).with_name("secret-argv-audit.py"))
)
spec = importlib.util.spec_from_file_location("secret_argv_audit", MODULE)
audit = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(audit)


class SecretArgvAuditTests(unittest.TestCase):
    def test_known_bad_shapes_are_rejected(self):
        fixtures = {
            "password DSN": "--dsn postgresql://discogs:secret@127.0.0.1/discogs",
            "keyword password DSN": "--dsn 'host=127.0.0.1 dbname=discogs password=secret'",
            "Kopia password flag": "kopia server start --server-password=$KOPIA_SERVER_PASSWORD",
            "Kopia username flag": "kopia server start --server-username=$KOPIA_SERVER_USER",
            "curl short user flag": 'curl -u "$user:$pass" https://example.invalid',
            "curl attached short user flag": 'curl -u"$user:$pass" https://example.invalid',
            "curl clustered short user flag": 'curl -fsSu "$user:$pass" https://example.invalid',
            "curl long user flag": 'curl --user "$user:$pass" https://example.invalid',
        }
        for name, fixture in fixtures.items():
            with self.subTest(name=name):
                self.assertTrue(audit.find_violations(fixture), name)

    def test_safe_file_and_stdin_boundaries_pass(self):
        safe = """
        discogs-api --dsn postgresql://discogs@127.0.0.1/discogs --credential-file %d/postgres-password
        kopia server start
        printf 'user = ...' | curl --config - https://example.invalid
        """
        self.assertEqual(audit.find_violations(safe), [])


if __name__ == "__main__":
    unittest.main()
