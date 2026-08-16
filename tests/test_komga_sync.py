import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).parents[1] / "scripts" / "komga-sync.py"
spec = importlib.util.spec_from_file_location("komga_sync", SCRIPT)
komga_sync = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(komga_sync)


def make_sidecar(root: Path, relative: str, side: dict | None = None) -> Path:
    sidecar = root / relative
    sidecar.parent.mkdir(parents=True, exist_ok=True)
    sidecar.write_text(json.dumps(side or {}))
    return sidecar


def libraries_for(root: Path) -> list[dict]:
    """Roots exactly as the live Komga instance reports them: bare paths."""
    return [
        {"id": "gaw", "name": "GAW", "root": f"{root}/GAW"},
        {"id": "wvj", "name": "WVJ", "root": f"{root}/WVJ"},
    ]


class FakeKomga:
    """Stand-in for the slice of Komga's REST API that komga-sync drives.

    Book ids are the PDF stem, so assertions read like the archive does.
    """

    def __init__(self, indexed=(), arrives=None, scan_status=202, libraries=()):
        self.indexed = {str(url) for url in indexed}
        # {url: book-list reloads to wait through before Komga returns it}
        self.arrives = {str(url): after for url, after in (arrives or {}).items()}
        self.scan_status = scan_status
        self.libraries = list(libraries)
        self.scans: list[str] = []
        self.listings = 0
        self.calls: list[tuple[str, str]] = []

    def http(self, method, path, body=None):
        self.calls.append((method, path))
        if method == "GET" and path == "/api/v1/libraries":
            return 200, self.libraries
        if method == "POST" and path.endswith("/scan"):
            self.scans.append(path.rsplit("/", 2)[1])
            return self.scan_status, None
        if method == "GET" and path.startswith("/api/v1/books?"):
            self.listings += 1
            for url, after in list(self.arrives.items()):
                if self.listings > after:
                    self.indexed.add(url)
                    del self.arrives[url]
            content = [
                {"id": Path(url).stem, "url": url} for url in sorted(self.indexed)
            ]
            return 200, {"content": content, "last": True}
        if method == "GET" and path.startswith("/api/v1/books/"):
            return 200, {"id": path.split("/")[4], "seriesId": "s1", "metadata": {}}
        if method == "GET" and path.startswith("/api/v1/series/"):
            return 200, {"metadata": {}}
        if method == "PATCH" and "/metadata" in path:
            return 204, None
        raise AssertionError(f"unexpected request: {method} {path}")


class FakeClock:
    """Deterministic time, so the bounded wait is asserted and not slept."""

    def __init__(self):
        self.now = 0.0
        self.sleeps: list[float] = []

    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)
        self.now += seconds

    def monotonic(self) -> float:
        return self.now


class KomgaSyncTestCase(unittest.TestCase):
    def setUp(self):
        # The book index is module-level state; keep tests independent.
        komga_sync._book_cache.clear()
        komga_sync._book_cache_loaded = False


