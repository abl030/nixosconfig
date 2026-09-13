"""Exercise the installed probe against Kopia's two distinct HTTP schemas."""

import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


def source(errors=329):
    return {
        "source": {"host": "kopia", "userName": "root", "path": "/Music/with spaces"},
        "lastSnapshot": {"stats": {"errorCount": errors}},
    }


def snapshot(day, errors):
    # /snapshots returns summary.numFailed. There is no stats field.
    return {"endTime": f"2026-09-{day:02d}T00:00:00Z", "summary": {"numFailed": errors}}


class ProbeTest(unittest.TestCase):
    def setUp(self):
        self.sources = {"sources": [source()]}
        self.history = {"snapshots": [snapshot(12, 329), snapshot(13, 329)]}
        self.http_status = 200
        self.requests = []
        case = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                parsed = urlsplit(self.path)
                case.requests.append((parsed.path, parse_qs(parsed.query)))
                body = case.sources if parsed.path.endswith("/sources") else case.history
                data = body.encode() if isinstance(body, str) else json.dumps(body).encode()
                self.send_response(case.http_status)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *_args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.temp = tempfile.TemporaryDirectory()
        self.auth = Path(self.temp.name) / "auth.env"
        self.auth.write_text("KOPIA_SERVER_USER=test\nKOPIA_SERVER_PASSWORD=fixture\n")

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def run_probe(self):
        return subprocess.run(
            [os.environ["KOPIA_BACKUP_PROBE"]],
            env={
                **os.environ,
                "KOPIA_AUTH_FILE": str(self.auth),
                "KOPIA_BASE_URL": f"http://127.0.0.1:{self.server.server_port}",
            },
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )

    def test_consecutive_failures_are_unhealthy(self):
        result = self.run_probe()
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn("two consecutive error snapshots", result.stderr)
        self.assertEqual(
            self.requests[-1][1],
            {"host": ["kopia"], "userName": ["root"], "path": ["/Music/with spaces"]},
        )

    def test_clean_sources_need_no_history(self):
        self.sources = {"sources": [source(0)]}
        result = self.run_probe()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.requests), 1)

    def test_one_transient_error_is_healthy(self):
        self.history = {"snapshots": [snapshot(12, 0), snapshot(13, 329)]}
        result = self.run_probe()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("previous was clean", result.stderr)

    def test_one_snapshot_is_not_consecutive(self):
        self.history = {"snapshots": [snapshot(13, 329)]}
        result = self.run_probe()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("only one snapshot", result.stderr)

    def test_history_is_sorted_before_selecting_latest_two(self):
        self.history = {"snapshots": [snapshot(13, 2), snapshot(11, 0), snapshot(12, 2)]}
        result = self.run_probe()
        self.assertNotEqual(result.returncode, 0, result.stderr)

    def test_malformed_sources_never_report_healthy(self):
        for body in ["not json", {}, {"sources": []}, {"sources": [None]}]:
            with self.subTest(body=body):
                self.sources = body
                self.assertNotEqual(self.run_probe().returncode, 0)

    def test_missing_or_invalid_source_error_count_is_unknown(self):
        for value in [None, "0", -1, 0.5]:
            with self.subTest(value=value):
                self.sources = {"sources": [source(value)]}
                self.assertNotEqual(self.run_probe().returncode, 0)
        self.sources = {"sources": [source()]}
        del self.sources["sources"][0]["lastSnapshot"]
        self.assertNotEqual(self.run_probe().returncode, 0)

    def test_malformed_history_never_report_healthy(self):
        for body in ["not json", {}, {"snapshots": []}, {"snapshots": [None]}]:
            with self.subTest(body=body):
                self.history = body
                self.assertNotEqual(self.run_probe().returncode, 0)

    def test_wrong_history_schema_is_unknown(self):
        self.history = {
            "snapshots": [
                {"endTime": "2026-09-13T00:00:00Z", "stats": {"errorCount": 0}}
            ]
        }
        result = self.run_probe()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("backup health unknown", result.stderr)

    def test_missing_or_invalid_history_count_is_unknown(self):
        for value in [None, "0", -1, 0.5]:
            with self.subTest(value=value):
                self.history = {"snapshots": [snapshot(12, 329), snapshot(13, value)]}
                self.assertNotEqual(self.run_probe().returncode, 0)

    def test_invalid_history_time_is_unknown(self):
        self.history["snapshots"][0]["endTime"] = None
        self.assertNotEqual(self.run_probe().returncode, 0)

    def test_http_failure_is_not_a_healthy_json_response(self):
        self.sources = {"sources": [source(0)]}
        self.http_status = 500
        self.assertNotEqual(self.run_probe().returncode, 0)

    def test_any_bad_source_makes_the_probe_fail(self):
        clean = copy.deepcopy(source(0))
        clean["source"]["path"] = "/clean"
        self.sources = {"sources": [clean, source()]}
        self.assertNotEqual(self.run_probe().returncode, 0)


if __name__ == "__main__":
    unittest.main()
