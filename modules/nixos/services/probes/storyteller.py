"""Check Storyteller's reader, private storage and actual SQLite write authority."""

import json
import os
import pathlib
import sqlite3
import subprocess
import sys
import urllib.request


def main():
    data_dir, port = sys.argv[1:]
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/health", timeout=20) as response:
        assert response.status == 200
        assert json.load(response)["status"] == "healthy"
    subprocess.run(
        ["podman", "exec", "--user", "2026:2026", "storyteller", "sh", "-c",
         'set -eu; p=$(mktemp /data/.homelab-probe.XXXXXX); trap \'rm -f "$p"\' EXIT; printf probe > "$p"; test "$(cat "$p")" = probe'],
        check=True, timeout=20,
    )
    os.setgroups([])
    os.setgid(2026)
    os.setuid(2026)
    database = pathlib.Path(data_dir) / "storyteller.db"
    connection = sqlite3.connect(f"file:{database}?mode=rw", uri=True, timeout=10)
    try:
        assert connection.execute("PRAGMA quick_check").fetchone() == ("ok",)
        connection.execute("BEGIN IMMEDIATE")
        connection.rollback()
    finally:
        connection.close()
    print("Storyteller: HTTP/reader, application storage and SQLite write checks passed")


if __name__ == "__main__":
    main()
