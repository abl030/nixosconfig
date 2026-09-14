#!/usr/bin/env python3
"""Copy acquired Shelfarr ebooks through Calibre's supported content-server CLI.

Shelfarr's Book.file_path is committed only after atomic publication. Read its
SQLite database with WAL support; never write that DB or Calibre's metadata.db.
The private receipt database and Calibre's ignore-duplicate policy make retries
safe, including a crash between remote import and receipt commit.
"""

import hashlib
from contextlib import closing
import os
from pathlib import Path, PurePosixPath
import sqlite3
import stat
import subprocess
import tempfile
import time
import urllib.request

FORMATS = {".epub", ".pdf", ".mobi", ".azw", ".azw3", ".djvu"}
MAX_BYTES = 512 * 1024 * 1024


def acquired_books(database: Path) -> list[sqlite3.Row]:
    deadline = time.monotonic() + 30
    while True:
        try:
            with closing(sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=5)) as db:
                db.row_factory = sqlite3.Row
                return db.execute("""
                    SELECT id, title, author, file_path FROM books
                    WHERE book_type = 1 AND TRIM(COALESCE(file_path, '')) <> ''
                      AND acquisition_reservation_token IS NULL
                    ORDER BY id
                """).fetchall()
        except sqlite3.OperationalError as error:
            # A container restart briefly removes WAL/SHM before Rails opens
            # them again. Never grant write access to work around that window.
            if getattr(error, "sqlite_errorcode", None) not in (sqlite3.SQLITE_CANTOPEN, sqlite3.SQLITE_BUSY) or time.monotonic() >= deadline:
                raise
            time.sleep(1)


def book_files(root: Path, container_path: str) -> list[Path]:
    relative = PurePosixPath(container_path).relative_to("/ebooks")
    if not relative.parts or ".." in relative.parts:
        raise ValueError("Acquired book path is outside the ebook subtree")
    path = root / relative
    if not path.exists():
        raise FileNotFoundError("Acquired ebook path is missing")
    paths = [path] if path.is_file() else sorted(path.rglob("*"))
    files = [p for p in paths if p.suffix.lower() in FORMATS and not p.is_dir()]
    if not files:
        raise ValueError("Acquired book has no supported ebook files")
    return files


def snapshot(root: Path, source: Path, destination: Path) -> str:
    """Pin every path component; reject symlinks, devices and changing files."""
    parts = source.relative_to(root).parts
    directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
    finally:
        os.close(directory)
    with os.fdopen(fd, "rb") as src:
        before = os.fstat(src.fileno())
        if not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= MAX_BYTES:
            raise ValueError("Ebook is not a nonempty regular file within the size limit")
        digest = hashlib.sha256()
        size = 0
        with destination.open("xb") as dst:
            while chunk := src.read(1024 * 1024):
                size += len(chunk)
                if size > MAX_BYTES:
                    raise ValueError("Ebook grew beyond the size limit")
                digest.update(chunk)
                dst.write(chunk)
        after = os.fstat(src.fileno())
        if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
            after.st_size, after.st_mtime_ns, after.st_ctime_ns
        ) or size != before.st_size:
            raise ValueError("Ebook changed while being read; retry next run")
    return digest.hexdigest()


def calibre(*arguments: str) -> None:
    password = Path(os.environ["CREDENTIALS_DIRECTORY"]) / "calibre-password"
    command = [
        os.environ["CALIBREDB"], "--with-library", os.environ["CALIBRE_URL"],
        "--username", os.environ["CALIBRE_USERNAME"], "--password", f"<f:{password}>",
        *arguments,
    ]
    result = subprocess.run(command, capture_output=True, text=True, timeout=120)
    if result.returncode:
        # Do not copy arbitrary remote responses or credential-bearing command lines to logs.
        raise RuntimeError(f"Calibre {arguments[0]} exited {result.returncode}")


def scan_komga() -> None:
    env_file = Path(os.environ["CREDENTIALS_DIRECTORY"]) / "komga-env"
    values = dict(line.split("=", 1) for line in env_file.read_text().splitlines()
                  if line.strip() and not line.lstrip().startswith("#") and "=" in line)
    key = values["KOMGA_API_KEY"].strip().strip("\"'")
    url = os.environ["KOMGA_URL"].rstrip("/") + "/api/v1/libraries/" + os.environ["KOMGA_LIBRARY_ID"] + "/scan"
    request = urllib.request.Request(url, method="POST", data=b"", headers={"X-API-Key": key})
    with urllib.request.urlopen(request, timeout=30) as response:
        if response.status not in (200, 202, 204):
            raise RuntimeError(f"Komga scan returned {response.status}")


def import_books(books: list, root: Path, receipts: sqlite3.Connection) -> int:
    receipts.execute("CREATE TABLE IF NOT EXISTS imports (book_id INTEGER, digest TEXT, format TEXT, PRIMARY KEY(book_id,digest,format))")
    receipts.execute("CREATE TABLE IF NOT EXISTS pending_scan (singleton INTEGER PRIMARY KEY CHECK(singleton=1))")
    receipts.execute("CREATE TABLE IF NOT EXISTS files (book_id INTEGER, path TEXT, size INTEGER, modified INTEGER, PRIMARY KEY(book_id,path))")
    failures = 0
    for book in books:
        try:
            for source in book_files(root, book["file_path"]):
                info = source.stat(follow_symlinks=False)
                file_key = (book["id"], str(source.relative_to(root)), info.st_size, info.st_mtime_ns)
                if receipts.execute("SELECT 1 FROM files WHERE book_id=? AND path=? AND size=? AND modified=?", file_key).fetchone():
                    continue
                with tempfile.TemporaryDirectory(prefix="shelfarr-calibre-") as temp:
                    staged = Path(temp) / ("book" + source.suffix.lower())
                    digest = snapshot(root, source, staged)
                    key = (book["id"], digest, source.suffix.lower())
                    if not receipts.execute("SELECT 1 FROM imports WHERE book_id=? AND digest=? AND format=?", key).fetchone():
                        calibre("add", "--automerge", "ignore", "--title", book["title"],
                                "--authors", book["author"] or "Unknown", str(staged))
                    with receipts:
                        receipts.execute("INSERT OR IGNORE INTO imports VALUES (?,?,?)", key)
                        receipts.execute("INSERT OR REPLACE INTO files VALUES (?,?,?,?)", file_key)
                        receipts.execute("INSERT OR IGNORE INTO pending_scan VALUES (1)")
                    print(f"Calibre imported or already holds Shelfarr book #{book['id']} ({source.suffix.lower()})")
        except Exception as error:
            failures += 1
            print(f"SHELFARR_CALIBRE_FAILED book #{book['id']}: {type(error).__name__}: {error}")
    if receipts.execute("SELECT 1 FROM pending_scan").fetchone():
        scan_komga()
        with receipts:
            receipts.execute("DELETE FROM pending_scan")
        print("Komga Calibre-library scan requested")
    return failures


def main() -> None:
    books = acquired_books(Path(os.environ["SHELFARR_DATABASE"]))
    # Remote auth/library availability is checked even while the queue is empty.
    calibre("list", "--limit", "1", "--fields", "id", "--for-machine")
    state = Path(os.environ["STATE_DIRECTORY"])
    with sqlite3.connect(state / "imports.sqlite3") as receipts:
        failures = import_books(books, Path(os.environ["EBOOK_ROOT"]), receipts)
    print(f"Calibre bridge checked {len(books)} acquired ebooks; {failures} failed")
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"SHELFARR_CALIBRE_FAILED {type(error).__name__}: {error}")
        raise SystemExit(1) from None
