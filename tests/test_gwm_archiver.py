import contextlib
import http.client
import importlib.util
import io
import socket
import ssl
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch
from urllib.error import HTTPError, URLError


SCRIPT = Path(__file__).parents[1] / "scripts" / "gwm-archiver.py"
spec = importlib.util.spec_from_file_location("gwm_archiver", SCRIPT)
gwm = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = gwm
spec.loader.exec_module(gwm)


def dns_failure():
    return URLError(socket.gaierror(socket.EAI_AGAIN, "Temporary failure in name resolution"))


class Response(io.BytesIO):
    def __init__(self, body=b"ok", headers=None):
        super().__init__(body)
        self.headers = headers or {}


class HttpTests(unittest.TestCase):
    def setUp(self):
        self.opener = Mock()
        self.enterContext(patch.object(gwm, "OPENER", self.opener))
        self.sleep = self.enterContext(patch.object(gwm.time, "sleep"))
        self.enterContext(contextlib.redirect_stderr(io.StringIO()))
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))

    def test_get_recovers_after_three_dns_failures(self):
        self.opener.open.side_effect = [dns_failure(), dns_failure(), dns_failure(), Response()]
        self.assertEqual(gwm.http_get("https://example.invalid"), "ok")
        self.assertEqual(self.opener.open.call_count, 4)
        self.assertEqual([c.args[0] for c in self.sleep.call_args_list], [5, 15, 30])

    def test_retries_are_bounded(self):
        self.opener.open.side_effect = dns_failure()
        with self.assertRaises(URLError):
            gwm.http_get("https://example.invalid")
        self.assertEqual(self.opener.open.call_count, 4)

    def test_permanent_errors_are_not_retried(self):
        for error in [HTTPError("https://example.invalid", 403, "Forbidden", {}, None),
                      HTTPError("https://example.invalid", 404, "Not found", {}, None),
                      URLError(socket.gaierror(socket.EAI_NONAME, "No such host")),
                      URLError(ssl.SSLCertVerificationError("invalid certificate"))]:
            with self.subTest(error=error):
                self.opener.open.reset_mock()
                self.opener.open.side_effect = error
                with self.assertRaises(URLError):
                    gwm.http_get("https://example.invalid")
                self.assertEqual(self.opener.open.call_count, 1)

    def test_transient_http_error_is_retried(self):
        self.opener.open.side_effect = [HTTPError("https://example.invalid", 503, "Busy", {}, None), Response()]
        self.assertEqual(gwm.http_get("https://example.invalid"), "ok")

    def test_login_post_retries(self):
        self.opener.open.side_effect = [dns_failure(), Response()]
        cookie = Mock()
        cookie.name = "wordpress_logged_in_test"
        jar = Mock()
        jar.__iter__ = Mock(return_value=iter([cookie]))
        with patch.object(gwm, "JAR", jar):
            gwm.login("user", "password")
        self.assertEqual(self.opener.open.call_count, 2)
        self.assertEqual(self.opener.open.call_args.args[0].get_method(), "POST")

    def test_download_restarts_partial_body_from_byte_zero(self):
        interrupted = Response()
        interrupted.read = Mock(side_effect=[b"old-partial", ConnectionResetError()])
        self.opener.open.side_effect = [dns_failure(), interrupted, Response(b"complete")]
        dest = self.root / "article.pdf"
        self.assertEqual(gwm.http_post_stream("https://example.invalid", {}, dest), 8)
        self.assertEqual(dest.read_bytes(), b"complete")
        self.assertFalse(dest.with_suffix(".pdf.part").exists())

    def test_short_content_length_is_retried(self):
        self.opener.open.side_effect = [Response(b"short", {"Content-Length": "8"}), Response(b"complete")]
        dest = self.root / "article.pdf"
        gwm.http_post_stream("https://example.invalid", {}, dest)
        self.assertEqual(dest.read_bytes(), b"complete")
        self.assertEqual(self.opener.open.call_count, 2)

    def test_failed_transfer_preserves_existing_file_and_cleans_part(self):
        dest = self.root / "article.pdf"
        dest.write_bytes(b"existing")
        self.opener.open.side_effect = [Response(b"short", {"Content-Length": "8"}) for _ in range(4)]
        with self.assertRaises(http.client.IncompleteRead):
            gwm.http_post_stream("https://example.invalid", {}, dest)
        self.assertEqual(dest.read_bytes(), b"existing")
        self.assertFalse(dest.with_suffix(".pdf.part").exists())

    def test_full_issue_post_retries_and_uses_safe_filename(self):
        self.opener.open.side_effect = [dns_failure(), Response(b"pdf", {"Content-Disposition": 'attachment; filename="../../issue.pdf"'})]
        issue = gwm.Issue(752, "september-752", 2026, 9)
        with patch.object(gwm, "find_full_issue_slug", return_value="full-issue"), patch.object(gwm, "scrape_form", return_value=("1", "key", {})):
            result = gwm.download_full_issue(issue, self.root, 0)
        self.assertEqual(result, self.root / "2026" / "09_issue.pdf")
        self.assertEqual(result.read_bytes(), b"pdf")

    def test_empty_publisher_pdf_does_not_retry(self):
        self.opener.open.return_value = Response(b"")
        dest = self.root / "article.pdf"
        self.assertEqual(gwm.http_post_stream("https://example.invalid", {}, dest), 0)
        self.assertFalse(dest.exists())
        self.assertEqual(self.opener.open.call_count, 1)


class SweepTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.enterContext(patch.dict(gwm.os.environ, {
            "WT_USER": "test", "WT_PASS": "test", "OUT_ROOT": str(self.root),
            "ARCHIVE_MODE": "current", "LIMIT": "0", "DRY_RUN": "0"}))
        self.enterContext(patch.object(gwm.shutil, "which", return_value="/tool"))
        self.enterContext(patch.object(gwm, "login"))
        self.enterContext(patch.object(gwm, "list_issues", return_value=[
            (497, "june-497"), (641, "june-641"), (642, "july-642"), (752, "september-752")]))
        self.stderr = self.enterContext(contextlib.redirect_stderr(io.StringIO()))

    def test_current_never_calls_broken_archive_and_newest_is_first(self):
        seen = []
        def process(issue, *_):
            seen.append(issue.num)
            if issue.num < 642:
                raise dns_failure()
            return {"status": "downloaded"}
        with patch.object(gwm, "process_issue", side_effect=process):
            self.assertEqual(gwm.main(), 0)
        self.assertEqual(seen, [752, 642])
        self.assertIn("NEW_ISSUE: #752", self.stderr.getvalue())

    def test_backfill_is_separate_and_reprobes_missing_files(self):
        with patch.dict(gwm.os.environ, {"ARCHIVE_MODE": "backfill"}), patch.object(gwm, "process_issue", return_value={"status": "no-pdf"}) as process:
            self.assertEqual(gwm.main(), 0)
        self.assertEqual([c.args[0].num for c in process.call_args_list], [641, 497])

    def test_delivery_marker_survives_later_failure(self):
        with patch.object(gwm, "process_issue", side_effect=[{"status": "downloaded"}, dns_failure()]):
            self.assertEqual(gwm.main(), 1)
        self.assertIn("NEW_ISSUE: #752", self.stderr.getvalue())

    def test_missing_current_pdf_is_failure(self):
        with patch.object(gwm, "process_issue", return_value={"status": "no-pdf"}):
            self.assertEqual(gwm.main(), 1)

    def test_resumed_sidecar_emits_delivery_marker(self):
        with patch.object(gwm, "process_issue", return_value={"status": "sidecar-only"}):
            self.assertEqual(gwm.main(), 0)
        self.assertIn("NEW_ISSUE: #752", self.stderr.getvalue())

    def test_empty_index_is_not_success(self):
        with patch.object(gwm, "list_issues", return_value=[]):
            with self.assertRaisesRegex(RuntimeError, "no magazine issues"):
                gwm.main()

    def test_synthesis_does_not_misclassify_dns_as_publisher_gap(self):
        with patch.object(gwm, "article_slugs_in_order", return_value=["article"]), patch.object(gwm, "scrape_form", side_effect=dns_failure()):
            with self.assertRaises(URLError):
                gwm.synthesise_from_articles(gwm.Issue(497, "june-497", 2005, 6), self.root, 0)

    def test_failed_toc_preserves_pdf_without_publishing_sidecar(self):
        pdf = self.root / "issue.pdf"
        pdf.write_bytes(b"pdf")
        with patch.object(gwm, "existing_artifacts", return_value=(pdf, None)), patch.object(gwm, "article_slugs_in_order", return_value=["article"]), patch.object(gwm, "http_get", side_effect=dns_failure()):
            with self.assertRaises(URLError):
                gwm.process_issue(gwm.Issue(752, "september-752", 2026, 9), self.root, 0, False)
        self.assertTrue(pdf.exists())
        self.assertFalse(pdf.with_suffix(".json").exists())


if __name__ == "__main__":
    unittest.main()
