"""Behaviour contracts for remote ebook import and retry boundaries."""

import importlib.util
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("bridge", Path(__file__).parents[1] / "shelfarr-calibre.py")
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class ImportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.file = self.root / "a book.epub"
        self.file.write_bytes(b"fixture content")
        self.book = {"id": 7, "title": "A Book", "author": "Author", "file_path": "/ebooks/a book.epub"}
        self.db = sqlite3.connect(":memory:")
        self.addCleanup(self.db.close)

    @patch.object(bridge, "scan_komga")
    @patch.object(bridge, "calibre")
    def test_success_preserves_original_and_second_run_skips_bytes(self, calibre, scan):
        self.assertEqual(bridge.import_books([self.book], self.root, self.db), 0)
        self.assertEqual(self.file.read_bytes(), b"fixture content")
        self.assertIn("ignore", calibre.call_args.args)
        with patch.object(bridge, "snapshot", side_effect=AssertionError("unchanged file read again")):
            self.assertEqual(bridge.import_books([self.book], self.root, self.db), 0)
        calibre.assert_called_once()
        scan.assert_called_once()

    @patch.object(bridge, "scan_komga")
    @patch.object(bridge, "calibre")
    def test_import_failure_is_not_receipted_and_retries(self, calibre, scan):
        calibre.side_effect = RuntimeError("server unavailable")
        self.assertEqual(bridge.import_books([self.book], self.root, self.db), 1)
        self.assertEqual(self.db.execute("SELECT count(*) FROM imports").fetchone()[0], 0)
        scan.assert_not_called()
        calibre.side_effect = None
        self.assertEqual(bridge.import_books([self.book], self.root, self.db), 0)
        self.assertEqual(calibre.call_count, 2)

    @patch.object(bridge, "scan_komga")
    @patch.object(bridge, "calibre")
    def test_scan_failure_retries_without_reimporting(self, calibre, scan):
        scan.side_effect = RuntimeError("Komga unavailable")
        with self.assertRaisesRegex(RuntimeError, "Komga unavailable"):
            bridge.import_books([self.book], self.root, self.db)
        scan.side_effect = None
        self.assertEqual(bridge.import_books([self.book], self.root, self.db), 0)
        calibre.assert_called_once()
        self.assertEqual(scan.call_count, 2)

    @patch.object(bridge, "scan_komga")
    @patch.object(bridge, "calibre")
    def test_changed_file_gets_a_new_receipt(self, calibre, scan):
        bridge.import_books([self.book], self.root, self.db)
        self.file.write_bytes(b"different ebook content")
        bridge.import_books([self.book], self.root, self.db)
        self.assertEqual(calibre.call_count, 2)

    def test_outside_and_root_paths_are_rejected(self):
        for path in ["/audiobooks/a.epub", "/ebooks/../a.epub", "/ebooks"]:
            with self.subTest(path=path), self.assertRaises(ValueError):
                bridge.book_files(self.root, path)

    def test_symlink_file_and_parent_are_rejected(self):
        (self.root / "link.epub").symlink_to(self.file)
        (self.root / "linkdir").symlink_to(self.root, target_is_directory=True)
        for source in [self.root / "link.epub", self.root / "linkdir/a book.epub"]:
            with self.subTest(source=source), self.assertRaises(OSError):
                bridge.snapshot(self.root, source, self.root / "snapshot.epub")

    def test_empty_ebook_is_rejected(self):
        self.file.write_bytes(b"")
        with self.assertRaises(ValueError):
            bridge.snapshot(self.root, self.file, self.root / "snapshot.epub")

    def test_read_only_wal_reader_selects_only_acquired_unreserved_ebooks(self):
        database = self.root / "shelfarr.sqlite3"
        with sqlite3.connect(database) as writer:
            writer.execute("PRAGMA journal_mode=WAL")
            writer.execute("CREATE TABLE books (id, title, author, file_path, book_type, acquisition_reservation_token)")
            writer.executemany("INSERT INTO books VALUES (?, 'Title', 'Author', ?, ?, ?)", [
                (1, "/ebooks/a.epub", 1, None), (2, None, 1, None),
                (3, "/audiobooks/a.m4b", 0, None), (4, "/ebooks/b.epub", 1, "reserved"),
            ])
            writer.commit()
            self.assertEqual([b["id"] for b in bridge.acquired_books(database)], [1])

    def test_startup_missing_wal_is_retried_but_schema_errors_are_not(self):
        missing = sqlite3.OperationalError("unable to open database file")
        missing.sqlite_errorcode = sqlite3.SQLITE_CANTOPEN
        schema = sqlite3.OperationalError("no such column")
        schema.sqlite_errorcode = sqlite3.SQLITE_ERROR
        with patch.object(bridge.sqlite3, "connect", side_effect=[missing, schema]) as connect:
            with patch.object(bridge.time, "sleep") as sleep:
                with self.assertRaisesRegex(sqlite3.OperationalError, "no such column"):
                    bridge.acquired_books(self.root / "database")
        self.assertEqual(connect.call_count, 2)
        sleep.assert_called_once_with(1)


if __name__ == "__main__":
    unittest.main()
