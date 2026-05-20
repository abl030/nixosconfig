# Plan Review: Mailarchive / Mailstore VM Retirement

**Reviewer:** independent agent
**Date:** 2026-05-04
**Plan reviewed:** docs/plans/2026-05-04-001-feat-mailarchive-mailstore-retirement-plan.md

## Summary

The plan is substantively sound on architecture and infrastructure wiring — it correctly mirrors the kopia.nix shape, honours the monitor noise discipline, and traces back to the requirements/research/probe trio. But three concrete bugs would derail implementation if not caught: (1) the json-query monitor's `expectedValue = "<600"` does not work — `monitoring_sync.nix` hardcodes `jsonPathOperator = "=="`, so the comparator form silently fails open; (2) U6's runbook tells the user to rebuild `#proxmox-vm` from doc2 — that is doc1's flake target, the U8 fixup is correct but never propagated back into U6; and (3) the migration's Maildir++ folder layout (U7b) doesn't match the live mbsync's `SubFolders Verbatim` layout (U3), so the dedupe in U7c will see two parallel folder hierarchies and won't merge them. Plus several smaller issues (mbsync `Create Both` is unsafe for an archive, `vms/definitions.nix` doesn't exist, `/mnt/data` is NFS to tower not virtiofs, Gmail `Patterns *` will multiply messages via labels). Worth one revision pass before shipping.

## Critical Issues (must-fix before implementation)

### C1. `expectedValue = "<600"` will not work; switch to server-side boolean now (not "verify at implementation time")

The plan flags this as a "verify at implementation time" item (U4 approach + Open Questions). Verification is conclusive *now*: it doesn't work. In `modules/nixos/services/monitoring_sync.nix:201` the operator is hardcoded:

```python
common_kwargs["jsonPathOperator"] = "=="
```

`expectedValue` is then passed straight to Uptime Kuma as a literal equality compare. So `expectedValue = "<600"` will be compared as `<actual> == "<600"` — always false → monitor permanently DOWN, or always true depending on Kuma's coercion of the literal string. Either way, not the semantics you want.

**Fix:** the plan's "fallback" should be the primary plan. The heartbeat HTTP server should compute `healthy: true|false` server-side and the monitor uses `jsonPath = "$.healthy"`, `expectedValue = "true"`. Alternatively, `homelab.monitoring.monitors` could be extended to expose `jsonPathOperator` — but the plan explicitly defers that, and that's a sound call given scope. Just make the boolean shape canonical from U4 onwards.

### C2. U6 runbook deploys to the WRONG host (doc1, not doc2)

Plan line 399:
> `nixos-rebuild switch --flake github:abl030/nixosconfig#proxmox-vm --refresh` from doc2 (per CLAUDE.md remote-deploy rule).

Per `hosts.nix`, `proxmox-vm` is doc1 (vmid 104). doc2's flake key is literally `doc2` (`hosts.nix:298-303`). The plan correctly identifies this in U8 step 3 with a parenthetical fixup ("wait, doc2 is `doc2`, not `proxmox-vm` (which is doc1). Use `ssh doc2 "...#doc2 --refresh"`") — but the U6 runbook still has the wrong target embedded. A future user following the bootstrap runbook *first* (which is exactly the recommended order) would rebuild doc1 instead of doc2.

**Fix:** scrub U6 to use `--flake github:abl030/nixosconfig#doc2 --refresh` and `ssh doc2 "..."`. Drop the meta-narrative fixup from U8 step 3 entirely — it shouldn't be in the plan at all, just write the right command.

### C3. Migration (U7b) and live tree (U3) use incompatible Maildir layouts

U3 sets `SubFolders Verbatim`, which produces (per `man mbsync`):
> `Path/top/sub/subsub` and `Inbox/sub/subsub` (this is the style you probably want to use)

i.e. nested directories: `/mnt/data/Life/Andy/Email/work/Inbox/Sent Items/cur/`.

U7b's migration script writes:
> Reconstruct folder hierarchy as Maildir subfolders (`Maildir/.Folder.Subfolder/`, with `.` separator per Maildir++ convention).

i.e. flat dot-separated names: `/mnt/data/Life/Andy/Email/work.archive/.Inbox.Sent Items/cur/`.

Same logical folder, different path. The U7c dedup ("merge against live") will see them as siblings, not duplicates of the same folder, and the dedup-by-Message-ID across the *whole* tree will work but the resulting tree will have two parallel hierarchies — half flat-Maildir++, half nested-Verbatim. mbsync also won't merge in any future-fetched messages with the migrated tree because mbsync's state lives per-folder.

