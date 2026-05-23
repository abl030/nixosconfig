#!/usr/bin/env python3
"""Batch convert every magazine PDF in the archive to an EPUB next to it.

For each `<dir>/<basename>.pdf` with a matching `<basename>.json` sidecar:
  1. `marker_single <pdf> --page_range 0-9999 --output_dir <tmpdir>` -> `<basename>.md`
  2. `scripts/marker-to-epub.py --md ... --sidecar ... --out <basename>.epub`
  3. Drop the EPUB next to the PDF.

Skip rules:
  - EPUB already exists at the target path.
  - Sidecar missing (we need TOC titles for the post-processor).
  - PDF basename contains "_synthetic" (those are pdfunite stitches of
    per-article PDFs and are typically too noisy for Marker; skip until
    we tune for them specifically).

Env:
  ARCHIVE_ROOT  (default /mnt/data/Media/Magazines)
  MARKER_BIN    (default marker_single — must be on PATH)
  TO_EPUB       (default scripts/marker-to-epub.py relative to this file)
  LIMIT         (default 0 = unlimited) max issues to process this run
  ONLY          (optional regex on the basename — restrict to matches)

This is a long-running batch (~8-15 min per 80-page issue on CPU); run
in a screen / tmux / systemd-run --scope so an SSH disconnect doesn't
kill it.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def pdfs_to_convert(root: Path, only_re: re.Pattern | None) -> list[Path]:
    pdfs: list[Path] = []
    for pdf in root.rglob("*.pdf"):
        # Skip the post-processor's own scratch files if any.
        if pdf.name.endswith(".part") or "DOWNLOADING" in pdf.name:
            continue
        if "_synthetic" in pdf.name:
            continue
        sidecar = pdf.with_suffix(".json")
        if not sidecar.is_file():
            continue
        target_epub = pdf.with_suffix(".epub")
        if target_epub.exists():
            continue
        if only_re and not only_re.search(pdf.name):
            continue
        pdfs.append(pdf)
    pdfs.sort()
    return pdfs


def run_marker(pdf: Path, workdir: Path, marker_bin: str) -> Path:
    """Returns the produced .md path (in workdir/<basename>/<basename>.md)."""
    subprocess.run(
        [
            marker_bin,
            str(pdf),
            "--output_format", "markdown",
            "--output_dir", str(workdir),
            "--disable_image_extraction",
            "--page_range", "0-9999",
        ],
        check=True,
    )
    # Marker creates workdir/<pdf_stem>/<pdf_stem>.md
    stem = pdf.stem
    md = workdir / stem / f"{stem}.md"
    if not md.exists():
        # Some versions drop directly into workdir/.
        alt = workdir / f"{stem}.md"
        if alt.exists():
            return alt
        raise RuntimeError(f"marker did not produce {md} or {alt}")
    return md


def run_to_epub(to_epub: Path, md: Path, sidecar: Path, out: Path) -> None:
    subprocess.run(
        [
            sys.executable, str(to_epub),
            "--md", str(md),
            "--sidecar", str(sidecar),
            "--out", str(out),
        ],
        check=True,
    )


def main() -> int:
    root = Path(os.environ.get("ARCHIVE_ROOT", "/mnt/data/Media/Magazines"))
    marker_bin = os.environ.get("MARKER_BIN", "marker_single")
    to_epub = Path(os.environ.get(
        "TO_EPUB",
        str(Path(__file__).parent / "marker-to-epub.py"),
    ))
    limit = int(os.environ.get("LIMIT", "0")) or None
    only_re = re.compile(os.environ["ONLY"]) if os.environ.get("ONLY") else None

    if not shutil.which(marker_bin):
        sys.exit(f"ERROR: {marker_bin} not on PATH")
    if not to_epub.is_file():
        sys.exit(f"ERROR: post-processor missing: {to_epub}")
    if not root.is_dir():
        sys.exit(f"ERROR: archive root not a directory: {root}")

    pdfs = pdfs_to_convert(root, only_re)
    print(f"-> {len(pdfs)} PDFs need EPUBs (root={root})", file=sys.stderr, flush=True)
    if not pdfs:
        return 0

    ok = err = 0
    for i, pdf in enumerate(pdfs, 1):
        if limit and ok >= limit:
            break
        sidecar = pdf.with_suffix(".json")
        out = pdf.with_suffix(".epub")
        t0 = time.time()
        with tempfile.TemporaryDirectory(prefix="marker-batch-") as tmp:
            try:
                print(f"[{i}/{len(pdfs)}] {pdf.relative_to(root)} -> ...", file=sys.stderr, flush=True)
                md = run_marker(pdf, Path(tmp), marker_bin)
                run_to_epub(to_epub, md, sidecar, out)
                size = out.stat().st_size if out.exists() else 0
                dt = time.time() - t0
                print(
                    f"   OK  {dt/60:5.1f}m {size/1024:6.0f} KB  {out.name}",
                    file=sys.stderr, flush=True,
                )
                ok += 1
            except subprocess.CalledProcessError as e:
                dt = time.time() - t0
                print(
                    f"   ERR {dt/60:5.1f}m exit={e.returncode} for {pdf.name}",
                    file=sys.stderr, flush=True,
                )
                err += 1
                # Clean up any partial EPUB so retries are valid.
                if out.exists():
                    out.unlink()
            except Exception as e:
                print(f"   ERR {pdf.name}: {e}", file=sys.stderr, flush=True)
                err += 1
                if out.exists():
                    out.unlink()

    print(f"\nsummary: ok={ok} err={err} of {len(pdfs)}", file=sys.stderr)
    return 0 if err == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
