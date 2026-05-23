#!/usr/bin/env python3
"""Sync JSON sidecars under /mnt/data/Media/Magazines into Komga metadata.

Walks every <basename>.json that sits next to <basename>.pdf, looks up the
matching book in Komga by filename, and PATCHes book + series metadata with the
sidecar's title / TOC / authors / keywords / release date / issue URL. Every
field is locked so a later library refresh does not stomp the sync.

The script is idempotent: it GETs current metadata first and only PATCHes when
something actually changed.

Env:
  KOMGA_URL          (default https://magazines.ablz.au)
  KOMGA_API_KEY      (required)  X-API-Key header value
  SIDECAR_ROOT       (default /mnt/data/Media/Magazines)
  DRY_RUN            (default 0 = off)  log intended PATCHes, no writes

Exit codes:
  0  success (with or without changes)
  1  bad config / unreachable Komga
  2  one or more sidecars failed to sync (others may have succeeded)
"""
from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from collections import OrderedDict
from pathlib import Path
from typing import Any, Iterable

KOMGA_URL = os.environ.get("KOMGA_URL", "https://magazines.ablz.au").rstrip("/")
API_KEY = os.environ.get("KOMGA_API_KEY", "")
SIDECAR_ROOT = Path(os.environ.get("SIDECAR_ROOT", "/mnt/data/Media/Magazines"))
DRY_RUN = os.environ.get("DRY_RUN", "0") not in ("", "0", "false", "False")

# Komga book-tag limits are not documented; cap defensively to keep the UI fast.
MAX_TAGS_PER_BOOK = 60
MAX_TAG_CHARS_TOTAL = 500

# Series-level constants — applied per-year series within each library.
SERIES_DEFAULTS = {
    "GAW": {
        "title_prefix": "Grapegrower & Winemaker",
        "summary": (
            "Grapegrower & Winemaker is Australia's leading monthly trade "
            "publication for the wine industry, published by Winetitles Media."
        ),
        "publisher": "Winetitles Media",
        "genres": ["Magazine", "Wine industry"],
        "language": "en",
    },
    "WVJ": {
        "title_prefix": "Wine & Viticulture Journal",
        "summary": (
            "Wine & Viticulture Journal is a peer-reviewed quarterly covering "
            "viticultural and oenological research and practice in Australia, "
            "published by Winetitles Media."
        ),
        "publisher": "Winetitles Media",
        "genres": ["Magazine", "Wine industry"],
        "language": "en",
    },
}


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def http(method: str, path: str, body: Any = None) -> tuple[int, Any]:
    """Issue a Komga API request and return (status, decoded-json-or-None)."""
    url = f"{KOMGA_URL}{path}"
    data = None
    headers = {"X-API-Key": API_KEY, "Accept": "application/json"}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            status = resp.status
    except urllib.error.HTTPError as e:
        return e.code, {"error": e.read().decode("utf-8", errors="replace")}
    except urllib.error.URLError as e:
        log(f"  network error: {e}")
        return 0, None
    if not raw:
        return status, None
    try:
        return status, json.loads(raw)
    except json.JSONDecodeError:
        return status, raw.decode("utf-8", errors="replace")


def get(path: str) -> tuple[int, Any]:
    return http("GET", path, None)


def patch(path: str, body: dict) -> tuple[int, Any]:
    return http("PATCH", path, body)


# ---------------------------------------------------------------------------
# Sidecar parsing


def kind_for(sidecar: Path) -> str:
    """GAW vs WVJ based on the .../Magazines/<kind>/<year>/<file>.json layout."""
    parts = sidecar.parts
    if "GAW" in parts:
        return "GAW"
    if "WVJ" in parts:
        return "WVJ"
    return "UNKNOWN"


