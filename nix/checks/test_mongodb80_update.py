#!/usr/bin/env python3
"""Exercise MongoDB 8.0 package provenance and patch-update boundaries."""

from __future__ import annotations

import base64
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = Path(os.environ.get("MONGODB80_PACKAGE_SOURCE", ROOT / "nix" / "pkgs" / "mongodb80.nix"))
UPDATER = Path(os.environ.get("MONGODB80_UPDATER_SOURCE", ROOT / "scripts" / "update_mongodb80.sh"))
CANDIDATE_HASH = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
CANDIDATE_HEX = "00" * 32


def fail(message: str) -> None:
    raise SystemExit(message)


def package_version() -> str:
    text = PACKAGE.read_text(encoding="utf-8")
    match = re.search(r'^\s*version = "([0-9]+\.[0-9]+\.[0-9]+)";', text, re.MULTILINE)
    if match is None:
        fail("package contract has no semantic version")
    assert match is not None
    return match.group(1)


def next_patch_version() -> str:
    major, minor, patch = (int(part) for part in package_version().split("."))
    return f"{major}.{minor}.{patch + 1}"


def previous_patch_version() -> str:
    major, minor, patch = (int(part) for part in package_version().split("."))
    if patch == 0:
        fail("fixture requires a non-zero current patch")
    return f"{major}.{minor}.{patch - 1}"


def fixture_candidate_version() -> str:
    return os.environ.get("MONGODB80_TEST_CANDIDATE_VERSION") or next_patch_version()


