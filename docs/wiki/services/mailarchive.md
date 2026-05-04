# Mail archival (mailarchive)

**Last researched:** 2026-05-04
**Status:** built and merged; pending bootstrap + first sync on doc2
**Host:** `doc2`
**Module:** `modules/nixos/services/mailarchive.nix`
**Plan:** `docs/plans/2026-05-04-001-feat-mailarchive-mailstore-retirement-plan.md`

## What this is

`homelab.services.mailarchive` continuously pulls Gmail and work O365
(`cullenwines.com.au`) into Maildir under
`/mnt/data/Life/Andy/Email/<account>/`. Replaces the Win10 MailStore VM
(VMID 102 — to be retired once the smoke test passes).

Posture: backup-of-record. mbsync is configured `Sync Pull` + `Create
Near` + `Remove None` + `Expunge None`, so server-side deletions never
propagate to the local archive. New folders cannot be created on the
remote by mbsync.

## One-time bootstrap

Run from any machine with this flake checked out and a browser
(workstation works best). Bootstrap is needed once per account and once
again whenever Microsoft revokes the refresh token (~90 days inactive,
or earlier if a Conditional Access policy changes).

### Personal Gmail

1. **Register an OAuth client** in your own Google Cloud project:
   <https://console.cloud.google.com/apis/credentials>. Type:
   "Desktop application". Record the `client_id` and `client_secret`.
2. **Run the bootstrap helper:**

   ```bash
   nix run github:abl030/nixosconfig#oauth2-helper -- bootstrap \
     --provider=gmail --user=<your.gmail@gmail.com> \
     --client-id=<gcp-client-id> --client-secret=<gcp-client-secret>
   ```

3. The helper prints a URL + code on stderr. Sign in via that URL.
4. On success it prints a paste-ready dotenv block on stdout. Save it:

   ```bash
   sops -e -i secrets/hosts/doc2/mailarchive-gmail.env
   # (file opens in $EDITOR; paste the printed block; :wq)
   git add secrets/hosts/doc2/mailarchive-gmail.env
   git commit -m "feat(mailarchive): seed gmail refresh token"
   git push
   ```

### Work O365 (cullenwines.com.au)

The work tenant has Thunderbird's published OAuth client_id pre-consented
(`9e5f94bc-e8a4-4e73-b8be-63364c29d753`, app object id
`ffa49eb9-9ee2-4ac1-9207-e05cf008015a`). No app registration required.
DavMail's client_id is **not** consented and would need an admin ticket —
the probe (`docs/brainstorms/2026-05-04-mailstore-vm-probe-result.md`)
ruled out DavMail for that reason.

```bash
nix run github:abl030/nixosconfig#oauth2-helper -- bootstrap \
  --provider=o365 --user=andy@cullenwines.com.au
```

Sign in at <https://login.microsoft.com/device> with the printed code.
Tenant defaults to `common` — Microsoft routes by `login_hint`. Override
with `--tenant=<id>` only if `common` refuses to route (rare; would
surface as a clear AADSTS error).

Save the printed block to `secrets/hosts/doc2/mailarchive-work.env`:

```bash
sops -e -i secrets/hosts/doc2/mailarchive-work.env
git commit && git push
```

## Enable on doc2

The host config in `hosts/doc2/configuration.nix` already declares the
two accounts but ships with `enable = false;` so initial deploys don't
break on missing secrets. After both
`secrets/hosts/doc2/mailarchive-work.env` and
`secrets/hosts/doc2/mailarchive-gmail.env` exist (encrypted via the
bootstrap flow above), flip `enable = false;` → `enable = true;` in the
host config:

```nix
homelab.services.mailarchive = {
  enable = true;  # ← flip here
  accounts = { ... };
};
```

Commit and push.

## Deploy

Per `CLAUDE.md`: never use `--target-host` for remote rebuilds. The host
pulls from GitHub:

```bash
ssh doc2 "sudo nixos-rebuild switch \
  --flake github:abl030/nixosconfig#doc2 --refresh"
```

`--refresh` forces nix to re-resolve the flake ref so the latest push is
picked up.

## First-run quirk: Microsoft eventual consistency

> **The very first `mailarchive-work.service` run after bootstrap may
> fail with `AUTHENTICATE failed.` in the journal. This is *expected*.
> Microsoft's auth-issuer and Exchange Online's IMAP service have a
> few-minute consistency lag on first-auth. Do NOT re-run the bootstrap.
> Wait 5 minutes; the next timer fire will succeed.**