def release_date(side: dict, kind: str) -> str | None:
    year = side.get("year")
    if not year:
        return None
    if kind == "GAW":
        month = side.get("month") or 1
        return f"{int(year):04d}-{int(month):02d}-01"
    if kind == "WVJ":
        # Quarterly: V*-1 ~ Summer, V*-2 ~ Autumn, V*-3 ~ Winter, V*-4 ~ Spring
        # in Southern-hemisphere terms. Pin to first day of approximate quarter.
        issue = side.get("issue") or 1
        month = {1: 1, 2: 4, 3: 7, 4: 10}.get(int(issue), 1)
        return f"{int(year):04d}-{int(month):02d}-01"
    return None


def book_number(side: dict, kind: str) -> tuple[str, float]:
    if kind == "GAW":
        n = int(side.get("issue_number") or 0)
        return (str(n), float(n))
    if kind == "WVJ":
        vol = int(side.get("volume") or 0)
        iss = int(side.get("issue") or 0)
        return (f"Vol{vol}-{iss:02d}", float(vol * 100 + iss))
    return ("", 0.0)


def dedup(items: Iterable[str]) -> list[str]:
    """Preserve first-occurrence order while deduping (case-insensitively)."""
    seen: "OrderedDict[str, str]" = OrderedDict()
    for raw in items:
        if not raw:
            continue
        s = str(raw).strip()
        if not s:
            continue
        k = s.casefold()
        if k not in seen:
            seen[k] = s
    return list(seen.values())


def build_tags(articles: list[dict]) -> list[str]:
    tags: list[str] = []
    for a in articles:
        for kw in a.get("keywords") or []:
            tags.append(str(kw).strip().lower())
    tags = dedup(tags)

    capped: list[str] = []
    total = 0
    for t in tags:
        if len(capped) >= MAX_TAGS_PER_BOOK:
            break
        # +2 accounts for the ", " join overhead, matching how Komga shows them.
        if total + len(t) + 2 > MAX_TAG_CHARS_TOTAL:
            break
        capped.append(t)
        total += len(t) + 2
    return capped


def build_authors(articles: list[dict]) -> list[dict]:
    names = dedup(str(a["author"]) for a in articles if a.get("author"))
    return [{"name": n, "role": "writer"} for n in names]


def build_summary(side: dict) -> str:
    arts = side.get("articles") or []
    lines: list[str] = []
    # Heading: link back to the issue page for the reader.
    issue_url = side.get("issue_url")
    if issue_url:
        lines.append(f"Issue page: <{issue_url}>")
        lines.append("")
    lines.append("## Contents")
    lines.append("")
    for i, art in enumerate(arts, 1):
        title = (art.get("title") or "").strip() or f"Article {i}"
        author = (art.get("author") or "").strip()
        pages = (art.get("page_numbers") or "").strip()
        url = (art.get("url") or "").strip()

        bits: list[str] = [f"{i}. "]
        bits.append(f"[{title}]({url})" if url else title)
        if author:
            bits.append(f" — {author}")
        if pages:
            bits.append(f" (pp. {pages})")
        lines.append("".join(bits))
    return "\n".join(lines)


def book_title(side: dict) -> str:
    title = (side.get("title") or "").strip()
    return title or side.get("pdf_filename") or "Untitled"


# ---------------------------------------------------------------------------
# Komga interactions


def stem_for(sidecar: Path) -> str:
    """Filename stem to match a Komga book against (no .json/.pdf extension)."""
    return sidecar.stem


_book_cache: dict[str, str] = {}
_book_cache_loaded = False


def _load_book_cache() -> None:
    """Page through every book in Komga once, keyed by filesystem url.

    Komga's ?search= matches metadata.title — useless after we relabel books.
    The url field is a stable filesystem path, so we cache the full map up
    front and look up by exact match.
    """
    global _book_cache_loaded
    if _book_cache_loaded:
        return
    page = 0
    size = 500
    total_loaded = 0
    while True:
        status, body = get(f"/api/v1/books?unpaged=false&page={page}&size={size}")
        if status != 200 or not isinstance(body, dict):
            log(f"  warn: book listing page {page} returned {status}")
            break
        for entry in body.get("content") or []:
            url = entry.get("url")
            bid = entry.get("id")
            if url and bid:
                _book_cache[url] = bid
                total_loaded += 1
        if body.get("last", True):
            break
        page += 1
    log(f"  cached {total_loaded} books from Komga")
    _book_cache_loaded = True


