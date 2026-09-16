"""Exercise real audio -> HTTP ZIP, ordering, boundaries and scratch cleanup."""

import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile


source = Path(os.environ.get("YOTO_SERVER", "modules/nixos/services/yoto-share/server.py"))
spec = importlib.util.spec_from_file_location("yoto_server", source)
yoto = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = yoto
spec.loader.exec_module(yoto)


class LibraryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = tempfile.TemporaryDirectory()
        cls.audio = Path(cls.fixture.name) / "source.m4a"
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i",
                        "sine=frequency=400:duration=3", "-c:a", "aac", str(cls.audio)],
                       check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.fixture.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.library = self.root / "library"
        self.share = self.root / "share"
        self.scratch = self.root / "scratch"
        self.bookdir = self.library / "Author" / "A Book"
        self.bookdir.mkdir(parents=True)
        (self.share / "Music").mkdir(parents=True)
        self.andys_music = self.root / "AndysCollection"
        self.andys_music.mkdir()
        self.scratch.mkdir()
        self.audio_path = self.bookdir / "book.m4b"
        self.audio_path.write_bytes(self.audio.read_bytes())
        self.app = yoto.create_app(self.library, self.share, str(self.scratch), self.andys_music)
        self.app.testing = True
        self.client = self.app.test_client()

    def link(self):
        book = yoto.plan_book(self.bookdir, [self.audio_path])
        return f"/cards/Author/A%20Book/0.zip?v={book.version}"

    def test_catalogue_search_and_new_books_are_automatic(self):
        self.assertIn(b"Audiobooks", self.client.get("/").data)
        self.assertIn(b"Author", self.client.get("/Books/").data)
        self.assertIn(b"Download Card A", self.client.get("/Books/Author/A%20Book/").data)
        self.assertIn(b"A Book", self.client.get("/Books/?q=a+book").data)
        new = self.library / "New Author" / "New Book"
        new.mkdir(parents=True)
        (new / "audio.mp3").write_bytes(b"new book")
        self.assertIn(b"New Book", self.client.get("/Books/?q=new").data)

    def test_download_is_valid_audio_and_leaves_no_second_copy(self):
        before = {str(p): p.stat().st_size for p in self.library.rglob("*") if p.is_file()}
        response = self.client.get(self.link())
        self.assertEqual(response.status_code, 200)
        self.assertIn("attachment", response.headers["Content-Disposition"])
        self.assertEqual(response.headers["Accept-Ranges"], "none")
        with zipfile.ZipFile(io.BytesIO(response.data)) as archive:
            self.assertIsNone(archive.testzip())
            audio = [n for n in archive.namelist() if n.endswith(".m4a")]
            self.assertEqual(len(audio), 1)
            track = self.root / "download.m4a"
            track.write_bytes(archive.read(audio[0]))
            info = yoto.prep.probe(str(track))
            self.assertAlmostEqual(float(info["format"]["duration"]), 3, delta=.1)
            subprocess.run(["ffmpeg", "-v", "error", "-i", str(track), "-f", "null", "-"],
                           check=True, capture_output=True)
        self.assertEqual(list(self.scratch.iterdir()), [])
        self.assertEqual(before, {str(p): p.stat().st_size for p in self.library.rglob("*") if p.is_file()})
        self.assertEqual(list(self.share.rglob("*.zip")), [])

    def test_multi_file_book_uses_natural_order_without_overwriting(self):
        self.audio_path.unlink()
        for name in ["10.m4a", "2.m4a", "1.m4a"]:
            (self.bookdir / name).write_bytes(self.audio.read_bytes())
        sources = yoto.children(self.library, self.bookdir)
        book = yoto.plan_book(self.bookdir, sources)
        self.assertEqual([t.source.name for t in book.cards[0]], ["1.m4a", "2.m4a", "10.m4a"])
        data = b"".join(yoto.card_zip(book, 0, str(self.scratch)))
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            tracks = [n for n in archive.namelist() if n.endswith(".m4a")]
            self.assertEqual(len(tracks), 3)
            self.assertEqual(len(set(tracks)), 3)

    def test_disconnect_and_source_change_clean_scratch(self):
        book = yoto.plan_book(self.bookdir, [self.audio_path])
        stream = yoto.card_zip(book, 0, str(self.scratch))
        next(stream)
        next(stream)
        self.assertTrue(list(self.scratch.iterdir()))
        stream.close()
        self.assertEqual(list(self.scratch.iterdir()), [])
        self.audio_path.touch()
        stream = yoto.card_zip(book, 0, str(self.scratch))
        first = next(stream)
        with self.assertRaisesRegex(RuntimeError, "Source changed"):
            b"".join(stream)
        with self.assertRaises(zipfile.BadZipFile):
            zipfile.ZipFile(io.BytesIO(first))
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_download_limit_is_released_after_cancel(self):
        link = self.link()
        first = self.client.get(link, buffered=False)
        second = self.client.get(link, buffered=False)
        self.assertEqual(self.client.get(link).status_code, 503)
        first.close()
        third = self.client.get(link, buffered=False)
        self.assertEqual(third.status_code, 200)
        second.close()
        third.close()
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_head_range_and_stale_links(self):
        link = self.link()
        with patch.object(yoto.prep, "cut", side_effect=AssertionError("HEAD generated audio")):
            self.assertEqual(self.client.head(link).status_code, 200)
        self.assertEqual(self.client.get(link, headers={"Range": "bytes=0-9"}).status_code, 416)
        self.audio_path.touch()
        self.assertEqual(self.client.get(link).status_code, 409)

    def test_traversal_symlinks_metadata_and_writes_are_denied(self):
        (self.library / "escape").symlink_to(self.root)
        (self.bookdir / "metadata.json").write_text('{"private":true}')
        (self.library / "<img src=x onerror=alert(1)>").mkdir()
        listing = self.client.get("/Books/").data
        self.assertNotIn(b"<img src=x", listing)
        self.assertIn(b"&lt;img", listing)
        for path in ["/Books/../", "/Books/%2e%2e/", "/Books/escape/", "/Books/.hidden/",
                     "/Books/Author/A%20Book/metadata.json", "/Music/../../library/"]:
            with self.subTest(path=path):
                self.assertEqual(self.client.get(path).status_code, 404)
        for method in ["post", "put", "delete"]:
            self.assertEqual(getattr(self.client, method)("/Books/").status_code, 405)

    def test_music_links_still_download(self):
        (self.share / "Music" / "song.mp3").write_bytes(b"music")
        response = self.client.get("/Music/song.mp3")
        self.assertEqual(response.data, b"music")
        self.assertIn("attachment", response.headers["Content-Disposition"])
        response.close()

    def test_music_album_zip_is_generated_without_stored_archive(self):
        album = self.share / "Music" / "Artist" / "Album"
        album.mkdir(parents=True)
        (album / "01 Song.m4a").write_bytes(self.audio.read_bytes())
        (album / "02 Song.m4a").write_bytes(self.audio.read_bytes())
        (album / "cratedigger.json").write_text('{"private": true}')
        page = self.client.get("/Music/Artist/Album/")
        self.assertIn(b"Download album", page.data)
        self.assertNotIn(b"cratedigger.json", page.data)
        book = yoto.plan_book(album, sorted(album.glob("*.m4a")))
        response = self.client.get(f"/music-cards/Artist/Album/0.zip?v={book.version}")
        self.assertEqual(response.status_code, 200)
        with zipfile.ZipFile(io.BytesIO(response.data)) as archive:
            self.assertIsNone(archive.testzip())
            self.assertEqual(len([n for n in archive.namelist() if n.endswith('.m4a')]), 2)
        self.assertEqual(list(album.glob("*.zip")), [])
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_unfinished_import_sibling_is_not_a_track(self):
        (self.bookdir / "book.tmp.m4b").write_bytes(b"")
        page = self.client.get("/Books/Author/A%20Book/")
        self.assertEqual(page.status_code, 200)
        self.assertIn(b"Download Card A", page.data)
        self.assertNotIn(b"book.tmp", page.data)

    def test_andys_music_searches_artists_albums_and_tracks_separately(self):
        album = self.andys_music / "Favourite Artist" / "2020 - Rare Album"
        album.mkdir(parents=True)
        (album / "01 Hidden Gem.m4a").write_bytes(self.audio.read_bytes())
        self.assertIn(b"Andy's music", self.client.get("/").data)
        for query in ("favourite", "rare album", "hidden gem", "rare favourite"):
            with self.subTest(query=query):
                result = self.client.get("/AndysMusic/", query_string={"q": query})
                self.assertIn(b"2020 - Rare Album", result.data)
                self.assertIn(b'/AndysMusic/Favourite%20Artist/', result.data)
                self.assertIn(b'action="/AndysMusic/"', result.data)
        self.assertNotIn(b"Rare Album", self.client.get("/Music/?q=rare").data)
        self.assertNotIn(b"Rare Album", self.client.get("/Books/?q=rare").data)

    def test_andys_music_converts_opus_preserves_sources_and_orders_discs(self):
        album = self.andys_music / "Artist" / "Album"
        album.mkdir(parents=True)
        for filename, disc, track, title in [
            ("01 Alpha.opus", 2, 1, "Disc two opener"),
            ("02 Zulu.opus", 1, 2, "Disc one finale"),
            ("01 Zulu.opus", 1, 1, "Disc one opener"),
        ]:
            subprocess.run(["ffmpeg", "-v", "error", "-i", str(self.audio),
                            "-c:a", "libopus", "-metadata", f"disc={disc}",
                            "-metadata", f"track={track}", "-metadata", f"title={title}",
                            str(album / filename)], check=True, capture_output=True)
        before = {p.name: p.read_bytes() for p in album.iterdir()}
        sources = sorted(album.glob("*.opus"))
        book = yoto.plan_book(album, sources, music=True)
        page = self.client.get("/AndysMusic/Artist/Album/")
        self.assertIn(b"Download album", page.data)
        self.assertIn(b"Disc one opener", page.data)
        response = self.client.get(f"/andys-music-cards/Artist/Album/0.zip?v={book.version}")
        self.assertEqual(response.status_code, 200)
        with zipfile.ZipFile(io.BytesIO(response.data)) as archive:
            self.assertIsNone(archive.testzip())
            tracks = [n for n in archive.namelist() if n.endswith(".m4a")]
            self.assertEqual([Path(n).name for n in tracks], [
                "001 - Disc one opener.m4a", "002 - Disc one finale.m4a", "003 - Disc two opener.m4a"])
            for n in tracks:
                p = self.root / Path(n).name
                p.write_bytes(archive.read(n))
                info = yoto.prep.probe(str(p))
                self.assertEqual(info["streams"][0]["codec_name"], "aac")
                subprocess.run(["ffmpeg", "-v", "error", "-i", str(p), "-f", "null", "-"],
                               check=True, capture_output=True)
        self.assertEqual(before, {p.name: p.read_bytes() for p in album.iterdir()})
        self.assertEqual(list(self.scratch.iterdir()), [])
        self.assertEqual(list((self.share / "Music").iterdir()), [])

    def test_andys_music_denies_source_files_symlinks_and_mutations(self):
        (self.andys_music / "escape").symlink_to(self.library)
        (self.andys_music / "metadata.json").write_text("private")
        (self.andys_music / "book.m4a").write_bytes(self.audio.read_bytes())
        for path in ("/AndysMusic/../", "/AndysMusic/escape/", "/AndysMusic/book.m4a",
                     "/AndysMusic/metadata.json", "/andys-music-cards/../Artist/0.zip?v=x"):
            with self.subTest(path=path):
                self.assertEqual(self.client.get(path).status_code, 404)
        for method in ("post", "put", "delete"):
            self.assertEqual(getattr(self.client, method)("/AndysMusic/").status_code, 405)
        self.assertNotIn(b"Author", self.client.get("/AndysMusic/?q=author").data)

    def test_music_search_refreshes_without_copying_media(self):
        with patch.object(yoto.time, "monotonic", return_value=1):
            self.assertNotIn(b"New Artist", self.client.get("/AndysMusic/?q=new").data)
        album = self.andys_music / "New Artist" / "New Album"
        album.mkdir(parents=True)
        (album / "song.m4a").write_bytes(self.audio.read_bytes())
        with patch.object(yoto.time, "monotonic", return_value=62):
            self.assertIn(b"New Artist", self.client.get("/AndysMusic/?q=new").data)

    def test_optional_andys_library_is_hidden_when_unconfigured(self):
        app = yoto.create_app(self.library, self.share, str(self.scratch))
        client = app.test_client()
        self.assertNotIn(b"Andy's music", client.get("/").data)
        self.assertEqual(client.get("/AndysMusic/").status_code, 404)

    def test_health_checks_andys_read_only_mount(self):
        self.andys_music.rmdir()
        with self.assertLogs("yoto", level="ERROR"):
            self.assertEqual(self.client.get("/healthz").status_code, 503)

    def test_track_and_card_limits_use_mixed_source_sizes(self):
        # Synthetic long metadata exercises packing without generating hours of audio.
        info = {"streams": [{"codec_type": "audio", "codec_name": "aac"}],
                "format": {"duration": 12 * 3600}, "chapters": [
                    {"start_time": 0, "end_time": 12 * 3600, "tags": {"title": "Long chapter"}}]}
        with patch.object(yoto, "source_info", return_value=info):
            book = yoto.plan_book(self.bookdir, [self.audio_path])
        self.assertGreaterEqual(len(book.cards), 3)
        self.assertAlmostEqual(sum(t.duration for c in book.cards for t in c), 12 * 3600)
        for card in book.cards:
            self.assertLessEqual(len(card), 100)
            self.assertLessEqual(sum(t.duration for t in card), 5 * 3600)
            self.assertLessEqual(sum(t.estimated_bytes for t in card), yoto.CARD_BYTES)
            self.assertTrue(all(t.duration <= 58 * 60 for t in card))

    def test_health_reports_missing_source_mount(self):
        self.assertEqual(self.client.get("/healthz").status_code, 200)
        self.library.rename(self.root / "gone")
        with self.assertLogs("yoto", level="ERROR"):
            self.assertEqual(self.client.get("/healthz").status_code, 503)


if __name__ == "__main__":
    unittest.main()
