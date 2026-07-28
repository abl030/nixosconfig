# Paperless

Paperless-ngx runs on `doc2` through
`modules/nixos/services/paperless.nix`. Its consume and media directories are
space-free paths inside a narrowed systemd mount namespace; `BindPaths=` maps
those paths to the tower-backed NFS directories.

## Duplex blank-page stripping

`paperless-strip-blank-pages` runs as `PAPERLESS_PRE_CONSUME_SCRIPT` before OCR.
It rasterises multi-page PDFs at 50 DPI and removes scanner backs that satisfy
both calibrated blank-page thresholds:

- standard deviation below `0.01`;
- mean brightness above `0.985`.

One-page PDFs are inspected only for their page count and are left untouched.
If every page appears blank, the original PDF is also left untouched.

### Recoverable qpdf warnings

qpdf exit status `3` means the operation succeeded with warnings. This commonly
occurs when qpdf repairs a readable PDF whose object-count metadata is
inconsistent. Paperless treats every non-zero pre-consume exit as fatal, so both
qpdf calls use `--warning-exit-0`:

- warning-only status `3` becomes success;
- genuine qpdf errors remain non-zero;
- warning details remain on stderr and therefore in the Paperless journal.

This invariant applies to both `--show-npages` and the final `--empty --pages`
rewrite. Omitting it from either call can reintroduce ingestion failures for
recoverable malformed PDFs.

## Verification

After deployment, verify the exact generated script and an affected ingestion:

```sh
ssh doc2 'systemctl show paperless-consumer -p Environment --no-pager \
  | tr " " "\n" | grep "^PAPERLESS_PRE_CONSUME_SCRIPT="'
ssh doc2 'journalctl -u paperless-task-queue --since "10 minutes ago" --no-pager \
  | grep -E "pre-consume script|exited [0-9]+|consumption finished"'
```

Expected result: the pre-consume script exits `0`; qpdf may still log its warning;
and Paperless subsequently logs `consumption finished` and a successful document
ID.

For a configuration regression test, evaluate and realise the generated
`PAPERLESS_PRE_CONSUME_SCRIPT`, run it against a disposable copy of a known
warning-producing PDF via `DOCUMENT_WORKING_PATH`, and require exit `0`. Never
run this mutation-oriented script directly against the only copy of a document.