def find_book_id(url_path: str) -> str | None:
    _load_book_cache()
    return _book_cache.get(url_path)


def needs_patch_book(current: dict, desired: dict) -> dict:
    """Return only the fields whose current value differs from desired."""
    diff: dict = {}
    cur_meta = current or {}
    # Komga returns authors as [{name, role}] — match shape.
    for key, want in desired.items():
        have = cur_meta.get(key)
        if key == "authors":
            cur_norm = [
                {"name": a.get("name"), "role": a.get("role")}
                for a in (have or [])
            ]
            if cur_norm != want:
                diff[key] = want
        elif key == "links":
            cur_norm = [
                {"label": l.get("label"), "url": l.get("url")}
                for l in (have or [])
            ]
            if cur_norm != want:
                diff[key] = want
        elif key == "tags":
            # Komga stores tags as a set; compare set-wise.
            if set(have or []) != set(want):
                diff[key] = want
        elif key == "numberSort":
            # Float comparison with epsilon.
            try:
                if abs(float(have or 0) - float(want)) > 1e-6:
                    diff[key] = want
            except (TypeError, ValueError):
                diff[key] = want
        else:
            if have != want:
                diff[key] = want
    return diff


def needs_patch_series(current: dict, desired: dict) -> dict:
    diff: dict = {}
    for key, want in desired.items():
        have = current.get(key)
        if key == "genres":
            # Komga normalises genres to lowercase on store.
            cur_norm = {str(g).casefold() for g in (have or [])}
            want_norm = {str(g).casefold() for g in want}
            if cur_norm != want_norm:
                diff[key] = want
        else:
            if have != want:
                diff[key] = want
    return diff


def attach_locks(payload: dict) -> dict:
    """Append a <field>Lock: true companion for every set field."""
    out = dict(payload)
    for k in list(payload.keys()):
        out[f"{k}Lock"] = True
    return out


def sync_book(sidecar: Path, kind: str) -> tuple[str, str | None]:
    """Return ("ok"|"skip"|"err", "<book-id-or-msg>")."""
    try:
        side = json.loads(sidecar.read_text(encoding="utf-8"))
    except Exception as e:
        return "err", f"{sidecar}: bad json ({e})"

    pdf_name = side.get("pdf_filename")
    if not pdf_name:
        # Fallback: assume <stem>.pdf next to the sidecar.
        pdf_name = f"{sidecar.stem}.pdf"
    pdf_path_on_komga = str(sidecar.with_name(pdf_name))

    book_id = find_book_id(pdf_path_on_komga)
    if not book_id:
        return "err", f"no book matches {pdf_path_on_komga}"

    status, current = get(f"/api/v1/books/{book_id}")
    if status != 200 or not isinstance(current, dict):
        return "err", f"book {book_id}: GET status {status}"
    cur_meta = current.get("metadata") or {}

    number, number_sort = book_number(side, kind)
    desired = {
        "title": book_title(side),
        "summary": build_summary(side),
        "number": number,
        "numberSort": number_sort,
        "tags": build_tags(side.get("articles") or []),
        "authors": build_authors(side.get("articles") or []),
    }
    rdate = release_date(side, kind)
    if rdate:
        desired["releaseDate"] = rdate
    issue_url = side.get("issue_url")
    if issue_url:
        desired["links"] = [{"label": "Issue page", "url": issue_url}]

    diff = needs_patch_book(cur_meta, desired)
    if not diff:
        return "skip", book_id
    payload = attach_locks(diff)

    if DRY_RUN:
        log(f"  DRY_RUN book {book_id}: would patch fields={list(diff)}")
        return "ok", book_id

    status, body = patch(f"/api/v1/books/{book_id}/metadata", payload)
    if status not in (200, 204):
        return "err", f"book {book_id}: PATCH status {status} body={body!r}"
    return "ok", book_id


