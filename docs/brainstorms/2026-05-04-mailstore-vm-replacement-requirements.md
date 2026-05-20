# Mailstore VM Replacement — Requirements

**Date:** 2026-05-04
**Status:** Requirements drafted; research and probe complete; ready for `/ce-plan`.
**Owner:** abl030
**Companion docs:**
- `2026-05-04-mailstore-vm-replacement-research.md` — deep research output
- `2026-05-04-mailstore-vm-probe-result.md` — pre-implementation OAuth probe; **revises the architecture choice from 2 to 1** because Thunderbird is already tenant-consented on cullenwines.com.au and DavMail is not.

## Problem

A Windows 10 VM (`prom`/VMID 102, ssh `root@192.168.1.12`) exists solely to run Thunderbird + MailStore Home for email archiving. Windows 10 is out of support; the VM is the last Windows host in the fleet. The setup persists because at the time it was built, OAuth/MFA against O365 and Gmail from Linux clients was painful enough that a "trusted" Windows MUA + a GUI archiver was the path of least resistance.

The archive is the user's full personal+work email history (~11 GB), used as a deletion-resistant backup ("Google deletes my account tomorrow → I still have my life") more than as a search tool. Retrieval happens roughly 3x/year, when Gmail's own search fails or a work email was deleted prematurely.

## Goal

Replace the Windows VM with a Linux/NixOS-native solution that:
- Continues to capture every personal Gmail and work O365 email (including attachments) with deletion-resistance
- Stores them in an **open, non-proprietary format** so future search/UI tooling stays optional
- Handles modern OAuth without registering an app in the work Entra tenant
- Migrates the existing 11 GB MailStore archive into the new store, then retires MailStore entirely

## Users and Use Cases

Single user (abl030). Two use cases:

1. **Backup-of-record** — passive accumulation; never touched.
2. **Emergency retrieval** — ~3x/year, find a specific email/attachment that was deleted upstream or that Gmail's search can't surface.

## Stated Requirements

- **Sources:** personal Gmail + work O365 (outlook.com tenant). IMAP confirmed working on the work tenant today.
- **OAuth:**
  - Personal Gmail: user generates own GCP OAuth client — fine.
  - Work O365: **must not require registering an app in the work Entra tenant.** User has limited admin access but prefers to avoid touching it.
- **Storage:**
  - Open format (Maildir is the obvious answer — one file per message, every client and indexer reads it).
  - Located under `/mnt/data/Life/Andy/Email/` so existing Kopia backups (Wasabi + offsite) cover it without new infrastructure.
- **Migration:** the 11 GB existing MailStore archive (`/mnt/data/Life/Andy/Email/Mailstore/`, MailStore Home `.dat`/`.rr` proprietary format) must be exported to Maildir and merged into the new store.
- **Deletion-resistance:** the user deletes work emails after processing them. The archiver must capture mail before that deletion happens — i.e. either IMAP IDLE or polling fast enough that a same-day delete is still caught.
- **Retire MailStore + the Windows VM** at end of project.

## Inferred Decisions (confirmed)

- Host the fetcher on **doc2** — matches the "stateful services live on doc2" fleet pattern.
- Build as a NixOS module under `homelab.services.mailarchive` (name TBD), enabled in `hosts/doc2/configuration.nix`. Follow `.claude/rules/nixos-service-modules.md`.
- Wire into `homelab.monitoring` so Uptime Kuma alerts when the fetcher stops pulling.
- Secrets via `sops-nix` at `secrets/hosts/doc2/<service>.env` for OAuth tokens / refresh tokens / client_ids.
- Output of this brainstorm = the deep research prompt below; user will run the research separately, then come back for ce-plan.

## Out of Scope

- Web-UI archive products (Mailpiler, Stalwart, Roundcube on top of local Dovecot, etc.) — overkill for 3x/year retrieval; the user explicitly does not want a "MailStore replacement" with its own UI baggage.
- Replacing daily mail clients (work Outlook, Gmail web) — those stay as-is.
- Adding search/indexing infrastructure (notmuch, mu, mairix) — Maildir leaves the door open; building it is a separate project.
- Any work-tenant Entra app registration.
- Keeping MailStore Home around as a "cold reader" for the legacy archive — explicit goal is full migration, no proprietary format hangover.

## Success Criteria

