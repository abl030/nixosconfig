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
  WORKERS       (default 3) parallel marker_single invocations
  ENABLE_OCR    (default off) — leave off for InDesign-origin magazine
                 PDFs (real text layer present). Set to 1 to force OCR.

Tuning notes:
  - Each marker_single uses ~3 effective cores + ~14 GB RAM at peak
    (model weights + layout/text/table caches). On a 16-core / 64 GB
    host, WORKERS=3 hits a good usage point (~70% CPU, ~50 GB RAM).
  - --disable_ocr is a 2-3x speedup for text-layer PDFs and produces
    indistinguishable markdown for our InDesign-origin sources.
  - --disable_image_extraction skips image OCR + extraction; we don't
    use images in the EPUB anyway.

Long-running (~5-15 min/issue × N/workers issues). Run with nohup +
nice + ionice so an SSH disconnect doesn't kill it and so foreground
work on the host stays responsive.
"""

from __future__ import annotations

import concurrent.futures
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
    # Newest issue first. The PDF tree is /mnt/data/Media/Magazines/<pub>/<YEAR>/<basename>.
    # Sort key is (year_from_dir, basename) descending so 2026 May > 2026 Apr > ...
    # > 2018 Apr across both GAW + WVJ. mtime isn't reliable because some files
    # were freshly downloaded today and would otherwise overtake older-but-newer-
    # by-issue-date PDFs.
    def sort_key(p: Path) -> tuple:
        try:
            year = int(p.parent.name)
        except ValueError:
            year = 0
        return (year, p.name)
    pdfs.sort(key=sort_key, reverse=True)
    return pdfs


def run_marker(pdf: Path, workdir: Path, marker_bin: str,
               disable_ocr: bool) -> Path:
    """Returns the produced .md path (in workdir/<basename>/<basename>.md)."""
    # --page_range omitted -> marker defaults to the entire document.
    # Explicit 0-N values must be in range or marker asserts and exits.
    cmd = [
        marker_bin,
        str(pdf),
        "--output_format", "markdown",
        "--output_dir", str(workdir),
        "--disable_image_extraction",
    ]
    if disable_ocr:
        # InDesign PDFs ship with a real text layer; OCR is redundant and
        # costs the bulk of Marker's runtime. Use ENABLE_OCR=1 to override
        # for any future scanned/image-only PDFs we add.
        cmd.append("--disable_ocr")
    subprocess.run(cmd, check=True)
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
    # marker-to-epub.py CLI: positional <markdown> <sidecar> + -o <output>.
    subprocess.run(
        [
            sys.executable, str(to_epub),
            str(md), str(sidecar),
            "-o", str(out),
        ],
        check=True,
    )


def process_one(
    pdf: Path,
    root: Path,
    marker_bin: str,
    to_epub: Path,
    disable_ocr: bool,
    idx: int,
    total: int,
) -> tuple[Path, str, float, int]:
    """Convert one PDF. Returns (pdf, status, elapsed, size_bytes).

    status: "ok" | "err"
    Runs inside a worker process; logs to stderr from there so progress
    interleaves naturally between concurrent workers.
    """
    sidecar = pdf.with_suffix(".json")
    out = pdf.with_suffix(".epub")
    t0 = time.time()
    print(
        f"[{idx}/{total}] start  {pdf.relative_to(root)}",
        file=sys.stderr, flush=True,
    )
    with tempfile.TemporaryDirectory(prefix="marker-batch-") as tmp:
        try:
            md = run_marker(pdf, Path(tmp), marker_bin, disable_ocr)
            run_to_epub(to_epub, md, sidecar, out)
            dt = time.time() - t0
            size = out.stat().st_size if out.exists() else 0
            print(
                f"[{idx}/{total}] OK     {dt/60:5.1f}m {size/1024:6.0f} KB  {out.name}",
                file=sys.stderr, flush=True,
            )
            return (pdf, "ok", dt, size)
        except subprocess.CalledProcessError as e:
            dt = time.time() - t0
            print(
                f"[{idx}/{total}] ERR    {dt/60:5.1f}m exit={e.returncode}  {pdf.name}",
                file=sys.stderr, flush=True,
            )
            if out.exists():
                out.unlink()
            return (pdf, "err", dt, 0)
        except Exception as e:
            dt = time.time() - t0
            print(
                f"[{idx}/{total}] ERR    {dt/60:5.1f}m {e}  {pdf.name}",
                file=sys.stderr, flush=True,
            )
            if out.exists():
                out.unlink()
            return (pdf, "err", dt, 0)


def main() -> int:
    root = Path(os.environ.get("ARCHIVE_ROOT", "/mnt/data/Media/Magazines"))
    marker_bin = os.environ.get("MARKER_BIN", "marker_single")
    to_epub = Path(os.environ.get(
        "TO_EPUB",
        str(Path(__file__).parent / "marker-to-epub.py"),
    ))
    limit = int(os.environ.get("LIMIT", "0")) or None
    only_re = re.compile(os.environ["ONLY"]) if os.environ.get("ONLY") else None
    workers = max(1, int(os.environ.get("WORKERS", "3")))
    disable_ocr = os.environ.get("ENABLE_OCR", "0") != "1"

    if not shutil.which(marker_bin):
        sys.exit(f"ERROR: {marker_bin} not on PATH")
    if not to_epub.is_file():
        sys.exit(f"ERROR: post-processor missing: {to_epub}")
    if not root.is_dir():
        sys.exit(f"ERROR: archive root not a directory: {root}")

    pdfs = pdfs_to_convert(root, only_re)
    if limit:
        pdfs = pdfs[:limit]
    total = len(pdfs)
    print(
        f"-> {total} PDFs need EPUBs (root={root}, workers={workers}, "
        f"ocr={'on' if not disable_ocr else 'off'})",
        file=sys.stderr, flush=True,
    )
    if not pdfs:
        return 0

    ok = err = 0
    t_start = time.time()
    with concurrent.futures.ProcessPoolExecutor(max_workers=workers) as pool:
        futures = {
            pool.submit(
                process_one, pdf, root, marker_bin, to_epub, disable_ocr,
                i, total,
            ): pdf
            for i, pdf in enumerate(pdfs, 1)
        }
        for fut in concurrent.futures.as_completed(futures):
            _, status, _, _ = fut.result()
            if status == "ok":
                ok += 1
            else:
                err += 1

    dt = time.time() - t_start
    print(
        f"\nsummary: ok={ok} err={err} of {total} in {dt/60:.1f} min",
        file=sys.stderr,
    )
    return 0 if err == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
