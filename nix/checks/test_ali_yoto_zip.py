from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
import time
import unittest
import zipfile
from pathlib import Path


SCRIPT = Path(os.environ["ALI_YOTO_ZIP"])
SPEC = importlib.util.spec_from_file_location("ali_yoto_zip", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class AliYotoZipTests(unittest.TestCase):
    def test_reconcile_creates_one_yoto_archive_per_album_atomically(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            library = Path(tmp)
            album = library / "Artist" / "2026 - Album"
            album.mkdir(parents=True)
            (album / "01 Song.mp3").write_bytes(b"first")
            (album / "02 Song.m4a").write_bytes(b"second")
            (album / "cover.jpg").write_bytes(b"cover")
            (album / "notes.txt").write_text("not published", encoding="utf-8")

            result = MODULE.reconcile_library(library)

            archive = album / "2026 - Album.zip"
            self.assertEqual(
                result,
                MODULE.ReconcileResult(created=1, refreshed=0, unchanged=0, removed=0),
            )
            self.assertTrue(archive.is_file())
            self.assertFalse(any(album.glob("*.partial")))
            with zipfile.ZipFile(archive) as handle:
                self.assertEqual(
                    handle.namelist(),
                    [
                        "2026 - Album/01 Song.mp3",
                        "2026 - Album/02 Song.m4a",
                        "2026 - Album/cover.jpg",
                    ],
                )
                self.assertTrue(handle.testzip() is None)

    def test_reconcile_is_content_idempotent_and_refreshes_changed_audio(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            library = Path(tmp)
            album = library / "Artist" / "Album"
            album.mkdir(parents=True)
            track = album / "01 Song.mp3"
            track.write_bytes(b"first")

            MODULE.reconcile_library(library)
            archive = album / "Album.zip"
            first_mtime = archive.stat().st_mtime_ns

            unchanged = MODULE.reconcile_library(library)
            self.assertEqual(
                unchanged,
                MODULE.ReconcileResult(created=0, refreshed=0, unchanged=1, removed=0),
            )
            self.assertEqual(archive.stat().st_mtime_ns, first_mtime)

            time.sleep(0.01)
            track.write_bytes(b"updated")
            os.utime(track, None)
            refreshed = MODULE.reconcile_library(library)

            self.assertEqual(
                refreshed,
                MODULE.ReconcileResult(created=0, refreshed=1, unchanged=0, removed=0),
            )
            self.assertGreater(archive.stat().st_mtime_ns, first_mtime)
            with zipfile.ZipFile(archive) as handle:
                self.assertEqual(handle.read("Album/01 Song.mp3"), b"updated")

    def test_reconcile_ignores_non_album_directories_and_symlinked_audio(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            library = Path(tmp)
            empty = library / "Artist" / "Empty"
            empty.mkdir(parents=True)
            outside = library / "outside.mp3"
            outside.write_bytes(b"outside")
            (empty / "01 Escape.mp3").symlink_to(outside)

            result = MODULE.reconcile_library(library)

            self.assertEqual(
                result,
                MODULE.ReconcileResult(created=0, refreshed=0, unchanged=0, removed=0),
            )
            self.assertFalse((empty / "Empty.zip").exists())

    def test_reconcile_removes_only_owned_archive_after_album_tracks_move(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            library = Path(tmp)
            owned_album = library / "Artist" / "Owned"
            foreign_album = library / "Artist" / "Foreign"
            owned_album.mkdir(parents=True)
            foreign_album.mkdir(parents=True)
            owned_track = owned_album / "01 Song.mp3"
            foreign_track = foreign_album / "01 Song.mp3"
            owned_track.write_bytes(b"owned")
            foreign_track.write_bytes(b"foreign")

            MODULE.reconcile_library(library)
            owned_archive = owned_album / "Owned.zip"
            foreign_archive = foreign_album / "Foreign.zip"
            with zipfile.ZipFile(foreign_archive, "a") as handle:
                handle.comment = b"not-owned-by-ali-yoto"
            owned_track.unlink()
            foreign_track.unlink()

            result = MODULE.reconcile_library(library)

            self.assertEqual(
                result,
                MODULE.ReconcileResult(created=0, refreshed=0, unchanged=0, removed=1),
            )
            self.assertFalse(owned_archive.exists())
            self.assertTrue(foreign_archive.exists())


if __name__ == "__main__":
    unittest.main()
