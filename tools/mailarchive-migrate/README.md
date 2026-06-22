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

## U7c — Dedup against the live tree (CHOSEN, 2026-06-18)

Scope changed during the live rollout (see issue #227 and the runbook's
"MailStore migration" section): **migrate work only** (Gmail's live pull is a
complete superset), and **dedup the work export against the live `work/`
tree** so `legacy.archive/` keeps ONLY the mail not on the live server — the
user's deleted history — instead of a giant duplicate of still-filed mail.

This is implemented as a `--dedupe-against <maildir>` flag (repeatable) on
`eml-to-maildir.py`: it walks the given live Maildir(s) and seeds the
`seen_ids` Message-ID set **before** converting the export, so any message
already present live is skipped. Reuses the tool's existing Message-ID dedup.
When seeding it reads only each live message's header block (not multi-MB
attachment bodies), so it scales to tens of thousands of messages over NFS.

```bash
python3 eml-to-maildir.py \
  --src /mnt/data/Life/Andy/Email/_mailstore-export-staging \
  --dst /mnt/data/Life/Andy/Email/legacy.archive \
  --dedupe-against /mnt/data/Life/Andy/Email/work \
  --dry-run -v
```

**Run only after the live work sync has gone green** (Kuma `Mailarchive: work`
green = first full pull done) — otherwise live-but-not-yet-synced mail would be
duplicated into `legacy.archive/`. The survivor count ≈ your deleted work
history.

`--dedupe-against` is implemented and tested (2026-06-22, #227). Verified
against the live `work/` tree on doc2: 27,310 files → 25,563 unique
Message-IDs seeded (cross-folder duplicates collapse), ~4 min over NFS.
Synthetic-Maildir tests live in `test_eml_to_maildir.py`
(`python3 tools/mailarchive-migrate/test_eml_to_maildir.py`).

## Verification

After U7b completes:

```bash
# Folder count sanity check
find /mnt/data/Life/Andy/Email/legacy.archive -type d -name cur | wc -l

# Open the archive in any standard client to spot-check
mutt -f /mnt/data/Life/Andy/Email/legacy.archive/Cullen\ Work/INBOX
```

A clean run reports (with `--dedupe-against`, the seed line first):

```
INFO dedupe: seeded <S> Message-IDs from live <maildir>
INFO done: <N> written, <L> already-live skipped, <M> intra-export dups, <K> corrupt/failed, <F> folders touched
```

`<N> written` is the survivor count — your deleted work history. `<L>
already-live skipped` is the mail that's still filed on the live server.

Spot-check 5 representative messages (plain text, HTML,
with-attachment, multi-recipient, calendar invite) before declaring
victory.