class LibraryMappingTests(KomgaSyncTestCase):
    def test_maps_sidecars_to_bare_absolute_library_roots(self):
        """Live Komga reports `/mnt/magazines/GAW`, not a `file:` URI."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sidecar = make_sidecar(root, "GAW/2026/08.json")

            libraries = [
                {"id": "gaw", "name": "GAW", "root": f"{root}/GAW"},
                {"id": "books", "name": "Books", "root": "/mnt/data/Books"},
            ]

            mapped, unmapped = komga_sync.map_sidecars_to_libraries(
                [sidecar], libraries
            )
            self.assertEqual(mapped, {sidecar: "gaw"})
            self.assertEqual(unmapped, [])

    def test_maps_sidecars_to_file_uri_library_roots(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sidecar = make_sidecar(root, "GAW/2026/08.json")

            libraries = [
                {"id": "gaw", "name": "GAW", "root": f"file://{root}/GAW/"},
                {"id": "books", "name": "Books", "root": "file:/mnt/data/Books/"},
            ]

            mapped, unmapped = komga_sync.map_sidecars_to_libraries(
                [sidecar], libraries
            )
            self.assertEqual(mapped, {sidecar: "gaw"})
            self.assertEqual(unmapped, [])

    def test_reports_sidecar_under_no_configured_library(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sidecar = make_sidecar(root, "XYZ/2026/08.json")

            mapped, unmapped = komga_sync.map_sidecars_to_libraries(
                [sidecar], [{"id": "gaw", "name": "GAW", "root": f"{root}/GAW"}]
            )
            self.assertEqual(mapped, {})
            self.assertEqual(unmapped, [sidecar])


class PdfPathTests(KomgaSyncTestCase):
    def test_pdf_path_derivation_honours_pdf_filename(self):
        """The pre-scan gate and sync_book must agree on the file Komga needs."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sidecar = make_sidecar(
                root, "GAW/2026/08.json", {"pdf_filename": "08_GW_AUG_2026-WEB.pdf"}
            )
            expected = sidecar.with_name("08_GW_AUG_2026-WEB.pdf")

            # Gate: reads the sidecar off disk itself.
            self.assertEqual(komga_sync.pdf_path_for(sidecar), expected)
            # sync_book: passes the sidecar it already parsed. Same answer.
            self.assertEqual(
                komga_sync.pdf_path_for(sidecar, {"pdf_filename": expected.name}),
                expected,
            )

    def test_pdf_path_falls_back_to_the_sidecar_stem(self):
        with tempfile.TemporaryDirectory() as tmp:
            sidecar = Path(tmp) / "08.json"
            sidecar.write_text("{ this is not json")
            self.assertEqual(
                komga_sync.pdf_path_for(sidecar), sidecar.with_suffix(".pdf")
            )
            self.assertEqual(
                komga_sync.pdf_path_for(sidecar, {}), sidecar.with_suffix(".pdf")
            )

    def test_pdf_path_ignores_directory_components(self):
        with tempfile.TemporaryDirectory() as tmp:
            sidecar = Path(tmp) / "08.json"
            sidecar.write_text("{}")
            self.assertEqual(
                komga_sync.pdf_path_for(sidecar, {"pdf_filename": "../../etc/x.pdf"}),
                sidecar.with_name("x.pdf"),
            )

    def test_sync_book_resolves_the_shared_pdf_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            sidecar = Path(tmp) / "08.json"
            sidecar.write_text(json.dumps({"pdf_filename": "08_GW_AUG_2026-WEB.pdf"}))

            with mock.patch.object(
                komga_sync, "find_book_id", return_value=None
            ) as find_book_id:
                result, msg = komga_sync.sync_book(sidecar, "GAW")

            self.assertEqual(result, "err")
            find_book_id.assert_called_once_with(
                str(sidecar.with_name("08_GW_AUG_2026-WEB.pdf"))
            )
            self.assertIn("08_GW_AUG_2026-WEB.pdf", msg)


