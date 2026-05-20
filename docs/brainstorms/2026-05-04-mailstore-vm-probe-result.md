# Mailstore VM Replacement — DavMail/OAuth Probe Result

**Date:** 2026-05-04
**Status:** Probe complete and end-to-end verified. **Architecture 1 (mbsync direct + Thunderbird client_id) is locked in** — confirmed working with a live IMAP fetch.
**Companion to:** `2026-05-04-mailstore-vm-replacement-research.md`

## What we tested

Section 5 of the research doc proposed a 30-minute pre-implementation probe to detect whether the work O365 tenant (cullenwines.com.au) imposes Conditional Access policies that would kill the project. We ran a variant on epimetheus, using DavMail 6.6.0 from nixpkgs as the OAuth driver.

## Outcomes observed

**1. DavMail's client_id is blocked at the consent layer.**

When the IMAP login was attempted via DavMail (which uses the published app id `facd6cff-a294-4415-b59f-c5b01937d7bd`), Microsoft's sign-in completed normally (credentials accepted, MFA passed, no Conditional Access block) — but the consent screen showed:

> DavMail needs permission to access resources in your organization that only an admin can grant. Please ask an admin to grant permission to this app before you can use it.

The "Have an admin account?" link was offered. The user (limited Entra admin role) does not have permissions to grant tenant-wide consent.

**2. Thunderbird's app id is already consented tenant-wide.**

In the cullenwines.com.au Entra Admin Center → Enterprise Applications, Thunderbird is listed as "Activated" with its app id visible. That means a previous tenant admin (or an earlier policy regime) granted consent to Thunderbird, and any OAuth flow using Thunderbird's client_id is accepted on this tenant without further consent prompts.

## What the probe rules out and rules in

**Rules out:**
- **Conditional Access blocking the headless OAuth flow.** CA didn't fire on either DavMail's or Thunderbird's auth attempts — sign-in itself succeeded both times. The project is *viable* (the section-5 worst case did not materialize).
- **Architecture 2 (DavMail) on this tenant without IT involvement.** DavMail's client_id requires admin consent we can't grant ourselves. Architecture 2 would require an IT ticket, which the user explicitly preferred to avoid.
- **Architecture 3 (Thunderbird-in-a-container) as a workaround.** Containers don't bypass tenant OAuth policy — the policy is keyed off the client_id, not the network origin. Architecture 3 hits the *same* consent layer Architecture 1 does, with strictly more moving parts.

**Rules in:**
- **Architecture 1 (mbsync + cyrus-sasl-xoauth2 + Thunderbird client_id direct to O365).** This is now the recommended path. Microsoft will accept the OAuth flow because Thunderbird is pre-consented; refresh tokens last as long as Microsoft's standard `offline_access` lifetime (90 days inactive / unlimited if used).

## Revised architecture recommendation

**Architecture 1.** The original research doc preferred Architecture 2 because it shifts the maintenance burden of tracking Microsoft's auth changes onto DavMail's maintainer. That logic is still sound in the abstract, but on *this specific tenant* the consent gate flips the calculus: DavMail can't run here without IT intervention, and the user has explicitly opted not to involve IT.

**Trade-offs we accept by going Arch 1:**

- **Microsoft client_id rotation risk.** Microsoft retired the older Thunderbird client_id `08162f7c-0fd2-4200-a84a-f25a4db0b584` on 2024-08-01. They could do it again to `9e5f94bc-…`. Recovery: discover the new id from Mozilla's published Thunderbird sources, update our helper script's config, re-bootstrap the refresh token. ~1 hour of work, zero data loss.
- **No abstraction over Microsoft auth changes.** When MS adjusts redirect-URI rules or scope behavior (as they did in March-April 2026), we patch our helper instead of pulling a DavMail release. Manageable if we keep the helper short and idiomatic.
- **Self-managed token refresh.** mbsync's `PassCmd` invokes a helper every sync; the helper holds the refresh token (sops-encrypted) and exchanges it for a fresh access token. Standard pattern, well-trod by `mutt_oauth2.py` and `oauth2ms`.

**Pre-condition to verify before building** (small but important):

- Confirm the Thunderbird app id registered in cullenwines.com.au's Enterprise Apps is the *current* `9e5f94bc-e8a4-4e73-b8be-63364c29d753`, not the retired `08162f7c-…`. If it's the retired id, we're on a grandfathered token that won't survive re-auth — and we'd need a different fallback (likely: ask IT to add tenant-wide consent for the current Thunderbird id, which is a single-click admin action and doesn't require any new app registration).

