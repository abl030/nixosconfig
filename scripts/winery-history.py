#!/usr/bin/env python3
"""Retain original HA history in immutable gzip chunks before Recorder purges it."""
import argparse
import fcntl
import gzip
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone
from urllib.error import HTTPError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

UTC = timezone.utc
ENTITIES = (
    "sensor.indoor_water_meter_total_water_litres",
    "sensor.indoor_water_meter_flow_rate",
    "sensor.sa_generation_power",
    "sensor.sa_import_export_power",
)


def iso(value):
    return value.astimezone(UTC).isoformat()


def stamp(value):
    return value.strftime("%Y%m%dT%H%M%SZ")


def read_json(path):
    return json.loads(path.read_text())


def atomic(path, content, mode=0o640):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".pending-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(name, mode)
        os.replace(name, path)
        directory = os.open(path.parent, os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def save_json(path, value, mode=0o640):
    atomic(path, json.dumps(value, sort_keys=True, indent=2).encode()+b"\n", mode)


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RuntimeError("HA redirect rejected; check configured origin")


def token_from(path):
    # Literal dotenv parsing, never shell evaluation; only the archive credential.
    for line in path.read_text().splitlines():
        key, _, value = line.partition("=")
        if key == "HA_TOKEN" and value.strip():
            return value.strip().strip('"').strip("'")
    raise RuntimeError("Missing HA_TOKEN in credential")


def fetch(url, token, start, end):
    parsed = urlsplit(url)
    if parsed.scheme != "https" or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("HA URL must be an HTTPS origin without credentials")
    query = urlencode({"filter_entity_id": ",".join(ENTITIES), "end_time": iso(end),
                       "significant_changes_only": "0"})
    request = Request(f"{url.rstrip('/')}/api/history/period/{iso(start)}?{query}",
                      headers={"Authorization": f"Bearer {token}"})
    opener = build_opener(NoRedirect())
    for attempt in range(3):
        try:
            with opener.open(request, timeout=60) as response:
                body = response.read(32*1024*1024+1)
                if len(body) > 32*1024*1024:
                    raise RuntimeError("HA history exceeds 32 MiB response limit")
                return json.loads(body)
        except HTTPError as error:
            if error.code < 500 or attempt == 2:
                raise RuntimeError(f"HA history HTTP {error.code}") from None
        except (TimeoutError, OSError):
            if attempt == 2:
                raise RuntimeError("HA history transport failed") from None
        time.sleep(2**attempt)


def inspect_history(history):
    if not isinstance(history, list):
        raise ValueError("Invalid history envelope")
    seen = set()
    counts = {}
    unavailable = {}
    for series in history:
        if not isinstance(series, list) or not series:
            raise ValueError("Missing history series")
        entity = series[0].get("entity_id")
        if entity not in ENTITIES or entity in seen:
            raise ValueError("Unexpected or duplicate history entity")
        seen.add(entity)
        last = None
        for point in series:
            if point.get("entity_id") != entity or not isinstance(point.get("state"), str):
                raise ValueError("Malformed history point")
            ts = datetime.fromisoformat(point["last_updated"])
            if ts.tzinfo is None or (last is not None and ts < last):
                raise ValueError("Unordered or unzoned history timestamps")
            last = ts
        counts[entity] = len(series)
        unavailable[entity] = sum(p['state'] in ('unknown', 'unavailable') for p in series)
    if seen != set(ENTITIES):
        raise ValueError("HA omitted an archive entity; cursor not advanced")
    return {"records": counts, "unavailable_records": unavailable}


def collect(root, url, credential, now=None, getter=fetch):
    now = now or datetime.now(UTC)
    # Leave at least five minutes for Recorder commits at the end of a chunk.
    end = (now-timedelta(minutes=5)).replace(minute=0, second=0, microsecond=0)
    status_path = root/"capture.json"
    previous = read_json(status_path) if status_path.exists() else None
    start = datetime.fromisoformat(previous['through']) if previous else end-timedelta(days=10)
    earliest = end-timedelta(days=10)
    if start < earliest:
        gap = {"start": iso(start), "end": iso(earliest), "detected_at": iso(now),
               "reason": "Outside bounded ten-day raw-history recovery window; not assumed zero"}
        save_json(root/"gaps"/f"{stamp(start)}-{stamp(earliest)}.json", gap)
        print("WINERY_HISTORY_GAP: raw-history recovery window exceeded", flush=True)
        start = earliest
    token = token_from(credential)
    while start < end:
        stop = min(start+timedelta(days=1), end)
        name = f"chunks/{stamp(start)}-{stamp(stop)}.json.gz"
        path = root/name
        if path.exists():
            document = json.loads(gzip.decompress(path.read_bytes()))
            if document['start'] != iso(start) or document['end'] != iso(stop):
                raise ValueError("Existing archive chunk has wrong boundaries")
            quality = inspect_history(document['history'])
        else:
            # Five-minute overlap preserves transitions near query boundaries.
            query_start = start-timedelta(minutes=5)
            history = getter(url, token, query_start, stop)
            quality = inspect_history(history)
            document = {"schema": 1, "start": iso(start), "end": iso(stop),
                        "query_start": iso(query_start), "collected_at": iso(now),
                        "source": url, "entities": ENTITIES, "quality": quality,
                        "notes": ["Unmodified HA history response; no resampling or clipping",
                                  "First state in each series may be a Recorder boundary state",
                                  "Overlap records must be deduplicated when replaying",
                                  "Requested interval is not proof of source completeness"],
                        "history": history}
            atomic(path, gzip.compress(json.dumps(document, separators=(',', ':')).encode(), mtime=0))
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        # Only commit progress after a durable, validated archive chunk exists.
        save_json(status_path, {"schema": 1, "through": iso(stop), "checked_at": iso(now),
                               "chunk": name, "sha256": digest, "quality": quality})
        print(f"Archived through {iso(stop)}: {sum(quality['records'].values())} records", flush=True)
        start = stop


def backup(root, destination):
    status = read_json(root/"capture.json")
    copied = 0
    for folder in ("chunks", "gaps", "bootstrap"):
        source = root/folder
        if not source.exists():
            continue
        for path in sorted(source.rglob('*')):
            if not path.is_file() or path.name.startswith('.pending-'):
                continue
            relative = path.relative_to(root)
            target = destination/relative
            content = path.read_bytes()
            if target.exists():
                if hashlib.sha256(target.read_bytes()).digest() != hashlib.sha256(content).digest():
                    raise ValueError(f"Backup checksum mismatch: {relative}")
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.parent.chmod(0o755)
                atomic(target, content, 0o644)
                if target.read_bytes() != content:
                    raise ValueError(f"Backup read-back mismatch: {relative}")
                copied += 1
    save_json(destination/"capture.json", status, 0o644)
    save_json(root/"backup.json", {"through": status['through'], "checked_at": iso(datetime.now(UTC)),
                                  "destination": str(destination), "copied_files": copied})
    print(f"Backup verified through {status['through']}; {copied} new files", flush=True)


def check(root, max_age_hours=4):
    now = datetime.now(UTC)
    status = read_json(root/"capture.json")
    for filename in ('capture.json', 'backup.json'):
        record = read_json(root/filename)
        through = datetime.fromisoformat(record['through'])
        if not timedelta(0) <= now-through <= timedelta(hours=max_age_hours):
            raise ValueError(f"Stale archive progress: {filename}")
    path = root/status['chunk']
    if hashlib.sha256(path.read_bytes()).hexdigest() != status['sha256']:
        raise ValueError("Latest chunk checksum mismatch")
    inspect_history(json.loads(gzip.decompress(path.read_bytes()))['history'])
    print(f"Archive and backup healthy through {status['through']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['collect', 'backup', 'check'])
    parser.add_argument('--data-dir', type=Path, required=True)
    parser.add_argument('--backup-dir', type=Path)
    parser.add_argument('--url', default='https://home.ablz.au')
    parser.add_argument('--credential', type=Path)
    args = parser.parse_args()
    try:
        if args.action == 'check':
            check(args.data_dir)
            return
        # Backup has its own lock: a stalled share cannot block collection.
        with (args.data_dir/f'.{args.action}.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if args.action == 'collect':
                if args.credential is None:
                    parser.error('--credential required for collection')
                collect(args.data_dir, args.url, args.credential)
            else:
                if args.backup_dir is None:
                    parser.error('--backup-dir required for backup')
                backup(args.data_dir, args.backup_dir)
    except Exception as error:
        # Avoid dumping response bodies, request headers or credential material.
        print(f'WINERY_HISTORY_FAILED: {args.action}: {type(error).__name__}: {error}', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
