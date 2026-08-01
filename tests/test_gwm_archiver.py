import importlib.util
import sys
import unittest
from pathlib import Path
from urllib.error import URLError


SCRIPT = Path(__file__).parents[1] / "scripts" / "gwm-archiver.py"
spec = importlib.util.spec_from_file_location("gwm_archiver", SCRIPT)
gwm = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = gwm
spec.loader.exec_module(gwm)


class Response:
    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self):
        return b"ok"


class FlakyOpener:
    def __init__(self):
        self.attempts = 0

    def open(self, *_args, **_kwargs):
        self.attempts += 1
        if self.attempts == 1:
            raise URLError(OSError(-3, "Temporary failure in name resolution"))
        return Response()


class HttpGetTests(unittest.TestCase):
    def test_retries_transient_url_error(self):
        opener = FlakyOpener()
        original = gwm.OPENER
        gwm.OPENER = opener
        try:
            self.assertEqual(gwm.http_get("https://example.invalid"), "ok")
        finally:
            gwm.OPENER = original
        self.assertEqual(opener.attempts, 2)


if __name__ == "__main__":
    unittest.main()