## What changes in the implementation plan

- **Drop DavMail entirely.** No NixOS service, no Java daemon on doc2, no admin-consent dependency.
- **Module reduces to: mbsync per account + a small token-refresh helper.** Both work and Gmail accounts use the same fetcher with different `PassCmd`s and different client_ids (Thunderbird's for work O365, the user's own GCP project for Gmail).
- **Helper script:** ship as `pkgs.writeShellApplication` wrapping a Python one-liner that exchanges refresh-token → access-token. ~20 lines.
- **Bootstrap procedure:** documented one-time step using a static localhost listener (not Microsoft's OOB redirect) to capture the initial refresh token, then sops-encrypt it. We'll write this as a runbook during `/ce-plan`.
- **Sops layout:** per-account `OAUTH_CLIENT_ID`, `OAUTH_REFRESH_TOKEN`, plus a `OAUTH_TENANT` (= `common`) for O365 and `OAUTH_CLIENT_SECRET` for Gmail (Google requires it; Microsoft doesn't for public clients).

## Gmail side: unchanged

The probe did not touch the Gmail side. The plan there remains: register a personal-use OAuth client in the user's own Google Cloud project, use the standard installed-app flow with localhost redirect, store refresh token in sops. This is well-trodden ground and not affected by Microsoft policy.

## End-to-end verification (Architecture 1)

After the consent-layer probe identified Architecture 1 as the path, a second probe
run a Python script (~120 lines) that exercises the full mbsync auth chain end-to-end:

1. Microsoft device-code OAuth with Thunderbird's `client_id`
2. Capture `refresh_token`; round-trip it through Microsoft's token endpoint
3. Decode the issued access-token JWT and verify claims
4. Connect TLS to `outlook.office365.com:993`
5. Send `AUTHENTICATE XOAUTH2` with the access token
6. Run `LIST "" "*"` to confirm full mailbox visibility

**Results:**

| Step | Result |
| --- | --- |
| Device-code → tokens | ✅ access_token + refresh_token issued |
| Refresh-token round-trip | ✅ new access_token issued |
| JWT `aud` claim | ✅ `https://outlook.office.com` |
| JWT `appid` claim | ✅ `9e5f94bc-e8a4-4e73-b8be-63364c29d753` (Thunderbird) |
| JWT `upn` / `unique_name` | ✅ `andy@cullenwines.com.au` |
| JWT `scp` | ✅ `IMAP.AccessAsUser.All POP.AccessAsUser.All SMTP.Send` |
| JWT `tid` | `32bffe65-3e64-414f-9d21-069572b800eb` (cullenwines.com.au) |
| TLS IMAP connect | ✅ |
| `AUTHENTICATE XOAUTH2` | ✅ `OK AUTHENTICATE completed.` |
| `LIST "" "*"` | ✅ 332 folders returned |

The first attempt at IMAP XOAUTH2 immediately after the initial consent failed with
`AUTHENTICATE failed.` — this is Microsoft's known eventual-consistency between
the auth issuer and Exchange Online's IMAP service on first-auth for an app
identity. A retry ~5 minutes later succeeded; in production this won't matter
because the bootstrap happens once per refresh-token rotation (90+ days),
followed by uninterrupted refresh-only auths.

**Confirmed implications for the implementation plan:**

- Only one `client_id` to embed in the helper: `9e5f94bc-e8a4-4e73-b8be-63364c29d753`.
- Tenant-routing endpoint is `/common/` (works because Thunderbird is consented
  in the user's home tenant; Microsoft routes by `login_hint`).
- Refresh-token lifetime tracks Microsoft default `offline_access` — 90 days
  inactive, indefinite if used. Continuous mbsync polls easily exceed that.
- Mailbox is large (332 folders, deep hierarchy) — migration plan must preserve
  folder structure, which the EML+Maildir path already does.

## Probe artifacts

- `/tmp/davmail-probe/` and `/tmp/mailprobe/` — both removed (refresh-token file
  was a real credential and was shred-deleted, not just `rm`).
- DavMail tested at version `6.6.0` from nixpkgs unstable.
- DavMail's app id (for reference if Architecture 2 ever becomes relevant again): `facd6cff-a294-4415-b59f-c5b01937d7bd`.
