"""Probe trial app HTTP, its state mount as its UID, and database write authority."""

import json
import pathlib
import sqlite3
import subprocess
import sys
import urllib.request

import psycopg2
import pymysql


def main() -> None:
    app, data_dir, port = sys.argv[1:]
    uid, state, endpoint = {
        "chaptarr": (2021, "/config", "/ping"),
        "booklore": (2022, "/app/data", "/api/v1/healthcheck"),
        "bookkeep": (2023, "/app/data", "/health"),
        "readmeabook": (2024, "/app/config", "/api/health"),
    }[app]
    # Numeric --user alone leaves podman exec in GID 0. Match the real app group.
    gid = 100 if app in {"booklore", "readmeabook"} else uid
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{endpoint}", timeout=15) as response:
        assert response.status == 200
    writable_paths = [state]
    if app == "readmeabook":
        writable_paths += ["/downloads/readmeabook", "/downloads/completed/readmeabook", "/media"]
    for writable_path in writable_paths:
        subprocess.run(
            ["podman", "exec", "--user", f"{uid}:{gid}", app, "sh", "-c",
             'set -eu; p=$(mktemp "$1/.homelab-probe.XXXXXX"); trap \'rm -f "$p"\' EXIT; printf probe > "$p"; test "$(cat "$p")" = probe',
             "probe", writable_path],
            check=True, timeout=15,
        )
    if app == "chaptarr":
        # Read/write transaction uses the actual SQLite catalog, never another DB.
        # Drop privileges before opening it so root cannot mask filesystem failures.
        import os
        os.setgroups([])
        os.setgid(uid)
        os.setuid(uid)
        database = pathlib.Path(data_dir) / "config" / "chaptarr.db"
        connection = sqlite3.connect(f"file:{database}?mode=rw", uri=True, timeout=5)
        try:
            assert connection.execute("PRAGMA quick_check").fetchone() == ("ok",)
            connection.execute("BEGIN IMMEDIATE")
            connection.execute('UPDATE "Config" SET "Value"="Value" WHERE 0')
            connection.rollback()
        finally:
            connection.close()
    else:
        env = dict(line.split("=", 1) for line in pathlib.Path(f"/run/secrets/{app}-env").read_text().splitlines() if "=" in line and not line.startswith("#"))
        if app == "booklore":
            connection = pymysql.connect(host="10.20.0.23", user=app, password=env["MYSQL_PASSWORD"], database=app, connect_timeout=5, read_timeout=10, write_timeout=10)
            table, column = "book", "id"
        else:
            host = "10.20.0.25" if app == "bookkeep" else "10.20.0.27"
            connection = psycopg2.connect(host=host, user=app, password=env["POSTGRES_PASSWORD"], dbname=app, connect_timeout=5, options="-c statement_timeout=10000")
            table, column = ("app_settings", "key") if app == "bookkeep" else ("configuration", "key")
        try:
            with connection.cursor() as cursor:
                quote = "`" if app == "booklore" else '"'
                cursor.execute(f"SELECT COUNT(*) FROM {quote}{table}{quote}")
                count = cursor.fetchone()[0]
                cursor.execute(f"UPDATE {quote}{table}{quote} SET {quote}{column}{quote}={quote}{column}{quote} WHERE 1=0")
                # Exercise UPDATE authority without DDL: MariaDB's audit alert
                # deliberately treats non-startup DDL as an operational event.
            connection.rollback()
            print(json.dumps({"app": app, "catalog_rows": count, "database_write_authority": "ok"}))
        finally:
            connection.close()
    print(f"{app}: HTTP, application state and database write checks passed")


if __name__ == "__main__":
    main()
