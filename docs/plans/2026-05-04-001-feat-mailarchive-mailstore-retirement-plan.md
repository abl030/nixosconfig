---
title: "feat: NixOS mailarchive module + MailStore VM retirement"
type: feat
status: active
date: 2026-05-04
origin: docs/brainstorms/2026-05-04-mailstore-vm-replacement-requirements.md
---

# feat: NixOS mailarchive module + MailStore VM retirement

## Summary

Build a NixOS service module (`homelab.services.mailarchive`) on doc2 that uses `mbsync` + `cyrus-sasl-xoauth2` plus a small Python OAuth refresh helper to continuously archive personal Gmail and work O365 (cullenwines.com.au) into Maildir under `/mnt/data/Life/Andy/Email/<account>/`. Migrate the 11 GB existing MailStore Home archive (mixed Gmail + O365, single repository) into a one-shot `legacy.archive/` Maildir tree. Smoke-test the live fetch with a few real messages, then stop and destroy VM 102 with a short safety window. Operational shape is one fetcher per account driven by a systemd timer, sops-encrypted refresh tokens, a heartbeat sentinel polled by Uptime Kuma, and the existing `homelab.nfsWatchdog` covering the NFS mount to tower.

---

## Problem Frame

The Windows 10 VM (VMID 102 on prom) exists solely to run Thunderbird + MailStore Home for email archiving. Win10 is out of support, the VM is the last Windows box in the fleet, and the historical MailStore proprietary `.dat`/`.rr` format prevents any non-MailStore tooling from reading the archive. The brainstorm + research + probe trio (see Sources & References) settled architecture, verified OAuth and IMAP end-to-end against the live cullenwines.com.au tenant, and confirmed Thunderbird is already tenant-consented — making `mbsync` direct with Thunderbird's published client_id viable without IT involvement.

This plan is the HOW: NixOS module shape, OAuth helper, monitoring wiring, migration script, cutover sequence, and operational runbook for refresh-token rotation. (See origin: `docs/brainstorms/2026-05-04-mailstore-vm-replacement-requirements.md`.)

---

## Requirements

- R1. Continuous IMAP archival of personal Gmail and work O365 to Maildir, with deletion-resistance (capture before user deletes from work mailbox).
- R2. OAuth2 authentication with no app registration in the work Entra tenant; uses Thunderbird's existing tenant consent.
- R3. Storage as Maildir (one file per message) under `/mnt/data/Life/Andy/Email/<account>/`, included by existing Kopia snapshots (Wasabi + offsite).
- R4. One-shot migration of the existing 11 GB MailStore Home archive (mixed Gmail + O365) into a single `legacy.archive/` Maildir tree; MailStore retired entirely (no proprietary-format hangover).
- R5. NixOS module under `modules/nixos/services/mailarchive.nix` following `.claude/rules/nixos-service-modules.md` (options under `homelab.services.mailarchive`, sops, monitoring, NFS watchdog).
- R6. Uptime Kuma monitor that goes red when a fetcher hasn't successfully synced within ~10 minutes (per the project's noise-discipline defaults).
- R7. Refresh-token bootstrap is a documented one-time interactive procedure; subsequent operation is fully unattended for ≥90 days.
- R8. Cutover plan that smoke-tests the live fetch against real messages (test send + observed mbsync run + Kuma green for both accounts), stops VM 102, waits a short safety window with disks intact, then destroys the VM.
- R9. Operational runbook for recovering from Microsoft revoking Thunderbird's client_id (precedent: 2024-08-01 retirement of `08162f7c-…`).

---

## Scope Boundaries

- No web UI archive product (Mailpiler, Stalwart, Roundcube, etc.) — overkill for ~3x/year retrieval; user wants format openness, not a UI.
- No replacement of daily mail clients — Outlook on work laptop and Gmail web stay.
- No search or indexing infrastructure (notmuch, mu, mairix). Deferred; Maildir keeps the door open.
- No Entra app registration in the work tenant; no IT involvement.
- No DavMail (rejected after probe — DavMail's client_id requires admin consent we can't grant).
- No headless Thunderbird (rejected — same OAuth surface as mbsync, more moving parts).

### Deferred to Follow-Up Work

- **Search/indexing**: a future plan can add notmuch or mu against the same Maildir tree without changes to this module.
- **`homelab.monitoring` json-query operator support**: today the sync hardcodes `==`. This plan works around that with a server-side boolean health check; a separate refactor could expose `jsonPathOperator` in the module.
- **Splitting the legacy archive per-account**: the MailStore archive is mixed; it lands as one `legacy.archive/` tree. If we ever want it split by account, that's a separate one-shot script.

---

## Context & Research

### Relevant Code and Patterns

- `modules/nixos/services/kopia.nix` — closest pattern match: `homelab.services.kopia.instances = attrsOf submodule`, sops dotenv, NFS-aware service wiring, `homelab.nfsWatchdog`/`homelab.monitoring` registration, json-query monitor with `basicAuthUserEnv`/`basicAuthPassEnv`. Mirror its shape closely. Note: kopia uses `runAsRoot` for restrictive NFS perms; mailarchive does not need this — it owns its own Maildir as the `mailarchive` user.
- `modules/nixos/services/nfs-watchdog.nix` — confirms the watchdog API: one-line registration `homelab.nfsWatchdog.<name>.path = "..."`. Default 5min interval. The watchdog restarts `<name>.service`, so naming the watchdog entry `mailarchive-<name>` is correct.
- `modules/nixos/services/monitoring_sync.nix:201` — read-only context: confirms `jsonPathOperator` is hardcoded to `==`, so json-query monitors must use server-side boolean health checks rather than client-side comparators. The plan honours this in U4.
- `modules/nixos/services/mounts/nfs-local.nix` — mounts `/mnt/data` from `192.168.1.2:/mnt/user/data/` (tower / Unraid) as NFSv4.2. The systemd unit is `mnt-data.mount`. `/mnt/virtio` is separate and is the virtiofs mount used for VM-local state.
- `modules/nixos/services/podcast.nix` — pattern for `pkgs.writers.writePython3Bin` with `libraries = [...]`. Use for the OAuth refresh helper.
- `modules/nixos/services/default.nix` — register the new module by adding `./mailarchive.nix` to the imports list.
- `hosts/doc2/configuration.nix` — confirms `/mnt/data` is mounted on doc2 (already used by `kopia` for the photos backup).
- `modules/nixos/common/secrets.nix:35` — confirms `secrets/hosts/<hostname>/` is the canonical search path for `homelab.secrets.sopsFile`.
- `.claude/rules/nixos-service-modules.md` — service hierarchy, monitoring noise discipline (interval=60, maxretries=10, retryInterval=60, resendInterval=240).

### Institutional Learnings

- The probe (`docs/brainstorms/2026-05-04-mailstore-vm-probe-result.md`) demonstrated a Microsoft eventual-consistency quirk on first-auth: an access token can pass OAuth validation seconds after consent yet still be rejected by Exchange Online's IMAP service for a few minutes until consent propagates. **Implication for the bootstrap runbook**: after bootstrap, the very first sync attempt may show `AUTHENTICATE failed` in journal — this is **expected**, not a bootstrap failure. Wait 5 minutes; do not re-bootstrap.
- The probe confirmed Thunderbird's published OAuth client_id `9e5f94bc-e8a4-4e73-b8be-63364c29d753` is registered as an Activated Enterprise App on cullenwines.com.au with object ID `ffa49eb9-9ee2-4ac1-9207-e05cf008015a`. No admin consent needed.
- Multiple concurrent IMAP sessions against the same O365 mailbox are normal Exchange Online behaviour. The Win VM Thunderbird and the new mailarchive can both connect during the cutover window without provoking session limits.

### External References

