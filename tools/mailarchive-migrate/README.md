# mailarchive-migrate

One-shot migration utility: MailStore Home archive → nested Maildir tree.

**Plan reference:** [docs/plans/2026-05-04-001-feat-mailarchive-mailstore-retirement-plan.md](../../docs/plans/2026-05-04-001-feat-mailarchive-mailstore-retirement-plan.md) (U7)
**Module:** [modules/nixos/services/mailarchive.nix](../../modules/nixos/services/mailarchive.nix)
**Runbook:** [docs/wiki/services/mailarchive.md](../../docs/wiki/services/mailarchive.md)

The historical MailStore Home archive (~11 GB, mixed Gmail + O365 in one
proprietary repository) lives entirely outside the new mailarchive
module's reach until it's exported and reformatted. Stdlib only — no
pip, no nixpkgs packaging.

## Why a one-shot tool

`maildir-deduplicate` and `mail-deduplicate` (the renamed PyPI package)
are **not** packaged in nixpkgs. The migration is small, reversible, and
runs once — a ~150-line stdlib script is the right tool.

## U7a — Export from MailStore Home

Run on the Win10 VM (VMID 102) before retirement:

1. **MailStore Home** → `Export Email`
2. Format: **File system, EML format**
3. **Retain folder structure** ✓
4. Target path: a temp directory reachable from doc2. Recommended:
   `/mnt/data/Life/Andy/Email/_mailstore-export-staging/` (NFS mount on
   the Win VM; remove after migration completes).
5. Wait for the export. Output is one `.eml` per message, folder
   hierarchy preserved exactly as MailStore had it.

## U7b — Convert EML tree → Maildir

```bash
# Dry-run first to confirm folder counts
python3 tools/mailarchive-migrate/eml-to-maildir.py \
  --src /mnt/data/Life/Andy/Email/_mailstore-export-staging \
  --dst /mnt/data/Life/Andy/Email/legacy.archive \
  --dry-run -v

# Then for real
python3 tools/mailarchive-migrate/eml-to-maildir.py \
  --src /mnt/data/Life/Andy/Email/_mailstore-export-staging \
  --dst /mnt/data/Life/Andy/Email/legacy.archive
```

Output is a **nested** Maildir tree (matching mbsync's `SubFolders
Verbatim` layout):

```
legacy.archive/
├── Cullen Work/
│   ├── cur/
│   ├── new/
│   ├── tmp/
│   └── INBOX/
│       ├── cur/
│       ├── new/
│       └── tmp/
└── Personal/
    └── ...
```

NOT Maildir++ (flat dot-separated names like
`legacy.archive/.Cullen Work.INBOX/`) — that would diverge from the live
trees and break any future merge.

Messages land in `cur/` with the `:2,S` (Seen) flag.

## U7c — Optional dedup against live trees (deferred)

**Default recommendation: leave `legacy.archive/` separate from the
live `o365/` and `gmail/` trees forever.** No risk of merge corruption.

If you ever want a unified tree, write a small inline Python script
(~30 lines) that walks both trees, builds a `Message-ID → filepath`
map, and on collision deletes the older file (typically the legacy
copy). Run **after** the live trees have populated and stabilised. The
plan deliberately defers this — see U7c in the plan doc.

## Verification

After U7b completes:

```bash
# Folder count sanity check
find /mnt/data/Life/Andy/Email/legacy.archive -type d -name cur | wc -l

# Open the archive in any standard client to spot-check
mutt -f /mnt/data/Life/Andy/Email/legacy.archive/Cullen\ Work/INBOX
```

A clean run reports:

```
INFO done: <N> written, <M> duplicates skipped, <K> corrupt/failed, <F> folders touched
```

Spot-check 5 representative messages (plain text, HTML,
with-attachment, multi-recipient, calendar invite) before declaring
victory.