The probe documented this on 2026-05-04 — first attempt failed
immediately after consent, retry ~5 minutes later succeeded. In normal
operation (refresh-only auths) this never recurs.

## Verify

```bash
# Service status + recent journal
ssh doc2 systemctl status mailarchive-work.service mailarchive-gmail.service
ssh doc2 'journalctl -u mailarchive-work.service -n 50'

# Health endpoint (server-side boolean)
ssh doc2 'curl -s http://127.0.0.1:9876/health/work | jq'
ssh doc2 'curl -s http://127.0.0.1:9876/health/gmail | jq'
# → {"healthy": true, "stale_seconds": <small>, "last_sync": "..."}

# Maildir populated
ssh doc2 'find /mnt/data/Life/Andy/Email/work/INBOX/cur -type f | head'
ssh doc2 'find /mnt/data/Life/Andy/Email/gmail -type d -name cur | head'
```

Uptime Kuma should show two new monitors green within ~2 minutes of the
`homelab-monitoring-sync` job picking them up.

## Folder selection

### O365

`Patterns "INBOX*" "Sent Items*" "Archive" "Archives*" "Drafts" "Deleted Items*" "Junk Email"`

The trailing `*` makes a pattern recursive. The probe showed 332 folders
on cullenwines.com.au (deeply nested under INBOX). Excluded:
`Calendar`, `Contacts`, `Tasks`, `Notes`, `Sync Issues*`,
`Conversation History`, `Outbox`, `RSS Feeds`, `Templates` — these are
calendar/state folders, not mail.

Verify against the live folder tree at first run; tighten or expand
`folderPatterns` in `hosts/doc2/configuration.nix` as needed.

### Gmail

`Patterns "[Gmail]/All Mail"` only. Gmail's IMAP exposes labels as
folders and every message appears in every folder it's labelled with.
Fetching by label would multiply messages by N. `[Gmail]/All Mail`
contains every message exactly once — the canonical backup target.

## Operational recovery

### Refresh-token expiry (AADSTS70008 / AADSTS70043)

Symptoms: `mailarchive-<account>.service` starts failing; journal shows
the AADSTS code from `oauth2-helper`. Heartbeat stops updating; Kuma
turns red after ~10-20 minutes.

Fix: re-run the bootstrap procedure for the affected account, re-encrypt
the secret, redeploy. No code changes.

### Microsoft revokes the Thunderbird client_id

Precedent: 2024-08-01 retirement of `08162f7c-…`. Recovery is documented
but happens out-of-band:

1. Find the new Thunderbird client_id from Mozilla's `mozilla-central`
   sources (search for the OAuth issuer config).
2. Update the helper's default in `nix/pkgs/oauth2-helper.nix`
   (`THUNDERBIRD_O365_CLIENT_ID`) **or** override per-account by setting
   `OAUTH_CLIENT_ID=<new-id>` in the sops dotenv.
3. Re-bootstrap, redeploy.
4. **Append a dated note to this wiki entry** capturing the new id and
   the date Microsoft retired the old one — that's the institutional
   record for the next rotation.

Total recovery time: ~30-60 minutes per account.

### NFS to tower goes stale

The `homelab.nfsWatchdog` registers one watchdog per account at
`${dataDir}/${name}`. Stat-check every 5 min; on timeout, restarts the
fetcher service. mbsync's incremental sync semantics tolerate the gap.

If the mount is stuck for longer than that, check tower (`192.168.1.2`)
NFS export status and the `mnt-data.mount` unit on doc2.

## Architecture references

- Plan: `docs/plans/2026-05-04-001-feat-mailarchive-mailstore-retirement-plan.md`
- Probe (end-to-end verification of OAuth + IMAP):
  `docs/brainstorms/2026-05-04-mailstore-vm-probe-result.md`
- Tool comparison (mbsync vs getmail6 vs OfflineIMAP, MailStore migration
  mechanics): `docs/brainstorms/2026-05-04-mailstore-vm-replacement-research.md`
- `cyrus-sasl-xoauth2` `SASL_PATH` requirement:
  <https://github.com/moriyoshi/cyrus-sasl-xoauth2>
- Migration tool (MailStore EML → Maildir): `tools/mailarchive-migrate/`
