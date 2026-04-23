#!/usr/bin/env python3
"""Audit Audiobookshelf items against Audnexus runtimes.

Defaults are tuned to suppress normal edition variance:
- absolute runtime delta >= 120s
- percentage delta >= 2%
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.parse
import urllib.request
from pathlib import Path


def load_env() -> dict[str, str]:
    env_file = os.environ.get("AUDIOBOOKSHELF_MCP_ENV_FILE", "/run/secrets/mcp/audiobookshelf.env")
    env: dict[str, str] = {}
    for line in Path(env_file).read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key] = value
    required = ["AUDIOBOOKSHELF_URL", "AUDIOBOOKSHELF_TOKEN", "AUDIOBOOKSHELF_LIBRARY_ID"]
    missing = [k for k in required if not env.get(k)]
    if missing:
        raise SystemExit(f"missing env vars in {env_file}: {', '.join(missing)}")
    return env


def get_json(url: str, token: str | None = None) -> dict:
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--min-seconds", type=int, default=120)
    parser.add_argument("--min-pct", type=float, default=0.02)
    parser.add_argument("--limit", type=int, default=1000)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    env = load_env()
    base = env["AUDIOBOOKSHELF_URL"].rstrip("/")
    token = env["AUDIOBOOKSHELF_TOKEN"]
    library_id = env["AUDIOBOOKSHELF_LIBRARY_ID"]

    items = get_json(f"{base}/api/libraries/{library_id}/items?limit={args.limit}", token)["results"]
    rows = []
    for item in items:
        media = item.get("media") or {}
        meta = media.get("metadata") or {}
        asin = meta.get("asin")
        duration = media.get("duration")
        if not asin or not duration:
            continue
        try:
            aud = get_json(f"https://api.audnex.us/books/{urllib.parse.quote(asin)}")
        except Exception:
            continue
        runtime_min = aud.get("runtimeLengthMin")
        if not runtime_min:
            continue
        aud_seconds = runtime_min * 60
        diff = duration - aud_seconds
        pct = abs(diff) / max(duration, aud_seconds)
        if abs(diff) >= args.min_seconds and pct >= args.min_pct:
            rows.append(
                {
                    "id": item["id"],
                    "title": meta.get("title"),
                    "subtitle": meta.get("subtitle"),
                    "asin": asin,
                    "publisher": meta.get("publisher"),
                    "duration": int(duration),
                    "audnex_duration": int(aud_seconds),
                    "diff": int(diff),
                    "pct": round(pct * 100, 2),
                    "path": item.get("path"),
                }
            )

    rows.sort(key=lambda row: abs(row["diff"]), reverse=True)

    if args.json:
        json.dump(rows, sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")
        return 0

    for row in rows:
        sign = "+" if row["diff"] > 0 else "-"
        print(
            f"{row['title']}\t{row['asin']}\t"
            f"{row['duration']}\t{row['audnex_duration']}\t"
            f"{sign}{abs(row['diff'])}\t{row['pct']}%"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
