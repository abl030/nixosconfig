# Mailstore VM Replacement — Deep Research

**Date:** 2026-05-04
**Status:** Research complete; recommended path is DavMail + mbsync.
**Owner:** abl030
**Companion to:** `2026-05-04-mailstore-vm-replacement-requirements.md`

---

## 1. Executive Recommendation

**Build Architecture 2: DavMail (as a NixOS service) + mbsync (isync) for Maildir landing + a separate mbsync configuration with the user's own GCP OAuth client for Gmail.** Both feed into `/mnt/data/Life/Andy/Email/<account>/` as Maildir.

Three trade-offs drove the ranking:

1. **DavMail decouples the Microsoft-auth problem from the fetcher.** Microsoft has tightened OAuth twice in 2026 alone (the redirect-URI flip in 6.6.0 / April, then re-flip in 6.7.0 / May — see DavMail RELEASE-NOTES). DavMail is *currently being patched in lock-step* with those changes; mbsync + a borrowed Thunderbird `client_id` + a hand-rolled `oauth2ms`-style helper would push that maintenance burden onto us. DavMail releases through April–May 2026 explicitly call out tracking Microsoft's behaviour, plus a brand-new Graph backend that will replace EWS before Microsoft's 2027 EWS shutdown ([Help Net Security 2026-04-14](https://www.helpnetsecurity.com/2026/04/14/davmail-6-6-0-released/), [SourceForge 6.7.0 news](https://sourceforge.net/p/davmail/news/2026/05/davmail-670-released/)).
2. **DavMail has a first-class NixOS module already.** `services.davmail.{enable,url,config}` exists in nixpkgs (verified `unstable`, package version 6.5.1). Wiring the device-code one-shot bootstrap and persisting the encrypted refresh token through sops is straightforward. Architecture 1's path requires shipping `cyrus-sasl-xoauth2` + a custom token-refresher script per account and praying the borrowed Thunderbird `client_id` keeps working. Architecture 3 (headless TB in a container) reproduces the Windows-VM problem nearly verbatim.
3. **mbsync is the strongest IMAP fetcher in 2026 — but for plain-IMAP, not OAuth on its own.** `getmail6` has unresolved IDLE+OAuth refresh bugs (issues #60 / #62, both still showing the failure mode where `IMAP IDLE` reconnects with a stale token). `OfflineIMAP3` had an O365 XOAUTH2 regression in Feb 2024 (issue #187) that mbsync did not. With a localhost DavMail bridge, mbsync only sees a plain IMAP server, so the brittle XOAUTH2 path inside the fetcher disappears entirely. For the Gmail account (where the user has their own OAuth client and Gmail's XOAUTH2 has been stable for years) mbsync + `cyrus-sasl-xoauth2` is the better path than running it through DavMail.

**Why not Architecture 1 (mbsync + borrowed client_id direct to O365):** the Thunderbird client_id approach genuinely works *today* against the `common` tenant endpoint, but: (a) the August 2024 incident where Microsoft disabled the older `08162f7c-…` Thunderbird client_id ([email-oauth2-proxy issue #267](https://github.com/simonrob/email-oauth2-proxy/issues/267)) is the canonical failure mode and could happen to `9e5f94bc-…` at any time; (b) when Microsoft tightens the redirect-URI rules (as they did April 2026 ahead of May 2026 reverting), every mbsync user has to write a patch; DavMail users got a release. The whole point of paying for the extra component is shifting that maintenance to someone else.

**Why not Architecture 3 (headless Thunderbird):** TB can run headless, but the export-to-Maildir path either requires the now-deprecated ImportExportTools NG add-on running on a TB instance with a real profile dir, or `birdtrayexport`-style poking at TB's mbox files — neither is cleaner than just landing mail in Maildir directly. You also keep the GUI-OAuth-flow problem.

---

## 2. Per-Architecture Findings

### Architecture 1 — Direct IMAP fetcher with borrowed Thunderbird client_id

**Solves no-app-registration in 2026?** Yes, conditionally. The current Thunderbird `client_id = 9e5f94bc-e8a4-4e73-b8be-63364c29d753` works against the `common` tenant endpoint with scopes `IMAP.AccessAsUser.All`, `offline_access`, `SMTP.Send` — confirmed by [Mozilla's own KB](https://support.mozilla.org/en-US/kb/microsoft-oauth-authentication-and-thunderbird-202) and [benswift.me 2025-09-12](https://benswift.me/blog/2025/09/12/the-great-2025-email-yak-shave-o365-mbsync-mu-neomutt-msmtp/) (a working 2025 guide using exactly this client_id with mbsync). For organisationally-managed tenants the Mozilla KB recommends admins visit `login.microsoftonline.com/{tenant}/adminconsent?client_id=…`, but for a tenant where the user only has their own mailbox and IMAP is enabled at the protocol level (the user's stated situation), individual user consent on the `common` endpoint is generally enough.

**Operational fragility:** moderate-to-high. Specific failure modes:

- **Client_id revocation.** Microsoft disabled the older Thunderbird client_id `08162f7c-0fd2-4200-a84a-f25a4db0b584` on **2024-08-01** ([email-oauth2-proxy issue #267](https://github.com/simonrob/email-oauth2-proxy/issues/267)). Mozilla rotated to `9e5f94bc-…`. There is no public commitment from Microsoft that this won't recur.
- **Redirect-URI regime changes.** Microsoft changed allowed redirect URIs for native clients in March-April 2026; both DavMail and the email-oauth2-proxy needed releases. mbsync + a hand-rolled `oauth2ms` would also have needed editing.
- **IDLE + token refresh.** `getmail6` has a documented bug (issues [#60](https://github.com/getmail6/getmail6/issues/60), [#62](https://github.com/getmail6/getmail6/issues/62)) where the IDLE reconnect loop reuses an expired access token and fails. Issue #62 has a linked PR (#63); current status as of May 2026 is unclear from the public record. mbsync doesn't natively IDLE — it polls or runs under `goimapnotify` — so mbsync sidesteps that specific bug, but we'd then need `goimapnotify` *also* to use OAuth, doubling the refresh-token plumbing.

**NixOS friendliness:** medium. `isync` (1.5.1), `cyrus-sasl-xoauth2` (0.2), and `getmail6` (6.19.12) are all packaged in nixpkgs unstable. There is no NixOS module for either; you write a systemd service and timer yourself. `oauth2ms` / `mutt_oauth2.py` are not packaged — you'd ship them via `pkgs.writeScriptBin` or similar. Manageable but bespoke.

**2026 health signal:**
- isync 1.5.1 in nixpkgs; isync project itself is sleepy but stable — no concerning silence.
- `cyrus-sasl-xoauth2`: low-activity but functioning.
- getmail6 v6.19.10–6.19.12 released through 2025; latest 2026-08 per release feed. Active.
- `oauth2ms` (harishkrupo/oauth2ms): largely unmaintained as a project; people copy-paste it.
- Community signal in 2025 (Stanford, UWashington, ETHZ, multiple personal blogs) treats this stack as "works, but expect to tinker each year."

**Verdict:** viable, lots of in-the-wild evidence, but you absorb every Microsoft auth-policy shift personally.

### Architecture 2 — DavMail as O365 → IMAP bridge (RECOMMENDED)

**Solves no-app-registration in 2026?** Yes. DavMail uses `O365Modern` / `O365Manual` / `O365DeviceCode` modes, all of which authenticate the *user* via Microsoft's standard interactive or device-code flow. It uses a published Microsoft client_id internally and persists an encrypted refresh token (`davmail.oauth.persistToken=true`) in its properties file after first login. No app registration in the work tenant.

**Operational fragility:** low-to-medium. The key signal is: when Microsoft moved the redirect-URI goalposts in early 2026, DavMail shipped 6.6.0 in April fixing it, and the maintainer reverted in 6.7.0 in May after Microsoft re-flipped (live.com vs localhost). That responsiveness is exactly what we're paying for. Resource cost is one Java JVM (~150–250 MB RSS, idle); modest on doc2 (which has plenty of headroom).

Weak points:
- **Initial bootstrap requires interactive code-paste.** This is one-off per refresh-token rotation. Workflow: temporarily set `davmail.mode=O365Manual` (or `O365DeviceCode`), run `davmail` interactively, paste the device code into the browser, wait for refresh token to be appended to the properties file, capture that token, re-encrypt with sops, restore service mode. Documented in [SourceForge headless-mode thread](https://sourceforge.net/p/davmail/discussion/644056/thread/c89c682851/).
- **Refresh tokens can in principle be revoked** by tenant admins or by long inactivity; in practice the Microsoft Graph offline_access lifetime is 90 days of inactivity / unlimited if used. We meet that easily with continuous polling. If the refresh token does get revoked, recovery is "re-bootstrap" — same as Arch 1.
- **DavMail's Graph backend isn't yet production-ready** (per 6.7.0 release notes) but the EWS path remains the production default. Microsoft's EWS shutdown begins **2026-10-01** (tenant-by-tenant) with full retirement **2027-04-01** ([Mozilla's Thunderbird Exchange announcement, 2025-11](https://blog.thunderbird.net/2025/11/thunderbird-adds-native-microsoft-exchange-email-support/)). DavMail's roadmap pivots to Graph before then; we should plan to bump DavMail packages aggressively through late 2026.

**NixOS friendliness:** high. `services.davmail.enable` exists; `services.davmail.url` and `services.davmail.config` (free-form attribute set written into the davmail properties file) are the two main knobs. We write the IMAP and refresh-token state into `services.davmail.config`. Sample option list confirmed via mcp-nixos: only three options (`enable`, `url`, `config`) — small surface area, easy to wrap.

**2026 health signal:** strongly positive.
- DavMail 6.7.0 — **2026-05-02** (released two days ago)
- DavMail 6.6.0 — 2026-04-12
- DavMail 6.5.1 — 2025-10-29
- DavMail 6.5.0 — 2025-10-23 (FIDO2, Windows Hello, SWT WebView2)
- DavMail 6.4.0 — 2025-08-31 (introduced experimental Graph backend)
- DavMail 6.3.0 — 2025-02-26 (JRE 21, TLS 1.3 channel binding)

That's **6 releases in 14 months**, with each one explicitly tracking Microsoft auth changes. Maintainer Mickaël Guessant continues to ship.

The nixpkgs package lags slightly (unstable shows 6.5.1 — the late 2025 version) but the maintainer can override with a flake input or we can land a nixpkgs bump ourselves; cycle is normal for a Java desktop app.

### Architecture 3 — Linux Thunderbird in a container

**Solves no-app-registration in 2026?** Yes — TB uses the same `9e5f94bc-…` client_id as mbsync would, just inside a GUI. Same revocation risk.

**Operational fragility:** high. You're running an interactive MUA without a human in front of it. OAuth re-prompts (which TB occasionally throws when access tokens fail mid-session) require a `xpra`/VNC session; refresh-token rotation requires the TB profile to be writable; and the Maildir export is a separate moving part:

- Native TB stores in mbox by default, not Maildir. A profile preference (`mail.serverDefaultStoreContractID = "@mozilla.org/msgstore/maildirstore;1"`) switches this; not all add-ons cope.
- ImportExportTools NG is the de-facto export add-on and its 2025 status is "still works, occasionally lags" — another moving part.

The *only* reason to choose this path is if both Arch 1 and Arch 2 fail simultaneously, which would require Microsoft to make the borrowed-client_id approach unworkable AND DavMail's bridge to die. In that scenario, TB-in-a-container is also dead because TB uses the same approach.

**NixOS friendliness:** low. You'd ship TB via `oci-containers` (rootful podman per the project's `homelab.podman` pattern), persistent volume for the profile, and an exporter sidecar (offlineimap pulling from TB? hardly cleaner than fetching directly). This is the worst NixOS story of the three.

**2026 health signal:** TB itself is healthy (v145 added native Exchange/EWS in November 2025) but the *headless container TB* community is small. Few people do this on purpose.

**Verdict:** rejected unless 1 and 2 both fail.

---

## 3. Specific Tool Comparison (within Architecture 1, also relevant for Gmail under Arch 2)

| Tool | XOAUTH2 in 2026 | IDLE | nixpkgs | Refresh-token UX |
| --- | --- | --- | --- | --- |
| **mbsync (isync)** 1.5.1 | Works via `cyrus-sasl-xoauth2` SASL plug-in + `PassCmd` returning a fresh access token. Stable when wired correctly. AuthMechs XOAUTH2; Method tail | **No native IDLE.** Use `goimapnotify` to invoke mbsync on push, or systemd timer for poll. With O365's TLS overhead, 60s timer is fine. | Yes, `pkgs.isync` 1.5.1; `pkgs.cyrus-sasl-xoauth2` 0.2 | Helper script (oauth2ms / mutt_oauth2.py) refreshes each invocation; mbsync never sees a long-lived token. Robust. |
| **getmail6** 6.19.12 | Has `use_xoauth2` option, documented for Gmail, used in the wild for O365. | **Native IDLE retriever exists**, but issues [#60](https://github.com/getmail6/getmail6/issues/60) and [#62](https://github.com/getmail6/getmail6/issues/62) document a token-refresh failure when the server invalidates the IDLE session at token expiry. | Yes, `pkgs.getmail6` 6.19.12 | Cached in-memory, *not refreshed on reconnect* — that's the bug. Workarounds exist; not pretty. |
| **OfflineIMAP3** | XOAUTH2 supported; users hit a Feb 2024 regression with O365 ([issue #187](https://github.com/OfflineIMAP/offlineimap3/issues/187)). | No native IDLE. | Yes (`pkgs.offlineimap`) | Helper-script pattern same as mbsync. Heavier, slower than mbsync. |
| **Davmail-bridged plain IMAP** (Arch 2) | N/A — bridge speaks plain IMAP. | mbsync poll against localhost is essentially free; no IDLE needed at all because the polling cost is negligible. | mbsync packaged. | Refresh-token lives in DavMail's encrypted properties file. mbsync never touches OAuth. |

**Recommendation within the comparison:** **mbsync everywhere.** For Gmail (own OAuth client, stable), use `mbsync + cyrus-sasl-xoauth2 + PassCmd-of-a-token-refresher`. For O365 via DavMail, use `mbsync + plain login` against localhost. One fetcher, two configs, one set of operational habits.

---

## 4. MailStore Migration

**What MailStore Home exports:**

- Format: **EML** files (one per message), or MSG (Outlook). EML is RFC822 — exactly the byte stream we want in Maildir. Headers, body, attachments, dates all preserved (it's just the raw message envelope).
- Folder hierarchy: preserved if the **"Retain folder structure"** checkbox is enabled — confirmed in MailStore's docs ([Exporting Email — MailStore Home Help](https://help.mailstore.com/en/home/Exporting_Email)).
- Maildir export: **not directly supported.** EML-tree is the closest format and is trivially convertible.
- Other relevant export targets that MailStore Home can do but we don't want: Outlook profile, IMAP server, MBOX. EML-to-directory is the only one that gives us per-message files cleanly.

**Third-party tools that read MailStore's `.dat`/`.rr` directly:** none worth using. The format is proprietary; the only practical reader is MailStore Home itself. Don't go down that path — use the export.

**Migration plan sketch:**

1. **One-time:** install MailStore Home on the existing Windows VM (it's already there). Use `Export Email → File system, EML format → Retain folder structure` to dump the full archive to e.g. `\\doc2\share\mailstore-export\`. ~11 GB of EML files, no compression.
2. **EML → Maildir conversion:** a ~30-line Python script using `mailbox.Maildir` and `email.parser`. For each `.eml`:
   - Parse, extract `Message-ID` header (fallback: hash of first 4KB of message bytes as synthetic ID).
   - Dedup by Message-ID against a set you build as you go.
   - Reconstruct folder hierarchy as Maildir subfolders (`Maildir/.Folder.Subfolder/`).
   - Write to `cur/` with a generated filename and `:2,S` suffix so mbsync treats them as already-seen.
3. **Merge with live archive:** because mbsync is already populating `/mnt/data/Life/Andy/Email/<account>/` with new mail, just import the historical Maildir into the same tree but in a separate folder hierarchy *first* (e.g. `Archive.Historical.<original-folder>`). Then optionally run `maildir-deduplicate` ([PyPI](https://pypi.org/project/maildir-deduplicate/)) to drop any messages that live in both. Defer until you're certain the live mbsync run is stable; it's safer to have duplicates than gaps.
4. **Retire MailStore:** once the Maildir tree is verified (count messages by year, spot-check a few attachments), `pveum vm destroy 102`. Wipe the EML export staging directory.

**Fidelity caveat:** EML preserves the *message*, but MailStore-internal labels/tags/categories (if you used them — most home users don't) are not in the EML envelope. They were probably never written back to the source server either, so this is a non-issue for our use case.

---

## 5. Conditional Access Risk — Pre-Implementation Test

**The risk:** even if Microsoft accepts the OAuth flow with Thunderbird's client_id, a tenant-level Conditional Access policy can still block the resulting IMAP session. Common policies that hit headless OAuth IMAP:

- "Require multi-factor authentication" — usually OK for OAuth (MFA happens at consent), unless paired with "every N days" re-MFA on the resource.
- "Require device to be marked as compliant" — fatal. Doc2 will not be Intune-managed.
- "Block legacy authentication / 'Other clients'" — should be OK if our session uses XOAUTH2 (which it does), but some tenant configs misclassify XOAUTH2-IMAP as legacy.
- "Authentication flows" condition (recent CA feature) — explicitly can block device-code flow ([Microsoft docs: policy-block-authentication-flows](https://learn.microsoft.com/en-us/entra/identity/conditional-access/policy-block-authentication-flows)).

**Pre-implementation test (run this BEFORE building anything):**

The cheapest probe is exactly what the eventual production stack does, but on a workstation:

1. On a Linux box, install `davmail` from nixpkgs (or grab a release jar). Set `davmail.mode=O365Manual` and `davmail.url=https://outlook.office365.com/EWS/Exchange.asmx`.
2. Run davmail. Configure a local mail client (or `openssl s_client` to localhost:1143) to fetch INBOX.
3. Davmail will print a code and a URL. Visit, sign in, paste code.
4. Outcomes:
   - **Success:** mail starts flowing. CA is not in the way. Production path is safe.
   - **Sign-in shows "Your organization needs to manage this device":** device-compliance CA. Architecture is dead until you can either get an exemption or use a different account.
   - **Consent UI shows "needs admin approval" with no user-consent button:** the tenant has user-consent disabled. You'd need an admin to grant consent for `9e5f94bc-…` (the Thunderbird app used by DavMail under the hood, or whatever DavMail uses now — check at consent time). Pre-emptive fix: ask the tenant admin to grant tenant-wide consent for Thunderbird's app id. This is a single click and doesn't require any *new* app registration.
   - **Authentication succeeds but `LIST` or `LOGIN` fails immediately on the IMAP side:** this is the "IMAP disabled at the protocol level" failure. The user's brief says IMAP is confirmed working today, so unlikely.
5. **Bonus probe:** ask the tenant admin (or a trusted colleague who has admin) to dump the CA policy summary: in Entra Admin Center → Conditional Access → Policies, screenshot the matrix. Look for any policy that targets "Office 365" or "Exchange Online" and applies "Block" or "Require compliant device" without excluding `Other clients`.

If the probe fails specifically on device-compliance, neither Arch 1 nor Arch 2 will save us. Arch 3 (TB-in-a-container) ALSO fails, because device-compliance keys off the device, not the app. In that scenario the only way forward is a tenant exemption or an alternative export channel (POP/IMAP from the user's Outlook desktop client to a local Dovecot — out of scope here).

**Run the probe first.** It's 30 minutes of effort and tells you whether the project is viable before any module work.

---

## 6. Deduplication Strategy

Maildir filenames are arbitrary; deduplication is by **`Message-ID` header**. Strategy when merging migrated archive against live mbsync output:

1. **Keep the archive in a separate Maildir tree initially.** `/mnt/data/Life/Andy/Email/o365/` (live) and `/mnt/data/Life/Andy/Email/o365.archive/` (migrated). No collision possible.
2. **Run `maildir-deduplicate` (Python, [PyPI](https://pypi.org/project/maildir-deduplicate/))** with `--strategy=delete-older`. It hashes Message-ID + a few fallback headers (Date, Subject, From) and removes duplicates. The "older" tiebreaker keeps the live-fetched copy — which we trust more because the migrated archive may have been re-encoded by MailStore.
3. **Schedule the dedupe as a one-shot oneshot systemd unit**, gated behind a flag file you create after manual verification — not a recurring job. Once the merge is done, you don't want it running again because it would compete with live writes.
4. **Worth knowing:** mbsync writes new messages to the `new/` subdir initially and moves them to `cur/` after the next sync. If you start a dedupe run mid-fetch, you can race. Stop mbsync during the merge.

If you'd rather not import a third-party tool, the same logic in 50 lines of Python: walk both trees, map Message-ID → filepath, on collision keep the live one and `os.unlink` the archive one.

---

## 7. NixOS Module Sketch

Following `.claude/rules/nixos-service-modules.md`. Two modules: `homelab.services.mailarchive` (top-level orchestrator) and lean wrappers around the upstream `services.davmail` plus mbsync. Keep DavMail's existing nixpkgs module; layer our concerns on top.

**File:** `modules/nixos/services/mailarchive.nix`

```nix
{ config, lib, pkgs, ... }: let
  cfg = config.homelab.services.mailarchive;
  user = "mailarchive";
in {
  options.homelab.services.mailarchive = {
    enable = lib.mkEnableOption "Continuous IMAP archival to Maildir";
    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/mnt/data/Life/Andy/Email";
      description = "Root for per-account Maildir trees.";
    };
    accounts = lib.mkOption {
      description = "Mailbox accounts to archive.";
      default = { };
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        options = {
          provider = lib.mkOption {
            type = lib.types.enum [ "gmail" "o365-davmail" ];
          };
          remoteUser = lib.mkOption { type = lib.types.str; };
          # Path to a sops secret. Format depends on provider:
          #   gmail:        OAuth refresh-token (used by mbsync PassCmd helper)
          #   o365-davmail: localhost auth password (mbsync uses plain LOGIN against davmail)
          credentialSecret = lib.mkOption { type = lib.types.str; };
          syncIntervalSec = lib.mkOption {
            type = lib.types.int;
            default = 60;
          };
        };
      }));
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${user} = {
      isSystemUser = true;
      group = user;
      home = cfg.dataDir;
      createHome = false;
    };
    users.groups.${user} = { };

    # -- DavMail (one instance, handling all O365 accounts via per-account OAuth state)
    services.davmail = lib.mkIf (lib.any (a: a.provider == "o365-davmail")
                                         (lib.attrValues cfg.accounts)) {
      enable = true;
      url = "https://outlook.office365.com/EWS/Exchange.asmx";
      config = {
        davmail.mode = "O365Modern";        # after bootstrap; "O365Manual" for first run
        davmail.imapPort = 1143;
        davmail.bindAddress = "127.0.0.1";
        davmail.allowRemote = false;
        davmail.oauth.persistToken = true;
        davmail.disableUpdateCheck = true;
        # Per-account refresh tokens injected via systemd EnvironmentFile from sops:
        # davmail.oauth.<user@tenant>.refreshToken={AES}...
      };
    };

    # -- Per-account mbsync configs and timers
    systemd.tmpfiles.rules = lib.flatten (lib.mapAttrsToList (n: a: [
      "d ${cfg.dataDir}/${n}                0700 ${user} ${user} -"
      "d ${cfg.dataDir}/${n}/Maildir        0700 ${user} ${user} -"
    ]) cfg.accounts);

    environment.etc = lib.mapAttrs' (n: a: lib.nameValuePair
      "mailarchive/mbsync-${n}.rc" {
        mode = "0400";
        user = user; group = user;
        text = mkMbsyncrc { inherit n a cfg; };
      }) cfg.accounts;

    systemd.services = lib.mapAttrs' (n: a: lib.nameValuePair
      "mailarchive-${n}" {
        description = "Mail archive sync: ${n}";
        path = with pkgs; [ isync cyrus-sasl-xoauth2 ];
        serviceConfig = {
          Type = "oneshot";
          User = user;
          EnvironmentFile = config.sops.secrets."mailarchive/${n}".path;
          ExecStart = "${pkgs.isync}/bin/mbsync -c /etc/mailarchive/mbsync-${n}.rc -a";
          Nice = 10;
        };
        # Restart davmail-coupled accounts whenever davmail's unit changes.
        restartTriggers = lib.optional (a.provider == "o365-davmail")
          config.systemd.units."davmail.service".unit;
      }) cfg.accounts;

    systemd.timers = lib.mapAttrs' (n: a: lib.nameValuePair
      "mailarchive-${n}" {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2min";
          OnUnitActiveSec = "${toString a.syncIntervalSec}s";
          AccuracySec = "10s";
        };
      }) cfg.accounts;

    # -- Sops secrets layout
    sops.secrets = lib.mapAttrs' (n: a: lib.nameValuePair
      "mailarchive/${n}" {
        sopsFile = config.homelab.secrets.sopsFile "mailarchive-${n}.env";
        format = "dotenv";
        owner = user; mode = "0400";
      }) cfg.accounts;

    # Plus a separate secret with davmail's per-account refresh tokens, owned by davmail user
    sops.secrets."mailarchive/davmail-tokens" = lib.mkIf
      (lib.any (a: a.provider == "o365-davmail") (lib.attrValues cfg.accounts)) {
        sopsFile = config.homelab.secrets.sopsFile "davmail-oauth.env";
        format = "dotenv";
        owner = "davmail"; mode = "0400";
      };

    # -- Reverse proxy: not needed (no external surface)
    # -- Monitoring
    homelab.monitoring.monitors = lib.flatten (lib.mapAttrsToList (n: _: [{
      name = "Mailarchive: ${n}";
      # Push-style: a successful mbsync run touches a heartbeat file; a tiny
      # http endpoint on localhost serves its mtime delta. See uptime-kuma push monitors.
      type = "push";
      pushInterval = 600;  # alert if no sync in 10 minutes
    }]) cfg.accounts);

    # -- NFS watchdog (dataDir is on /mnt/data which is virtiofs; treat like NFS)
    homelab.nfsWatchdog.mailarchive.path = cfg.dataDir;
  };
}
```

**Host enablement** (`hosts/doc2/configuration.nix`):

```nix
homelab.services.mailarchive = {
  enable = true;
  dataDir = "/mnt/data/Life/Andy/Email";
  accounts = {
    gmail = {
      provider = "gmail";
      remoteUser = "abl030@gmail.com";
      credentialSecret = "mailarchive/gmail";
      syncIntervalSec = 120;
    };
    work = {
      provider = "o365-davmail";
      remoteUser = "<work-email>";
      credentialSecret = "mailarchive/work";
      syncIntervalSec = 60;   # tighter — we delete fast
    };
  };
};
```

**Sops secret layout (`secrets/hosts/doc2/`):**

- `mailarchive-gmail.env` — `MBSYNC_PASS=<output-of-oauth2-helper>` plus `OAUTH_CLIENT_ID`, `OAUTH_CLIENT_SECRET`, `OAUTH_REFRESH_TOKEN` for the Gmail PassCmd helper.
- `mailarchive-work.env` — `MBSYNC_PASS=<davmail-localhost-passphrase>` (DavMail uses the user's Microsoft password as the IMAP login password OR a configurable static value; check DavMail's `davmail.imapAuth` setting).
- `davmail-oauth.env` — environment-file fragment containing `davmail.oauth.<user>.refreshToken=...` style lines, sourced by the davmail systemd unit.

**Two helper bits worth flagging:**

1. The Gmail PassCmd helper: ship as a small `pkgs.writeShellApplication` calling Python's `msal` or `requests` to swap the refresh token for a fresh access token, print it, exit. mbsync calls this every sync.
2. DavMail bootstrap: a separate documented one-time procedure (`docs/runbooks/mailarchive-bootstrap.md`) that flips davmail to `O365Manual`, runs it, captures the refresh token from the properties file, encrypts it into sops, then restores `O365Modern`.

---

## 8. Open Questions

These need user verification before / during implementation:

1. **Does the work tenant block device-code flow?** Run the pre-implementation test in section 5. If yes, the project is dead — escalate to user.
2. **Does the work tenant require admin consent for `9e5f94bc-…` (Thunderbird) or DavMail's internal client_id?** DavMail's modern auth flows use Microsoft-published client_ids. If the consent UI says "needs admin approval," the user needs to ask the tenant admin to grant tenant-wide consent — single click, no new app registration.
3. **What is DavMail's IMAP auth password?** DavMail can either pass through Microsoft passwords (won't work — we have no password, we have OAuth) or accept a configurable static value (`davmail.imapAuth=...`). Verify in the davmail.properties reference. Affects what we put in `MBSYNC_PASS`.
4. **Does the existing MailStore archive include sent mail and IMAP-server-side folders that no longer exist on the live server?** If yes, the archive contains historical data the live fetch will never produce — keeping the migrated tree separate (section 6 step 1) becomes mandatory, not optional.
5. **Is `/mnt/data/Life/Andy/Email/` on the same virtiofs mount as other doc2 state?** Confirm before turning on the NFS watchdog at that path; if it's a different mountpoint, pick the right one.
6. **Where should the heartbeat-monitor live?** The Uptime Kuma push pattern in the sketch is hand-wavy. May be cleaner to switch to an active probe: a tiny script on doc2 that touches a file on each successful mbsync run, and a Kuma "Keyword" monitor that hits a localhost endpoint serving the mtime delta. Defer concrete design to ce-plan.
7. **How will EWS-shutdown affect us in late 2026?** DavMail's Graph backend is "experimental" as of 6.7.0. We'll likely need to bump DavMail across the rest of 2026 and may hit breaking changes when the maintainer flips the default backend. Plan for one DavMail bump every 2-3 months minimum through 2027.
8. **What does the Conditional Access policy review actually look like for the user?** They have "limited admin access" per the brief — does that include enough to view CA policies in the Entra admin center? If not, the probe in section 5 is the only practical way to discover policy effects.

---

## Source Map

Key URLs cited above, grouped:

**Microsoft auth landscape (2025–2026):**
- [Mozilla Thunderbird OAuth KB (admin consent + scopes)](https://support.mozilla.org/en-US/kb/microsoft-oauth-authentication-and-thunderbird-202)
- [Mailbird — Email Client Compatibility Crisis 2025-2026](https://www.getmailbird.com/email-client-compatibility-crisis-third-party-guide/)
- [Mailbird — Modern Authentication Enforcement in 2026](https://www.getmailbird.com/microsoft-modern-authentication-enforcement-email-guide/)
- [TB Knowledgebase issue #122 — admin enablement page request](https://github.com/thunderbird/knowledgebase-issues/issues/122)
- [TB Blog — Native Exchange support, Nov 2025](https://blog.thunderbird.net/2025/11/thunderbird-adds-native-microsoft-exchange-email-support/)
- [Microsoft Learn — Block authentication flows with CA](https://learn.microsoft.com/en-us/entra/identity/conditional-access/policy-block-authentication-flows)
- [Microsoft — SMTP basic-auth deprecation timeline](https://techcommunity.microsoft.com/blog/exchange/updated-exchange-online-smtp-auth-basic-authentication-deprecation-timeline/4489835)

**Thunderbird client_id revocation history:**
- [email-oauth2-proxy issue #267 — older client_id disabled 2024-08-01](https://github.com/simonrob/email-oauth2-proxy/issues/267)
- [TB Bugzilla #1685414 — Confidential vs Public Client](https://bugzilla.mozilla.org/show_bug.cgi?id=1685414)

**DavMail health & releases:**
- [DavMail RELEASE-NOTES.md (master)](https://github.com/mguessan/davmail/blob/master/RELEASE-NOTES.md)
- [DavMail 6.6.0 release news (2026-04)](https://sourceforge.net/p/davmail/news/2026/04/davmail-660-released/)
- [DavMail 6.7.0 release news (2026-05)](https://sourceforge.net/p/davmail/news/2026/05/davmail-670-released/)
- [Help Net Security — DavMail 6.6.0 coverage](https://www.helpnetsecurity.com/2026/04/14/davmail-6-6-0-released/)
- [DavMail FAQ](https://davmail.sourceforge.net/faq.html)
- [DavMail headless / persistToken thread](https://sourceforge.net/p/davmail/discussion/644056/thread/c89c682851/)

**mbsync/getmail6/offlineimap stack:**
- [Arch Wiki — isync](https://wiki.archlinux.org/title/Isync)
- [benswift.me 2025 yak-shave (mbsync + O365)](https://benswift.me/blog/2025/09/12/the-great-2025-email-yak-shave-o365-mbsync-mu-neomutt-msmtp/)
- [Simon Dobson — mbsync + O365 OAuth 2024](https://simondobson.org/2024/02/03/getting-email/)
- [getmail6 issue #60 — token refresh on IDLE reconnect](https://github.com/getmail6/getmail6/issues/60)
- [getmail6 issue #62 — IDLE + OAuth unhandled exceptions](https://github.com/getmail6/getmail6/issues/62)
- [offlineimap3 issue #187 — XOAUTH2 LIST regression Feb 2024](https://github.com/OfflineIMAP/offlineimap3/issues/187)
- [moriyoshi/cyrus-sasl-xoauth2](https://github.com/moriyoshi/cyrus-sasl-xoauth2)
- [harishkrupo/oauth2ms](https://github.com/harishkrupo/oauth2ms)
- [UvA-FNWI/M365-IMAP — refresh-token helper](https://github.com/UvA-FNWI/M365-IMAP)

**Nixpkgs:**
- [nixos/modules/services/mail/davmail.nix (master)](https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/mail/davmail.nix)
- mcp-nixos confirmations for `davmail` (6.5.1), `isync` (1.5.1), `cyrus-sasl-xoauth2` (0.2), `getmail6` (6.19.12) on `unstable`.

**MailStore migration:**
- [MailStore Home — Exporting Email](https://help.mailstore.com/en/home/Exporting_Email)
- [maildir-deduplicate on PyPI](https://pypi.org/project/maildir-deduplicate/)