def sync_series(series_id: str, year: str, kind: str) -> tuple[str, str]:
    cfg = SERIES_DEFAULTS.get(kind)
    if not cfg:
        return "skip", series_id

    status, current = get(f"/api/v1/series/{series_id}")
    if status != 200 or not isinstance(current, dict):
        return "err", f"series {series_id}: GET status {status}"
    cur_meta = current.get("metadata") or {}

    desired = {
        "title": f"{cfg['title_prefix']} ({year})",
        "summary": cfg["summary"],
        "publisher": cfg["publisher"],
        "genres": cfg["genres"],
        "language": cfg["language"],
    }
    diff = needs_patch_series(cur_meta, desired)
    if not diff:
        return "skip", series_id
    payload = attach_locks(diff)

    if DRY_RUN:
        log(f"  DRY_RUN series {series_id} ({year}): would patch fields={list(diff)}")
        return "ok", series_id

    status, body = patch(f"/api/v1/series/{series_id}/metadata", payload)
    if status not in (200, 204):
        return "err", f"series {series_id}: PATCH status {status} body={body!r}"
    return "ok", series_id


# ---------------------------------------------------------------------------
# Main


def find_sidecars(root: Path) -> list[Path]:
    out: list[Path] = []
    for p in sorted(root.rglob("*.json")):
        # Heuristic: sidecar must have a matching .pdf next to it.
        if p.with_suffix(".pdf").is_file():
            out.append(p)
    return out


YEAR_RE = re.compile(r"/(?P<kind>GAW|WVJ)/(?P<year>\d{4})/")


def main() -> int:
    if not API_KEY:
        log("KOMGA_API_KEY not set")
        return 1
    if not SIDECAR_ROOT.is_dir():
        log(f"SIDECAR_ROOT not a directory: {SIDECAR_ROOT}")
        return 1

    # Sanity-check Komga reachability.
    status, _ = get("/api/v1/libraries")
    if status != 200:
        log(f"Komga unreachable: GET /api/v1/libraries -> {status}")
        return 1

    sidecars = find_sidecars(SIDECAR_ROOT)
    log(f"Found {len(sidecars)} sidecars under {SIDECAR_ROOT}")

    ok_books = skip_books = err_books = 0
    series_seen: dict[tuple[str, str], str] = {}  # (kind, year) -> seriesId

    for side in sidecars:
        kind = kind_for(side)
        result, msg = sync_book(side, kind)
        if result == "ok":
            ok_books += 1
            log(f"ok   {kind} {side.relative_to(SIDECAR_ROOT)} -> {msg}")
        elif result == "skip":
            skip_books += 1
            log(f"skip {kind} {side.relative_to(SIDECAR_ROOT)} -> {msg}")
        else:
            err_books += 1
            log(f"ERR  {kind} {side.relative_to(SIDECAR_ROOT)} -> {msg}")
            continue

        # Track series for per-year metadata.
        m = YEAR_RE.search(str(side))
        if m and result != "err":
            year = m.group("year")
            book_id = msg if result in ("ok", "skip") else None
            if book_id:
                # Resolve seriesId once per book; cache by (kind, year).
                key = (kind, year)
                if key not in series_seen:
                    s, body = get(f"/api/v1/books/{book_id}")
                    if s == 200 and isinstance(body, dict):
                        series_seen[key] = body.get("seriesId", "")

    log("")
    log(f"book sync: ok={ok_books} skip={skip_books} err={err_books}")

    ok_series = skip_series = err_series = 0
    for (kind, year), sid in series_seen.items():
        if not sid:
            continue
        result, msg = sync_series(sid, year, kind)
        if result == "ok":
            ok_series += 1
            log(f"ok   series {kind} {year} -> {sid}")
        elif result == "skip":
            skip_series += 1
            log(f"skip series {kind} {year} -> {sid}")
        else:
            err_series += 1
            log(f"ERR  series {kind} {year} -> {msg}")

    log(f"series sync: ok={ok_series} skip={skip_series} err={err_series}")

    return 2 if (err_books or err_series) else 0


if __name__ == "__main__":
    sys.exit(main())
