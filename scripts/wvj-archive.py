#!/usr/bin/env python3
# See docs/wiki/services/wvj-archive.md for the full write-up, and
# docs/wiki/services/magazines.md for the overall magazine archive system.
"""One-shot archiver for the Wine & Viticulture Journal (winetitles.com.au/wvj).

The journal ended publication in 2024 (Vol 39 No 3 — lead article was
"farewell to the journal"). This script runs once to capture every recoverable
issue, then there's nothing left to do.

Walks https://winetitles.com.au/wvj/articles/ and for each issue:
  - downloads the FULL ISSUE PDF if present (Vol 33 No 2 onwards),
  - else synthesises one by downloading every per-article PDF and merging
    with qpdf (Vol 33 No 1 only),
  - else logs "no-pdf" (Vol 26-32 — same broken-archive issue as pre-Jul-2017
    GWM: forms exist but tmp.php returns 0 bytes).

Output layout:
  /mnt/data/Media/Magazines/WVJ/<YEAR>/V<vol>-<issue>_<basename>.pdf
  /mnt/data/Media/Magazines/WVJ/<YEAR>/V<vol>-<issue>_<basename>.json

Env:
  WT_USER, WT_PASS  (required)
  OUT_ROOT          (default /mnt/data/Media/Magazines/WVJ)
  SLEEP_SECS        (default 1.0)

Runtime deps: python3.10+, qpdf, poppler-utils (pdfinfo), exiftool.
"""

from __future__ import annotations

import http.cookiejar
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.parse
from html import unescape
from pathlib import Path
from urllib import request

BASE = "https://winetitles.com.au"
UA = "Mozilla/5.0 (X11; Linux x86_64) wvj-archive/1.0"

# WVJ slug shapes seen in the archive:
#   wine-viticulture-journal-volume-<V>-no-<I>-<YYYY>
#   wine-viticulture-journal-volume-<V>-no-<I>          (Vol 33 No 1, sans year)
#   volume-no-1-2018                                    (the off-slug for Vol 33 No 1)
#   wine-viticulture-journal-volume-35-no-2-2020-full-issue  (full-issue link in
#       the archive listing — treat as Vol 35 No 2 2020)
_SLUG_RE = re.compile(r'volume-(\d+)-no-(\d+)(?:-(\d{4}))?')


def parse_slug(slug: str) -> tuple[int, int, int | None]:
    """Return (volume, issue, year_or_None). Falls back through patterns for
    the malformed Vol 33 No 1 2018 slug."""
    m = _SLUG_RE.search(slug)
    if m:
        vol = int(m.group(1))
        iss = int(m.group(2))
        year = int(m.group(3)) if m.group(3) else None
        return vol, iss, year
    # `volume-no-1-2018` — Vol 33 No 1 2018 — recognised by the year-only tail.
    m2 = re.match(r'volume-no-(\d+)-(\d{4})', slug)
    if m2:
        return 33, int(m2.group(1)), int(m2.group(2))
    raise ValueError(f"can't parse volume/issue from slug: {slug!r}")


# ----------------------------------------------------------------- http --

JAR = http.cookiejar.CookieJar()
OPENER = request.build_opener(request.HTTPCookieProcessor(JAR))
OPENER.addheaders = [("User-Agent", UA), ("Accept-Encoding", "identity")]


def http_get(url: str) -> str:
    with OPENER.open(url, timeout=60) as r:
        return r.read().decode("utf-8", errors="replace")


def http_post_stream(url: str, data: dict, dest: Path,
                     referer: str | None = None) -> tuple[int, dict]:
    body = urllib.parse.urlencode(data).encode()
    req = request.Request(url, data=body, method="POST")
    if referer:
        req.add_header("Referer", referer)
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    n = 0
    with OPENER.open(req, timeout=300) as r, tmp.open("wb") as f:
        headers = dict(r.headers)
        while True:
            chunk = r.read(64 * 1024)
            if not chunk:
                break
            f.write(chunk)
            n += len(chunk)
    if n == 0:
        tmp.unlink(missing_ok=True)
        return 0, headers
    tmp.rename(dest)
    return n, headers


def login(user: str, pwd: str) -> None:
    JAR.set_cookie(http.cookiejar.Cookie(
        version=0, name="wordpress_test_cookie",
        value=urllib.parse.quote("WP Cookie check"),
        port=None, port_specified=False,
        domain="winetitles.com.au", domain_specified=True, domain_initial_dot=False,
        path="/", path_specified=True,
        secure=True, expires=None, discard=False,
        comment=None, comment_url=None, rest={}, rfc2109=False,
    ))
    body = urllib.parse.urlencode({
        "log": user, "pwd": pwd, "wp-submit": "Log In",
        "redirect_to": f"{BASE}/wvj/", "testcookie": "1",
    }).encode()
    with OPENER.open(request.Request(f"{BASE}/wp-login.php", data=body), timeout=60) as r:
        r.read()
    if not any(c.name.startswith("wordpress_logged_in_") for c in JAR):
        sys.exit("ERROR: login failed")


