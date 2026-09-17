"""Exercise the packaged helper without contacting an identity provider."""
import contextlib
import io
import json
import multiprocessing
import os
from pathlib import Path
import runpy
import tempfile
import time
import types
import unittest
from unittest.mock import patch
import urllib.error


HELPER = os.environ["OAUTH_HELPER"]


def refresh(post):
    function = runpy.run_path(HELPER)["cmd_refresh"]
    function.__globals__["http_post"] = post
    function(types.SimpleNamespace(provider="o365"))


def concurrent_refresh(start):
    start.wait()

    def post(url, params):
        time.sleep(0.1)
        return {"access_token": "access", "refresh_token": params["refresh_token"] + "+"}

    with contextlib.redirect_stdout(io.StringIO()):
        refresh(post)


class RotationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "token.json"
        self.env = patch.dict(os.environ, {
            "OAUTH_PROVIDER": "o365", "OAUTH_REFRESH_TOKEN": "seed",
            "OAUTH_CLIENT_ID": "client", "OAUTH_TENANT": "common",
            "OAUTH_TOKEN_STATE_FILE": str(self.path),
        })
        self.env.start()
        self.addCleanup(self.env.stop)

    def exchange(self, expected, replacement="rotated"):
        def post(url, params):
            self.assertEqual(params["refresh_token"], expected)
            return {"access_token": "access", "refresh_token": replacement}
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            refresh(post)
        self.assertEqual(output.getvalue(), "access\n")

    def test_rotation_survives_fresh_process_namespace(self):
        self.exchange("seed")
        self.exchange("rotated", "rotated-again")
        self.assertEqual(json.loads(self.path.read_text())["refresh_token"], "rotated-again")
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)

    def test_new_seed_overrides_cache(self):
        self.exchange("seed")
        os.environ["OAUTH_REFRESH_TOKEN"] = "new-seed"
        self.exchange("new-seed", "new-rotated")
        self.exchange("new-rotated")

    def test_identity_change_overrides_cache(self):
        self.exchange("seed")
        os.environ["OAUTH_CLIENT_ID"] = "new-client"
        self.exchange("seed")

    def test_missing_rotation_preserves_latest(self):
        self.exchange("seed")
        def post(url, params):
            self.assertEqual(params["refresh_token"], "rotated")
            return {"access_token": "access"}
        with contextlib.redirect_stdout(io.StringIO()):
            refresh(post)
        self.exchange("rotated")

    def test_write_failure_keeps_state_and_emits_no_access(self):
        self.exchange("seed")
        before = self.path.read_bytes()
        output = io.StringIO()
        with patch("os.replace", side_effect=OSError("private detail")):
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    refresh(lambda *_: {"access_token": "secret-access", "refresh_token": "new"})
        self.assertEqual(output.getvalue(), "")
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(list(self.path.parent.glob(".oauth-*")), [])

    def test_endpoint_error_is_redacted_and_preserves_state(self):
        self.exchange("seed")
        before = self.path.read_bytes()
        def post(*_):
            body = io.BytesIO(json.dumps({"error_codes": [700082], "refresh_token": "secret"}).encode())
            raise urllib.error.HTTPError("url", 400, "private detail", {}, body)
        errors = io.StringIO()
        with contextlib.redirect_stderr(errors), self.assertRaises(SystemExit):
            refresh(post)
        self.assertIn("AADSTS700082", errors.getvalue())
        self.assertNotIn("secret", errors.getvalue())
        self.assertEqual(self.path.read_bytes(), before)

    def test_corrupt_cache_fails_without_silent_seed_fallback(self):
        for contents in ("not json", "null", "{}", '{"seed_id":"old"}'):
            with self.subTest(contents=contents):
                self.path.write_text(contents)
                with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                    refresh(lambda *_: self.fail("must not contact endpoint"))

    def test_missing_access_never_logs_or_saves_refresh(self):
        errors = io.StringIO()
        with contextlib.redirect_stderr(errors), self.assertRaises(SystemExit):
            refresh(lambda *_: {"refresh_token": "secret"})
        self.assertNotIn("secret", errors.getvalue())
        self.assertFalse(self.path.exists())

    def test_no_state_path_preserves_stateless_use(self):
        del os.environ["OAUTH_TOKEN_STATE_FILE"]
        os.environ["OAUTH_PROVIDER"] = "gmail"
        os.environ["OAUTH_CLIENT_SECRET"] = "test-client-secret"
        self.exchange("seed")
        self.exchange("seed")
        self.assertFalse(self.path.exists())

    def test_malformed_response_fails_without_writing_state(self):
        for response in ([], None, {"access_token": "access", "refresh_token": ""}):
            with self.subTest(response=response):
                output = io.StringIO()
                with contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit):
                        refresh(lambda *_: response)
                self.assertEqual(output.getvalue(), "")
                self.assertFalse(self.path.exists())

    def test_concurrent_processes_chain_rotations(self):
        ctx = multiprocessing.get_context("fork")
        start = ctx.Event()
        children = [ctx.Process(target=concurrent_refresh, args=(start,)) for _ in range(3)]
        for child in children:
            child.start()
        start.set()
        for child in children:
            child.join(10)
            if child.is_alive():
                child.terminate()
                child.join()
                self.fail("refresh lock did not release")
            self.assertEqual(child.exitcode, 0)
        self.assertEqual(json.loads(self.path.read_text())["refresh_token"], "seed+++")


if __name__ == "__main__":
    unittest.main()
