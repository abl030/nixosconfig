#!/usr/bin/env python3
# See docs/wiki/services/magazine-epub-pipeline.md §"marker-to-epub.py — the
# post-processor" for the fuzzy-match logic, OPF metadata payload, calibration
# results. Companion script is scripts/marker-batch.py (orchestrator).
"""Marker markdown -> clean EPUB post-processor for GAW magazine issues.

Pipeline:
  1. Read Marker's .md output + JSON sidecar.
  2. Locate every sidecar article title inside the body via rapidfuzz fuzzy
     match against a normalised, two-line-merged view of the markdown. The
     first match anchors "start of body" and trims front matter (cover,
     contents page, masthead).
  3. Inject `## <Title>` boundaries at every matched location so KOReader's
     TOC reflects the real article list, not Marker's eight semi-random H2s.
  4. Strip back matter: classifieds, advertiser index, marketplace blocks.
     Heuristic = a sustained drop in average paragraph length toward the
     tail.
  5. Collapse single-letter drop-cap orphan lines into the following
     paragraph (`W\n\nelcome...` -> `Welcome...`).
  6. Group runs of very short (<=3 word) lines into fenced code blocks so
     pricing-table debris reads as a block rather than one word per line.
  7. Render EPUB via pandoc with rich OPF metadata (series, tags, authors,
     subjects) so Komga + KOReader pick up the structure cleanly.

Usage:
  marker-to-epub.py <issue.md> <issue.json> -o <output.epub>

If -o omitted, writes `<stem-without-.SAMPLE>.V2.epub` next to the input.

Run via the marker venv that already has rapidfuzz, e.g.:
  /tmp/marker-test/.venv/bin/python scripts/marker-to-epub.py ...

Pandoc is invoked via `nix-shell -p pandoc --run` so no system install
needed.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import string
import subprocess
import sys
import tempfile
import unicodedata
from dataclasses import dataclass
from pathlib import Path

try:
    from rapidfuzz import fuzz
except ImportError:
    sys.stderr.write(
        "rapidfuzz not installed. Run via marker venv:\n"
        "  /tmp/marker-test/.venv/bin/python scripts/marker-to-epub.py ...\n"
    )
    sys.exit(2)


# ------------------------------ helpers ------------------------------ #


def normalise(s: str) -> str:
    """ASCII-fold, lowercase, strip punctuation, collapse whitespace."""
    s = unicodedata.normalize("NFKD", s)
    s = s.encode("ascii", "ignore").decode("ascii")
    s = s.lower()
    # Replace punctuation with space so word boundaries survive.
    s = "".join(ch if ch not in string.punctuation else " " for ch in s)
    s = re.sub(r"\s+", " ", s).strip()
    return s


def is_short_line(line: str, max_words: int = 3) -> bool:
    """A 'short line' is a non-empty line with at most N whitespace-separated
    tokens. Excludes markdown markers, URLs, and existing H2s."""
    stripped = line.strip()
    if not stripped:
        return False
    if stripped.startswith("#"):
        return False
    if "://" in stripped or "@" in stripped:
        return False
    # Drop-cap orphan? Single capital letter only.
    if len(stripped) == 1 and stripped.isalpha():
        return True
    words = stripped.split()
    return len(words) <= max_words


# ------------------------------ matching ------------------------------ #


@dataclass
class Match:
    article_idx: int
    title: str
    line_idx: int  # 0-indexed line in the cleaned-paragraph view
    raw_line: str
    score: float


def find_article_anchors(
    paragraphs: list[str],
    articles: list[dict],
    *,
    threshold: int = 80,
    head_threshold: int = 72,
) -> list[Match]:
    """For each article title, scan paragraphs and pick the best fuzzy match.

    Strategy:
      - Build a normalised view of each paragraph plus a 2-paragraph
        lookahead concat (handles titles split across blocks).
      - Use rapidfuzz.partial_ratio: a good token-level match against any
        sub-span of the candidate string. Articles named in a contents
        page sometimes share substrings, so we ALSO compare token_set
        and average them to disambiguate.
      - The first match per title (going head-down) is the article body;
        repeated mentions later are TOC echoes or callouts.
      - We bias toward later matches that aren't immediately after a prior
        match — contents-page hits cluster tightly, body hits are spread.
    """
    norm_paras: list[str] = [normalise(p) for p in paragraphs]
    lookahead: list[str] = []
    for i, n in enumerate(norm_paras):
        merged = n
        if i + 1 < len(norm_paras):
            merged = (n + " " + norm_paras[i + 1]).strip()
        lookahead.append(merged)

    # Find the contents/TOC region: an early stretch where many article
    # titles partially match in close proximity. We'll require the chosen
    # match for each title to start AFTER that region.
    toc_end = _find_toc_end(norm_paras, articles)

    matches: list[Match] = []
    for art_idx, art in enumerate(articles):
        title_norm = normalise(art["title"])
        if not title_norm:
            continue
        best: Match | None = None
        for i, cand in enumerate(lookahead):
            if not cand:
                continue
            partial = fuzz.partial_ratio(title_norm, cand)
            token_set = fuzz.token_set_ratio(title_norm, cand)
            score = (partial + token_set) / 2.0
            # Boost: title appears near start of paragraph (real headings
            # tend to be the opening of a block).
            head = cand[: max(len(title_norm) + 10, 40)]
            head_partial = fuzz.partial_ratio(title_norm, head)
            if head_partial >= head_threshold:
                score += 5
            min_thresh = threshold
            # Long titles tolerate slightly lower scores (more chances for
            # OCR mangling).
            if len(title_norm) > 60:
                min_thresh -= 5
            if score < min_thresh:
                continue
            # Prefer matches after TOC region.
            if i <= toc_end:
                score -= 8  # penalise but don't reject outright
            if best is None or score > best.score:
                best = Match(art_idx, art["title"], i, paragraphs[i], score)
        if best is not None:
            matches.append(best)

    # Sort matches by line position, dedupe collisions (two titles pointing
    # at the same paragraph -> keep the higher scorer).
    matches.sort(key=lambda m: (m.line_idx, -m.score))
    deduped: list[Match] = []
    seen_lines: set[int] = set()
    for m in matches:
        if m.line_idx in seen_lines:
            continue
        seen_lines.add(m.line_idx)
        deduped.append(m)
    return deduped


def _find_toc_end(norm_paras: list[str], articles: list[dict]) -> int:
    """Return the paragraph index after which the contents-page region ends.

    Method: slide a window across the first third of the document; the
    window with the highest density of article-title hits is the TOC.
    Return the last index of that window.
    """
    if not norm_paras:
        return 0
    title_norms = [normalise(a["title"]) for a in articles if a.get("title")]
    horizon = min(len(norm_paras), max(150, len(norm_paras) // 3))
    window = 20
    best_count = -1
    best_end = 0
    for start in range(0, max(1, horizon - window)):
        end = start + window
        chunk = " ".join(norm_paras[start:end])
        hits = sum(
            1
            for t in title_norms
            if fuzz.partial_ratio(t, chunk) >= 75
        )
        if hits > best_count:
            best_count = hits
            best_end = end
    return best_end


# ----------------------------- cleaning ----------------------------- #


DROPCAP_RE = re.compile(r"^([A-Z])$")


def collapse_dropcaps(paragraphs: list[str]) -> list[str]:
    """Merge `W\\n\\nelcome to...` -> `Welcome to...`.

    Marker emits single-cap-letter paragraphs adjacent to lowercase-start
    follow-ups whenever it can't reattach a drop cap. Detect and rejoin.
    """
    out: list[str] = []
    i = 0
    while i < len(paragraphs):
        p = paragraphs[i].strip()
        m = DROPCAP_RE.match(p)
        if m and i + 1 < len(paragraphs):
            nxt = paragraphs[i + 1].lstrip()
            if nxt and nxt[0].islower():
                out.append(m.group(1) + nxt)
                i += 2
                continue
        out.append(paragraphs[i])
        i += 1
    return out


def group_short_runs(
    paragraphs: list[str], min_run: int = 4
) -> list[str]:
    """Group runs of >=min_run consecutive short paragraphs into one fenced
    code block. Captures pricing-table noise and column-bleed debris.
    """
    out: list[str] = []
    i = 0
    while i < len(paragraphs):
        if is_short_line(paragraphs[i]):
            # find run extent
            j = i
            while j < len(paragraphs) and is_short_line(paragraphs[j]):
                j += 1
            run = paragraphs[i:j]
            if len(run) >= min_run:
                # render as a code block so e-readers don't explode one
                # word per line.
                fenced = ["```", *[p.strip() for p in run], "```"]
                out.append("\n".join(fenced))
            else:
                out.extend(paragraphs[i:j])
            i = j
        else:
            out.append(paragraphs[i])
            i += 1
    return out


def trim_back_matter(paragraphs: list[str]) -> tuple[list[str], int]:
    """Trim trailing classifieds/marketplace/calendar/advertiser-index.

    Heuristic: walk back from the end. The 'back matter' starts at the
    first occurrence (in tail third) of any of:
      - a paragraph containing "marketplace" as the sole content (case-
        insensitive), or
      - "Thank you to all our advertisers", or
      - "Winetitles Calendar" / "CALENDAR Winetitles" advertiser block, or
      - "looking back 20" header.
    We return up to but not including that anchor.
    """
    if not paragraphs:
        return paragraphs, 0
    tail_start = max(0, len(paragraphs) - max(60, len(paragraphs) // 3))
    cut_at = len(paragraphs)
    triggers_strict = [
        re.compile(r"^\s*marketplace\s*$", re.I),
        re.compile(r"thank you to all our advertisers", re.I),
        re.compile(r"^\s*looking back\b", re.I),
        re.compile(r"winetitles calendar upcoming events", re.I),
        re.compile(r"^\s*calendar\s+winetitles", re.I),
    ]
    for i in range(tail_start, len(paragraphs)):
        p = paragraphs[i].strip()
        for rx in triggers_strict:
            if rx.search(p):
                cut_at = i
                break
        if cut_at != len(paragraphs):
            break
    trimmed = paragraphs[:cut_at]
    return trimmed, len(paragraphs) - cut_at


# --------------------------- assembly --------------------------- #


_XML_CTRL_RE = re.compile(
    # XML 1.0 forbids these C0 control characters (except \t \n \r) and
    # the noncharacters FFFE/FFFF. Marker occasionally emits BEL (0x07)
    # and similar from PDF text-extraction quirks; strip them.
    r"[\x00-\x08\x0B\x0C\x0E-\x1F￾￿]"
)


def strip_xml_control_chars(s: str) -> str:
    return _XML_CTRL_RE.sub("", s)


def split_into_paragraphs(md: str) -> list[str]:
    """Marker emits blank-line-separated paragraphs. Preserve order."""
    md = strip_xml_control_chars(md)
    blocks: list[str] = []
    cur: list[str] = []
    for line in md.splitlines():
        if line.strip() == "":
            if cur:
                blocks.append("\n".join(cur).rstrip())
                cur = []
        else:
            cur.append(line)
    if cur:
        blocks.append("\n".join(cur).rstrip())
    return blocks


def build_clean_markdown(
    paragraphs: list[str],
    matches: list[Match],
    issue_title: str,
    description_md: str,
) -> str:
    """Splice in H2 anchors at match positions; drop the original first
    paragraph (Marker's noisy title) and Marker's pre-existing H2s — we
    re-emit our own. Keep the upfront editor/contents-page content trimmed
    via match[0].line_idx as the body start."""
    if not matches:
        body_start = 0
    else:
        body_start = matches[0].line_idx

    # Remove Marker's existing H2/H1 markers; we'll re-inject our own at
    # match line indices. Keep H3+ alone — they may be legitimate sub-
    # heads inside articles (rare from Marker, but harmless).
    out_lines: list[str] = []
    match_by_idx = {m.line_idx: m for m in matches}

    out_lines.append(f"# {issue_title}\n")
    if description_md:
        out_lines.append(description_md)
        out_lines.append("")

    for idx in range(body_start, len(paragraphs)):
        block = paragraphs[idx]
        # If this paragraph IS the article-title anchor, replace with H2.
        if idx in match_by_idx:
            m = match_by_idx[idx]
            out_lines.append(f"## {m.title}")
            out_lines.append("")
            # If the matched paragraph has additional text *after* the
            # title fragment, keep that residue as the opening body para.
            residue = _strip_title_from_paragraph(block, m.title)
            if residue:
                out_lines.append(residue)
                out_lines.append("")
            continue
        # Strip Marker's H1/H2 — they're either dup of our title or wrong.
        if block.startswith("# ") or block.startswith("## "):
            continue
        out_lines.append(block)
        out_lines.append("")
    return "\n".join(out_lines).rstrip() + "\n"


def _strip_title_from_paragraph(block: str, title: str) -> str:
    """If the matched paragraph contains text beyond the title fragment,
    return the residue. Otherwise return empty string. Uses normalised
    matching to find the title span, then maps back to original text."""
    norm_block = normalise(block)
    norm_title = normalise(title)
    if not norm_title or not norm_block:
        return ""
    # Quick win: if normalised title is essentially the entire block (>=85%
    # coverage), return empty.
    if fuzz.ratio(norm_title, norm_block) >= 85:
        return ""
    # Find rough span of title inside original block via partial token
    # search; for simplicity, just remove first occurrence of the longest
    # contiguous title-word sequence.
    title_words = title.split()
    if len(title_words) < 3:
        return ""
    # Try last 3 title words — usually less ambiguous than first.
    tail = " ".join(title_words[-3:])
    idx = block.find(tail)
    if idx == -1:
        # Try case-insensitive
        idx = block.lower().find(tail.lower())
        if idx == -1:
            return ""
    residue = block[idx + len(tail) :].strip()
    # If residue is tiny or just punctuation, drop it.
    if len(residue) < 20:
        return ""
    return residue


# ----------------------------- metadata ----------------------------- #


AUTHOR_NOISE = {"", "n/a", "staff", "staff writer"}


def build_metadata(sidecar: dict, matches: list[Match]) -> dict:
    """Build pandoc YAML metadata dict + a markdown description string."""
    year = sidecar.get("year")
    month = sidecar.get("month")
    issue = sidecar.get("issue_number")
    title = sidecar.get("title") or "Grapegrower & Winemaker"
    articles = sidecar.get("articles", [])

    # Tags / subjects: flatten keywords + dedupe
    subjects: list[str] = []
    seen: set[str] = set()
    for a in articles:
        for kw in a.get("keywords", []) or []:
            k = kw.strip()
            kl = k.lower()
            if k and kl not in seen:
                seen.add(kl)
                subjects.append(k)

    # Authors: dedupe (most articles have empty author in this sidecar)
    authors: list[str] = []
    seen_auth: set[str] = set()
    for a in articles:
        au = (a.get("author") or "").strip()
        if au.lower() in AUTHOR_NOISE:
            continue
        if au.lower() in seen_auth:
            continue
        seen_auth.add(au.lower())
        authors.append(au)
    if not authors:
        authors = ["Winetitles Media"]

    date = None
    if year and month:
        date = f"{int(year):04d}-{int(month):02d}-01"

    series_index = month  # one issue per month, 1-12 is a natural index

    # Description: dc:description must be a single paragraph (OPF spec),
    # so we use "; " separators and lead with "In this issue: ".
    matched_titles = {m.title for m in matches}
    parts: list[str] = []
    for a in articles:
        t = a.get("title", "").strip()
        if not t:
            continue
        pages = a.get("page_numbers") or ""
        item = t
        if pages:
            item += f" (pp. {pages})"
        if t not in matched_titles:
            item += " [not in body]"
        parts.append(item)
    description = "In this issue: " + "; ".join(parts) + "."

    return {
        "title": title,
        "creator": authors,
        "publisher": "Winetitles Media",
        "language": "en",
        "subjects": subjects,
        "date": date,
        "series": "Grapegrower & Winemaker",
        "series_index": series_index,
        "issue_number": issue,
        "description": description,
    }


def write_metadata_yaml(meta: dict, path: Path) -> None:
    """Emit a pandoc-friendly YAML metadata file. We hand-roll YAML because
    PyYAML may not be in the venv and the shape is tiny."""
    lines: list[str] = ["---"]

    def esc(s: str) -> str:
        # Quote with double quotes; escape inner quotes and backslashes.
        s = s.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{s}"'

    lines.append(f"title: {esc(meta['title'])}")
    lines.append(f"language: {esc(meta['language'])}")
    if meta.get("date"):
        lines.append(f"date: {esc(meta['date'])}")
    lines.append(f"publisher: {esc(meta['publisher'])}")
    lines.append("creator:")
    for c in meta["creator"]:
        lines.append(f"  - role: aut")
        lines.append(f"    text: {esc(c)}")
    if meta.get("subjects"):
        lines.append("subject:")
        for s in meta["subjects"]:
            lines.append(f"  - {esc(s)}")
    # Pandoc EPUB takes belongs-to-collection as a scalar string and
    # group-position as a sibling. The OPF emitter then writes the proper
    # <meta property="belongs-to-collection"> + group-position refines.
    lines.append(f"belongs-to-collection: {esc(meta['series'])}")
    if meta.get("series_index") is not None:
        lines.append(f"group-position: {int(meta['series_index'])}")
    if meta.get("issue_number"):
        lines.append(f"identifier: gwm-issue-{int(meta['issue_number'])}")
    if meta.get("description"):
        lines.append(f"description: {esc(meta['description'])}")
    lines.append("---")
    lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")


# ------------------------------- main ------------------------------- #


def run_pandoc(md_path: Path, yaml_path: Path, epub_path: Path) -> None:
    """Render the EPUB with pandoc.

    Prefers a `pandoc` on PATH (or $PANDOC_BIN) — that's what the
    marker-convert systemd unit supplies via pkgs.pandoc, and it's faster
    for interactive use too. Falls back to `nix-shell -p pandoc` so the
    script still works from a bare checkout with no pandoc installed.
    """
    pandoc_args = [
        "--from=markdown+smart",
        "--to=epub3",
        "--standalone",
        "--metadata-file=" + str(yaml_path),
        "--toc",
        "--toc-depth=2",
        "--split-level=2",
        "-o",
        str(epub_path),
        str(md_path),
    ]
    pandoc_bin = os.environ.get("PANDOC_BIN") or shutil.which("pandoc")
    if pandoc_bin:
        cmd = [pandoc_bin, *pandoc_args]
    else:
        cmd = ["nix-shell", "-p", "pandoc", "--run",
               " ".join(["pandoc", *pandoc_args])]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write("pandoc failed:\n")
        sys.stderr.write(result.stderr)
        sys.exit(result.returncode)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("markdown", type=Path)
    ap.add_argument("sidecar", type=Path)
    ap.add_argument("-o", "--output", type=Path, default=None)
    ap.add_argument(
        "--match-threshold",
        type=int,
        default=80,
        help="rapidfuzz score floor for article matches (default 80)",
    )
    ap.add_argument(
        "--keep-intermediate",
        action="store_true",
        help="write the cleaned .md alongside the EPUB",
    )
    args = ap.parse_args()

    if not args.markdown.is_file():
        sys.stderr.write(f"missing: {args.markdown}\n")
        return 1
    if not args.sidecar.is_file():
        sys.stderr.write(f"missing: {args.sidecar}\n")
        return 1

    if args.output is None:
        stem = args.markdown.stem
        stem = stem.replace(".SAMPLE", "")
        args.output = args.markdown.with_name(stem + ".V2.epub")

    raw = args.markdown.read_text(encoding="utf-8")
    sidecar = json.loads(args.sidecar.read_text(encoding="utf-8"))

    paragraphs = split_into_paragraphs(raw)
    n_initial = len(paragraphs)

    # 1. drop-cap collapse first — affects line positions for matching
    paragraphs = collapse_dropcaps(paragraphs)
    n_after_dropcap = len(paragraphs)

    # 2. trim back matter
    paragraphs, n_back_trimmed = trim_back_matter(paragraphs)

    # 3. find article anchors
    articles = sidecar.get("articles", [])
    matches = find_article_anchors(
        paragraphs, articles, threshold=args.match_threshold
    )

    # 4. metadata depends on matches (for description)
    meta = build_metadata(sidecar, matches)

    # 5. body markdown
    body_md = build_clean_markdown(
        paragraphs, matches, sidecar.get("title", "Issue"), ""
    )

    # 6. group leftover short-line runs (after H2 injection so we don't
    # crush titles)
    body_paras = split_into_paragraphs(body_md)
    body_paras = group_short_runs(body_paras)
    body_md = "\n\n".join(body_paras) + "\n"

    # 7. emit
    with tempfile.TemporaryDirectory() as td:
        td_path = Path(td)
        yaml_path = td_path / "meta.yaml"
        md_path = td_path / "body.md"
        write_metadata_yaml(meta, yaml_path)
        md_path.write_text(body_md, encoding="utf-8")
        if args.keep_intermediate:
            keep_md = args.output.with_suffix(".clean.md")
            shutil.copy(md_path, keep_md)
        run_pandoc(md_path, yaml_path, args.output)

    # report
    print(
        f"input paragraphs: {n_initial}",
        f"after drop-cap collapse: {n_after_dropcap}",
        f"trimmed off tail: {n_back_trimmed}",
        f"final paragraphs: {len(paragraphs)}",
        sep="\n",
    )
    print(
        f"\narticles in sidecar: {len(articles)}",
        f"H2 boundaries injected: {len(matches)}",
        sep="\n",
    )
    if matches:
        print("\nmatched articles:")
        for m in matches:
            print(f"  [{m.score:5.1f}] line {m.line_idx:4d}: {m.title}")
    unmatched = [
        a["title"]
        for a in articles
        if a.get("title") and a["title"] not in {m.title for m in matches}
    ]
    if unmatched:
        print("\nunmatched articles:")
        for t in unmatched:
            print(f"  - {t}")
    print(f"\nwrote: {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