# ------------------------------------------------------------ scraping --

_FIELD_RE = re.compile(
    r'<p>\s*<strong>([A-Za-z ()&;]+):\s*</strong>\s*(.*?)\s*</p>', re.S,
)


def list_issues() -> list[str]:
    """Return issue slugs from /wvj/articles/, filtered to actual magazine issues."""
    html = http_get(f"{BASE}/wvj/articles/")
    slugs: list[str] = []
    seen: set[str] = set()
    for m in re.finditer(r'/wvj/articles/([a-z0-9-]+)/', html):
        s = m.group(1)
        if s in seen or s == "feed":
            continue
        if s.endswith("-full-issue"):
            # Strip the "-full-issue" suffix to get the issue slug — happens
            # for the Vol 35 No 2 2020 entry which links the full-issue page
            # directly from the archive listing.
            parent = s[: -len("-full-issue")]
            if parent in seen:
                continue
            s = parent
        try:
            parse_slug(s)
        except ValueError:
            continue
        seen.add(s)
        slugs.append(s)
    return slugs


_ISSUE_HTML_CACHE: dict[str, str] = {}


def _issue_html(slug: str) -> str:
    h = _ISSUE_HTML_CACHE.get(slug)
    if h is None:
        h = http_get(f"{BASE}/wvj/articles/{slug}/")
        _ISSUE_HTML_CACHE[slug] = h
    return h


def find_full_issue_slug(issue_slug: str) -> str | None:
    m = re.search(
        rf'/wvj/articles/{re.escape(issue_slug)}/([a-z0-9-]+-full-issue)/',
        _issue_html(issue_slug),
    )
    return m.group(1) if m else None


def article_slugs_in_order(issue_slug: str) -> list[str]:
    seen: list[str] = []
    seen_set: set[str] = set()
    for m in re.finditer(
        rf'/wvj/articles/{re.escape(issue_slug)}/([a-z0-9-]+)/',
        _issue_html(issue_slug),
    ):
        s = m.group(1)
        if s in seen_set or s.endswith("-full-issue"):
            continue
        seen_set.add(s)
        seen.append(s)
    return seen


def parse_article_meta(html: str) -> dict:
    fields: dict[str, str] = {}
    for m in _FIELD_RE.finditer(html):
        key = m.group(1).strip().replace("&amp;", "&")
        raw = re.sub(r'<[^>]+>', '', m.group(2))
        val = re.sub(r'\s+', ' ', unescape(raw)).strip()
        fields[key] = val
    out = {
        "title": fields.get("Title", ""),
        "author": fields.get("Author", ""),
        "keywords": [k.strip() for k in fields.get("Keywords", "").split(",") if k.strip()],
        "page_numbers": fields.get("Page Number(s)", ""),
    }
    if not out["title"]:
        m = re.search(r'<title>([^<]+?)\s*-\s*Winetitles</title>', html)
        if m:
            out["title"] = unescape(m.group(1)).strip()
    return out


def scrape_form(url: str) -> tuple[str, str, dict]:
    html = http_get(url)
    docid = re.search(r'name="docid"[^>]*value="(\d+)"', html)
    dockey = re.search(r'name="dockey"[^>]*value="([^"]+)"', html)
    if not docid or not dockey:
        raise RuntimeError(f"docid/dockey missing on {url}")
    return docid.group(1), dockey.group(1), parse_article_meta(html)


# ---------------------------------------------------------------- pdf --

def pdf_page_count(p: Path) -> int:
    r = subprocess.run(["pdfinfo", str(p)], capture_output=True, text=True, check=True)
    for line in r.stdout.splitlines():
        if line.startswith("Pages:"):
            return int(line.split()[1])
    raise RuntimeError(f"no Pages: in pdfinfo {p}")


def qpdf_merge(parts: list[Path], dest: Path) -> None:
    cmd = ["qpdf", "--empty", "--pages"] + [
        arg for p in parts for arg in (str(p), "1-z")
    ] + ["--", str(dest)]
    subprocess.run(cmd, check=True)


def embed_pdf_metadata(pdf_path: Path, title: str, keywords: list[str],
                       subject: str = "Wine & Viticulture Journal") -> None:
    kw = ", ".join(sorted(set(k for k in keywords if k)))[:4000]
    subprocess.run([
        "exiftool", "-q", "-P", "-overwrite_original",
        f"-Title={title}", f"-Subject={subject}", f"-Keywords={kw}",
        str(pdf_path),
    ], check=False)


