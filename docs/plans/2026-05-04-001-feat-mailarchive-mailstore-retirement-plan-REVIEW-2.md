# Plan Re-Review (Round 2): Mailarchive / Mailstore VM Retirement

**Reviewer:** independent agent (round 2)
**Date:** 2026-05-04
**Plan reviewed:** docs/plans/2026-05-04-001-feat-mailarchive-mailstore-retirement-plan.md (revised)
**Round 1 review:** docs/plans/2026-05-04-001-feat-mailarchive-mailstore-retirement-plan-REVIEW.md

## Summary

The rewrite is a substantial improvement: every C-class issue from round 1 is decisively fixed, all 9 S-class items are addressed (8 cleanly, 1 with a small remnant), and the user's three explicit directives (drop the parallel run, single mixed legacy tree, explicit folder selection) are all reflected. Two genuinely new issues emerged: (1) the plan asserts `pkgs.python3Packages.maildir-deduplicate` is available in nixpkgs unstable — it is **not** (verified via mcp-nixos; only a Perl `MailMaildir` and unrelated dedup tools exist), so U7c needs a different tool or an inline fallback; (2) U7c's smoke-test step "delete a test message from the live server, confirm Maildir copy stays" is tautological under `Sync Pull` + `Remove None` (mbsync never propagates remote deletes regardless of timing) — the test confirms the configuration matches the rc but doesn't exercise the deletion-resistance contract meaningfully. A handful of smaller items (PassCmd quoting, bootstrap chicken-and-egg, OAUTH_TENANT default consistency) deserve a sentence each. With those fixes the plan is ready.

## Round-1 Findings — Verification Status