Also: per `man mbsync`, "attempts to set `Path` are rejected" with `SubFolders Maildir++`. So even if you wanted to flip the live mbsync rc to `Maildir++`, the rc stanza in U3 (which sets `Path`) won't validate.

**Fix:** pick one layout and use it everywhere. Recommended: `SubFolders Verbatim` in mbsync (matches U3) AND have the migration script reproduce nested directories (drop the `.Folder.Subfolder` flattening). This is simpler — no Maildir++ encoding edge cases to care about. Update U7b's "approach" bullet accordingly.

## Should-Fix Issues (would cause friction or technical debt if unaddressed)

### S1. `vms/definitions.nix` does not exist; VM 102 is not in fleet inventory

The plan tells the implementer to "Update `vms/definitions.nix` to drop VM 102" (U8 step 6) and lists `vms/definitions.nix no longer references VM 102` as a verification gate. Reality:

- `vms/definitions.nix` does not exist on this branch (`find /home/abl030/nixosconfig/vms -name 'definitions.nix'` → empty).
- VM 102 is not in `hosts.nix`, not in `vms/tofu/vm-resources.nix`, not in any inventory file (grep'd `vmid = 102` and `"102"` across the repo — zero hits).
- CLAUDE.md *does* still list `vms/definitions.nix` as an "Important Files" entry (line 312); that's a CLAUDE.md staleness bug, separate but related.

VM 102 is a Proxmox-side-only VM (created by hand, lives on `nvmeprom`, never managed by NixOS/OpenTofu). Retirement is purely a Proxmox operation — no fleet-config changes needed.

**Fix:** drop the `vms/definitions.nix` references from U8 step 6 and the verification block. Replace with: "after destroy, run `vms/proxmox-ops.sh list` and confirm 102 is gone; no fleet config changes needed because 102 was never inventoried." Optionally: file a separate issue to update CLAUDE.md's stale "Important Files" line.

### S2. `/mnt/data` is NFS to tower (Unraid), not virtiofs

The plan repeatedly characterises `/mnt/data` as virtiofs (e.g. "the virtiofs mount is already provisioned on doc2", System-Wide Impact bullet about "/mnt/data (virtiofs from prom)"). It is not. `modules/nixos/services/mounts/nfs-local.nix:27-43` mounts `/mnt/data` from `192.168.1.2:/mnt/user/data/` as NFSv4.2. `/mnt/virtio` is the virtiofs mount (separate, e.g. used by all the other doc2 services for state).

This matters operationally:
- If tower (192.168.1.2) goes down, `/mnt/data` goes stale, `mailarchive-*.service` will fail to write, `nfsWatchdog.mailarchive-*` will catch it (good — that wiring is correct). The watchdog is genuinely needed because the mount is genuinely network-shared.
- The data lives on tower's array, not on prom. Kopia from doc2 reads it via NFS. That's the existing topology.
- The systemd unit name `mnt-data.mount` works regardless (systemd names by mountpoint, not FS type) — so the `requires = ["mnt-data.mount"]` line in U3 is correct.

**Fix:** correct the prose throughout the plan ("virtiofs" → "NFS to tower / Unraid"). It's misleading framing that future readers will inherit. The actual systemd wiring is fine.

### S3. mbsync `Create Both` and bidirectional `Sync All` are unsafe for an archive

U3 lists the rc structure as: `Sync All`, `Create Both`, `Expunge None`, `SyncState *`.

- `Create Both` will create new local folders on the *remote* IMAP server if they appear locally. After U7b runs, `o365.archive/.Inbox.Sent Items` (or whatever) exists on the local Maildir; the next mbsync run will *create that folder upstream on cullenwines.com.au's Exchange*. Side-effect on the live mailbox.
- `Sync All` propagates everything in both directions, including the migration script's `:2,S` Seen flag — which mbsync will *push back to O365*, marking historical messages as read on the live server.

Neither is what an archive wants. A proper archive is one-way pull: messages flow remote → local, never the other direction.

**Fix:** the rc should be `Sync Pull` (or explicitly `Sync Pull Flags Gone` if you want to track flag changes from the server) plus `Create Near`, `Remove None`, `Expunge None`. Update U3's "Approach" accordingly. The plan does say final flags get tuned during U2/U3 — but the listed defaults are dangerous, not just imperfect.

### S4. Gmail `Patterns *` will multiply messages via labels

Gmail's IMAP exposes labels as folders, and every labelled message appears in *every* folder (label) it has, plus `[Gmail]/All Mail`. With `Patterns *`, mbsync will fetch the same message N+1 times into N+1 different Maildir folders.

For a backup-of-record use case, fetching only `[Gmail]/All Mail` once is the canonical answer (every message lives there exactly once). For per-folder organisation, you fetch labels separately but **exclude** All Mail to avoid duplication. The plan doesn't address this and will result in massive over-fetch, duplication, and Kopia bloat.

**Fix:** Gmail rc should use `Patterns "[Gmail]/All Mail"` (or similar) and exclude other folders. Document the choice in U3 and the runbook. Make this an explicit per-provider policy in the module.

### S5. Push-monitor / heartbeat scheme couples mailarchive to kuma's host

The monitor URL `http://localhost:9876/health/<account>` works because kuma and mailarchive are both on doc2. If kuma ever moves (it has moved between doc1/doc2 historically, see `docs/wiki/services/lgtm-stack.md` style migrations), the monitor will silently break — kuma will probe `localhost:9876` from its new host and find nothing.

Same problem in reverse: the plan claims (Open Questions resolved) that pull/json-query "matches existing patterns and keeps `homelab.monitoring` unchanged." But kopia's existing json-query monitors at `http://localhost:51515/api/v1/sources` (kopia.nix:348) *also* assume kuma is on doc2 — so this is a fleet-wide hidden constraint. Worth surfacing in the plan rather than ignoring.

**Fix:** add a short note in the plan under "System-Wide Impact" or "Risks" that the localhost monitoring URL pattern assumes kuma is co-located with the service. Either accept the constraint explicitly or use `https://<service>.ablz.au` via localProxy and depend on the LAN-only proxy. Probably accept-and-document; localProxy for a localhost health endpoint is overkill.

### S6. `secrets/.sops.yaml` change in U1 is unnecessary

U1 says: "Modify: `secrets/.sops.yaml` (add `mailarchive-*.env` to the encrypted-files glob if needed)."

`.sops.yaml` uses `path_regex: .*` — already matches everything. No edit needed. The "if needed" is doing some work but a junior implementer following the plan literally will go look for a glob and waste time. Just delete that bullet.

### S7. `Inbox` directive with `SubFolders Verbatim` may trip mbsync

The plan's mbsync rc snippet:
```
MaildirStore <name>-local:
  Path /mnt/data/Life/Andy/Email/<name>/
  Inbox /mnt/data/Life/Andy/Email/<name>/INBOX/
  SubFolders Verbatim
```

With `Path` set, mbsync expects subfolder paths to be relative under `Path`. Setting `Inbox` to a path *under* `Path` is supported but redundant; `SubFolders Verbatim` then yields `Path/INBOX/` for the INBOX. The plan's verification step ("messages appear under `/mnt/data/Life/Andy/Email/work/INBOX/cur/`") is consistent with this layout.

**Fix:** likely just drop the explicit `Inbox` line; let mbsync put INBOX under `Path` per Verbatim's default. Worth verifying empirically during implementation.

### S8. `path = with pkgs; [ isync cyrus-sasl-xoauth2 ]` may not be enough for SASL plugin discovery

U3's "Approach" claims "the systemd `path` setting handles `LD_LIBRARY_PATH`-equivalent for the unit." This is wrong: systemd's `Environment.PATH` (`path = [...]` in NixOS lingo) sets `$PATH`, not `$LD_LIBRARY_PATH` and not the SASL plugin search path. cyrus-sasl-xoauth2 is a `libsasl2` plugin loaded at runtime by libsasl, which scans `/usr/lib/sasl2/` or paths via `SASL_PATH`.

The kopia precedent doesn't help here (kopia doesn't use SASL plugins). On NixOS, the standard pattern is to point `SASL_PATH` at `${pkgs.cyrus-sasl-xoauth2}/lib/sasl2`. Without that, mbsync will say "SASL XOAUTH2 not available" at runtime even though the plugin is in the closure.