def filename_from_cd(cd: str, fallback: str) -> str:
    m = re.search(r'filename="([^"]+)"', cd)
    return m.group(1) if m else fallback


# -------------------------------------------------------- per issue op --

def existing_artifacts(out_root: Path, vol: int, issue: int, year: int) -> tuple[Path | None, Path | None]:
    """Look for already-downloaded PDF + sidecar under <YEAR>/V<vol>-<issue>_*.{pdf,json}."""
    year_dir = out_root / str(year)
    if not year_dir.exists():
        return None, None
    prefix = f"V{vol}-{issue}_"
    pdfs = sorted(year_dir.glob(f"{prefix}*.pdf"))
    sidecars = sorted(year_dir.glob(f"{prefix}*.json"))
    return (pdfs[0] if pdfs else None, sidecars[0] if sidecars else None)


def download_full_issue(slug: str, vol: int, issue: int, year: int,
                        out_root: Path, sleep_s: float) -> Path | None:
    full = find_full_issue_slug(slug)
    if not full:
        return None
    full_url = f"{BASE}/wvj/articles/{slug}/{full}/"
    docid, dockey, _ = scrape_form(full_url)
    year_dir = out_root / str(year)
    staging = year_dir / f"V{vol}-{issue}_DOWNLOADING.pdf"
    n, headers = http_post_stream(
        f"{BASE}/wp-content/uploads/tmp.php",
        {"docid": docid, "dockey": dockey},
        staging, referer=full_url,
    )
    if n == 0:
        return None
    cd = headers.get("Content-Disposition", "") or ""
    orig = filename_from_cd(cd, f"WVJ_V{vol}-I{issue}_{year}.pdf")
    final = year_dir / f"V{vol}-{issue}_{orig}"
    staging.rename(final)
    time.sleep(sleep_s)
    return final


def synthesise_from_articles(slug: str, vol: int, issue: int, year: int,
                             out_root: Path, sleep_s: float,
                             empty_fail_fast: int = 2) -> tuple[Path | None, list[dict]]:
    year_dir = out_root / str(year)
    final = year_dir / f"V{vol}-{issue}_WVJ_V{vol}-I{issue}_{year}_synthetic.pdf"
    article_slugs = article_slugs_in_order(slug)
    if not article_slugs:
        return None, []
    work_dir = year_dir / f"V{vol}-{issue}_{year}_parts"
    work_dir.mkdir(parents=True, exist_ok=True)
    parts: list[Path] = []
    records: list[dict] = []
    cumulative = 0
    empties = 0
    for idx, aslug in enumerate(article_slugs, 1):
        a_url = f"{BASE}/wvj/articles/{slug}/{aslug}/"
        try:
            docid, dockey, meta = scrape_form(a_url)
        except Exception as e:
            records.append({"order": idx, "slug": aslug, "url": a_url, "_error": str(e)})
            empties += 1
            if not parts and empties >= empty_fail_fast:
                shutil.rmtree(work_dir, ignore_errors=True)
                return None, records
            continue
        tmp = work_dir / f"{idx:02d}_{aslug[:60]}.pdf"
        n, _ = http_post_stream(f"{BASE}/wp-content/uploads/tmp.php",
                                {"docid": docid, "dockey": dockey},
                                tmp, referer=a_url)
        if n == 0:
            records.append({"order": idx, "slug": aslug, "url": a_url,
                            "title": meta["title"], "_error": "empty PDF"})
            empties += 1
            time.sleep(sleep_s)
            if not parts and empties >= empty_fail_fast:
                shutil.rmtree(work_dir, ignore_errors=True)
                return None, records
            continue
        pages = pdf_page_count(tmp)
        records.append({
            "order": idx, "slug": aslug, "url": a_url,
            "title": meta["title"], "author": meta["author"],
            "keywords": meta["keywords"],
            "print_page_numbers": meta["page_numbers"],
            "merged_pages": [cumulative + 1, cumulative + pages],
            "size_bytes": n,
        })
        parts.append(tmp)
        cumulative += pages
        empties = 0
        time.sleep(sleep_s)

    if not parts:
        shutil.rmtree(work_dir, ignore_errors=True)
        return None, records

    qpdf_merge(parts, final)
    shutil.rmtree(work_dir, ignore_errors=True)
    return final, records