1. Windows VM 102 powered off and removed from the Proxmox inventory.
2. Both Gmail and work O365 have a Maildir under `/mnt/data/Life/Andy/Email/` that is being updated continuously, verifiable by sending a test email to each and watching it land within minutes.
3. The 11 GB MailStore archive is exported to Maildir and merged into the live archive (deduplicated against new fetches if there's overlap).
4. Kopia snapshots include the new Maildir paths.
5. An Uptime Kuma monitor is green and pages on persistent fetch failure.
6. OAuth tokens refresh automatically — no manual re-auth required for at least 90 days of operation.

## Risks and Open Questions

- **Microsoft tightening borrowed client_ids.** The "Thunderbird OAuth client_id" trick that lets non-tenant-registered clients authenticate against arbitrary O365 tenants has been the historical workaround. Microsoft has been progressively tightening this and could revoke it at any time. Mitigation candidates: Davmail (which abstracts the auth dance and rotates as needed) or falling back to a Linux Thunderbird in a container.
- **Tenant policies.** Work tenant might enable Conditional Access policies (device compliance, IP restrictions) that block headless OAuth flows even when the client_id is allowed. Needs verification.
- **MailStore export fidelity.** MailStore Home does support EML/Maildir export, but folder structure, attachments, and metadata fidelity need verification before committing to migration.
- **Future search/UI.** Deferred, but storage-format choice (Maildir) preserves the option.

---

## Deep Research Prompt

> Use the following prompt for the deep-research pass. Goal is a recommendation with concrete trade-offs, not just a survey.

```
I need to replace a Windows 10 VM that exists solely to run Thunderbird + MailStore
Home for email archiving. Replacement is a NixOS service on Linux running on a
homelab VM (doc2, NixOS, x86_64). The new system must:

  - Continuously archive (a) personal Gmail and (b) work Microsoft 365 / outlook.com
    mail to Maildir on a local NFS-backed path, with deletion-resistance — the user
    deletes work emails after processing, so the archiver must capture them first
    (IMAP IDLE or fast polling).
  - Authenticate via modern OAuth2.
      * Personal Gmail: user has their own Google Cloud project and can register a
        custom OAuth client — assume this path is open.
      * Work O365: the user CANNOT register an app in the work Entra tenant. The
        solution must use either (a) a borrowed/published client_id that O365
        tolerates against arbitrary tenants (e.g. Thunderbird's), (b) a translation
        bridge like Davmail that handles auth internally, or (c) some equivalent
        approach. IMAP is confirmed enabled at the protocol level on the work tenant.
  - Store one file per message in Maildir format under
    /mnt/data/Life/Andy/Email/<account>/, so existing Kopia backups (to Wasabi and
    an offsite home server) cover it without new infrastructure.
  - Migrate ~11 GB of existing MailStore Home archive (proprietary .dat/.rr files)
    into the new Maildir store as a one-time operation, then retire MailStore
    entirely. No proprietary format hangover.
  - Run as a NixOS module (the fleet uses sops-nix for secrets, systemd units,
    Uptime Kuma for monitoring).

Investigate and compare these candidate architectures, with a strong recommendation
at the end:

  1. Direct IMAP fetcher (mbsync/isync, getmail6, OfflineIMAP, or other) using a
     borrowed OAuth client_id (typically Thunderbird's) for O365. Cover: which tool
     has the cleanest XOAUTH2 story in 2026, IDLE support, NixOS packaging status,
     refresh-token handling, and how vulnerable each is to Microsoft revoking
     borrowed client_ids.

  2. Davmail as a translation bridge: Davmail handles O365 auth internally and
     exposes plain IMAP on localhost; any standard IMAP fetcher consumes it.
     Evaluate Davmail's current health and maintenance velocity, resource cost,
     NixOS packaging, failure modes, and whether its OAuth resilience justifies the
     extra component.

  3. Linux Thunderbird in a container, with a separate process exporting its local
     store to Maildir. Closest to the current architecture. Evaluate practicality
     of running TB headlessly, OAuth reliability, and whether this is just the Win
     VM problem in a slightly nicer box.

For each candidate, report:
  - Whether it actually solves the no-tenant-app-registration constraint in 2026
  - Operational fragility: what specifically breaks when Microsoft tightens auth,
    and how fast recovery is
  - NixOS / declarative-config friendliness
  - 2026 health signal: recent commits, recent issues about O365 auth breaking,
    community size

Also research:
  - Best path for one-time MailStore Home → Maildir migration. What does MailStore's
    export actually preserve (folder structure, headers, attachments, dates)? Are
    there third-party tools that read MailStore's .dat format directly?
  - Whether Gmail's own client_id requirements have shifted (any need for OAuth app
    verification, even for a personal-use app accessing only the user's own account?).
  - Whether work O365 tenants commonly enforce Conditional Access policies that
    would block a headless OAuth flow even when the client_id is accepted, and how
    to detect this before committing to architecture 1 or 2.
  - Deduplication strategy when merging the migrated MailStore archive against
    newly-fetched live mail (e.g. messages that exist in both because the archive
    is recent).

Constraints:
  - No work-tenant Entra app registration. Hard constraint.
  - Output format must be Maildir or comparably open (one-file-per-message, plain
    RFC822). No proprietary stores.
  - Must run unattended for at least 90 days without manual re-auth.
  - Should be expressible as a NixOS module that fits the project's existing service
    pattern (modules/nixos/services/<name>.nix with options under
    homelab.services.<name>, sops-nix secrets, Uptime Kuma monitor wiring).

Deliver a ranked recommendation with the trade-offs that drove the ranking, plus a
sketch of the NixOS module shape for the recommended option.
```

## Next Steps

1. Run the deep research prompt above (any deep-research tool / agent).
2. Review the recommendation; if a clear winner emerges, dispatch `/ce-plan` to design the NixOS module + migration runbook.
3. Implement, deploy on doc2, run in parallel with the Win VM for ~2 weeks to verify deletion-resistance, then retire VM 102.
