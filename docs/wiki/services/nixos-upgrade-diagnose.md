# nixos-upgrade-diagnose

**Date researched:** 2026-05-15
**Status:** active, fleet-wide opt-in default
**Issue:** none yet (built reactively after the 2026-05-14 doc2 cratedigger hold-service failure)

## What it does

When the nightly `nixos-upgrade.service` fails on any NixOS host:

1. `smart-nixos-upgrade` (in `modules/nixos/autoupdate/update.nix`) copies the failure log to `/var/lib/nixos-upgrade/last-failure.log` and exits non-zero. **Does not** post to Gotify itself when `diagnose.enable = true` — the diagnose unit owns the notification.
2. systemd `OnFailure=` triggers `nixos-upgrade-diagnose.service`, which runs as the host's interactive user (`hostConfig.user`, usually `abl030`).
3. The diagnose script feeds a recent `git diff HEAD~1 HEAD` + the last 200 log lines into `claude -p --model haiku --allowedTools ""` with a tight system prompt asking for `Classification / Summary / Fix`.
4. The structured diagnosis is printed to stdout (journal → Loki) **and** posted to Gotify as the failure ping you'd otherwise have got.
5. If `claude` is unauthenticated, times out, or returns empty, the script falls back to the raw log tail in Gotify — exactly the pre-diagnose behaviour. No host is worse off than before.

The `triage-overnight` skill (`.claude/skills/triage-overnight/SKILL.md`) is the morning ritual: queries Loki for both this unit and `rolling-flake-update.service`, summarises diagnoses, proposes fixes.

## Bootstrap (one-time per host)

`claude` uses subscription auth via OAuth. The first run on a host needs to be interactive so the OAuth flow can write `~/.claude.json`:

```bash
ssh <host> 'sudo -u <user> --login claude'
```

Replace `<user>` with the host's `hostConfig.user` (usually `abl030`; `nixos` on wsl). Walk through the OAuth prompts in a browser, then exit. The token persists across reboots and through token refreshes. If it ever expires, the diagnose unit silently falls back to raw-log Gotify and you'll see `(claude triage unavailable, raw log tail follows)` at the top of the Gotify message — re-run the bootstrap to fix.

Hosts to bootstrap (everything with `homelab.update.enable = true`, which is the base default — i.e. everything except `sandbox`):

- proxmox-vm (doc1)
- doc2
- igpu
- epimetheus
- framework
- dev
- cache
- wsl (user is `nixos`, not `abl030`)

## Architecture notes

- **Why `--allowedTools ""`**: claude is a text oracle here, not an executor. It reads stdin, writes stdout. No bash, no edit, no web fetch — even if the model is convinced by an adversarial journal log, the worst-case output is a misleading diagnosis, not a privilege escalation.
- **Why User=abl030 (not a dedicated user)**: reuses the existing interactive login. Adding a `claude-autofix` system user would require either an API key (cost + secret surface) or a second OAuth login per host. The handoff is one-way (root writes log, abl030 reads it), so no privilege concentration.
- **Why haiku**: triage is bounded — 200 lines of log, 200 lines of diff, three labels of output. haiku is fast and cheap and the task is well within its capability. The rolling-flake-update wrapper uses the same model for the same reason.
- **Why `git log -1` + `git diff HEAD~1 HEAD`**: most overnight failures are caused by yesterday's flake bump or yesterday's commit. Feeding the diff makes claude's `Fix` field cite a real file/line ~80% of the time. Hosts without a local checkout get a "diff unavailable" stub and claude works from the log alone.

## Related

- `modules/nixos/ci/rolling-flake-update.nix` — the same pattern but for the doc1 nightly flake-update job. Predates this work; copied the triage shape from there.
- `.claude/skills/triage-overnight/SKILL.md` — morning ritual that surfaces these diagnoses.
- `modules/nixos/autoupdate/update.nix` — option `homelab.update.diagnose.enable`, defaults to `true` via `modules/nixos/profiles/base.nix`.

## When to revisit

- If a host fires `(claude triage unavailable…)` more than once → bootstrap that host.
- If diagnoses are systematically wrong → tune `diagnoseSystemPrompt` in `update.nix`.
- If we ever want to act on diagnoses (not just read them) → see the conversation history; we explicitly chose **not** to do this because the autofix path crosses our least-privilege rules.

## 2026-05-25 — diagnose was silently blind to activation-phase failures

**Symptom:** epi's `nixos-upgrade.service` failed at 01:18 AWST (avahi PID-file
race during activation, `switch-to-configuration` returned 4). `nixos-upgrade-diagnose.service`
fired on the `OnFailure=` trigger but its Loki line was just:

> `[Diagnose] No failure log at /var/lib/nixos-upgrade/last-failure.log; nothing to do.`

No claude triage, no Gotify ping, no idea anything was wrong until the next morning.

**Root cause:** `smartUpgrade` was writing the failure log with plain `cp` from
a `mktemp` source. mktemp creates files with mode `0600 root:root`, and `cp`
preserves the source mode — so the persisted log was unreadable by the diagnose
unit's `User=abl030`. The script's `[ -r "$log_file" ]` guard returned false,
and the misleading "No failure log" branch ran. **The file was there the whole
time, just unreadable.**

**Fix in `daa705d2`:**

1. Swap `cp` → `install -m 0644` in the smartUpgrade failure branch so the
   persisted log is world-readable.
2. Split the diagnose-script guard into three explicit branches: missing,
   present-but-unreadable (now loud + named), and OK.
3. Add a **`journalctl -u nixos-upgrade.service` fallback** for the missing
   branch. This covers cases where smartUpgrade exits before reaching the
   failure-write branch (e.g. `set -e` triggered earlier in the script).
4. Add `SupplementaryGroups=systemd-journal` to the diagnose unit so the
   journalctl fallback works under `User=` (which drops normal supplementary
   groups including `wheel`).
5. Tag the diagnosis line in Loki with `source=<log_file|journalctl|perm-error>`
   so we can tell at a glance which path fired.

**Look for in Loki:** `{unit="nixos-upgrade-diagnose.service"} |~ "source="`
gives you the route each diagnosis took. `source=perm-error` should now be
unreachable — if it ever fires, smartUpgrade regressed the mode again.