def build_sidecar(slug: str, vol: int, issue: int, year: int, pdf_path: Path,
                  synthetic: bool, records: list[dict] | None,
                  sleep_s: float) -> dict:
    if synthetic and records is not None:
        articles = records
    else:
        articles = []
        for idx, aslug in enumerate(article_slugs_in_order(slug), 1):
            a_url = f"{BASE}/wvj/articles/{slug}/{aslug}/"
            try:
                html = http_get(a_url)
                meta = parse_article_meta(html)
                meta["url"] = a_url
                meta["order"] = idx
                articles.append(meta)
            except Exception as e:
                articles.append({"order": idx, "url": a_url, "_error": str(e)})
            time.sleep(sleep_s * 0.5)

    return {
        "publication": "Wine & Viticulture Journal",
        "volume": vol,
        "issue": issue,
        "year": year,
        "title": f"Wine & Viticulture Journal Vol {vol} No {issue} ({year})",
        "issue_url": f"{BASE}/wvj/articles/{slug}/",
        "issue_slug": slug,
        "pdf_path": str(pdf_path),
        "pdf_filename": pdf_path.name,
        "synthetic": synthetic,
        **({
            "synthesis_note": "Merged from per-article PDFs because winetitles "
                              "does not publish a single FULL ISSUE PDF for this issue."
        } if synthetic else {}),
        "articles": articles,
    }


def process_issue(slug: str, out_root: Path, sleep_s: float) -> dict:
    try:
        vol, issue, year = parse_slug(slug)
    except ValueError as e:
        return {"status": "bad-slug", "error": str(e)}
    if year is None:
        return {"status": "bad-slug", "error": f"no year in {slug!r}"}

    pdf_existing, json_existing = existing_artifacts(out_root, vol, issue, year)
    if pdf_existing and json_existing:
        return {"status": "skip-complete", "pdf": str(pdf_existing)}

    synthetic = False
    records: list[dict] | None = None
    pdf_path = pdf_existing
    pdf_freshly_obtained = False

    if pdf_path is None:
        pdf_path = download_full_issue(slug, vol, issue, year, out_root, sleep_s)
        if pdf_path is None:
            pdf_path, records = synthesise_from_articles(
                slug, vol, issue, year, out_root, sleep_s
            )
            if pdf_path is None:
                return {"status": "no-pdf"}
            synthetic = True
        pdf_freshly_obtained = True
    elif "_synthetic" in pdf_path.name:
        synthetic = True

    if json_existing is None:
        sidecar = build_sidecar(slug, vol, issue, year, pdf_path, synthetic,
                                records, sleep_s)
        all_kw: list[str] = []
        for a in sidecar["articles"]:
            all_kw.extend(a.get("keywords", []))
        subject = ("Wine & Viticulture Journal (synthetic full issue)"
                   if synthetic else "Wine & Viticulture Journal")
        embed_pdf_metadata(pdf_path, sidecar["title"], all_kw, subject=subject)
        json_path = pdf_path.with_suffix(".json")
        tmp = json_path.with_suffix(".json.part")
        tmp.write_text(json.dumps(sidecar, indent=2, ensure_ascii=False))
        tmp.rename(json_path)

    if pdf_freshly_obtained:
        return {"status": "synthesised" if synthetic else "downloaded",
                "pdf": str(pdf_path)}
    return {"status": "sidecar-only", "pdf": str(pdf_path)}


# --------------------------------------------------------------- main --

def main() -> int:
    user = os.environ.get("WT_USER")
    pwd = os.environ.get("WT_PASS")
    if not user or not pwd:
        sys.exit("ERROR: set WT_USER + WT_PASS")
    out_root = Path(os.environ.get("OUT_ROOT", "/mnt/data/Media/Magazines/WVJ"))
    sleep_s = float(os.environ.get("SLEEP_SECS", "1.0"))

    for tool in ("qpdf", "pdfinfo", "exiftool"):
        if not shutil.which(tool):
            sys.exit(f"ERROR: missing tool: {tool}")

    print(f"-> login as {user}", file=sys.stderr)
    login(user, pwd)
    print("-> listing issues ...", file=sys.stderr)
    slugs = list_issues()
    print(f"   {len(slugs)} issues listed", file=sys.stderr)

    counts: dict[str, int] = {}
    for slug in slugs:
        try:
            r = process_issue(slug, out_root, sleep_s)
        except Exception as e:
            r = {"status": "error", "error": str(e)}
        status = r.get("status", "?")
        counts[status] = counts.get(status, 0) + 1
        if status != "skip-complete":
            print(f"   {slug}: {r}", file=sys.stderr, flush=True)
        _ISSUE_HTML_CACHE.pop(slug, None)

    print(f"\nsummary: {counts}", file=sys.stderr)
    return 0 if counts.get("error", 0) == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
