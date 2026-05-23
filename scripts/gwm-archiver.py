#!/usr/bin/env python3
"""Grapegrower & Winemaker (winetitles.com.au) archiver.

For every magazine issue listed at https://winetitles.com.au/gwm/articles/:
  1. If the issue exposes a FULL ISSUE PDF (Apr 2018 -> present), download it.
  2. Else if the issue exposes per-article PDFs (Jul 2017 - Mar 2018), download
     each article PDF and merge into a synthetic FULL ISSUE PDF via qpdf.
  3. Else (Jan 2005 - Jun 2017): server-side files are missing -> skip.

For each PDF produced, write:
  - JSON sidecar with per-article TOC (title, author, keywords, page numbers,
    plus merged_pages range for synthetic issues).
  - Embedded PDF metadata (Title, Subject, Keywords) via exiftool.

Output layout (idempotent):
  <OUT_ROOT>/<YYYY>/<MM>_<basename>.pdf
  <OUT_ROOT>/<YYYY>/<MM>_<basename>.json

A weekly run on a fresh archive does nothing; on the day a new issue ships, it
adds exactly one PDF + JSON sidecar.

Env:
  WT_USER, WT_PASS   (required)  winetitles.com.au credentials
  OUT_ROOT           (default /mnt/data/Media/Magazines/GAW)
  SLEEP_SECS         (default 1.0)  delay between site fetches
  LIMIT              (default 0 = unlimited)  stop after N successful issues
  DRY_RUN            (default 0 = off)  report intended actions, no writes

Notifications (failure + new-issue) are wired by the systemd unit, not the
script — see modules/nixos/services/gwm-archiver.nix.

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
from dataclasses import dataclass
from html import unescape
from pathlib import Path
from urllib import request

BASE = "https://winetitles.com.au"
UA = "Mozilla/5.0 (X11; Linux x86_64) gwm-archiver/1.0"
MONTHS = [
    "january", "february", "march", "april", "may", "june",
    "july", "august", "september", "october", "november", "december",
]
MONTH_TITLES = [m.capitalize() for m in MONTHS]

# Anchor for issue-number <-> year/month derivation.
# May 2026 == issue 748. The mapping is linear (one issue per month).
ANCHOR_N = 748
ANCHOR_YEAR = 2026
ANCHOR_MONTH = 5  # 1=Jan ... 12=Dec


# ---------------------------------------------------------------- date math --

def year_month_for(n: int) -> tuple[int, int]:
    idx = (ANCHOR_YEAR * 12 + (ANCHOR_MONTH - 1)) - (ANCHOR_N - n)
    return idx // 12, (idx % 12) + 1


def slug_for(n: int) -> str:
    _, m = year_month_for(n)
    return f"{MONTHS[m - 1]}-{n}"


# ------------------------------------------------------------- http session --

JAR = http.cookiejar.CookieJar()
OPENER = request.build_opener(request.HTTPCookieProcessor(JAR))
OPENER.addheaders = [("User-Agent", UA), ("Accept-Encoding", "identity")]


def http_get(url: str, referer: str | None = None) -> str:
    req = request.Request(url)
    if referer:
        req.add_header("Referer", referer)
    with OPENER.open(req, timeout=60) as r:
        return r.read().decode("utf-8", errors="replace")


def http_post_stream(url: str, data: dict, dest: Path,
                     referer: str | None = None) -> int:
    body = urllib.parse.urlencode(data).encode()
    req = request.Request(url, data=body, method="POST")
    if referer:
        req.add_header("Referer", referer)
    n = 0
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    with OPENER.open(req, timeout=300) as r, tmp.open("wb") as f:
        while True:
            chunk = r.read(64 * 1024)
            if not chunk:
                break
            f.write(chunk)
            n += len(chunk)
    if n == 0:
        tmp.unlink(missing_ok=True)
        return 0
    tmp.rename(dest)
    return n


def login(user: str, pwd: str) -> None:
    # wp-login.php requires wordpress_test_cookie pre-seeded; sets
    # wordpress_logged_in_<hash> on success.
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
        "redirect_to": f"{BASE}/gwm/", "testcookie": "1",
    }).encode()
    with OPENER.open(request.Request(f"{BASE}/wp-login.php", data=body), timeout=60) as r:
        r.read()
    if not any(c.name.startswith("wordpress_logged_in_") for c in JAR):
        sys.exit("ERROR: login failed (no wordpress_logged_in_* cookie)")


# ------------------------------------------------------------- site parsing --

_FIELD_RE = re.compile(
    r'<p>\s*<strong>([A-Za-z ()]+):\s*</strong>\s*(.*?)\s*</p>', re.S,
)


def list_issues() -> list[tuple[int, str]]:
    """Return [(num, slug)] for every magazine issue on the archive index."""
    html = http_get(f"{BASE}/gwm/articles/")
    found: dict[int, str] = {}
    for m in re.finditer(r'/gwm/articles/([a-z]+-(\d+))/', html):
        slug, n = m.group(1), int(m.group(2))
        # Filter out non-magazine outliers (e.g. 'ati-1004' = annual directory)
        if slug.rsplit("-", 1)[0] not in MONTHS:
            continue
        found[n] = slug
    return sorted(found.items())


_ISSUE_HTML_CACHE: dict[str, str] = {}


def _issue_html(issue_slug: str) -> str:
    h = _ISSUE_HTML_CACHE.get(issue_slug)
    if h is None:
        h = http_get(f"{BASE}/gwm/articles/{issue_slug}/")
        _ISSUE_HTML_CACHE[issue_slug] = h
    return h


def find_full_issue_slug(issue_slug: str) -> str | None:
    m = re.search(
        rf'/gwm/articles/{re.escape(issue_slug)}/([a-z0-9-]+-full-issue)/',
        _issue_html(issue_slug),
    )
    return m.group(1) if m else None


def article_slugs_in_order(issue_slug: str) -> list[str]:
    """Article slugs in document order (matches print order). Excludes -full-issue."""
    seen: list[str] = []
    seen_set: set[str] = set()
    for m in re.finditer(
        rf'/gwm/articles/{re.escape(issue_slug)}/([a-z0-9-]+)/',
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
        key = m.group(1).strip()
        raw = re.sub(r'<[^>]+>', '', m.group(2))
        val = re.sub(r'\s+', ' ', unescape(raw)).strip()
        fields[key] = val
    out: dict = {
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
    """Return (docid, dockey, parsed_metadata) from an Article Details page."""
    html = http_get(url)
    docid = re.search(r'name="docid"[^>]*value="(\d+)"', html)
    dockey = re.search(r'name="dockey"[^>]*value="([^"]+)"', html)
    if not docid or not dockey:
        raise RuntimeError(f"docid/dockey missing on {url}")
    return docid.group(1), dockey.group(1), parse_article_meta(html)


# ---------------------------------------------------------------- pdf tools --

def pdf_page_count(p: Path) -> int:
    r = subprocess.run(["pdfinfo", str(p)], capture_output=True, text=True, check=True)
    for line in r.stdout.splitlines():
        if line.startswith("Pages:"):
            return int(line.split()[1])
    raise RuntimeError(f"no Pages: in pdfinfo {p}")


def qpdf_merge(parts: list[Path], dest: Path) -> None:
    """Merge PDFs with qpdf (cleaner xref than pdfunite -> exiftool can write)."""
    cmd = ["qpdf", "--empty", "--pages"] + [
        arg for p in parts for arg in (str(p), "1-z")
    ] + ["--", str(dest)]
    subprocess.run(cmd, check=True)


def embed_pdf_metadata(pdf_path: Path, title: str, keywords: list[str],
                       subject: str = "Grapegrower & Winemaker") -> None:
    kw = ", ".join(sorted(set(k for k in keywords if k)))[:4000]
    subprocess.run([
        "exiftool", "-q", "-P", "-overwrite_original",
        f"-Title={title}",
        f"-Subject={subject}",
        f"-Keywords={kw}",
        str(pdf_path),
    ], check=False)


def filename_from_cd(cd: str, fallback: str) -> str:
    m = re.search(r'filename="([^"]+)"', cd)
    return m.group(1) if m else fallback


# ------------------------------------------------------------- per-issue op --

@dataclass
class Issue:
    num: int
    slug: str
    year: int
    month: int
    pdf_path: Path | None = None   # final PDF location once known
    sidecar_path: Path | None = None
    synthetic: bool = False


def existing_artifacts(out_root: Path, year: int, month: int) -> tuple[Path | None, Path | None]:
    year_dir = out_root / str(year)
    if not year_dir.exists():
        return None, None
    pdfs = sorted(year_dir.glob(f"{month:02d}_*.pdf"))
    sidecars = sorted(year_dir.glob(f"{month:02d}_*.json"))
    return (pdfs[0] if pdfs else None, sidecars[0] if sidecars else None)


def download_full_issue(issue: Issue, out_root: Path, sleep_s: float) -> Path | None:
    """Return the saved PDF path, or None if no FULL ISSUE link / empty file."""
    full = find_full_issue_slug(issue.slug)
    if not full:
        return None
    docid, dockey, _ = scrape_form(f"{BASE}/gwm/articles/{issue.slug}/{full}/")
    year_dir = out_root / str(issue.year)
    staging = year_dir / f"{issue.month:02d}_DOWNLOADING_{issue.num}.pdf"
    # Need the Content-Disposition filename, so do a manual request to read headers.
    body = urllib.parse.urlencode({"docid": docid, "dockey": dockey}).encode()
    req = request.Request(f"{BASE}/wp-content/uploads/tmp.php",
                          data=body, method="POST")
    req.add_header("Referer", f"{BASE}/gwm/articles/{issue.slug}/{full}/")
    staging.parent.mkdir(parents=True, exist_ok=True)
    tmp = staging.with_suffix(staging.suffix + ".part")
    n = 0
    cd = ""
    with OPENER.open(req, timeout=300) as r, tmp.open("wb") as f:
        cd = r.headers.get("Content-Disposition", "") or ""
        while True:
            chunk = r.read(64 * 1024)
            if not chunk:
                break
            f.write(chunk)
            n += len(chunk)
    if n == 0:
        tmp.unlink(missing_ok=True)
        return None
    orig = filename_from_cd(cd, f"GWM_{issue.num}.pdf")
    final = year_dir / f"{issue.month:02d}_{orig}"
    tmp.rename(final)
    time.sleep(sleep_s)
    return final


def synthesise_from_articles(issue: Issue, out_root: Path,
                             sleep_s: float,
                             empty_fail_fast: int = 2) -> tuple[Path | None, list[dict]]:
    """Download every article PDF and merge into a synthetic FULL ISSUE.

    Issues are empirically all-or-nothing: either every per-article PDF exists,
    or none do (server purged them). Bail after `empty_fail_fast` consecutive
    empties / no-form articles so a weekly cron doesn't pound ~20 requests per
    issue on the 150-ish purged pre-Jul-2017 issues. Next week's run will
    re-probe; if the publisher restores the files, we auto-heal.

    Returns (final_pdf_or_None, per_article_records).
    """
    year_dir = out_root / str(issue.year)
    final = year_dir / f"{issue.month:02d}_GW_{issue.year}-{issue.month:02d}_synthetic.pdf"
    article_slugs = article_slugs_in_order(issue.slug)
    if not article_slugs:
        return None, []
    work_dir = year_dir / f"{issue.month:02d}_GW_{issue.year}-{issue.month:02d}_parts"
    work_dir.mkdir(parents=True, exist_ok=True)
    parts: list[Path] = []
    records: list[dict] = []
    cumulative = 0
    empties_in_a_row = 0
    for idx, aslug in enumerate(article_slugs, 1):
        a_url = f"{BASE}/gwm/articles/{issue.slug}/{aslug}/"
        try:
            docid, dockey, meta = scrape_form(a_url)
        except Exception as e:
            records.append({"order": idx, "slug": aslug, "url": a_url, "_error": str(e)})
            empties_in_a_row += 1
            if not parts and empties_in_a_row >= empty_fail_fast:
                shutil.rmtree(work_dir, ignore_errors=True)
                return None, records
            continue
        tmp = work_dir / f"{idx:02d}_{aslug[:60]}.pdf"
        n = http_post_stream(f"{BASE}/wp-content/uploads/tmp.php",
                             {"docid": docid, "dockey": dockey},
                             tmp, referer=a_url)
        if n == 0:
            records.append({"order": idx, "slug": aslug, "url": a_url,
                            "title": meta["title"], "_error": "empty PDF"})
            empties_in_a_row += 1
            time.sleep(sleep_s)
            if not parts and empties_in_a_row >= empty_fail_fast:
                shutil.rmtree(work_dir, ignore_errors=True)
                return None, records
            continue
        pages = pdf_page_count(tmp)
        records.append({
            "order": idx,
            "slug": aslug,
            "url": a_url,
            "title": meta["title"],
            "author": meta["author"],
            "keywords": meta["keywords"],
            "print_page_numbers": meta["page_numbers"],
            "merged_pages": [cumulative + 1, cumulative + pages],
            "size_bytes": n,
        })
        parts.append(tmp)
        cumulative += pages
        empties_in_a_row = 0
        time.sleep(sleep_s)

    if not parts:
        shutil.rmtree(work_dir, ignore_errors=True)
        return None, records

    qpdf_merge(parts, final)
    shutil.rmtree(work_dir, ignore_errors=True)
    return final, records


def build_sidecar_for_native(issue: Issue, pdf_path: Path,
                             sleep_s: float) -> dict:
    """Walk per-article pages of a FULL-ISSUE-bearing issue to collect TOC."""
    article_slugs = article_slugs_in_order(issue.slug)
    articles = []
    for idx, aslug in enumerate(article_slugs, 1):
        a_url = f"{BASE}/gwm/articles/{issue.slug}/{aslug}/"
        try:
            html = http_get(a_url)
            meta = parse_article_meta(html)
            meta["url"] = a_url
            meta["order"] = idx
            articles.append(meta)
        except Exception as e:
            articles.append({"order": idx, "url": a_url, "_error": str(e)})
        time.sleep(sleep_s)

    return {
        "issue_number": issue.num,
        "year": issue.year,
        "month": issue.month,
        "month_name": MONTH_TITLES[issue.month - 1],
        "title": f"Grapegrower & Winemaker {MONTH_TITLES[issue.month-1]} {issue.year} (#{issue.num})",
        "issue_url": f"{BASE}/gwm/articles/{issue.slug}/",
        "issue_slug": issue.slug,
        "pdf_path": str(pdf_path),
        "pdf_filename": pdf_path.name,
        "synthetic": False,
        "articles": articles,
    }


def build_sidecar_for_synthetic(issue: Issue, pdf_path: Path,
                                records: list[dict]) -> dict:
    return {
        "issue_number": issue.num,
        "year": issue.year,
        "month": issue.month,
        "month_name": MONTH_TITLES[issue.month - 1],
        "title": f"Grapegrower & Winemaker {MONTH_TITLES[issue.month-1]} {issue.year} (#{issue.num})",
        "issue_url": f"{BASE}/gwm/articles/{issue.slug}/",
        "issue_slug": issue.slug,
        "pdf_path": str(pdf_path),
        "pdf_filename": pdf_path.name,
        "synthetic": True,
        "synthesis_note": ("Merged from per-article PDFs because winetitles "
                           "does not publish a single FULL ISSUE PDF for this issue."),
        "articles": records,
    }


def process_issue(issue: Issue, out_root: Path, sleep_s: float,
                  dry_run: bool) -> dict:
    """Idempotent: returns a small status dict."""
    pdf_existing, json_existing = existing_artifacts(out_root, issue.year, issue.month)

    if pdf_existing and json_existing:
        return {"status": "skip-complete", "pdf": str(pdf_existing)}

    if dry_run:
        return {"status": "would-process",
                "have_pdf": bool(pdf_existing),
                "have_json": bool(json_existing)}

    pdf_path = pdf_existing
    records: list[dict] | None = None  # only populated for synthetic path
    pdf_freshly_obtained = False  # so we can report 'sidecar-only' for resumes

    if pdf_path is None:
        # Try FULL ISSUE first
        pdf_path = download_full_issue(issue, out_root, sleep_s)
        if pdf_path is None:
            # Fall back to per-article synthesis
            pdf_path, records = synthesise_from_articles(issue, out_root, sleep_s)
            if pdf_path is None:
                return {"status": "no-pdf"}
            issue.synthetic = True
        pdf_freshly_obtained = True
    elif "_synthetic" in pdf_path.name:
        # Resuming on a synthetic PDF whose sidecar didn't get written.
        # Records will be empty — sidecar gets the native-style path.
        issue.synthetic = True

    # Build sidecar (skip if we already have one)
    if json_existing is None:
        if issue.synthetic and records is not None:
            sidecar = build_sidecar_for_synthetic(issue, pdf_path, records)
        else:
            sidecar = build_sidecar_for_native(issue, pdf_path, sleep_s * 0.5)

        # Aggregate keywords for the embedded PDF dict.
        all_kw: list[str] = []
        for a in sidecar["articles"]:
            all_kw.extend(a.get("keywords", []))
        subject = ("Grapegrower & Winemaker (synthetic full issue)"
                   if issue.synthetic else "Grapegrower & Winemaker")
        embed_pdf_metadata(pdf_path, sidecar["title"], all_kw, subject=subject)

        json_path = pdf_path.with_suffix(".json")
        tmp = json_path.with_suffix(".json.part")
        tmp.write_text(json.dumps(sidecar, indent=2, ensure_ascii=False))
        tmp.rename(json_path)
        issue.sidecar_path = json_path
    else:
        issue.sidecar_path = json_existing

    if pdf_freshly_obtained:
        status = "synthesised" if issue.synthetic else "downloaded"
    else:
        status = "sidecar-only"
    return {
        "status": status,
        "pdf": str(pdf_path),
        "json": str(issue.sidecar_path),
    }


# ------------------------------------------------------------------- main --

def main() -> int:
    user = os.environ.get("WT_USER")
    pwd = os.environ.get("WT_PASS")
    if not user or not pwd:
        sys.exit("ERROR: set WT_USER and WT_PASS")

    out_root = Path(os.environ.get("OUT_ROOT", "/mnt/data/Media/Magazines/GAW"))
    sleep_s = float(os.environ.get("SLEEP_SECS", "1.0"))
    limit = int(os.environ.get("LIMIT", "0")) or None
    dry_run = os.environ.get("DRY_RUN", "0") == "1"

    for tool in ("qpdf", "pdfinfo", "exiftool"):
        if not shutil.which(tool):
            sys.exit(f"ERROR: missing tool: {tool}")

    print(f"-> login as {user}", file=sys.stderr)
    login(user, pwd)

    print("-> listing issues ...", file=sys.stderr)
    all_issues = list_issues()
    print(f"   {len(all_issues)} issues listed", file=sys.stderr)
    if dry_run:
        print("   (DRY_RUN: no PDFs will be downloaded, no files written)",
              file=sys.stderr)

    counts: dict[str, int] = {}
    n_done = 0
    for num, slug in reversed(all_issues):  # newest first
        if limit and n_done >= limit:
            break
        year, month = year_month_for(num)
        issue = Issue(num=num, slug=slug, year=year, month=month)
        try:
            r = process_issue(issue, out_root, sleep_s, dry_run)
        except Exception as e:
            r = {"status": "error", "error": str(e)}
        status = r.get("status", "?")
        counts[status] = counts.get(status, 0) + 1
        if status not in ("skip-complete",):
            # "NEW_ISSUE:" is the marker the systemd OnSuccess hook greps for.
            tag = ("NEW_ISSUE: " if status in ("downloaded", "synthesised") else "")
            print(f"   {tag}#{num} {slug}: {r}", file=sys.stderr, flush=True)
            n_done += 1
        # Drop cached HTML for the issue we just processed; large archive walks
        # would otherwise hold a few hundred pages in RAM.
        _ISSUE_HTML_CACHE.pop(slug, None)

    print(f"\nsummary: {counts}", file=sys.stderr)

    return 0 if counts.get("error", 0) == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
