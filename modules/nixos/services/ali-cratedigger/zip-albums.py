"""Publish Ali's Beets albums as phone-downloadable Yoto ZIP files."""

from __future__ import annotations

import argparse
import hashlib
import os
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


PUBLISHED_SUFFIXES = frozenset({".aac", ".jpeg", ".jpg", ".m4a", ".mp3", ".png"})
COMMENT_PREFIX = b"ali-yoto-sha256:"


@dataclass(frozen=True)
class ReconcileResult:
    created: int
    refreshed: int
    unchanged: int
    removed: int


def _published_files(album_dir: Path) -> list[Path]:
    return sorted(
        path
        for path in album_dir.iterdir()
        if path.is_file()
        and not path.is_symlink()
        and path.suffix.lower() in PUBLISHED_SUFFIXES
    )


def _manifest_digest(files: Iterable[Path]) -> bytes:
    digest = hashlib.sha256()
    for path in files:
        encoded_name = path.name.encode("utf-8")
        digest.update(len(encoded_name).to_bytes(4, "big"))
        digest.update(encoded_name)
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
    return COMMENT_PREFIX + digest.hexdigest().encode("ascii")


def _archive_is_current(archive: Path, comment: bytes) -> bool:
    try:
        with zipfile.ZipFile(archive) as handle:
            return handle.comment == comment and handle.testzip() is None
    except (FileNotFoundError, zipfile.BadZipFile, OSError):
        return False


def _archive_is_owned(archive: Path) -> bool:
    try:
        with zipfile.ZipFile(archive) as handle:
            return handle.comment.startswith(COMMENT_PREFIX)
    except (FileNotFoundError, zipfile.BadZipFile, OSError):
        return False


def _fsync_directory(directory: Path) -> None:
    directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def _write_archive(album_dir: Path, files: list[Path], archive: Path, comment: bytes) -> None:
    temporary = archive.with_suffix(f"{archive.suffix}.partial")
    try:
        with zipfile.ZipFile(
            temporary,
            mode="w",
            compression=zipfile.ZIP_STORED,
            strict_timestamps=False,
        ) as handle:
            for path in files:
                handle.write(path, arcname=f"{album_dir.name}/{path.name}")
            handle.comment = comment
        with temporary.open("rb") as handle:
            os.fsync(handle.fileno())
        os.replace(temporary, archive)
        _fsync_directory(album_dir)
    finally:
        temporary.unlink(missing_ok=True)


def reconcile_library(library: Path) -> ReconcileResult:
    created = 0
    refreshed = 0
    unchanged = 0
    removed = 0
    for root, directories, _filenames in os.walk(library, followlinks=False):
        directories.sort()
        album_dir = Path(root)
        if len(album_dir.relative_to(library).parts) < 2:
            continue
        archive = album_dir / f"{album_dir.name}.zip"
        files = _published_files(album_dir)
        if not files:
            if _archive_is_owned(archive):
                archive.unlink()
                _fsync_directory(album_dir)
                removed += 1
            continue
        comment = _manifest_digest(files)
        if _archive_is_current(archive, comment):
            unchanged += 1
            continue
        existed = archive.exists()
        _write_archive(album_dir, files, archive, comment)
        if existed:
            refreshed += 1
        else:
            created += 1
    return ReconcileResult(
        created=created,
        refreshed=refreshed,
        unchanged=unchanged,
        removed=removed,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("library", type=Path)
    args = parser.parse_args()
    result = reconcile_library(args.library)
    print(
        f"ali-yoto-zip: created={result.created} refreshed={result.refreshed} "
        f"unchanged={result.unchanged} removed={result.removed}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