def run_updater(
    package_file: Path,
    release_html: str,
    *,
    archive: Path | None = None,
    archive_store: Path | None = None,
    prefetch_status: int = 0,
    official_hex: str = CANDIDATE_HEX,
    prefetch_hash: str = CANDIDATE_HASH,
    candidate_version: str | None = None,
) -> subprocess.CompletedProcess[str]:
    candidate = candidate_version or fixture_candidate_version()
    with tempfile.TemporaryDirectory(prefix="mongodb80-updater-fixture-") as temporary:
        fixture = Path(temporary)
        fake_bin = fixture / "bin"
        fake_bin.mkdir()

        curl = fake_bin / "curl"
        curl.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "output=\n"
            "previous=\n"
            "for arg in \"$@\"; do\n"
            "  if [ \"$previous\" = --output ]; then output=\"$arg\"; fi\n"
            "  case \"$arg\" in http://*|https://*) url=\"$arg\" ;; esac\n"
            "  previous=\"$arg\"\n"
            "done\n"
            "test -n \"$output\"\n"
            "case \"$url\" in\n"
            "  *.sha256) printf '%s  %s\\n' \"$MONGODB80_TEST_OFFICIAL_HEX\" \"$MONGODB80_TEST_ARCHIVE_NAME\" > \"$output\" ;;\n"
            "  *) printf '%s' \"$MONGODB80_TEST_RELEASE_HTML\" > \"$output\" ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        curl.chmod(curl.stat().st_mode | stat.S_IXUSR)

        nix = fake_bin / "nix"
        nix.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "if [ \"$1\" = hash ] && [ \"$2\" = convert ]; then printf '%s\\n' \"$MONGODB80_TEST_OFFICIAL_SRI\"; exit 0; fi\n"
            "test \"$1\" = store\n"
            "test \"$2\" = prefetch-file\n"
            "if [ \"${MONGODB80_TEST_PREFETCH_STATUS:-0}\" -ne 0 ]; then exit \"$MONGODB80_TEST_PREFETCH_STATUS\"; fi\n"
            "printf '{\"hash\":\"%s\",\"storePath\":\"%s\"}\\n' \"$MONGODB80_TEST_HASH\" \"$MONGODB80_TEST_ARCHIVE\"\n",
            encoding="utf-8",
        )
        nix.chmod(nix.stat().st_mode | stat.S_IXUSR)

        environment = os.environ.copy()
        store_archive = str(archive_store or "")
        if archive is not None and not store_archive:
            nix_binary = shutil.which("nix")
            if nix_binary is None:
                fail("the updater fixture requires nix to add its tarball to the store")
            assert nix_binary is not None
            added = subprocess.run(
                [nix_binary, "store", "add-file", "--name", "mongodb80-test-archive.tgz", str(archive)],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            if added.returncode != 0:
                fail(f"could not add fixture archive to the Nix store: {added.stderr}")
            store_archive = added.stdout.strip().splitlines()[-1]
        if not store_archive:
            store_archive = str(archive or fixture / "missing.tgz")
        environment.update(
            {
                "MONGODB80_PACKAGE_FILE": str(package_file),
                "MONGODB80_TEST_RELEASE_HTML": release_html,
                "MONGODB80_TEST_CANDIDATE_VERSION": candidate,
                "MONGODB80_TEST_ARCHIVE_NAME": f"mongodb-linux-x86_64-ubuntu2404-{candidate}.tgz",
                "MONGODB80_TEST_HASH": prefetch_hash,
                "MONGODB80_TEST_OFFICIAL_HEX": official_hex,
                "MONGODB80_TEST_OFFICIAL_SRI": "sha256-"
                + base64.b64encode(bytes.fromhex(official_hex)).decode(),
                "MONGODB80_TEST_ARCHIVE": store_archive,
                "MONGODB80_TEST_PREFETCH_STATUS": str(prefetch_status),
                "PATH": f"{fake_bin}{os.pathsep}{environment['PATH']}",
            }
        )
        return subprocess.run(
            ["bash", str(UPDATER)],
            cwd=ROOT,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )


def make_archive(directory: Path, *, version: str | None = None, include_mongos: bool = True) -> Path:
    version = version or fixture_candidate_version()
    source = directory / f"mongodb-linux-x86_64-ubuntu2404-{version}"
    (source / "bin").mkdir(parents=True)
    (source / "bin" / "mongod").write_bytes(b"fixture mongod")
    if include_mongos:
        (source / "bin" / "mongos").write_bytes(b"fixture mongos")
    archive = directory / f"mongodb-{version}.tgz"
    with tarfile.open(archive, "w:gz") as tar:
        tar.add(source, arcname=source.name)
    return archive


def test_static_package_contract() -> None:
    text = PACKAGE.read_text(encoding="utf-8")
    version = re.search(r'^\s*version = "([0-9]+\.[0-9]+\.[0-9]+)";', text, re.MULTILINE)
    if version is None or not version.group(1).startswith("8.0."):
        fail("package contract does not pin an 8.0 patch version")
    required = (
        "https://fastdl.mongodb.org/linux/mongodb-linux-x86_64-ubuntu2404-",
        "autoPatchelfHook",
        "dontBuild = true;",
        "sourceProvenance = [lib.sourceTypes.binaryNativeCode];",
        'mongodbSeries = "8.0";',
    )
    for marker in required:
        if marker not in text:
            fail(f"package contract missing {marker!r}")
    if "r8.2" in text or "fetchFromGitHub" in text:
        fail("MongoDB package unexpectedly contains source/git updater material")


def test_success_updates_only_the_patch() -> None:
    with tempfile.TemporaryDirectory(prefix="mongodb80-update-success-") as temporary:
        directory = Path(temporary)
        package = directory / "mongodb80.nix"
        original = PACKAGE.read_text(encoding="utf-8")
        package.write_text(original, encoding="utf-8")
        archive = make_archive(directory)
        store_archive = os.environ.get("MONGODB80_TEST_COMPLETE_ARCHIVE")
        result = run_updater(
            package,
            f"<html><h3>{fixture_candidate_version()}</h3></html>",
            archive=archive,
            archive_store=Path(store_archive) if store_archive else None,
        )
        if result.returncode != 0:
            fail(f"valid patch update failed: {result.stderr}")
        updated = package.read_text(encoding="utf-8")
        candidate = fixture_candidate_version()
        if f'version = "{candidate}";' not in updated:
            fail("valid patch update did not update the package version")
        if updated.count(CANDIDATE_HASH) != 2:
            fail("valid patch update did not update both package hashes")


def test_series_boundary_is_fail_closed() -> None:
    with tempfile.TemporaryDirectory(prefix="mongodb80-update-series-") as temporary:
        package = Path(temporary) / "mongodb80.nix"
        original = PACKAGE.read_text(encoding="utf-8")
        package.write_text(original, encoding="utf-8")
        for version in ("8.1.0", "8.2.12", "8.3.8", "9.0.0", "8.0.999-rc0"):
            result = run_updater(package, f"<html><h3>{version}</h3></html>")
            if result.returncode == 0:
                fail(f"updater accepted forbidden release {version}")
            if package.read_text(encoding="utf-8") != original:
                fail("series-boundary rejection modified the package")


def test_prefetch_failure_is_fail_closed() -> None:
    with tempfile.TemporaryDirectory(prefix="mongodb80-update-prefetch-") as temporary:
        package = Path(temporary) / "mongodb80.nix"
        original = PACKAGE.read_text(encoding="utf-8")
        package.write_text(original, encoding="utf-8")
        result = run_updater(
            package,
            f"<html><h3>{fixture_candidate_version()}</h3></html>",
            prefetch_status=42,
        )
        if result.returncode == 0:
            fail("updater accepted a failed archive prefetch")
        if package.read_text(encoding="utf-8") != original:
            fail("prefetch failure modified the package")


def test_archive_layout_failure_is_fail_closed() -> None:
    with tempfile.TemporaryDirectory(prefix="mongodb80-update-archive-") as temporary:
        directory = Path(temporary)
        package = directory / "mongodb80.nix"
        original = PACKAGE.read_text(encoding="utf-8")
        package.write_text(original, encoding="utf-8")
        archive = make_archive(directory, include_mongos=False)
        store_archive = os.environ.get("MONGODB80_TEST_MISSING_MONGOS_ARCHIVE")
        result = run_updater(
            package,
            f"<html><h3>{fixture_candidate_version()}</h3></html>",
            archive=archive,
            archive_store=Path(store_archive) if store_archive else None,
        )
        if result.returncode == 0:
            fail("updater accepted an archive missing mongos")
        if package.read_text(encoding="utf-8") != original:
            fail("archive-layout failure modified the package")


def test_downgrade_is_fail_closed() -> None:
    with tempfile.TemporaryDirectory(prefix="mongodb80-update-downgrade-") as temporary:
        package = Path(temporary) / "mongodb80.nix"
        original = PACKAGE.read_text(encoding="utf-8")
        package.write_text(original, encoding="utf-8")
        result = run_updater(package, f"<html><h3>{previous_patch_version()}</h3></html>")
        if result.returncode == 0:
            fail("updater accepted a patch downgrade")
        if package.read_text(encoding="utf-8") != original:
            fail("downgrade rejection modified the package")


def test_checksum_mismatch_is_fail_closed() -> None:
    with tempfile.TemporaryDirectory(prefix="mongodb80-update-checksum-") as temporary:
        directory = Path(temporary)
        package = directory / "mongodb80.nix"
        original = PACKAGE.read_text(encoding="utf-8")
        package.write_text(original, encoding="utf-8")
        archive = make_archive(directory)
        store_archive = os.environ.get("MONGODB80_TEST_COMPLETE_ARCHIVE")
        result = run_updater(
            package,
            f"<html><h3>{fixture_candidate_version()}</h3></html>",
            archive=archive,
            archive_store=Path(store_archive) if store_archive else None,
            official_hex="11" * 32,
        )
        if result.returncode == 0:
            fail("updater accepted an archive whose hash differs from MongoDB's checksum")
        if package.read_text(encoding="utf-8") != original:
            fail("checksum mismatch modified the package")


def main() -> int:
    test_static_package_contract()
    test_success_updates_only_the_patch()
    test_series_boundary_is_fail_closed()
    test_prefetch_failure_is_fail_closed()
    test_archive_layout_failure_is_fail_closed()
    test_downgrade_is_fail_closed()
    test_checksum_mismatch_is_fail_closed()
    print("mongodb80 updater/package contract: 7 tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
