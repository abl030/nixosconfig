#!/usr/bin/env python3
"""Publish reviewed plain lyrics to LRCLIB with auditable receipts."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


USER_AGENT = "nixosconfig-cd-preservation/1.0 (https://git.ablz.au/abl030/nixosconfig)"


def request_json(
    url: str,
    *,
    method: str = "GET",
    payload: dict[str, Any] | None = None,
    headers: dict[str, str] | None = None,
) -> tuple[int, Any]:
    body = None if payload is None else json.dumps(payload).encode()
    request_headers = {"User-Agent": USER_AGENT, **(headers or {})}
    if body is not None:
        request_headers["Content-Type"] = "application/json"
    request = urllib.request.Request(
        url, data=body, headers=request_headers, method=method
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            response_body = response.read().decode()
            return response.status, json.loads(response_body) if response_body else None
    except urllib.error.HTTPError as error:
        response_body = error.read().decode()
        try:
            parsed_body: Any = json.loads(response_body)
        except json.JSONDecodeError:
            parsed_body = response_body
        return error.code, parsed_body


def write_receipt(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def lookup(base_url: str, track: dict[str, Any]) -> tuple[int, Any, str]:
    query = urllib.parse.urlencode(
        {
            "track_name": track["trackName"],
            "artist_name": track["artistName"],
            "album_name": track["albumName"],
            "duration": track["duration"],
        }
    )
    url = f"{base_url}/api/get?{query}"
    status, response = request_json(url)
    return status, response, url


def solve_challenge(prefix: str, target_hex: str) -> int:
    target = bytes.fromhex(target_hex)
    nonce = 0
    while True:
        digest = hashlib.sha256(f"{prefix}{nonce}".encode()).digest()
        if digest <= target:
            return nonce
        nonce += 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("receipts", type=Path)
    parser.add_argument("--base-url", default="https://lrclib.net")
    parser.add_argument(
        "--publish",
        action="store_true",
        help="perform public writes; without this flag only validate and look up",
    )
    parser.add_argument(
        "--replace-existing",
        action="store_true",
        help="publish a reviewed revision when an existing entry differs",
    )
    args = parser.parse_args()

    manifest_path = args.manifest.resolve()
    tracks = json.loads(manifest_path.read_text())
    if not isinstance(tracks, list) or not tracks:
        raise SystemExit("manifest must be a non-empty JSON array")
    args.receipts.mkdir(parents=True, exist_ok=True)

    failures = 0
    for index, item in enumerate(tracks, start=1):
        lyric_path = (manifest_path.parent / item["lyricsFile"]).resolve()
        lyrics = lyric_path.read_text().strip()
        if not lyrics:
            raise SystemExit(f"empty lyric file: {lyric_path}")
        track = {
            "trackName": item["trackName"],
            "artistName": item["artistName"],
            "albumName": item["albumName"],
            "duration": item["duration"],
            "plainLyrics": lyrics,
            "syncedLyrics": None,
        }
        stem = f"{index:02d}"
        request_metadata = {
            key: value for key, value in track.items() if key not in {"plainLyrics"}
        }
        request_metadata.update(
            {
                "lyricsFile": str(lyric_path),
                "plainLyricsSha256": hashlib.sha256(lyrics.encode()).hexdigest(),
            }
        )
        write_receipt(args.receipts / f"{stem}-request.json", request_metadata)

        status, existing, lookup_url = lookup(args.base_url, track)
        write_receipt(
            args.receipts / f"{stem}-lookup-before.json",
            {"url": lookup_url, "status": status, "body": existing},
        )
        if status == 200 and existing.get("plainLyrics", "").strip() == lyrics:
            print(f"{stem}: already published with identical plain lyrics")
            continue
        if status == 200 and not args.replace_existing:
            print(
                f"{stem}: existing entry differs; refusing without --replace-existing",
                file=sys.stderr,
            )
            failures += 1
            continue
        if status not in {200, 404}:
            print(f"{stem}: lookup failed with HTTP {status}", file=sys.stderr)
            failures += 1
            continue
        publish_receipt = args.receipts / f"{stem}-publish.json"
        if status == 404 and publish_receipt.exists():
            prior_publish = json.loads(publish_receipt.read_text())
            if prior_publish.get("status") in {200, 201}:
                print(f"{stem}: publish accepted previously; verification pending")
                continue
        if not args.publish:
            print(f"{stem}: reviewed lyrics absent; dry run only")
            continue

        challenge_status, challenge = request_json(
            f"{args.base_url}/api/request-challenge", method="POST"
        )
        if challenge_status != 200:
            print(f"{stem}: challenge failed with HTTP {challenge_status}", file=sys.stderr)
            failures += 1
            continue
        nonce = solve_challenge(challenge["prefix"], challenge["target"])
        publish_token = f"{challenge['prefix']}:{nonce}"
        publish_status, publish_response = request_json(
            f"{args.base_url}/api/publish",
            method="POST",
            payload=track,
            headers={"X-Publish-Token": publish_token},
        )
        write_receipt(
            publish_receipt,
            {
                "challenge": challenge,
                "nonce": nonce,
                "status": publish_status,
                "body": publish_response,
            },
        )
        if publish_status not in {200, 201}:
            print(f"{stem}: publish failed with HTTP {publish_status}", file=sys.stderr)
            failures += 1
            continue

        post_status, published, post_url = lookup(args.base_url, track)
        write_receipt(
            args.receipts / f"{stem}-lookup-after.json",
            {"url": post_url, "status": post_status, "body": published},
        )
        if post_status != 200 or published.get("plainLyrics", "").strip() != lyrics:
            print(f"{stem}: post-publication verification failed", file=sys.stderr)
            failures += 1
            continue
        print(f"{stem}: published and verified")

    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