The plan's risk row mentions this in passing ("verify in U3 with `mbsync -V` listing XOAUTH2") but the proposed mitigation (`path = ...`) won't actually fix it.

**Fix:** in U3, set `serviceConfig.Environment = "SASL_PATH=${pkgs.cyrus-sasl-xoauth2}/lib/sasl2"` (or similar). Reference: nixpkgs has done this for other XOAUTH2-using services; check `pkgs.isync`'s test suite or the [cyrus-sasl-xoauth2 README](https://github.com/moriyoshi/cyrus-sasl-xoauth2). The plan-attached probe v2 script bypassed mbsync entirely (raw IMAP), so didn't exercise this.

### S9. U7c sequencing is fine but worth restating

The instructions ask to verify U7c fires *after* U8's 14-day green window. Plan U8 step 5 says: "U7c dedupe (run `maildir-deduplicate` against `o365.archive/` + live `o365/` if the user wants the historical archive merged into the live tree; or keep them separate forever, which is also fine and arguably safer)."

U7's "Dependencies" line says: "(independent of U1-U5; can be done before or after the live module is deployed, but the dedupe step in U7c happens after U8's parallel-run)." Consistent with U8 step 5. Good.

But the structural mismatch in C3 means U7c's dedup will not actually merge folders — it would only deduplicate Message-IDs across two parallel Maildir trees. Once C3 is fixed, U7c's dedup becomes meaningful.

