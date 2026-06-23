# Mail archival (mailarchive)

**Last researched:** 2026-05-04 (deploy paths refreshed 2026-06-18 for the signed-fleet-deploys cutover #235)
**Status:** **LIVE on doc2 (2026-06-18)** — both accounts enabled, authenticated, and pulling. Initial syncs running; Kuma monitors go green after each first full sync. Remaining: MailStore VM 102 retirement (see "MailStore migration" below and issue #227).
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

> **Run from a local Forgejo clone, not `github:`.** Since the
> signed-fleet-deploys cutover (#235) GitHub is a frozen, ancestor-only
> fallback and does not carry this module's `oauth2-helper` flake app.
> `cd` into an up-to-date checkout (origin = `git.ablz.au`) and invoke
> the app with `nix run .#oauth2-helper -- ...` as shown below.

### Personal Gmail

> **Gmail uses a DIFFERENT OAuth flow than O365 — verified end-to-end
> 2026-06-18 against Google's live API.** The Gmail path was never probed
> during the original build (only O365 was), and the device-code flow the
> helper first used for both is **fundamentally unusable for Gmail**:
>
> 1. **Gmail needs the loopback authorization-code flow, NOT device-code.**
>    Gmail's restricted scope `https://mail.google.com/` is not on Google's
>    device-flow allowlist — the device endpoint rejects it with
>    `HTTP 400 invalid_scope: "Invalid device flow scope"`. (A "TVs and
>    Limited Input devices" client gets *past* the `Invalid client type`
>    error only to hit this one.) Google's documented path for a CLI/headless
>    tool needing a restricted scope is the **installed-app authorization-code
>    flow over a localhost loopback redirect**, which requires a
>    **"Desktop app"** OAuth client. The helper's `bootstrap --provider=gmail`
>    runs exactly this: it starts a local listener, prints a consent URL, and
>    catches the redirect (PKCE S256, `access_type=offline`, `prompt=consent`).
> 2. **App publishing status MUST be "Production", not "Testing".** For an
>    *External + Testing* app requesting a restricted scope, Google **expires
>    the refresh token after 7 days** — a backup-of-record would die weekly
>    with `invalid_grant`. Publishing to Production gives a long-lived token.
>    As the sole user you click through the "Google hasn't verified this app"
>    warning; the formal CASA security review is NOT required for personal
>    single-user use.

1. **Register an OAuth client** in your own Google Cloud project:
   <https://console.cloud.google.com/apis/credentials>. Type:
   **"Desktop app"** (the loopback flow requires it; "TVs and Limited Input
   devices" will NOT work — see footgun 1). Record the `client_id` and
   `client_secret`.
1. **Publish the app to Production.** Google Auth Platform → *Audience* →
   **Publish app** (see footgun 2).
1. **Run the bootstrap.** Two modes — the dotenv block always goes to
   **stdout** (redirect into the secret file); the consent URL + prompts go to
   **stderr**.

   **`--manual` (recommended — works everywhere, incl. SSH / WSL / headless):**
   the helper prints the consent URL and reads the auth code back by paste, so
   the browser never has to reach the helper's `127.0.0.1` listener.

   ```bash
   nix run .#oauth2-helper -- bootstrap --manual \
     --provider=gmail --user=<your.gmail@gmail.com> \
     --client-id=<desktop-client-id> --client-secret=<desktop-client-secret> \
     > secrets/hosts/doc2/mailarchive-gmail.env
   ```

   Open the printed URL, click through the unverified-app warning
   (*Advanced → Go to … (unsafe)*), Allow. The browser then tries to load a
   `http://127.0.0.1:8087/...` page and **fails to connect — that is
   expected**; copy the whole address-bar URL (or just the `code=` value) and
   paste it at the prompt. The token lands in the file.

   **Listener mode (drop `--manual`):** nicer when the browser and helper are
   the *same* machine (a local workstation), or behind
   `ssh -L 8087:127.0.0.1:8087 <host>`. The helper runs a local listener and
   catches the redirect automatically. (Override the port with `--port`.)
1. **Encrypt in place, then commit.** sops discovers `.sops.yaml` from the
   *current directory*, and `path_regex` is relative to `secrets/`, so you
   MUST run it from inside `secrets/` with a repo-relative path (this is the
   #1 footgun — see CLAUDE.md "Re-key … from inside `secrets/`"):

   ```bash
   test -s secrets/hosts/doc2/mailarchive-gmail.env || echo "EMPTY — bootstrap failed, retry"
   ( cd secrets && sops -e -i hosts/doc2/mailarchive-gmail.env )
   git add secrets/hosts/doc2/mailarchive-gmail.env
   git commit -m "feat(mailarchive): seed gmail refresh token"
   git push
   ```

   Note: `sops -e -i` encrypts an **existing plaintext** file in place — it
   does not open an editor. (To hand-edit an already-encrypted file later,
   use `sops secrets/hosts/doc2/mailarchive-gmail.env`.)

### Work O365 (cullenwines.com.au)

The work tenant has Thunderbird's published OAuth client_id pre-consented
(`9e5f94bc-e8a4-4e73-b8be-63364c29d753`, app object id
`ffa49eb9-9ee2-4ac1-9207-e05cf008015a`). No app registration required.
DavMail's client_id is **not** consented and would need an admin ticket —
the probe (`docs/brainstorms/2026-05-04-mailstore-vm-probe-result.md`)
ruled out DavMail for that reason.

```bash
nix run .#oauth2-helper -- bootstrap \
  --provider=o365 --user=andy@cullenwines.com.au \
  > secrets/hosts/doc2/mailarchive-work.env
```

Sign in at <https://login.microsoft.com/device> with the code printed on
**stderr**. Tenant defaults to `common` — Microsoft routes by `login_hint`.
Override with `--tenant=<id>` only if `common` refuses to route (rare;
would surface as a clear AADSTS error). The dotenv block lands in the file.

Encrypt in place (from inside `secrets/` — see the Gmail note above) and
commit:

```bash
test -s secrets/hosts/doc2/mailarchive-work.env || echo "EMPTY — bootstrap failed, retry"
( cd secrets && sops -e -i hosts/doc2/mailarchive-work.env )
git add secrets/hosts/doc2/mailarchive-work.env
git commit -m "feat(mailarchive): seed work o365 refresh token"
git push
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

Post-cutover (#235) the verified deploy path is `fleet-update`: it fetches
Forgejo (`git.ablz.au`), verifies every commit in range is SSH-signed by a
key in `hosts.nix`, then builds from its own root-owned clone. Push your
signed commit to Forgejo first, then:

```bash
ssh doc2 "sudo fleet-update"
```

Do **not** deploy `--flake github:abl030/nixosconfig#doc2` (GitHub is the
frozen, stale fallback) and do **not** use `--target-host`. See
`CLAUDE.md` and `docs/wiki/infrastructure/signed-fleet-deploys.md`.

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

# Health endpoint — HTTP 200 when fresh, 503 when stale (per account).
# Port 9877 (9876 is taken by alert-bridge on doc2).
ssh doc2 'curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:9877/health/work'
ssh doc2 'curl -s http://127.0.0.1:9877/health/work | jq'
# → 200  {"healthy": true, "stale_seconds": <small>, "last_sync": "..."}

# Maildir populated (note: work mail lands under work/INBOX — the rc sets
# an explicit `Inbox` directive; without it mbsync dumps INBOX in ~/Maildir)
ssh doc2 'find /mnt/data/Life/Andy/Email/work/INBOX/cur -type f | head'
ssh doc2 'find /mnt/data/Life/Andy/Email/gmail -type d -name cur | head'
```

The two Kuma monitors (`Mailarchive: work/gmail`) are **plain HTTP
status-code** monitors (NOT json-query — see issue #278). They stay RED
until each account's **first full sync completes** and writes a heartbeat
(the health endpoint returns 503 until then), then flip green. The initial
Gmail All-Mail pull is large, so expect red for a while on first deploy.

Watch progress: Grafana Explore (logs.ablz.au) →
`{host="doc2", unit=~"mailarchive-.*"}`.

> **First-deploy gotcha (2026-06-18).** A long-running initial mbsync is a
> oneshot that systemd will NOT restart mid-flight on a `fleet-update`. If you
> change the rc (e.g. the `Inbox` fix) while an initial sync is in progress,
> `systemctl stop mailarchive-<acct>.service` and start it again so it picks up
> the new rc; otherwise the old invocation keeps using the old config.

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

### Gmail refresh-token revoked (`invalid_grant`)

Symptoms: `mailarchive-gmail.service` fails; journal shows `oauth2-helper`
reporting `HTTP 400 ... invalid_grant` from the token endpoint. Gmail
refresh tokens are revoked when any of these happen:

- **The OAuth app is in "Testing", not "Production"** → token expires after
  7 days (the original setup bug; see the Gmail bootstrap footguns above).
  Permanent fix: publish the app to Production, then re-bootstrap.
- **The Google account password was changed** — Google revokes all
  Gmail-scope refresh tokens on password change. Re-bootstrap.
- **6 months without use** (won't happen while the timer runs), or the user
  manually revoked access at <https://myaccount.google.com/permissions>.

Fix: re-run the Gmail bootstrap, re-encrypt, redeploy. No code changes.

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

## MailStore migration (VM 102 retirement)

Scope decided 2026-06-18 (supersedes the original "migrate the whole 11 GB
archive" plan — see issue #227):

- **Skip Gmail entirely.** The live `[Gmail]/All Mail` pull is a complete
  superset of MailStore's Gmail content; importing it would just duplicate
  everything.
- **Migrate WORK only.** The user deletes work mail regularly, so MailStore
  holds cullenwines O365 mail that exists nowhere else (deleted off the live
  server before the deletion-resistant pull existed). That historical mail is
  the *only* thing worth recovering.
- **Dedup against the live tree.** Extend `tools/mailarchive-migrate/eml-to-maildir.py`
  with a `--dedupe-against <maildir>` flag (repeatable): seed the seen
  Message-ID set from the live `work/` Maildir *first*, then convert the
  MailStore export skipping anything already live. Result: `legacy.archive/`
  holds ONLY the deleted history, not a duplicate of filed mail. ~20 lines —
  the tool is already Message-ID based.

Sequence (do NOT start until the live work sync has gone green — the dedup set
must be complete, or live-but-not-yet-synced mail gets duplicated into legacy):

1. Build + test `--dedupe-against` against synthetic Maildirs.
2. U7a — in MailStore Home on VM 102, export the **work** folders → *File
   system / EML / retain folder structure* to a path doc2 can read (e.g.
   `/mnt/data/Life/Andy/Email/_mailstore-export-staging/`).
3. U7b — `eml-to-maildir.py --src <staging> --dst …/legacy.archive
   --dedupe-against /mnt/data/Life/Andy/Email/work` (dry-run first). Survivor
   count ≈ your deleted work history; spot-check a few.
4. Stop VM 102 via the Proxmox **web UI** (or `ssh root@prom 'qm stop 102'`).
   `vms/proxmox-ops.sh` was removed in `fa246070`.
5. Safety window (~3-5 days), then destroy VM 102 via the web UI; wipe the
   staging dir. Flip the plan frontmatter to `status: completed` and close #227.

### Executed 2026-06-23 — U7a/U7b done, archive verified

The work export landed in `/mnt/data/Life/Andy/Email/export-staging/`
(`Thunderbird andy@cullenwines.com.au (2)/Inbox/`, 10,806 `.eml`). U7b ran
on doc2 against live `work/`. Final, verified result:

- **4,148 survivors** written (3,313 with a real Message-ID confirmed absent
  from live + 835 that genuinely carry no Message-ID, kept conservatively),
  **6,645 already-live skipped**, 13 intra-export dups, 0 corrupt. Re-audit:
  **0** survivors duplicate live mail, **0** header BOMs in output.
- **Merged into the live mailbox (2026-06-23, user request).** The 4,148 were
  staged in a separate `legacy.archive/` tree, then moved into
  `work/INBOX/cur/` (127 → 4,275) and `legacy.archive/` removed — one unified
  work mailbox instead of two trees. Safe because the work channel is
  `Sync Pull` + `Remove None` + `Expunge None`: mbsync never pushes local-only
  messages to the server and never deletes them. The recovered history is
  identifiable by its `…maildir-migrate.<hex>:2,S` filenames if it ever needs
  splitting back out.

**GOTCHA — Thunderbird/MailStore BOM corruption (fixed in `c8142ca6`).**
Every exported EML is a Thunderbird message: `X-Mozilla-*` pseudo-headers
plus a stray UTF-8 BOM (`\xef\xbb\xbf`) injected *before the first real
header*. Python's `email` parser (and mutt) treat the BOM as end-of-headers,
so `message_id_for()` never saw the real `Message-ID` and fell back to a
synthetic SHA id. Synthetic ids never match the clean live Maildir, so the
first (pre-fix) run let ~2,300 BOM-corrupted messages bypass `--dedupe-against`
and survive as live duplicates (survivors 6,449 vs the correct 4,148), and
the stored messages were unreadable (no From/Subject). The fix
(`strip_header_bom`) drops BOMs from the header block only — applied to both
the dedup key and the stored bytes, so dedup works and the archive is
byte-clean. If you ever re-import another Thunderbird-sourced export, this is
already handled; verify post-run with: count survivors, grep for header BOMs,
and confirm 0 survivor Message-IDs intersect the live set.

## Architecture references

- Plan: `docs/plans/2026-05-04-001-feat-mailarchive-mailstore-retirement-plan.md`
- Probe (end-to-end verification of OAuth + IMAP):
  `docs/brainstorms/2026-05-04-mailstore-vm-probe-result.md`
- Tool comparison (mbsync vs getmail6 vs OfflineIMAP, MailStore migration
  mechanics): `docs/brainstorms/2026-05-04-mailstore-vm-replacement-research.md`
- `cyrus-sasl-xoauth2` `SASL_PATH` requirement:
  <https://github.com/moriyoshi/cyrus-sasl-xoauth2>
- Migration tool (MailStore EML → Maildir): `tools/mailarchive-migrate/`