- The companion research doc (`docs/brainstorms/2026-05-04-mailstore-vm-replacement-research.md`) covers the per-tool comparison (mbsync vs getmail6 vs OfflineIMAP) and the MailStore migration mechanics.
- Microsoft auth scope: `offline_access https://outlook.office.com/IMAP.AccessAsUser.All`, OAuth endpoint `https://login.microsoftonline.com/common/oauth2/v2.0/`.
- Gmail OAuth scope: `https://mail.google.com/`, OAuth endpoint `https://oauth2.googleapis.com/`.
- `cyrus-sasl-xoauth2` plugin lookup: at runtime via `SASL_PATH=${pkgs.cyrus-sasl-xoauth2}/lib/sasl2`. The systemd `path` setting only sets `$PATH`; SASL plugins need the `SASL_PATH` env var. See [moriyoshi/cyrus-sasl-xoauth2 README](https://github.com/moriyoshi/cyrus-sasl-xoauth2).

---

## Key Technical Decisions

- **One module, two providers (`gmail` and `o365`).** Per-account submodule with a `provider` enum drives the small differences in OAuth flow (Gmail needs `client_secret`; Microsoft public client doesn't) and the folder-set defaults. Same fetcher, same Maildir layout, same monitoring wiring.
- **OAuth refresh helper as a single `pkgs.writers.writePython3Bin` script** (~80 lines, stdlib only). Invoked by mbsync's `PassCmd` once per sync; exchanges the on-disk refresh token for a fresh access token; prints it. Same tool, two subcommands: `refresh` (used by mbsync) and `bootstrap` (one-time interactive). Matches the probe v2 script structure that already validated end-to-end.
- **Refresh tokens stored in sops dotenv per account** at `secrets/hosts/doc2/mailarchive-<account>.env`. Format: `OAUTH_REFRESH_TOKEN=...`, plus `OAUTH_CLIENT_ID`, `OAUTH_TENANT` (O365 only), `OAUTH_CLIENT_SECRET` (Gmail only).
- **mbsync as a oneshot systemd unit fired by a per-account timer**, not as a daemon. Polling intervals: 60s for O365 (delete-resistance), 120s for Gmail (Gmail retains everything; less critical). Matches `kopia-verify-*` timer pattern.
- **mbsync direction is one-way Pull only.** rc uses `Sync Pull`, `Create Near`, `Remove None`, `Expunge None`. Rationale: this is a backup-of-record, not a synced mailbox. Two-way `Sync All` would push local Maildir state (including the migration script's `:2,S` Seen flags) back to the live server, marking historical messages read. `Create Both` would create local-only folders upstream on the live mailbox. Both are unsafe for an archive. `Expunge None` is the deletion-resistance lever — when the user deletes from O365 the Maildir copy stays.
- **Folder selection is provider-specific:**
  - **O365**: explicit folder set — `Patterns "INBOX*" "Sent Items*" "Archive" "Archives*" "Drafts" "Deleted Items*" "Junk Email"`. Captures everything the user actively organises (probe showed 332 folders, deeply nested under INBOX); excludes `Calendar`, `Contacts`, `Tasks`, `Notes`, `Sync Issues`, `Conversation History`, `Outbox`, `RSS Feeds`, `Templates` which are calendar/state folders not mail. Final pattern list verified at U3 implementation against the live folder tree.
  - **Gmail**: `Patterns "[Gmail]/All Mail"` only. Gmail's IMAP exposes labels as folders and every message appears in every folder it's labelled with — fetching by label would multiply messages by N. `[Gmail]/All Mail` contains every message exactly once; that's the canonical backup target.
- **SASL plugin discovery** via `Environment = "SASL_PATH=${pkgs.cyrus-sasl-xoauth2}/lib/sasl2"` on the systemd unit. `path = [...]` only sets `$PATH`; libsasl2 finds plugins via `SASL_PATH` (or `/usr/lib/sasl2`). Verify at first run with `mbsync -V` listing XOAUTH2 in supported AuthMechs.
- **Maildir layout: `SubFolders Verbatim` everywhere.** mbsync's Verbatim mode produces nested directories (`work/Inbox/Sent Items/cur/`). The migration script (U7) **must** produce the same nested layout so the live and migrated trees are structurally compatible. Maildir++ (flat dot-separated names) is rejected — it doesn't validate alongside an explicit `Path` directive in mbsync rc, and would create two parallel hierarchies if mixed with Verbatim.
- **Heartbeat via pull/json-query with server-side boolean.** mbsync's `ExecStartPost` touches `/var/lib/mailarchive/<account>.heartbeat` only on success. A long-running Python HTTP server reads heartbeat mtimes and serves `GET /health/<account>` returning `{"healthy": true|false, "stale_seconds": <int>}` based on a server-side threshold (default 600s). Uptime Kuma's json-query checks `$.healthy == "true"`. Rationale: `monitoring_sync.nix` hardcodes the json-query operator to `==`; comparator forms like `<600` would silently fail. Server-side boolean works with the existing module unchanged.
- **Static system user `mailarchive`** with `extraGroups = ["users"]` for NFS write access to `/mnt/data`. Mirrors the `kopia` user pattern.
- **`/mnt/data` mount dependency**: `requires = ["mnt-data.mount"]; after = ["mnt-data.mount" "network-online.target"];`. `/mnt/data` is NFSv4.2 to tower (192.168.1.2 / Unraid), not virtiofs — the systemd unit name is `mnt-data.mount` regardless of FS type, so the wiring is the same; the watchdog is genuinely needed because the mount is genuinely network-shared.
- **Module location: `modules/nixos/services/mailarchive.nix` (single file)** rather than a directory.
- **Migration: single `legacy.archive/` tree (mixed Gmail + O365).** The MailStore archive is mixed and not partitioned per-account. The migration imports everything to one tree under `/mnt/data/Life/Andy/Email/legacy.archive/` preserving MailStore's folder hierarchy. The live trees `o365/` and `gmail/` are siblings. Deduplication between legacy and live is optional and deferred — see U7.

---

## Open Questions

### Resolved During Planning

- **DavMail vs mbsync direct**: resolved by probe; mbsync direct via Thunderbird client_id works.
- **Where does the heartbeat sentinel live?**: `/var/lib/mailarchive/<account>.heartbeat`. Owned by the `mailarchive` user.
- **Push or pull monitoring?**: pull via json-query with **server-side boolean** (not client-side comparator — the existing `monitoring_sync.nix` hardcodes `==`).
- **OAuth scope set**: `offline_access https://outlook.office.com/IMAP.AccessAsUser.All` for O365; `https://mail.google.com/` for Gmail.
- **Migration target structure**: single `legacy.archive/` tree (the MailStore archive is mixed Gmail + O365 in one repository). Maildir layout `SubFolders Verbatim` matching the live trees.
- **Sync intervals**: 60s O365, 120s Gmail.
- **Folder selection**: O365 fetches mail folders explicitly (INBOX, Sent Items, Archive(s), Drafts, Deleted Items, Junk); excludes calendar/state. Gmail fetches `[Gmail]/All Mail` only.
- **Concurrent IMAP sessions during cutover**: accepted — multiple IMAP sessions per mailbox are normal.
- **Dedup tool for U7c**: `maildir-deduplicate` (and the renamed PyPI tool `mail-deduplicate`) are **not** packaged in nixpkgs (verified via mcp-nixos). U7c uses a small inline Python script (~30 lines, stdlib only — Message-ID set walk) instead. The optional dedup is low-risk and the default recommendation is to leave legacy and live trees separate forever.
- **Runbook location**: `docs/wiki/services/mailarchive.md` (matches the project's existing wiki convention; no new `docs/runbooks/` tree).

### Deferred to Implementation

- **Final mbsync rc detail tuning** — the rc structure is locked but exact pattern strings (e.g., precise list of O365 folder patterns) verify against the live folder tree at first run.
- **Heartbeat HTTP server port choice** — `9876` is a placeholder; pick an unused port on doc2 at implementation time.
- **Final shape of the bootstrap script's prompt text** — runbook in U6 specifies what the script does; the literal text gets refined once we run it for real.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

```text
┌────────────────────────────────────────────────────────────────┐
│  systemd timer (per account, OnUnitActiveSec=60s/120s)         │
│              │                                                  │
│              ▼                                                  │
│  systemd oneshot service: mailarchive-<account>                 │
│   Environment SASL_PATH=${cyrus-sasl-xoauth2}/lib/sasl2         │
│              │                                                  │
│              ▼                                                  │
│  mbsync -c /etc/mailarchive/mbsync-<account>.rc -a              │
│              │                                                  │
│              │  PassCmd → invokes oauth2-helper                 │
│              │              │                                   │
│              │              ▼                                   │
│              │   reads $OAUTH_REFRESH_TOKEN from sops env       │
│              │   POSTs to provider's token endpoint             │
│              │   prints fresh access_token                      │
│              │                                                  │
│              ▼                                                  │
│  XOAUTH2 IMAP (Sync Pull, Create Near, Expunge None)            │
│   → outlook.office365.com OR imap.gmail.com                     │
│              │                                                  │
│              ▼                                                  │
│  Maildir at /mnt/data/Life/Andy/Email/<account>/                │
│  (SubFolders Verbatim — nested dirs)                            │
│              │                                                  │
│              │  ExecStartPost (only on Exec success)            │
│              ▼                                                  │
│  touch /var/lib/mailarchive/<account>.heartbeat                 │
│                                                                 │
│  ──── Independent watcher ────────────────────────────────────  │
│                                                                 │
│  systemd service: mailarchive-health (long-running)             │
│              │                                                  │
│              ▼                                                  │
│  Python http.server on 127.0.0.1:9876                           │
│  GET /health/<account> →                                        │
│      {"healthy": true|false, "stale_seconds": <int>}            │
│              │  (healthy = stale_seconds < THRESHOLD, srv-side) │
│              ▼                                                  │
│  Uptime Kuma json-query: $.healthy == "true" → green            │
└────────────────────────────────────────────────────────────────┘
```

```text
Bootstrap (one-time, per account):
  user runs:  oauth2-helper bootstrap --provider=o365 --user=andy@cullenwines.com.au
                                    OR --provider=gmail --user=user@gmail.com
                                       --client-id=<...> --client-secret=<...>
  helper:     1. presents device-code URL + code
              2. polls Microsoft / Google token endpoint
              3. on success, prints sops env block to stdout
  user:       sops -e -i secrets/hosts/doc2/mailarchive-<account>.env
              (paste in the printed block)
              git commit && git push
              ssh doc2 "sudo nixos-rebuild switch \\
                --flake github:abl030/nixosconfig#doc2 --refresh"
```

---

## Implementation Units

- U1. **Create the `homelab.services.mailarchive` module skeleton**

  **Goal:** Land the module file with options, the `mailarchive` system user, sops secret declarations, and the per-account `attrsOf submodule` shape. No fetcher logic yet — this is the chassis everything else hangs off.

  **Requirements:** R5

  **Dependencies:** None.

  **Files:**
  - Create: `modules/nixos/services/mailarchive.nix`
  - Modify: `modules/nixos/services/default.nix` (add `./mailarchive.nix` to the imports list)

  **Approach:**
  - Declare `homelab.services.mailarchive.{enable, dataDir, healthPort, accounts}`. Defaults: `dataDir = "/mnt/data/Life/Andy/Email"`, `healthPort = 9876`. `accounts = attrsOf submodule` with submodule fields `{provider, remoteUser, syncIntervalSec, credentialSecret, folderPatterns}`.
  - `provider = enum ["gmail" "o365"]`. `syncIntervalSec` derives in module body from provider (60 for o365, 120 for gmail) but the option lets per-account override. `credentialSecret` is a sops secret name (e.g. `"mailarchive/work"`). `folderPatterns = listOf str` defaults to `["[Gmail]/All Mail"]` for gmail and `["INBOX*" "Sent Items*" "Archive" "Archives*" "Drafts" "Deleted Items*" "Junk Email"]` for o365.
  - Static user `mailarchive`, group `mailarchive`, home `/var/lib/mailarchive`, `extraGroups = ["users"]` (NFS write access). Mirror `kopia.nix:186-192`.
  - Create `tmpfiles.rules` for `/var/lib/mailarchive` and per-account `${dataDir}/${name}` directories owned by `mailarchive:mailarchive`, mode 0700.
  - Per-account sops secret declarations: `sops.secrets."mailarchive/<name>" = {sopsFile = config.homelab.secrets.sopsFile "mailarchive-<name>.env"; format = "dotenv"; owner = "mailarchive"; mode = "0400";}`.

  **Patterns to follow:**
  - `modules/nixos/services/kopia.nix:105-164` — submodule shape and option types.
  - `modules/nixos/services/kopia.nix:186-200` — static user + sops dotenv pattern.
  - `.claude/rules/nixos-service-modules.md` — module structure section.

  **Test scenarios:**
  - Happy path: `nix build .#nixosConfigurations.doc2.config.system.build.toplevel` succeeds with the module imported and `enable = false`.
  - Edge case: with `enable = true` and one account configured, `nixos-rebuild build --flake .#doc2` succeeds; check that the `mailarchive` user is created and per-account tmpfiles rules are present in the activation script.
  - Edge case: with `enable = true` but `accounts = {}`, the build still succeeds and creates no per-account state.
  - Test expectation: no automated test suite — validation is via `nix flake check` and `nixos-rebuild build`.

  **Verification:**
  - `nix flake check` passes.
  - `nix build .#nixosConfigurations.doc2.config.system.build.toplevel` succeeds.
  - Module appears in the imports list and `homelab.services.mailarchive` shows up in `eval` output.

---

- U2. **OAuth refresh helper script (`pkgs.writers.writePython3Bin`)**

  **Goal:** A single Python binary, callable two ways: as `oauth2-helper refresh --provider=<gmail|o365>` (used by mbsync's `PassCmd` — prints a fresh access token to stdout, exits 0) and as `oauth2-helper bootstrap --provider=<...> --user=<...>` (one-time interactive — runs device-code flow, prints sops env block to stdout for the user to paste into their secret file).

  **Requirements:** R2, R7, R9

  **Dependencies:** U1.

  **Files:**
  - Modify: `modules/nixos/services/mailarchive.nix` (add the helper definition near the top of the module's `let ... in` block; expose it as a top-level package via `pkgs.callPackage` indirection or a tiny helper module so the module body and `flake.nix` share one definition)
  - Modify: `flake.nix` — expose the helper as `packages.${system}.oauth2-helper` and `apps.${system}.oauth2-helper` so it's invokable via `nix run github:abl030/nixosconfig#oauth2-helper -- bootstrap ...` from any clone. Mirrors the existing `apps.${system}.fmt-nix` / `lint-nix` pattern (per CLAUDE.md "Common Commands"). This is the bootstrap chicken-and-egg fix: the user must be able to run the helper *before* the module is enabled on doc2 to capture the initial refresh token.

  **Approach:**
  - Use `pkgs.writers.writePython3Bin "oauth2-helper" {libraries = [];} ''<python>''`. Stdlib only — `urllib.request`, `urllib.parse`, `json`, `os`, `sys`, `time`, `argparse`. Match the working v2 probe at `docs/brainstorms/2026-05-04-mailstore-vm-probe-result.md`; that ~120-line script is essentially the helper.
  - **OAUTH_TENANT default** is `common`. Microsoft routes to the user's home tenant via `login_hint`; `common` works on every tenant the user has access to. Tenant-specific endpoints (e.g. `32bffe65-3e64-414f-9d21-069572b800eb` for cullenwines.com.au, captured in the probe) are valid alternatives but offer no concrete benefit and add brittleness to tenant-rename events. Sticking with `common` matches the probe and keeps the door open for additional providers without changing helper code.
  - `refresh` subcommand: read `OAUTH_PROVIDER`, `OAUTH_REFRESH_TOKEN`, `OAUTH_CLIENT_ID` from env (provided by systemd `EnvironmentFile`); for Gmail also `OAUTH_CLIENT_SECRET`; for O365 also `OAUTH_TENANT` (default `common`). POST to provider token endpoint with `grant_type=refresh_token`. Print only the access_token to stdout. Exit 0 on success, 1 on failure (non-zero exit causes mbsync to fail the run, which is correct).
  - `bootstrap` subcommand: print the device-code URL + user code to stderr, poll the token endpoint, on success print a multi-line block to stdout: `OAUTH_PROVIDER=...`, `OAUTH_CLIENT_ID=...`, `OAUTH_REFRESH_TOKEN=...`, etc. Stderr carries instructions; stdout is paste-ready.
  - O365: device-code URL `https://login.microsoftonline.com/{tenant}/oauth2/v2.0/devicecode`, scope `offline_access https://outlook.office.com/IMAP.AccessAsUser.All`, client_id from arg or default to Thunderbird's `9e5f94bc-…`.
  - Gmail: device-code URL `https://oauth2.googleapis.com/device/code`, scope `https://mail.google.com/`, client_id and client_secret required as args.
  - On the Microsoft eventual-consistency quirk (probe documented this), `refresh` does not pre-emptively retry — let mbsync's next timer fire. The helper is one-shot.

  **Patterns to follow:**
  - `modules/nixos/services/podcast.nix:14-60` — `pkgs.writers.writePython3Bin` with libraries (we won't need libraries).
  - The probe v2 script at `docs/brainstorms/2026-05-04-mailstore-vm-probe-result.md` (the authoritative shape).

  **Test scenarios:**
  - Happy path (refresh): `OAUTH_REFRESH_TOKEN=<live token> oauth2-helper refresh --provider=o365` prints a JWT-shaped string, exits 0. The token decodes to claims with `aud=https://outlook.office.com`.
  - Happy path (bootstrap): `oauth2-helper bootstrap --provider=o365 --user=andy@cullenwines.com.au` prints a URL + code, polls, and on user sign-in prints a sops-paste-ready env block.
  - Error path: missing `OAUTH_REFRESH_TOKEN` in env → exits non-zero with a clear stderr message.
  - Error path: Microsoft returns `AADSTS70008` (refresh token expired) on `refresh` → exits non-zero with the AADSTS code in stderr.
  - Edge case: HTTP timeout on token endpoint → exits non-zero, doesn't hang past 30s.
  - Test expectation: manual exercise during U6 bootstrap; no automated tests (the probe v2 script already validated the chain end-to-end).

  **Verification:**
  - `nix-build` of the module succeeds and produces an `oauth2-helper` binary in the closure.
  - Manual `oauth2-helper refresh --provider=o365` against a stored test refresh token returns a working access token.

---

- U3. **mbsync configs and per-account systemd timer + service**

  **Goal:** Generate one mbsync rc per account into `/etc/mailarchive/mbsync-<account>.rc`; one oneshot systemd service per account that runs `mbsync` with the right SASL environment and on success touches the heartbeat sentinel; one timer per account.

  **Requirements:** R1, R5

  **Dependencies:** U1, U2.

  **Files:**
  - Modify: `modules/nixos/services/mailarchive.nix`

  **Approach:**
  - Build mbsync rc text in Nix from each account's submodule values. Use `environment.etc."mailarchive/mbsync-${name}.rc" = {text = mkMbsyncrc ...; mode = "0400"; user = "mailarchive"; group = "mailarchive";}`.
  - mbsync rc structure (one-way Pull, archive-safe):
    - `IMAPAccount <name>`: `Host {imap.gmail.com|outlook.office365.com}`, `User <remoteUser>`, `AuthMechs XOAUTH2`, `PassCmd "${oauth2-helper}/bin/oauth2-helper refresh --provider=${provider}"`, `SSLType IMAPS`, `PipelineDepth 1`. (Note: mbsync runs `PassCmd` via `popen()`, so the value is shell-evaluated. Nix store paths cannot contain shell metacharacters by construction, and `${provider}` interpolates an enum value (`gmail` or `o365`) — both safe. If the provider enum is ever extended to a value containing spaces, escape or pass via env.)
    - `IMAPStore <name>-remote`: `Account <name>`.
    - `MaildirStore <name>-local`: `Path /mnt/data/Life/Andy/Email/<name>/`, `SubFolders Verbatim`. Do **not** set an explicit `Inbox` directive — Verbatim defaults handle it under `Path`.
    - `Channel <name>`: `Far :<name>-remote:`, `Near :<name>-local:`, `Patterns <provider-specific>`, `Sync Pull`, `Create Near`, `Remove None`, `Expunge None`, `SyncState *`. **`Sync Pull`** is the one-way semantics; `Create Near` only creates folders locally (never upstream); `Remove None` keeps local copies of server-deleted messages; `Expunge None` is the deletion-resistance.
    - O365 `Patterns`: `"INBOX*" "Sent Items*" "Archive" "Archives*" "Drafts" "Deleted Items*" "Junk Email"` (the trailing `*` makes the pattern recursive — INBOX has 200+ subfolders per the probe). The plain `"Archive"` is defensive (some Outlook configurations use singular `Archive`; the probe showed plural `Archives` on cullenwines.com.au — `Archive` matches harmlessly if absent). Excludes `Calendar`, `Contacts`, `Tasks`, `Notes`, `Sync Issues*`, `Conversation History`, `Outbox`, `RSS Feeds`, `Templates`. Verify against the live folder tree at first run; tighten or expand the pattern list as needed.
    - Gmail `Patterns`: `"[Gmail]/All Mail"` only.
  - Per-account systemd service `mailarchive-<name>.service`:
    - `Type = "oneshot"`, `User = "mailarchive"`, `Group = "mailarchive"`, `EnvironmentFile = config.sops.secrets."mailarchive/${name}".path`.
    - `serviceConfig.Environment = "SASL_PATH=${pkgs.cyrus-sasl-xoauth2}/lib/sasl2"` — required for libsasl2 to find the XOAUTH2 plugin at runtime. systemd's `path = [...]` only sets `$PATH` and is not enough.
    - `path = with pkgs; [ isync coreutils ]` (so `mbsync` and `touch` are on `$PATH`).
    - `ExecStart = "${pkgs.isync}/bin/mbsync -c /etc/mailarchive/mbsync-${name}.rc -a"`.
    - `ExecStartPost = "${pkgs.coreutils}/bin/touch /var/lib/mailarchive/${name}.heartbeat"`.
    - `after = ["network-online.target" "mnt-data.mount"]`, `requires = ["mnt-data.mount"]`, `wants = ["network-online.target"]`.
    - `Nice = 10`.
  - Per-account systemd timer `mailarchive-<name>.timer`:
    - `wantedBy = ["timers.target"]`, `OnBootSec = "2min"`, `OnUnitActiveSec = "${toString syncIntervalSec}s"`, `AccuracySec = "10s"`.

  **Patterns to follow:**
  - `modules/nixos/services/kopia.nix:239-311` — per-instance systemd services + timers with `lib.mapAttrs'`.
  - `modules/nixos/services/kopia.nix:96-103` (`mountDepsFor`) — NFS mount dependency wiring for `/mnt/data`.

  **Test scenarios:**
  - Happy path: with bootstrapped credentials and the module enabled, `systemctl start mailarchive-work.service` runs to completion with exit 0; messages appear under `/mnt/data/Life/Andy/Email/work/INBOX/cur/`; `/var/lib/mailarchive/work.heartbeat` mtime updates.
  - Happy path (SASL): `mbsync -V` (or first-run journal output) shows `XOAUTH2` listed in supported AuthMechs — confirms `SASL_PATH` is wired.
  - Edge case: `EnvironmentFile` missing the refresh token → service fails fast with the `oauth2-helper` error in journal; heartbeat not touched.
  - Edge case: `/mnt/data` is unmounted (NFS stale) → service fails to start because `requires = ["mnt-data.mount"]` won't satisfy.
  - Error path: Microsoft returns 401 on token refresh → `mbsync` exits non-zero (PassCmd fails); journal shows the AADSTS code; heartbeat not touched (`ExecStartPost` only runs on `ExecStart` success).
  - Integration (deletion-resistance): delete a message from O365 via OWA after it's been archived; on next mbsync run the Maildir copy stays (verifies `Sync Pull` + `Remove None` + `Expunge None`).
  - Integration (Gmail dedup): with `Patterns "[Gmail]/All Mail"`, total Maildir message count for gmail matches Gmail's All-Mail count; no per-label duplication.
  - Integration (no upstream pollution): create a new local Maildir folder under `work/` manually (`mkdir -p /mnt/data/Life/Andy/Email/work/Probe.NewFolder/{cur,new,tmp}`); on next mbsync run, that folder is **not** created on the live O365 server (verifies `Create Near` not `Create Both`).
  - Test expectation: the deletion-resistance integration is the load-bearing test before retiring VM 102.

  **Verification:**
  - `mailarchive-<name>.timer` is enabled and active; `systemctl status mailarchive-<name>.timer` shows it firing every `<syncIntervalSec>`s.
  - `/var/lib/mailarchive/<name>.heartbeat` mtime updates on each successful sync.
  - Maildir tree under `/mnt/data/Life/Andy/Email/<name>/` is populated and matches the IMAP folder selection.

---

- U4. **Heartbeat HTTP server + Uptime Kuma monitor wiring (server-side boolean)**

  **Goal:** A long-running systemd service that exposes `GET http://127.0.0.1:<port>/health/<account>` returning `{"healthy": true|false, "stale_seconds": <int>}`. Health is computed server-side: `healthy = stale_seconds < THRESHOLD` (default 600s). Wire one `homelab.monitoring.monitors` entry per account using `type = "json-query"` with `jsonPath = "$.healthy"`, `expectedValue = "true"`. Kuma's hardcoded `==` operator works correctly with this shape.

  **Requirements:** R6

  **Dependencies:** U1, U3.

  **Files:**
  - Modify: `modules/nixos/services/mailarchive.nix`

  **Approach:**
  - Define `mailarchive-health` as a second `pkgs.writers.writePython3Bin` script in the module's `let` block. Stdlib only (`http.server`, `json`, `os`, `time`, `urllib.parse`). It walks `/var/lib/mailarchive/*.heartbeat`, computes `stale_seconds = now - mtime`, and returns `{"healthy": stale_seconds < THRESHOLD, "stale_seconds": stale_seconds, "last_sync": iso8601}`. Reads `STALE_THRESHOLD_SEC` (default 600) and `HEARTBEAT_DIR` from env so it's portable.
  - Missing heartbeat file → returns `{"healthy": false, "stale_seconds": null, "last_sync": null}` and HTTP 200 (Kuma can still json-query it).
  - Unknown account in URL path → HTTP 404.
  - Systemd service `mailarchive-health.service`: `Type = "simple"`, `User = "mailarchive"`, listens on `127.0.0.1:${cfg.healthPort}` (default 9876). `Restart = "on-failure"`. Includes the same `requires = ["mnt-data.mount"]` dependency since heartbeat files live under `/var/lib/` (not `/mnt/data`), but the script that reads them is harmless if heartbeats don't exist.
  - For each account, register `homelab.monitoring.monitors`:
    ```
    {
      name = "Mailarchive: <name>";
      type = "json-query";
      url = "http://localhost:${toString cfg.healthPort}/health/<name>";
      jsonPath = "$.healthy";
      expectedValue = "true";   # works with monitoring_sync.nix:201's hardcoded ==
      interval = 60;
      maxretries = 10;
      retryInterval = 60;
      resendInterval = 240;
    }
    ```
    *(Honours the noise discipline defaults from `.claude/rules/nixos-service-modules.md`.)*
  - **Two complementary gates**, by design, not redundancy:
    - **Server-side `STALE_THRESHOLD_SEC = 600`**: flips `healthy: false` after 10 min of no successful sync. Suppresses heartbeat-clock-skew false positives; gives a meaningful answer to a manual `curl` check.
    - **Kuma-side `interval = 60s × maxretries = 10`**: another 10 min of confirmation before paging Gotify. Suppresses HTTP-server-blip false positives (e.g. brief restart of `mailarchive-health.service`).
    Total worst-case page latency: ~10-20 min after the underlying fetcher actually breaks. That's the right cadence for a backup-of-record. If `STALE_THRESHOLD_SEC` is changed, recompute Kuma's `maxretries` and `resendInterval` per the rule's "rebump" instructions.

  **Patterns to follow:**
  - `modules/nixos/services/kopia.nix:344-355` — json-query monitor entries (kopia uses an existing API; ours uses our own tiny server, but the registration shape is identical).
  - `modules/nixos/services/podcast.nix` — `pkgs.writers.writePython3Bin` precedent.

  **Test scenarios:**
  - Happy path: with `mailarchive-health` running and a fresh heartbeat, `curl http://127.0.0.1:9876/health/work` returns 200 + `{"healthy": true, "stale_seconds": <small>, "last_sync": "..."}`.
  - Edge case: heartbeat file missing (account configured but never run) → endpoint returns `{"healthy": false, "stale_seconds": null, "last_sync": null}` and Uptime Kuma marks down.
  - Edge case: heartbeat file mtime > 600s ago → endpoint returns `healthy: false`; Uptime Kuma's json-query check fails and (after 10 retries × 60s) Gotify pings.
  - Error path: malformed `<account>` in URL (not in configured accounts) → endpoint returns 404; Kuma marks down.
  - Integration: stop the `mailarchive-work.timer` for >10 min → Kuma turns red and Gotify pings; restart timer → Kuma turns green within one check cycle.
  - Integration (json-query operator): `homelab-monitoring-sync` runs successfully and the resulting Kuma monitor shows the expected `==` comparison against `"true"` (no silent fallthrough).

  **Verification:**
  - `systemctl status mailarchive-health.service` → active, serving on 127.0.0.1:9876.
  - `curl http://127.0.0.1:9876/health/work` returns the expected JSON shape.
  - The Mailarchive monitor appears in Uptime Kuma after the next `homelab-monitoring-sync` run and shows green when fresh heartbeats exist.
  - Stopping the work fetcher for >10 minutes triggers a Gotify notification.

---

- U5. **NFS watchdog wiring**

  **Goal:** Register one `homelab.nfsWatchdog` entry per account so the existing watchdog timer restarts the `mailarchive-<account>.service` if `/mnt/data` (NFS to tower) goes stale.

  **Requirements:** R5

  **Dependencies:** U1, U3.

  **Files:**
  - Modify: `modules/nixos/services/mailarchive.nix`

  **Approach:**
  - Inside the `config = lib.mkIf cfg.enable {...}` block, add:
    ```
    homelab.nfsWatchdog = lib.mapAttrs' (name: _: lib.nameValuePair "mailarchive-${name}" {
      path = "${cfg.dataDir}/${name}";
    }) cfg.accounts;
    ```
  - The watchdog's default 5-minute interval and stat-based liveness check are appropriate. It restarts the *service* (the next mbsync run picks up where it left off; mbsync's incremental sync semantics handle gaps gracefully).

  **Patterns to follow:**
  - `modules/nixos/services/kopia.nix:316-326` — exact same shape, only differs in path computation.
  - `modules/nixos/services/nfs-watchdog.nix:42-46` — confirms the watchdog restarts `<name>.service`.

  **Test scenarios:**
  - Happy path: with `/mnt/data` healthy, the watchdog timer fires every 5 min, stats the path successfully, and does nothing.
  - Integration: simulate a stale NFS handle (briefly stop `mnt-data.mount`); the watchdog's next stat fails with timeout, it restarts `mailarchive-work.service`; once the mount is back the next mbsync run completes.
  - Test expectation: `systemctl status mailarchive-work-nfs-watchdog.timer` shows it active; manual trigger (`systemctl start mailarchive-work-nfs-watchdog.service`) and verify journal output.

  **Verification:**
  - Per-account watchdog units exist (`mailarchive-<name>-nfs-watchdog.{service,timer}`) and the timer is in `timers.target`.

---

- U6. **OAuth bootstrap runbook + ops doc** *(absorbs the original U9 — token-rotation runbook — into this single wiki entry; per the plan template's U-ID stability rule, U9 is intentionally omitted as a gap, not renumbered)*

  **Goal:** A single wiki doc capturing the one-time bootstrap procedure for both work O365 and personal Gmail, plus deployment steps, the eventual-consistency callout, and operational recovery (token expiry / Microsoft client_id revocation — what was originally a separate U9). One place for "how do I work with mailarchive."

  **Requirements:** R7

  **Dependencies:** U2.

  **Files:**
  - Create: `docs/wiki/services/mailarchive.md`

  **Approach:**
  - The doc covers:
    1. **Personal Gmail one-time setup**: register an OAuth client in the user's own Google Cloud project (`https://console.cloud.google.com/apis/credentials`); choose "Desktop application" type; record `client_id` and `client_secret`. From any machine with a clone of this flake (workstation works best — needs a browser):
       ```
       nix run github:abl030/nixosconfig#oauth2-helper -- bootstrap \
         --provider=gmail --user=<email> \
         --client-id=<...> --client-secret=<...>
       ```
       Sign in via the printed URL; helper prints the sops env block to stdout; user runs `sops -e -i secrets/hosts/doc2/mailarchive-gmail.env` and pastes the block.
    2. **Work O365 one-time setup**: client_id is fixed (`9e5f94bc-…` Thunderbird's), no client_secret needed. Run:
       ```
       nix run github:abl030/nixosconfig#oauth2-helper -- bootstrap \
         --provider=o365 --user=andy@cullenwines.com.au
       ```
       Sign in at `https://login.microsoft.com/device` with the printed code. Helper prints sops env block; same `sops -e -i` flow. `OAUTH_TENANT` defaults to `common` — override only if Microsoft refuses to route the auth (rare; would surface as a clear AADSTS error).
    3. **Folder selection (O365)**: explicitly call out which folders are fetched — INBOX*, Sent Items*, Archive(s), Drafts, Deleted Items*, Junk Email — and which are excluded (Calendar, Contacts, Tasks, Notes, Sync Issues, Conversation History, Outbox, RSS Feeds, Templates). User confirms this matches their needs before deploy.
    4. **Folder selection (Gmail)**: only `[Gmail]/All Mail` is fetched. Document why (label-vs-folder duplication).
    5. **Deploy step**: `git push` + `ssh doc2 "sudo nixos-rebuild switch --flake github:abl030/nixosconfig#doc2 --refresh"` (per CLAUDE.md remote-deploy rule — not `--target-host`).
    6. **First-run quirk** (eventual-consistency): "**The very first `mailarchive-*.service` run after bootstrap may fail with `AUTHENTICATE failed` in the journal. This is *expected* — Microsoft's auth-issuer and Exchange Online's IMAP service have a few-minute consistency lag on first-auth. Do **not** re-run the bootstrap. Wait 5 minutes; the next timer fire will succeed.**" Bold the warning so a tired or anxious reader doesn't miss it.
    7. **Verify section**: `journalctl -u mailarchive-<name>.service -n 50` confirms `Sync completed`; `curl http://127.0.0.1:9876/health/<name>` shows `healthy: true`; Uptime Kuma shows green within ~2 min.
    8. **Token rotation / Microsoft client_id revocation recovery**: covers two operational events (incorporated from the original U9 plan):
       - **Refresh-token expiry** (AADSTS70008 or AADSTS70043 in journal): re-run the bootstrap procedure for the affected account; sops re-encrypt; redeploy. No code changes.
       - **Microsoft revokes Thunderbird's client_id** (precedent: 2024-08-01 retirement of `08162f7c-…`): find the new Thunderbird client_id from Mozilla's mozilla-central source; update the helper's `--client-id` default OR override per-account via `OAUTH_CLIENT_ID` in the sops env; re-bootstrap; deploy; add a dated note to this same wiki doc capturing the new id.

  **Patterns to follow:**
  - Existing wiki entries under `docs/wiki/services/` — terse, dated, with status indicators (`audiobookshelf.md`, `tdarr-node.md`, `lgtm-stack.md` are good models).

  **Test scenarios:**
  - Test expectation: none — this unit produces a documentation artifact. Quality is validated by U8's smoke test working from this doc.

  **Verification:**
  - Following the runbook from a clean state produces working refresh tokens for both accounts; no IT or admin involvement.

---

- U7. **MailStore Home → Maildir migration script (single legacy tree)**

  **Goal:** A one-shot migration utility that converts the existing 11 GB MailStore Home archive (mixed Gmail + O365 in one MailStore repository) into Maildir, lands it under `/mnt/data/Life/Andy/Email/legacy.archive/` using the same `SubFolders Verbatim` nested-directory layout the live trees use. No per-account split.

  **Requirements:** R3, R4

  **Dependencies:** None for U7a/U7b (independent of U1-U5). U7c (optional dedup) is independent of U8.

  **Files:**
  - Create: `tools/mailarchive-migrate/eml-to-maildir.py`
  - Create: `tools/mailarchive-migrate/README.md` (usage notes, including documented MailStore export path)

  **Approach (three sub-steps):**
  - **U7a — MailStore Home EML export.** On the Win VM, run MailStore Home → `Export Email` → `File system, EML format` → check `Retain folder structure` → target a path reachable from doc2 (the canonical choice: `/mnt/data/Life/Andy/Email/_mailstore-export-staging/` on a temp NFS write; document the chosen path in `tools/mailarchive-migrate/README.md`). ~11 GB output; one `.eml` file per message; folder hierarchy preserved as MailStore had it.
  - **U7b — EML tree → Maildir conversion.** Python script (`eml-to-maildir.py`, ~60 lines using stdlib `mailbox`, `email.parser`, `os`, `pathlib`, `hashlib`, `time`):
    - Walk the EML export tree.
    - For each `.eml`: parse with `email.parser.BytesParser`; extract `Message-ID` (fallback: SHA-256 of first 4096 bytes as synthetic ID).
    - Reconstruct folder hierarchy as **nested Maildir directories** matching `SubFolders Verbatim` — for an export folder `Cullen Work/INBOX/Sent Items/`, write to `legacy.archive/Cullen Work/INBOX/Sent Items/{cur,new,tmp}/`. Each level is a real subdirectory containing its own `cur/`, `new/`, `tmp/`. **Do not** flatten using Maildir++ dot-separated names (`legacy.archive/.Cullen Work.INBOX.Sent Items/`) — that would diverge from the live trees and break any future merge.
    - Write each message to the leaf folder's `cur/` with filename pattern `<unix-timestamp>.<random>.maildir-migrate:2,S` (suffix `:2,S` marks as already-seen; mbsync won't re-flag them if they ever get merged).
    - Track `Message-ID` set in memory; on collision within the same export, skip and log.
    - Output Maildir tree at `/mnt/data/Life/Andy/Email/legacy.archive/`.
    - Print stats: `<N> messages written, <M> duplicates skipped, <K> folders created`.
  - **U7c — Optional dedup against live trees.** Independent of cutover. If after the live `o365/` and `gmail/` trees have populated, the user wants to merge legacy into live and drop overlap (messages MailStore captured that O365 still has on the server, also fetched by the live mbsync), run a small inline Python script (~30 lines, stdlib only): walk both trees, build a `Message-ID → filepath` map keyed off `email.parser.BytesParser`, on collision delete the older file. `maildir-deduplicate` / `mail-deduplicate` are **not** packaged in nixpkgs (verified) — the inline script is the canonical path. The dedup is genuinely optional; keeping `legacy.archive/` separate forever is also fine and arguably safer (no risk of merge corruption). **Default recommendation: leave separate.** Only run dedup if the user explicitly wants a single unified tree.

  **Patterns to follow:**
  - `tools/` directory convention — the closest existing one-shot script in the repo, mirror its README/CLI shape.
  - `modules/nixos/services/podcast.nix` — `pkgs.writers.writePython3Bin` precedent if we package the script as a flake app instead of a loose `.py`.

  **Test scenarios:**
  - Happy path (U7b): given a small known-good EML tree (handful of messages with attachments, nested folders), the script produces a valid nested Maildir; opening the leaf folder in Thunderbird (point it at a local-folder path) shows messages with intact attachments.
  - Happy path (U7b): the produced layout matches `SubFolders Verbatim` — `find legacy.archive -type d -name cur | head` shows nested paths like `legacy.archive/Cullen Work/INBOX/cur`, not `legacy.archive/.Cullen Work.INBOX/cur`.
  - Edge case (U7b): EML files missing `Message-ID` header → fallback synthetic ID is generated and applied consistently for that file (so a re-run produces the same ID).
  - Edge case (U7b): folder names with spaces or special characters → preserved verbatim in the directory names (consistent with mbsync's Verbatim mode).
  - Error path (U7b): one corrupt EML in the tree → script logs the file and continues, doesn't abort the whole migration.
  - Edge case (U7c): if run, `maildir-deduplicate` correctly removes duplicates by Message-ID across `legacy.archive/` and live trees, keeping the live-fetched copy.
  - Test expectation: dry-run on a 100-message subset of the real archive before running on the full 11 GB.

  **Verification:**
  - After U7b: `find /mnt/data/Life/Andy/Email/legacy.archive -name 'cur' -type d | wc -l` matches the original folder count; total message count matches the script's output stats.
  - After U7b: opening the Maildir in any standard client (Thunderbird, mu, mutt) shows the historical archive intact.

---

- U8. **Host enablement on doc2 + smoke test + VM 102 retirement**

  **Goal:** Enable the module on doc2, complete the bootstrap, smoke-test against real messages, stop VM 102, and destroy it after a short safety window.

  **Requirements:** R8

  **Dependencies:** U1-U6 deployed; U7a + U7b complete (the historical archive can be migrated before, during, or after — independent).

  **Files:**
  - Modify: `hosts/doc2/configuration.nix` (add `homelab.services.mailarchive` block)
  - Create: `secrets/hosts/doc2/mailarchive-work.env` (sops-encrypted, populated via U6)
  - Create: `secrets/hosts/doc2/mailarchive-gmail.env` (sops-encrypted, populated via U6)

  **Approach:**
  - **Step 1 — enable on doc2.** Add to `hosts/doc2/configuration.nix`:
    ```
    homelab.services.mailarchive = {
      enable = true;
      dataDir = "/mnt/data/Life/Andy/Email";
      accounts = {
        work = { provider = "o365"; remoteUser = "andy@cullenwines.com.au"; credentialSecret = "mailarchive/work"; syncIntervalSec = 60; };
        gmail = { provider = "gmail"; remoteUser = "<personal-gmail>"; credentialSecret = "mailarchive/gmail"; syncIntervalSec = 120; };
      };
    };
    ```
  - **Step 2 — bootstrap secrets** per the U6 wiki doc. Push to GitHub.
  - **Step 3 — deploy.** `git push` then `ssh doc2 "sudo nixos-rebuild switch --flake github:abl030/nixosconfig#doc2 --refresh"`. Per CLAUDE.md, never use `--target-host`.
  - **Step 4 — smoke test (live).** Per U6's eventual-consistency note, the very first sync may fail; wait 5 min before judging. Then:
    - Send a test email from another account to the work address; within 60s, confirm it lands in `/mnt/data/Life/Andy/Email/work/INBOX/cur/` (or under whichever folder Outlook's rules drop it into).
    - Send a test email to the personal Gmail; within 120s, confirm it appears in `/mnt/data/Life/Andy/Email/gmail/[Gmail]/All Mail/cur/`.
    - Delete one of the test messages from the live server (OWA / Gmail web). Manually trigger another sync (`systemctl start mailarchive-work.service`). Confirm: (a) the service exits 0; (b) the Maildir copy is untouched; (c) `journalctl -u mailarchive-work.service -n 50` shows no `UID gap`, `message lost`, or similar warnings. Repeat the sync 3-4 times to ensure mbsync's incremental state file (`SyncState`) tolerates the gap. This exercises the rc's one-way semantics AND mbsync's state-tracking — under a misconfigured `Sync All` + `Remove Both` rc the local copy would disappear (test failure); under correct `Sync Pull` + `Remove None` it stays.
    - Both Uptime Kuma monitors are green; `journalctl -u mailarchive-work.service -n 20` shows successful `Sync completed`.
  - **Step 5 — stop VM 102.** Once smoke test passes: `vms/proxmox-ops.sh stop 102` (per CLAUDE.md: never run Proxmox commands directly).
  - **Step 6 — safety window.** Wait ~3-5 days with VM 102 stopped. The disks remain on `nvmeprom`; if any issue surfaces in the new fetcher, restart 102 and investigate. No further action needed during this window — just observe Kuma stays green and journal is quiet.
  - **Step 7 — destroy VM 102.** `vms/proxmox-ops.sh destroy 102`. Verify with `vms/proxmox-ops.sh list` that 102 is gone.
  - **Step 8 — clean up.** Remove `_mailstore-export-staging/` if it was on shared storage. VM 102 was never inventoried in `hosts.nix`, `vms/tofu/vm-resources.nix`, or any other fleet-config file (Proxmox-side-only VM created by hand) — no fleet config changes needed. Optionally file an issue to update the stale `vms/definitions.nix` reference in CLAUDE.md.

  **Patterns to follow:**
  - `vms/proxmox-ops.sh` — ALL Proxmox commands go through it (CLAUDE.md rule). Verify the wrapper supports `stop` and `destroy` verbs at implementation time; if not, extend it rather than reaching past it.
  - `hosts/doc2/configuration.nix` — match existing `homelab.services.*` block style.

  **Test scenarios:**
  - Happy path (smoke): test email lands in Maildir within one sync cycle; both Kuma monitors are green.
  - Happy path (deletion-resistance): test email deleted from live server stays in Maildir.
  - Error path (deploy): `nixos-rebuild switch` fails due to module bug → revert the host config change and re-deploy; the module's `enable = false` path keeps the system clean.
  - Integration: full chain — Microsoft sends new email → mbsync timer fires within 60s → message lands in `o365/INBOX/cur/` → heartbeat sentinel touched → Uptime Kuma shows green → Kopia's next snapshot picks up the new message.
  - Error path (destroy): `vms/proxmox-ops.sh destroy 102` fails or doesn't support destroy → stop here and check the wrapper script; do not reach for `qm destroy` directly.
  - Test expectation: smoke test is the validation. No "2-week parallel run" — once smoke test passes and the safety window elapses, retirement proceeds.

  **Verification:**
  - Both Uptime Kuma monitors green.
  - Test messages flowed end-to-end and survived a deletion test.
  - `vms/proxmox-ops.sh list` no longer shows VM 102.

---

## System-Wide Impact

- **Interaction graph:** mbsync → `oauth2-helper` (PassCmd) → Microsoft/Google token endpoints → Microsoft/Google IMAP servers → Maildir on `/mnt/data` (NFSv4.2 from tower / Unraid). Heartbeat sentinel → `mailarchive-health` HTTP server → Uptime Kuma's existing `homelab-monitoring-sync` flow. NFS watchdog timer → systemd → `mailarchive-<name>.service`. No direct interactions with other services on doc2.
- **Error propagation:** mbsync exit non-zero → systemd marks service failed → heartbeat NOT touched (`ExecStartPost` only runs on success) → Uptime Kuma sees `healthy: false` after ≥600s → after `maxretries × retryInterval` confirmation window → Gotify pings. NFS staleness → watchdog catches via stat timeout → restarts service.
- **State lifecycle risks:** `Sync Pull` + `Remove None` + `Expunge None` keep deleted-on-server messages in Maildir — that's the intended deletion-resistance, not a leak. If the user wants to ever expire archive messages, that's a separate manual step. mbsync writes to `tmp/` and renames to `new/`/`cur/` atomically, no partial-write risk.
- **API surface parity:** `homelab.services.mailarchive` adds new options namespace; existing services unaffected. `homelab.monitoring.monitors` gets two new entries; `homelab.nfsWatchdog` gets two new entries.
- **Integration coverage:** the smoke test in U8 is the integration test. Verifies the full chain end-to-end with real messages, real IMAP, real refresh tokens, real NFS, real Kuma, real Gotify, plus a deliberate deletion-resistance probe.
- **Hidden constraint — Kuma host co-location.** The monitor URL `http://localhost:${healthPort}/health/<account>` only works because Uptime Kuma and `mailarchive-health` are both on doc2. If Kuma ever moves hosts (precedent: services have moved between doc1/doc2 historically), this monitor will silently break — Kuma will probe `localhost:9876` from its new host and find nothing. The same fleet-wide constraint already applies to kopia's json-query monitors at `http://localhost:51515/...`; it's a known posture, not a new bug. Document and accept; revisit only if Kuma ever moves.
- **Unchanged invariants:** Kopia's snapshot job for `/mnt/data` already picks up everything under it; no change to `kopia.nix`. Existing `homelab.localProxy`/`homelab.tailscaleShare` not used here (the module exposes only a localhost-bound health endpoint). VM 102 stays runnable until U8 step 7.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Microsoft revokes Thunderbird's client_id mid-deployment, breaking ingest. | U6 runbook makes recovery a documented ~30-min operation. Uptime Kuma + Gotify catches it within 10-12 min of failure. |
| Refresh token expires unexpectedly (e.g., admin-side conditional access policy change). | U6 runbook covers re-bootstrap; one operation. |
| `Sync Pull` config error allowing accidental two-way sync, polluting the live mailbox. | Test in U3 deliberately verifies (a) deleted-from-server messages stay in Maildir and (b) local-only folders are NOT created upstream. Both must pass before the smoke test in U8. |
| `cyrus-sasl-xoauth2` SASL plugin not loaded by mbsync because of `SASL_PATH` not being set. | U3 sets `Environment = "SASL_PATH=..."` explicitly. Verify at first run that `mbsync -V` lists XOAUTH2 in supported AuthMechs. The probe v2 script bypassed mbsync (raw IMAP), so this is the first time we exercise the SASL path. |
| MailStore EML export loses headers or attachments. | Spot-check 5 messages across categories (plain text, HTML, with-attachment, multi-recipient, calendar invite) before running U7b on the full 11 GB. |
| 11 GB Maildir stresses Kopia's first-snapshot performance. | Acceptable — Kopia handles much larger trees, and EMLs are highly dedup-friendly (RFC822 has lots of common header structure). Run U7b at a quiet hour if concerned; subsequent snapshots are incremental. |
| `/mnt/data` NFS goes stale and causes message loss between watchdog cycles. | 5-min watchdog interval + 60s mbsync timer + mbsync's incremental sync semantics: gaps are recoverable; no data loss because we never delete locally. |
| Microsoft eventual-consistency quirk causes day-1 false alarms. | U6 runbook calls this out explicitly with a bolded warning; user is told to wait 5 min after first bootstrap. |
| Gmail folder selection wrong (e.g. Patterns matches more than All Mail). | U3's folder-selection test verifies total Maildir message count against Gmail's All-Mail count; mismatch = pattern wrong. |
| Uptime Kuma migrates to a different host post-deployment. | Localhost monitor URL constraint documented in System-Wide Impact. If Kuma moves, swap monitor URLs to `http://doc2.lan:9876/...` (or use localProxy) at that time. Same posture as kopia. |

---

## Documentation / Operational Notes

- New wiki entry: `docs/wiki/services/mailarchive.md` (U6) — bootstrap, deploy, troubleshoot, token rotation. Reference it from the module's header comment.
- After deployment, the wiki entry captures: deployment date, the working Thunderbird client_id at deployment time, the cullenwines.com.au tenant ID, the GCP project ID for personal Gmail (link). This is the institutional record per CLAUDE.md's wiki rules.
- After VM 102 retirement (U8 step 7), VM 102 was never in fleet-config inventory — no `hosts.nix`, `vms/tofu/`, or `vms/definitions.nix` updates needed (the latter doesn't exist; CLAUDE.md's "Important Files" list is stale on this point and could be cleaned up in a separate pass).
- No external docs (Cloudflare, ingress, etc.) need updating — the service exposes nothing public.

---

## Sources & References

- **Origin document:** [docs/brainstorms/2026-05-04-mailstore-vm-replacement-requirements.md](../brainstorms/2026-05-04-mailstore-vm-replacement-requirements.md)
- **Companion research:** [docs/brainstorms/2026-05-04-mailstore-vm-replacement-research.md](../brainstorms/2026-05-04-mailstore-vm-replacement-research.md) (per-tool comparison; architecture-2 recommendation now superseded by probe)
- **Probe result:** [docs/brainstorms/2026-05-04-mailstore-vm-probe-result.md](../brainstorms/2026-05-04-mailstore-vm-probe-result.md) — end-to-end verification of Architecture 1 against the live work tenant
- **Plan review (round 1):** [docs/plans/2026-05-04-001-feat-mailarchive-mailstore-retirement-plan-REVIEW.md](2026-05-04-001-feat-mailarchive-mailstore-retirement-plan-REVIEW.md) — independent review that surfaced 3 critical bugs and 9 should-fixes integrated into this revision
- **Plan review (round 2):** [docs/plans/2026-05-04-001-feat-mailarchive-mailstore-retirement-plan-REVIEW-2.md](2026-05-04-001-feat-mailarchive-mailstore-retirement-plan-REVIEW-2.md) — verification pass on the rewrite; surfaced N-C1 (`maildir-deduplicate` not in nixpkgs) and 5 should-fixes, all integrated
- **Pattern reference:** `modules/nixos/services/kopia.nix` (closest module shape match)
- **Service module rules:** `.claude/rules/nixos-service-modules.md`
- **NFS watchdog:** `modules/nixos/services/nfs-watchdog.nix`
- **NFS mount:** `modules/nixos/services/mounts/nfs-local.nix` (confirms `/mnt/data` is NFSv4.2 to tower, not virtiofs)
- **Monitoring sync:** `modules/nixos/services/monitoring_sync.nix:201` (json-query operator hardcoded `==` — drives the server-side boolean shape in U4)
- **Sops path resolution:** `modules/nixos/common/secrets.nix:35` (confirms `secrets/hosts/<hostname>/` search path)
- **Python helper precedent:** `modules/nixos/services/podcast.nix` (`pkgs.writers.writePython3Bin` shape)
- **VM ops:** `vms/proxmox-ops.sh` (CLAUDE.md mandates all Proxmox operations through this wrapper)
- **External:** [Mozilla Thunderbird OAuth KB](https://support.mozilla.org/en-US/kb/microsoft-oauth-authentication-and-thunderbird-202)
- **External:** [moriyoshi/cyrus-sasl-xoauth2 README](https://github.com/moriyoshi/cyrus-sasl-xoauth2) — `SASL_PATH` env var requirement
- **External:** [DavMail RELEASE-NOTES.md](https://github.com/mguessan/davmail/blob/master/RELEASE-NOTES.md) (for tracking auth-tightening events that may also affect us)