## Nits

- **Monitoring noise math is correct.** 60s × 10 retries = 600s = 10min before page; 240 heartbeats × 60s = 4h re-page. The plan's `expectedValue = "<600"` even encodes the same 10-minute threshold (matching maxretries × interval). When you fix C1 to use boolean, keep the *server-side* threshold at 600s so the page-after-10-minutes semantics is preserved.
- **Bootstrap eventual-consistency callout is adequate but could be stronger.** U6's wording ("the very first `mailarchive-work.service` run may show `AUTHENTICATE failed` in journalctl — wait 5 minutes and let the timer fire again") is fine for a calm reader. For an anxious reader at midnight, consider adding "this is *expected* and not a failure of the bootstrap; do not re-run the bootstrap, just wait 5 minutes." Minor.
- **`runAsRoot` is appropriately omitted.** kopia.nix has `runAsRoot` because kopia accesses NFS paths with restrictive perms; mailarchive writes its own Maildir owned by the `mailarchive` user, so `runAsRoot` would be inappropriate. Plan correctly skips it. Good — well calibrated.
- **R-ID traceability is decent but spotty.** R1-R9 map cleanly to U1-U9 with cross-refs. But R6's wording "fetcher hasn't successfully synced within ~10 minutes" is the *threshold*, not the *retry-count math*. A future reader may confuse "10 minutes" (R6) with "10 retries" (rule). Fine as written but worth a one-line clarification: "10 minutes of staleness comes from server-side threshold + the fact that maxretries × interval also ≈ 10 min."
- **`docs/runbooks/` is a new directory.** No existing runbooks per `find docs/runbooks -type f` (didn't run, but the plan says "if any exist; otherwise model on the docs/wiki/services/ doc style"). Worth choosing one location consistently — recommend `docs/wiki/services/mailarchive.md` instead, since the wiki convention already covers "research findings, architectural decisions, … operational knowledge" per CLAUDE.md. A separate `docs/runbooks/` tree fragments where institutional knowledge lives.
- **Test scenarios for U6/U9 ("none — documentation artifact") are correctly justified** (those units produce only docs). U1-U5, U7 all have specific scenarios. Good calibration.
- **U2 "no automated tests" is correct** — the probe v2 already validated the chain end-to-end. Good calibration.
- **Helper script: `pkgs.writers.writePython3Bin "oauth2-helper" {libraries = [];}` works** — confirmed pattern via `podcast.nix:14-20`. Stdlib-only is correct: the probe v2 script (~120 lines) was stdlib-only.
- **`maildir-deduplicate` packaging.** Easy check: it's available as `pkgs.python3Packages.maildir-deduplicate` in nixpkgs unstable. Not worth deferring; just bake it into U7c.
- **`Mailstore-export/` staging cleanup in U8 step 6.** Fine, one line. Mention which path explicitly so a future reader doesn't grep blind: it's whatever U7a wrote ("`\\doc2\share\mailstore-export\` or any path reachable from doc2") — pick one canonical path in U7a and reference it in U8.

## Strengths Worth Preserving

- **Origin coverage is solid.** Every Requirement (R1-R9), Open Question, and Risk in the requirements/research/probe trio is addressed by an Implementation Unit. The probe pivot to Architecture 1 is internalised; DavMail rejection is reasoned from the probe, not just asserted. Good chain of custody.
- **kopia.nix mirroring is the right call and is mostly correctly done.** Submodule shape, sops dotenv per-instance, NFS watchdog, monitoring with `homelab.monitoring.monitors`, mount dependency wiring (`mountDepsFor` analogue), per-instance systemd timers via `lib.mapAttrs'` — all correct and scoped right. The plan correctly omits `runAsRoot` (mailarchive is single-user, owns its own data) and doesn't blindly copy the kopia verify-script pattern (which would be inappropriate). Good restraint.
- **restartTriggers omitted.** Correct: mailarchive doesn't have a DB container, so the `restartTriggers` rule doesn't apply. Plan correctly skips.
- **Monitoring noise discipline honoured.** `interval = 60`, `maxretries = 10`, `retryInterval = 60`, `resendInterval = 240` matches the rule exactly. The math checks out.
- **DNS-first networking respected.** No hardcoded LAN IPs in module options or runtime config (the localhost monitor URL is the right exception per the rule, since it's the same-host loopback case, not a fleet IP).
- **Sops layout correct.** `secrets/hosts/doc2/mailarchive-<account>.env` is the canonical `homelab.secrets.sopsFile` host path (verified `modules/nixos/common/secrets.nix:35`). The plan got this right.
- **Service hierarchy correct.** mbsync and cyrus-sasl-xoauth2 are nixpkgs packages with no upstream module → custom systemd unit (Tier 2 per `.claude/rules/nixos-service-modules.md`). Plan correctly avoids OCI containers (Tier 3). DavMail's rejection is well-reasoned from the probe.
- **Deployment pattern documented.** U8 step 3 calls out the `--target-host` prohibition correctly and uses the `git push + ssh + nixos-rebuild --refresh` pattern from CLAUDE.md.
- **Parallel-run safety net.** 14 days of green monitors before VM 102 destruction, then another week with VM 102 stopped before destroy — that's an appropriately paranoid cadence for a backup-of-record.
- **`Expunge None` semantics articulated.** The plan correctly identifies this as the deletion-resistance lever and tests for it in U3 ("Integration: deleting a message from O365 via OWA after it's been archived leaves the Maildir copy intact").

## Open Questions for the Author

1. **What happens to the existing Thunderbird IMAP fetch on the Win VM during the 14-day parallel run?** If both the Win VM Thunderbird *and* the new mailarchive on doc2 have IMAP IDLE / polling sessions open against O365 with the same account, will Microsoft's per-account session limits cause one to fail? Worth probing once before parallel-run begins. Likely fine (multiple concurrent IMAP sessions are normal) but unproven.

2. **Does the user actually want O365 sent items archived?** Implicit in the plan is that "archive everything." Sent items are typically the most valuable historical record (the user's outbound prose), but the plan doesn't enumerate folder selection. Worth confirming with a 1-line checklist in U6's runbook: "INBOX, Sent Items, Archive, [other folders]?" Otherwise the user may not notice missing folders for months.

3. **Is the 11 GB MailStore archive Gmail-only, O365-only, or mixed?** The plan assumes "11 GB MailStore archive" can be partitioned to `o365.archive/` and `gmail.archive/`. MailStore Home stores everything in one repository by archive profile; if the user has multiple profiles, partitioning is straightforward — if it's one mixed profile, the EML export tree's per-folder hierarchy needs to be inspected before deciding the target tree. U7a should explicitly capture how the archive was structured.

4. **Will Kopia notice the new ~11 GB tree all at once?** When U7b lands the migrated archive into `/mnt/data/Life/Andy/Email/o365.archive/`, the next Kopia snapshot will see ~11 GB of new files. The plan flags this as "acceptable" in Risks but doesn't reason about Kopia's chunk-dedup behaviour. EMLs are very dedup-friendly (RFC822 has lots of common header structure) but the bandwidth/wall-time hit on the *first* snapshot run could be noticeable. Worth a sentence on whether to throttle or run off-hours.

5. **Does this plan introduce a new dependency on cyrus-sasl-xoauth2 0.2 in nixpkgs being stable?** The research doc dates the package version. If the package has a known regression in current `nixpkgs unstable` (the project's pin), the plan won't surface it. A pre-build sanity check via mcp-nixos `nix info isync` and `nix info cyrus-sasl-xoauth2` in U3 implementation would catch this.

6. **The plan's cleanup of `/tmp/davmail-probe/` and `/tmp/mailprobe/` is described in the probe doc but not echoed in this plan.** If those probe artifacts haven't been cleaned up by the time U8 step 5 runs, they may interfere with new probe runs during token rotation. Probably fine but worth a one-line "verify probe artifacts are gone" in the runbook.