| ID | Finding | Status | Notes |
|----|---------|--------|-------|
| C1 | json-query operator | Fixed | Plan line 97 (Key Technical Decisions) and U4 (lines 333-353) consistently use server-side boolean (`$.healthy == "true"`). No leftover `<600` comparator in the plan. The 600s threshold is preserved server-side as `STALE_THRESHOLD_SEC`. The risk row about `==` operator is gone (correctly, since that's no longer the failure mode). |
| C2 | U6 wrong host | Fixed | Plan U6 (line 426) and U8 step 3 (line 513) both use `github:abl030/nixosconfig#doc2 --refresh` and `ssh doc2 "..."`. The U8 fixup paragraph "wait, doc2 is `doc2`, not `proxmox-vm`" is gone. ASCII-art bootstrap block at line 187 also says `#doc2`. Clean. |
| C3 | Maildir layout | Fixed | U3 (line 285) and U7b (line 461) both explicitly state `SubFolders Verbatim` with nested directories. U7b's "Approach" bullet now reads "Reconstruct folder hierarchy as **nested Maildir directories** matching `SubFolders Verbatim`" and explicitly says "**Do not** flatten using Maildir++ dot-separated names". Key Technical Decisions section (line 96) reinforces the choice fleet-wide. |
| S1 | vms/definitions.nix | Fixed | U8 step 8 (line 522) and the Documentation/Operational Notes (line 576) both correctly state "VM 102 was never inventoried" and call out CLAUDE.md's stale "Important Files" line as a separate optional cleanup. The verification block doesn't reference vms/definitions.nix. Verified `vms/definitions.nix` does not exist on disk. |
| S2 | /mnt/data is NFS not virtiofs | Fixed | Summary (line 13), Key Technical Decisions (line 99), Context bullet (line 63), and System-Wide Impact (line 545) all say "NFSv4.2 to tower / Unraid". One borderline phrasing remains — Risks table line 565 says "/mnt/data NFS goes stale" which is now consistent. /mnt/virtio is correctly disambiguated as the virtiofs mount. |
| S3 | mbsync direction Pull only | Fixed | Key Technical Decisions (line 91) and U3 (line 286) both lock in `Sync Pull`, `Create Near`, `Remove None`, `Expunge None`. The risk row at line 561 explicitly cites the test that verifies one-way semantics (no upstream pollution). Strong fix. |
| S4 | Gmail patterns | Fixed | Plan line 94 (decisions) and U3 (line 288) both narrow Gmail to `Patterns "[Gmail]/All Mail"` only with explicit rationale (label-vs-folder duplication). U3's integration test (line 311) verifies total Maildir message count matches All-Mail count. |
| S5 | Kuma co-location documented | Fixed | System-Wide Impact section adds a dedicated "Hidden constraint — Kuma host co-location" paragraph (line 550) and Risks table line 568 references the same constraint with a fallback. Honest framing — accept and document, swap to FQDN if Kuma ever moves. |
| S6 | .sops.yaml edit removed | Fixed | U1's "Files" section (line 205) only lists `mailarchive.nix` create + `default.nix` modify. No mention of `secrets/.sops.yaml`. Clean. |
| S7 | Inbox directive removed | Fixed | U3 (line 285) explicitly states: "Do **not** set an explicit `Inbox` directive — Verbatim defaults handle it under `Path`." |
| S8 | SASL_PATH env var | Fixed | Key Technical Decisions (line 95) names `SASL_PATH=${pkgs.cyrus-sasl-xoauth2}/lib/sasl2` and U3 (line 291) wires it via `serviceConfig.Environment`. The risk row at line 562 cites the verification step (`mbsync -V` listing XOAUTH2). |
| S9 | U7c sequencing | Fixed | U7's Dependencies line (line 450) now reads "U7c (optional dedup) is independent of U8" — no parallel-run gate. U7c body (line 466) recommends keeping legacy and live separate by default. Sequencing is sound now that the parallel-run is gone. |

## New Critical Issues (must-fix before implementation)

### N-C1. `maildir-deduplicate` is NOT packaged in nixpkgs (round 1's claim was wrong; the rewrite codified it)

The plan's Open Questions (line 117) and U7c approach (line 466) both assert:
> `maildir-deduplicate` available as `pkgs.python3Packages.maildir-deduplicate` in nixpkgs unstable

Verified via mcp-nixos (`info` action, exact attribute path):
> `Error (NOT_FOUND): Package 'python3Packages.maildir-deduplicate' not found`

Broader search (`maildir-deduplicate` and `mail-deduplicate` queries) returned 20 unrelated results: `backdown`, `mb2md`, `mu`, `muchsync`, `getmail6`, `notmuch`, etc. — but no `maildir-deduplicate` or `mail-deduplicate` Python package. The closest is `perl5Packages.MailMaildir` (a different library entirely). The PyPI tool `maildir-deduplicate` (now renamed to `mail-deduplicate`) exists upstream but has not been packaged for nixpkgs.

This propagates a round-1 nit (line 152 of REVIEW.md, "easy check: it's available as `pkgs.python3Packages.maildir-deduplicate`") that was itself unverified. The plan now treats the existence as resolved when it's not.

**Fix options (any one is fine, since U7c is optional):**
- Drop U7c's automated dedup and document a manual approach (fall back to a small inline Python script using `email.parser.BytesParser` + Message-ID set, ~30 lines, stdlib only). This matches the research doc's section 6 fallback ("the same logic in 50 lines of Python").
- Package `mail-deduplicate` into the flake as a dev dependency via `nix-shell` or `pkgs.python3.withPackages` reading from `pip`/`builtins.fetchPyPI`. Adds friction.
- Swap U7c to suggest `muchsync` or `mu`'s built-in dedup (both packaged) — different semantics; needs investigation.

The plan's "default recommendation" already says "leave separate" (line 466) which is the lowest-risk path, so just removing the `maildir-deduplicate` claim and pointing at the inline-Python fallback closes the issue without architectural change.

## New Should-Fix Issues

### N-S1. U8 step 4 deletion-resistance test is tautological under `Sync Pull` + `Remove None`

U8 step 4 (line 517):
> Delete one of the test messages from the live server (OWA / Gmail web). Wait one more sync cycle. Confirm the Maildir copy stays put — this is the deletion-resistance load-bearing test.

mbsync with `Sync Pull` + `Remove None` + `Expunge None` will **never** propagate remote deletes downward, regardless of when the delete happens. The Maildir copy stays whether you delete the test message before or after the next sync cycle. The "wait one more sync cycle" framing implies there's a race or window the test is exercising, but there isn't one. This test confirms the rc was applied correctly, but is identical to inspecting the rc file with `cat`.

A more meaningful deletion-resistance test would verify:
1. **The mbsync state file (`SyncState`) doesn't track the remote delete and re-fetch in a way that creates a duplicate**, OR
2. **A new mbsync run after the delete still completes successfully** (regression: a misconfigured rc could fail on missing UIDs).

Better wording: "Delete one of the test messages from the live server. Run mbsync once more (`systemctl start mailarchive-work.service`). Confirm: (a) the service exits 0, (b) the Maildir copy is untouched, (c) journalctl doesn't show 'message lost' or 'UID gap' errors. Repeat after a few hours to ensure incremental sync handles the gap." The test still passes under `Sync Pull` + `Remove None`, but it now exercises mbsync's state-tracking, not just the layout.

Round 1 didn't catch this; my fault. Worth fixing.

### N-S2. U-ID renumbering: U9 is dropped without a gap (against plan template stability rule)

The instructions note that the plan template's stability rule says "deletion leaves a gap; gaps are fine." Per round 1's REVIEW.md (line 138, "U9: Document refresh-token rotation runbook"), the original plan had U1-U9. The rewrite consolidated U9 into U6 (per U6's body at line 411: "This doc consolidates U6 + U9").

But the rewrite renumbered: the new plan now has U1-U8 with the OAuth bootstrap as U6 and the migration as U7 — there is no gap at U9. Cross-reference: the original plan's "U7. MailStore migration" would have stayed U7 if gaps were honored, and U8/U9 should have remained as VM retirement and runbook respectively. Looking at the rewrite's U7 (line 444) and U8 (line 487), the migration stayed U7 and VM retirement stayed U8 — which is consistent with the original numbering, IF the original plan also had U7=migration and U8=VM retirement. I don't have the original plan in front of me to verify the original numbering.

If the original plan had: U1=skeleton, U2=helper, U3=mbsync, U4=monitor, U5=watchdog, U6=bootstrap, U7=migration, U8=enable+retire, U9=rotation runbook — then the rewrite correctly absorbs U9 into U6's doc and the gap convention is satisfied (U-IDs U1-U8 stable, U9 omitted). The new plan does match this numbering. **Verdict: probably fine, but explicitly call out "U9 is intentionally absorbed into U6 — no renumbering" in U6's preamble or in the section header so future reviewers don't have to reconstruct the history.**

### N-S3. Bootstrap chicken-and-egg in U6 not addressed

U6 (line 422):
> On any machine with `nix-shell`, run `nix-shell -p mailarchive-helper --run 'oauth2-helper bootstrap --provider=gmail --user=<email>...'`

But the helper (`oauth2-helper`) is defined inside the `mailarchive.nix` module's `let` block (per U2's approach, line 241) as a `pkgs.writers.writePython3Bin`. That makes it a derivation reachable from inside the module evaluation, not a top-level attribute named `mailarchive-helper` that `nix-shell -p` can find. A junior implementer following U6 verbatim will get "attribute 'mailarchive-helper' missing".

The bootstrap is a chicken-and-egg situation: the helper has to be invokable before the module is enabled (so the user can paste the resulting refresh token into sops, then deploy). Three resolutions:

1. **Expose the helper as a top-level flake app or package** (`packages.x86_64-linux.mailarchive-helper`). Then `nix run .#mailarchive-helper -- bootstrap ...` works from any clone of the repo. Cleanest.
2. **Define the helper as a top-level package outside the module**, and reference it from the module's `let` block. Same pattern as `tools/podcast-fetcher` if such existed.
3. **Document running the helper directly via `nix-build` against a known store path** — fragile.

Option 1 matches the project's existing pattern (the `nix run .#fmt-nix` / `nix run .#lint-nix` apps mentioned in CLAUDE.md). Plan should explicitly say "the helper is exposed as `packages.x86_64-linux.mailarchive-helper` so `nix run .#mailarchive-helper -- bootstrap ...` works on any machine with a clone."

This bug doesn't surface until U6 is actually executed, but the plan's bootstrap workflow assumes a packaging pattern not yet specified.

### N-S4. `OAUTH_TENANT` default inconsistency between probe and helper

The probe (`docs/brainstorms/2026-05-04-mailstore-vm-probe-result.md` line 99) used the `/common/` endpoint with `login_hint`-based tenant routing. The plan's U2 (line 245) says "for O365 also `OAUTH_TENANT` (default `common`)". The probe also captured the actual tenant ID `32bffe65-3e64-414f-9d21-069572b800eb` (probe result line 83).

Both work — `/common/` plus `login_hint=user@cullenwines.com.au` routes correctly. The user gains nothing concrete by hardcoding the tenant ID. But once the user is locked to one tenant (work O365), there is a small operational reason to prefer the tenant-specific endpoint: failed routing produces clearer error messages, and a tenant rename or migration would surface as an explicit refresh failure rather than silent rerouting.

Either default is defensible. Just be explicit: pick one and document why. Currently the plan defaults to `common` (per U2 line 245), which matches the probe. That's fine — but say so explicitly in U6's runbook: "OAUTH_TENANT defaults to `common` per probe; override only if you hit tenant-routing errors."

### N-S5. mbsync `PassCmd` shell-quoting under Nix interpolation is unaddressed

U3's mbsync rc snippet (line 283):
```
PassCmd "${oauth2-helper}/bin/oauth2-helper refresh --provider=${provider}"
```

mbsync's `PassCmd` invokes the value via `popen()` — it's a shell command. The Nix interpolation produces an absolute store path like `/nix/store/xxx-mailarchive-helper/bin/oauth2-helper`. Store paths never contain spaces or special shell characters (Nix sanitizes), so no escaping is needed for the path itself. `${provider}` interpolates `gmail` or `o365` — also safe.

**Verdict:** the quoting is fine in practice for these specific values. But the plan should note this assumption explicitly: "PassCmd's value is shell-evaluated; Nix store paths never contain shell metacharacters, so `${...}` interpolation is safe here. If the provider enum is ever extended to a value containing spaces/quotes, escape or pass via env." One sentence in U3's approach. Round 1 missed this; called out for completeness.

## New Nits

- **mbsync `Patterns` syntax with quoted folder names containing spaces.** The plan's O365 patterns include `"Sent Items*"`, `"Deleted Items*"`, `"Junk Email"` — all quoted, all containing spaces. mbsync's pattern syntax (per `man mbsync`) accepts double-quoted strings; spaces inside quotes are part of the pattern. This is correct usage. No fix needed, just confirming the syntax is valid (round 1 didn't verify, my responsibility to confirm: confirmed).
- **`Archive` (singular, no asterisk) in O365 patterns is leftover.** Probe output showed `Archives` (plural, with `Archives/2024`, `Archives/2025` children) but no `Archive` (singular) folder. The plan lists both `"Archive" "Archives*"` (line 209). `Archives*` matches `Archives` itself plus children; `Archive` singular is dead pattern. Either drop it, or — if the intent is to be defensive against tenants that use `Archive` (singular, common in some Outlook configurations) — leave it and note "matches if user has a singular Archive folder; harmless otherwise." A one-word annotation suffices.
- **`STALE_THRESHOLD_SEC` (server-side) and `interval × maxretries` (client-side) are complementary, not redundant.** The plan has both gates: `STALE_THRESHOLD_SEC = 600s` flips `healthy` to `false`; then Kuma's `interval=60s × maxretries=10 = 600s` adds another 10 minutes of confirmation before paging. Total worst case before Gotify: ~20 minutes. This is by design — server-side gate preserves health endpoint accuracy (so a `curl` shows true state); client-side gate suppresses transient 404s/502s/etc. The plan's U4 approach (line 352) almost says this but could state it more directly: "Server-side threshold suppresses heartbeat-clock-skew false positives; Kuma's retry window suppresses HTTP-server-blip false positives. Both gates together yield ~10-20 min before page; that's intentional." Clarify or accept.
- **`docs/runbooks/` reference removed; runbook lives at `docs/wiki/services/mailarchive.md`.** Verified — line 418, 574 both reference the wiki path. Round 1 nit closed.
- **The cleaned-up `Mailstore-export/` path is documented in U7a (line 457) as `_mailstore-export-staging/` and referenced in U8 step 8 (line 522).** Round 1 nit ("pick one canonical path") satisfied.
- **`vms/proxmox-ops.sh` supports `stop` and `destroy`.** Verified by grepping the wrapper: lines 352-364 of the script include `stop)`, `destroy)`, `list)`. The plan's U8 (lines 519, 521, 525) correctly calls `vms/proxmox-ops.sh stop 102` / `destroy 102` / `list`. Round 1 instruction-level concern addressed; no extension needed.
- **Bootstrap eventual-consistency callout strengthened.** U6 step 6 (line 427) reads: "**The very first `mailarchive-*.service` run after bootstrap may fail with `AUTHENTICATE failed` in the journal. This is *expected* — Microsoft's auth-issuer and Exchange Online's IMAP service have a few-minute consistency lag on first-auth. Do **not** re-run the bootstrap. Wait 5 minutes; the next timer fire will succeed.**" Bolded twice, "do not re-run" emphasized. Strong fix; round 1 nit closed.
- **`runAsRoot` correctly omitted, `restartTriggers` correctly omitted.** The plan's calibration on what to skip from the kopia pattern is clean. No change needed.
- **U3's `path = with pkgs; [ isync coreutils ]` simplification suggestion.** Round 1 line 126 noted that `path` only sets `$PATH`, not LD_LIBRARY_PATH. The rewrite uses `path` to expose `isync` and `coreutils` (so `mbsync` and `touch` are on `$PATH` — making the `ExecStart` and `ExecStartPost` strings shorter). Alternative would be absolute paths (`${pkgs.coreutils}/bin/touch`), as the prompt notes. Both work; the rewrite's choice is fine and idiomatic. No fix needed.

## User-Directive Verification

- (yes) **2-week parallel run removed.** Plan Summary (line 13) says "Smoke-test the live fetch with a few real messages, then stop and destroy VM 102 with a short safety window." U8 (line 487) goal: "smoke-test against real messages, stop VM 102, and destroy it after a short safety window." U8 step 6 (line 520) says "Wait ~3-5 days with VM 102 stopped." U8 test expectation (line 534): "No '2-week parallel run' — once smoke test passes and the safety window elapses, retirement proceeds." Strong, explicit removal across multiple sections.
- (yes) **Mixed Gmail+O365 archive treated as single legacy tree.** Summary (line 13): "Migrate the 11 GB existing MailStore Home archive (mixed Gmail + O365, single repository) into a one-shot `legacy.archive/` Maildir tree." Key Technical Decisions (line 101) and U7 goal (line 444) both reinforce. Scope Boundaries → Deferred (line 52) explicitly marks per-account split as a separate future script.
- (yes) **Sent Items + meaningful folders explicitly archived.** Plan line 93 (Key Technical Decisions): "O365: explicit folder set — `Patterns 'INBOX*' 'Sent Items*' 'Archive' 'Archives*' 'Drafts' 'Deleted Items*' 'Junk Email'`. Captures everything the user actively organises ... excludes `Calendar`, `Contacts`, `Tasks`, `Notes`, `Sync Issues`, `Conversation History`, `Outbox`, `RSS Feeds`, `Templates` which are calendar/state folders not mail." Folder selection is **explicit**, not implicit. U6 step 3 (line 424) makes the user re-confirm before deploy.
- (yes) **All round-1 issues addressed (or explicit reason for partial fixes).** All 12 round-1 items (3 critical + 9 should-fixes) are accounted for above; only minor remnants noted in N-S2, none unaddressed.

## Strengths Worth Preserving

- **Clean separation of concerns in module options.** `accounts = attrsOf submodule` + `provider = enum` is the right shape; doesn't repeat `kopia`'s slight option bloat.
- **Per-instance systemd timer-driven oneshot** correctly omits `restartTriggers` (no DB container) and correctly omits `runAsRoot` (mailarchive owns its own Maildir).
- **Server-side threshold + Kuma client-side retry as complementary gates** is good monitoring discipline. Both gates pull in the same direction (suppress false positives without delaying real alerts much).
- **Hidden-constraint documentation around localhost monitor URL.** The plan being honest about a fleet-wide constraint instead of papering over it is good agent-archaeology hygiene.
- **U6 absorbs U9's content cleanly** (line 429 — token-rotation + client_id-revocation recovery is in the same wiki doc as bootstrap). One operational doc, not two.
- **mbsync rc semantics locked down** (`Sync Pull`, `Create Near`, `Remove None`, `Expunge None`, no explicit `Inbox`, `SubFolders Verbatim`) with each choice justified in Key Technical Decisions. Future implementer can't accidentally pick a "two-way sync" rc.
- **Migration treats legacy and live as separate trees by default** with optional dedup. Lower-risk default; matches research doc section 6 step 1.
- **Probe trio remains the source of truth** — Sources & References cite the requirements, research, probe, and now the round-1 review explicitly.

## Open Questions for the Author

1. **Where does the helper actually surface for `nix run`?** See N-S3. The bootstrap workflow assumes the helper is invokable before the module is enabled; the packaging pattern needs to be one of: top-level flake app, top-level package, or explicit nix-shell/nix-build invocation. Not yet specified.
2. **U7c when `maildir-deduplicate` isn't packaged.** See N-C1. If the user wants the optional dedup, what's the fallback? Inline Python is the lowest-friction answer.
3. **Does U8's "delete-test on live server" actually exercise anything beyond the rc?** See N-S1. If not, replace with a more meaningful test of mbsync's state file behavior across UID gaps.
4. **Will the user actually want the smoke-test gate in front of VM 102 destruction to be 3-5 days, or shorter?** U8 step 6 says "~3-5 days." The rewrite removed the 2-week parallel run; how short should the new safety window be? 24h? 72h? Worth a one-line user-confirmation step in U6's runbook before destroy.
5. **The probe captured `tid=32bffe65-3e64-414f-9d21-069572b800eb` for cullenwines.com.au.** Should the helper hardcode this as a fallback if `OAUTH_TENANT=common` ever fails? Probably no — `common` works and avoids tenant-rename brittleness — but worth a sentence in the wiki doc capturing the known good tenant ID for reference.

## Verdict

**Needs one more pass, but a small one.** The rewrite landed all 12 round-1 issues and honored every user directive. The only must-fix is **N-C1** (`maildir-deduplicate` is not packaged — claim is wrong, U7c needs a different tool or inline Python fallback). The should-fix items (**N-S1** through **N-S5**) are all 1-2 sentence patches that don't change architecture: rephrase the deletion-resistance test, add a U-ID continuity note, specify how the helper is exposed for `nix-run`, document the OAUTH_TENANT default rationale, and add a one-line note about PassCmd shell-safety.

Priority order for the third pass:
1. **N-C1** (must-fix): drop `maildir-deduplicate` claim from Open Questions and U7c approach; replace with inline-Python fallback or document as "inline Python equivalent if dedup is ever wanted; manual review recommended."
2. **N-S3** (should-fix): specify the helper's packaging surface (flake app or top-level package) so U6's `nix-shell -p` / `nix run` invocation actually resolves.
3. **N-S1** (should-fix): rephrase U8 step 4's deletion-resistance test to exercise mbsync state, not the rc.
4. **N-S2, N-S4, N-S5** (nits with action): one-sentence clarifications.

After that, the plan is ready for `/ce-work`.