class RefreshBookIndexTests(KomgaSyncTestCase):
    def test_scans_only_libraries_holding_a_missing_pdf(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old = make_sidecar(root, "GAW/2025/07.json")
            new = make_sidecar(root, "WVJ/2026/03.json")
            komga = FakeKomga(
                indexed=[old.with_suffix(".pdf")],
                arrives={new.with_suffix(".pdf"): 1},
            )
            clock = FakeClock()

            with mock.patch.object(komga_sync, "http", komga.http):
                gate = komga_sync.refresh_book_index(
                    [old, new],
                    libraries_for(root),
                    sleep=clock.sleep,
                    monotonic=clock.monotonic,
                )

            self.assertEqual(komga.scans, ["wvj"])
            self.assertEqual(gate.missing, [])
            self.assertEqual(gate.unmapped, [])
            self.assertEqual(gate.scan_errors, [])

    def test_requests_no_scan_when_every_pdf_is_already_indexed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            gaw = make_sidecar(root, "GAW/2025/07.json")
            wvj = make_sidecar(root, "WVJ/2026/03.json")
            komga = FakeKomga(
                indexed=[gaw.with_suffix(".pdf"), wvj.with_suffix(".pdf")]
            )
            clock = FakeClock()

            with mock.patch.object(komga_sync, "http", komga.http):
                gate = komga_sync.refresh_book_index(
                    [gaw, wvj],
                    libraries_for(root),
                    sleep=clock.sleep,
                    monotonic=clock.monotonic,
                )

            self.assertEqual(komga.scans, [])
            self.assertEqual(komga.listings, 1)  # just the pre-scan index
            self.assertEqual(clock.sleeps, [])
            self.assertEqual(gate.missing, [])

    def test_gate_matches_the_index_on_pdf_filename(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sidecar = make_sidecar(
                root, "GAW/2026/08.json", {"pdf_filename": "08_GW_AUG_2026-WEB.pdf"}
            )
            komga = FakeKomga(indexed=[sidecar.with_name("08_GW_AUG_2026-WEB.pdf")])
            clock = FakeClock()

            with mock.patch.object(komga_sync, "http", komga.http):
                gate = komga_sync.refresh_book_index(
                    [sidecar],
                    libraries_for(root),
                    sleep=clock.sleep,
                    monotonic=clock.monotonic,
                )

            self.assertEqual(komga.scans, [])
            self.assertEqual(gate.missing, [])

    def test_reports_items_that_never_arrive_without_raising(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old = make_sidecar(root, "GAW/2025/07.json")
            new = make_sidecar(root, "GAW/2026/08.json")
            komga = FakeKomga(indexed=[old.with_suffix(".pdf")])
            clock = FakeClock()

            with mock.patch.object(komga_sync, "http", komga.http):
                gate = komga_sync.refresh_book_index(
                    [old, new],
                    libraries_for(root),
                    timeout=120,
                    sleep=clock.sleep,
                    monotonic=clock.monotonic,
                )

            self.assertEqual(gate.missing, [new])
            self.assertEqual(gate.scan_errors, [])
            self.assertLessEqual(clock.now, 120)

    def test_wait_backs_off_instead_of_hammering_the_book_list(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            new = make_sidecar(root, "GAW/2026/08.json")
            komga = FakeKomga()  # the scan never turns anything up
            clock = FakeClock()

            with mock.patch.object(komga_sync, "http", komga.http):
                gate = komga_sync.refresh_book_index(
                    [new],
                    libraries_for(root),
                    timeout=600,
                    sleep=clock.sleep,
                    monotonic=clock.monotonic,
                )

            self.assertEqual(gate.missing, [new])
            # Uses its whole budget, and no more (the unit allows 20 min).
            self.assertLessEqual(clock.now, 600)
            self.assertGreater(clock.now, 590)
            # A first check soon after the scan request, then progressively
            # further apart — 10 minutes of waiting is not 120 full listings.
            self.assertEqual(clock.sleeps[0], komga_sync.SCAN_POLL_SECONDS)
            self.assertEqual(clock.sleeps[:-1], sorted(clock.sleeps[:-1]))
            self.assertLessEqual(max(clock.sleeps), komga_sync.SCAN_POLL_MAX_SECONDS)
            self.assertLess(komga.listings, 30)

    def test_scan_request_failure_is_reported_not_raised(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            new = make_sidecar(root, "GAW/2026/08.json")
            komga = FakeKomga(scan_status=500)
            clock = FakeClock()

            with mock.patch.object(komga_sync, "http", komga.http):
                gate = komga_sync.refresh_book_index(
                    [new],
                    libraries_for(root),
                    sleep=clock.sleep,
                    monotonic=clock.monotonic,
                )

            self.assertEqual(gate.missing, [new])
            self.assertEqual(len(gate.scan_errors), 1)
            self.assertIn("gaw", gate.scan_errors[0])
            self.assertIn("500", gate.scan_errors[0])
            # Nothing was actually scanned, so don't burn the wait budget.
            self.assertEqual(komga.listings, 1)

    def test_transient_scan_failure_is_retried(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            new = make_sidecar(root, "GAW/2026/08.json")
            komga = FakeKomga(arrives={new.with_suffix(".pdf"): 1})
            clock = FakeClock()
            statuses = iter([503, 202])

            def flaky_http(method, path, body=None):
                if method == "POST":
                    komga.scan_status = next(statuses)
                return komga.http(method, path, body)

            with mock.patch.object(komga_sync, "http", flaky_http):
                gate = komga_sync.refresh_book_index(
                    [new],
                    libraries_for(root),
                    sleep=clock.sleep,
                    monotonic=clock.monotonic,
                )

            self.assertEqual(komga.scans, ["gaw", "gaw"])
            self.assertEqual(gate.scan_errors, [])
            self.assertEqual(gate.missing, [])

    def test_sidecar_outside_every_library_is_reported_not_scanned(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            stray = make_sidecar(root, "XYZ/2026/08.json")
            komga = FakeKomga()
            clock = FakeClock()

            with mock.patch.object(komga_sync, "http", komga.http):
                gate = komga_sync.refresh_book_index(
                    [stray],
                    libraries_for(root),
                    sleep=clock.sleep,
                    monotonic=clock.monotonic,
                )

            self.assertEqual(komga.scans, [])
            self.assertEqual(gate.unmapped, [stray])
            self.assertEqual(gate.missing, [stray])
            self.assertEqual(clock.sleeps, [])


class MainReconciliationTests(KomgaSyncTestCase):
    def test_absent_pdf_does_not_suppress_other_metadata_writes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old = make_sidecar(root, "GAW/2025/07.json")
            new = make_sidecar(root, "GAW/2026/08.json")
            for sidecar in (old, new):
                sidecar.with_suffix(".pdf").write_bytes(b"pdf")

            synced = []

            def fake_sync_book(sidecar, kind):
                synced.append(sidecar)
                return ("err", "no book matches") if sidecar == new else ("ok", "b1")

            with (
                mock.patch.object(komga_sync, "API_KEY", "test-key"),
                mock.patch.object(komga_sync, "SIDECAR_ROOT", root),
                mock.patch.object(komga_sync, "DRY_RUN", False),
                mock.patch.object(
                    komga_sync, "get", return_value=(200, libraries_for(root))
                ),
                mock.patch.object(komga_sync, "ensure_hashkoreader"),
                mock.patch.object(
                    komga_sync,
                    "refresh_book_index",
                    return_value=komga_sync.IndexGate(
                        missing=[new], unmapped=[], scan_errors=[]
                    ),
                ),
                mock.patch.object(komga_sync, "sync_book", fake_sync_book),
            ):
                result = komga_sync.main()

            # The historical sidecar is still reconciled; the absent one errors.
            self.assertEqual(synced, [old, new])
            self.assertEqual(result, 2)

    def test_scan_request_failure_exits_under_the_documented_contract(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sidecar = make_sidecar(root, "GAW/2025/07.json")
            sidecar.with_suffix(".pdf").write_bytes(b"pdf")

            with (
                mock.patch.object(komga_sync, "API_KEY", "test-key"),
                mock.patch.object(komga_sync, "SIDECAR_ROOT", root),
                mock.patch.object(komga_sync, "DRY_RUN", False),
                mock.patch.object(
                    komga_sync, "get", return_value=(200, libraries_for(root))
                ),
                mock.patch.object(komga_sync, "ensure_hashkoreader"),
                mock.patch.object(
                    komga_sync,
                    "refresh_book_index",
                    return_value=komga_sync.IndexGate(
                        missing=[], unmapped=[], scan_errors=["scan refused: 500"]
                    ),
                ),
                mock.patch.object(komga_sync, "sync_book", return_value=("ok", "b1")),
            ):
                result = komga_sync.main()

            # Exit code, not a traceback: 2 == "some sidecars failed to sync".
            self.assertEqual(result, 2)


class EndToEndInvariantTests(KomgaSyncTestCase):
    """The whole point of the gate, driven through main() over a fake Komga."""

    def test_new_pdf_is_indexed_before_its_metadata_is_written(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old = make_sidecar(root, "GAW/2025/07.json", {"issue_number": 740})
            new = make_sidecar(root, "GAW/2026/08.json", {"issue_number": 751})
            stuck = make_sidecar(root, "WVJ/2026/03.json", {"volume": 41, "issue": 3})
            for sidecar in (old, new, stuck):
                sidecar.with_suffix(".pdf").write_bytes(b"pdf")

            komga = FakeKomga(
                indexed=[old.with_suffix(".pdf")],
                # The archiver's fresh issue only shows up once Komga scans;
                # the WVJ one never does (bad file, still importing, ...).
                arrives={new.with_suffix(".pdf"): 1},
                libraries=libraries_for(root),
            )
            clock = FakeClock()
            real_refresh = komga_sync.refresh_book_index

            def refresh_on_a_fake_clock(sidecars, libraries):
                return real_refresh(
                    sidecars,
                    libraries,
                    timeout=120,
                    sleep=clock.sleep,
                    monotonic=clock.monotonic,
                )

            with (
                mock.patch.object(komga_sync, "API_KEY", "test-key"),
                mock.patch.object(komga_sync, "SIDECAR_ROOT", root),
                mock.patch.object(komga_sync, "DRY_RUN", False),
                mock.patch.object(komga_sync, "http", komga.http),
                mock.patch.object(komga_sync, "ensure_hashkoreader"),
                mock.patch.object(
                    komga_sync, "refresh_book_index", refresh_on_a_fake_clock
                ),
            ):
                result = komga_sync.main()

            patches = [path for method, path in komga.calls if method == "PATCH"]
            scan_at = komga.calls.index(("POST", "/api/v1/libraries/gaw/scan"))
            patch_at = komga.calls.index(("PATCH", "/api/v1/books/08/metadata"))

            # The invariant: the new PDF is discoverable before it is written to.
            self.assertLess(scan_at, patch_at)
            # The historical issue is reconciled despite the stuck WVJ one.
            self.assertIn("/api/v1/books/07/metadata", patches)
            # ...which is itself still reported as a failure.
            self.assertEqual(result, 2)
            self.assertEqual(sorted(komga.scans), ["gaw", "wvj"])


if __name__ == "__main__":
    unittest.main()
