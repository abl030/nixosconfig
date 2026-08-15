import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).parents[1] / "scripts" / "komga-sync.py"
spec = importlib.util.spec_from_file_location("komga_sync", SCRIPT)
komga_sync = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(komga_sync)


class KomgaSyncScanTests(unittest.TestCase):
    def test_selects_only_libraries_containing_sidecars(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sidecar = root / "GAW" / "2026" / "08.json"
            sidecar.parent.mkdir(parents=True)
            sidecar.write_text("{}")

            libraries = [
                {"id": "gaw", "root": f"file:{root}/GAW/"},
                {"id": "books", "root": "file:/mnt/data/Books/"},
            ]

            self.assertEqual(
                komga_sync.library_ids_for_sidecars([sidecar], libraries),
                ["gaw"],
            )

    def test_scans_then_reloads_until_new_book_is_indexed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sidecar = root / "GAW" / "2026" / "08.json"
            sidecar.parent.mkdir(parents=True)
            sidecar.write_text("{}")
            pdf_url = str(sidecar.with_suffix(".pdf"))
            calls = []
            listings = iter(
                [
                    {"content": [], "last": True},
                    {"content": [{"id": "new", "url": pdf_url}], "last": True},
                ]
            )

            def fake_http(method, path, body=None):
                calls.append((method, path))
                if method == "POST":
                    return 202, None
                return 200, next(listings)

            old_http = komga_sync.http
            try:
                komga_sync.http = fake_http
                missing = komga_sync.refresh_book_index(
                    [sidecar],
                    [{"id": "gaw", "root": f"file:{root}/GAW/"}],
                    attempts=2,
                    delay=0,
                )
            finally:
                komga_sync.http = old_http

            self.assertEqual(missing, [])
            self.assertEqual(calls[0], ("POST", "/api/v1/libraries/gaw/scan"))

    def test_failed_scan_request_is_propagated(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sidecar = root / "GAW" / "2026" / "08.json"
            sidecar.parent.mkdir(parents=True)
            sidecar.write_text("{}")

            def fake_http(method, path, body=None):
                self.assertEqual(method, "POST")
                return 500, None

            old_http = komga_sync.http
            try:
                komga_sync.http = fake_http
                with self.assertRaisesRegex(RuntimeError, "scan request failed.*gaw.*500"):
                    komga_sync.refresh_book_index(
                        [sidecar],
                        [{"id": "gaw", "root": f"file:{root}/GAW/"}],
                        attempts=1,
                        delay=0,
                    )
            finally:
                komga_sync.http = old_http

    def test_main_aborts_when_pdfs_remain_absent_after_polling(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sidecar = root / "GAW" / "2026" / "08.json"
            sidecar.parent.mkdir(parents=True)
            sidecar.write_text("{}")
            sidecar.with_suffix(".pdf").write_bytes(b"pdf")

            with (
                mock.patch.object(komga_sync, "API_KEY", "test-key"),
                mock.patch.object(komga_sync, "SIDECAR_ROOT", root),
                mock.patch.object(komga_sync, "DRY_RUN", False),
                mock.patch.object(
                    komga_sync,
                    "get",
                    return_value=(200, [{"id": "gaw", "root": f"file:{root}/GAW/"}]),
                ),
                mock.patch.object(komga_sync, "ensure_hashkoreader"),
                mock.patch.object(
                    komga_sync, "refresh_book_index", return_value=[sidecar]
                ),
                mock.patch.object(komga_sync, "sync_book") as sync_book,
            ):
                result = komga_sync.main()

            self.assertNotEqual(result, 0)
            sync_book.assert_not_called()


if __name__ == "__main__":
    unittest.main()
