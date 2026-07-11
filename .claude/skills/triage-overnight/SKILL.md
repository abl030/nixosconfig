---
name: triage-overnight
description: Pull overnight failure diagnoses (claude -p output) for nightly nixos-upgrade and rolling-flake-update from Loki, audit recent Gotify pings on doc2, AND review any auto-generated RCA fix PRs on Forgejo, then summarise with a merge recommendation per PR. Use when the user says "triage last night", "triage overnight", "what failed overnight", "what broke last night", or similar morning-ritual phrasing.
version: 1.4.0
---

# Triage Overnight Failures

## Framing — read before triaging

The user is **drowning in alerts and has alert fatigue**. The observability stack (alert-bridge, watchdogs, Kuma, Gotify, the nightly diagnose pipeline) is **new and being actively tweaked** — false positives, stale alert routing, duplicate pings across channels, and noisy thresholds are all expected and being iterated on. Many "overnight failures" turn out to be the alerting itself being wrong, not the underlying service.

Two consequences for how you triage:

1. **Cluster aggressively, don't restate.** Multiple pings about the same underlying cause = one finding, not five. The Gotify ping titles are alert-bridge's pattern-match guesses; they often misframe the real issue. **Always trace to the journal/unit log on the source host before reporting.**
2. **Flag self-inflicted / mis-tuned alerts explicitly.** If a ping fires from stale config, a recent migration the watchdog wasn't updated for, or a threshold that's wrong — say so. That's a meta-finding worth more than another "investigate X" recommendation, because fixing the alert wiring reduces tomorrow's noise.

## Reporting pattern

After investigating, **deliver a single summary message** with the punch list (one bullet per cluster, not per ping). End the summary with a question like *"Want to walk through them one by one?"* — and let the user reply in plain chat with `yes` / `no` / a specific item. **Do not use AskUserQuestion or any structured-question UI** — the user dislikes it. Keep it conversational.

When they say `yes`, the flow is **decide-all-then-edit-all**:

1. Take **one** issue at a time. Describe what's happening and the options in plain chat. Get a decision. **Do not write code or edit files yet** — just capture the decision.
2. Move to the next issue. Repeat.
3. Once all decisions are made, do the edits in one batch, then commit + push once.

This keeps the chat conversational while the user is deciding (often while driving / on voice mode), and bundles the mechanical work at the end. Don't ask "want me to commit?" after each item — only after the last decision.

## What to check

Four things to check every morning:

1. **`rolling-flake-update.service`** on `proxmox-vm` (doc1) at 23:00 AWST (15:00 UTC). Updates flake inputs, builds, pushes if green. On failure → claude triage → Gotify.
2. **`nixos-upgrade.service`** on every NixOS host between 01:00 and 02:00 local. Pulls the latest flake and rebuilds. On failure → `nixos-upgrade-diagnose.service` runs claude -p → Gotify.
3. **Gotify pings** on doc2. Picks up the long tail — watchdogs, alert-bridge, Grafana alerts, Domain-Monitor, Kuma — that isn't a nightly job but did wake the phone overnight.
4. **Auto-generated RCA fix PRs** on Forgejo. When an overnight alert's root cause has a mechanical fix, the RCA pipeline opens a PR with the patch (see Step 1c). These are candidate fixes already written for you — your job is to **review each and recommend merge / hold / changes**, then (on the user's go) merge and deploy.

The nightly-job diagnoses land in journal as plain text and ship to Loki. Gotify pings are stored on doc2 in sqlite. RCA fix PRs live on Forgejo. Your job in the morning is to pull them all out, summarise, review the PRs, and propose fixes.

## Step 1: Query Loki for failures, last 12h, all hosts

Run all three queries in parallel. Time format: RFC3339, anchor 12h before now.

The 12h window covers the rolling-flake-update at 23:00 AWST and every host's nixos-upgrade run between 01:00–02:00 local with a little slack on either side, without bleeding into the *previous* night's run (a 24h window run in the morning will overlap both nights and you cannot tell them apart from log content alone). If you're triaging late in the day, widen the window deliberately.

**Critical:** the diagnose unit only fires if the *currently-active* system generation has it. A host whose rebuild has failed since the diagnose feature landed will never activate it — its failures show up under `nixos-upgrade.service` only, and the Gotify ping comes from the inline `notify_failure` fallback. Always query both unit names.

**Always include the Loki timestamp** (`[\((.[0]|tonumber)/1e9|todate)]`) in every jq pipeline. The diagnose unit's output is multiline markdown with no embedded times — without the Loki timestamp prefix, an entry from 9h ago and one from 30h ago look identical.

```bash
START=$(date -u -d '12 hours ago' '+%Y-%m-%dT%H:%M:%SZ')
END=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# A. nixos-upgrade-diagnose: claude triage (when the diagnose unit fires)
curl -sG 'https://loki.ablz.au/loki/api/v1/query_range' \
  --data-urlencode "query={unit=\"nixos-upgrade-diagnose.service\"}" \
  --data-urlencode "start=$START" --data-urlencode "end=$END" \
  --data-urlencode 'limit=2000' --data-urlencode 'direction=forward' \
  | jq -r '.data.result[] | "=== \(.stream.host // "?") ===", (.values[] | "[\((.[0]|tonumber)/1e9|todate)] \(.[1])")'

# B. nixos-upgrade FAILURES — catches hosts that haven't activated the diagnose unit yet
curl -sG 'https://loki.ablz.au/loki/api/v1/query_range' \
  --data-urlencode 'query={unit="nixos-upgrade.service"} |~ "FAILURE|exit-code|error:"' \
  --data-urlencode "start=$START" --data-urlencode "end=$END" \
  --data-urlencode 'limit=500' --data-urlencode 'direction=forward' \
  | jq -r '.data.result[] | "=== \(.stream.host // "?") ===", (.values[] | "[\((.[0]|tonumber)/1e9|todate)] \(.[1])")'

# C. rolling-flake-update on doc1 (proxmox-vm)
curl -sG 'https://loki.ablz.au/loki/api/v1/query_range' \
  --data-urlencode "query={unit=\"rolling-flake-update.service\", host=\"proxmox-vm\"}" \
  --data-urlencode "start=$START" --data-urlencode "end=$END" \
  --data-urlencode 'limit=2000' --data-urlencode 'direction=forward' \
  | jq -r '.data.result[].values[] | "[\((.[0]|tonumber)/1e9|todate)] \(.[1])"'
```

For any host that shows up in query B but not A, fetch the full unit log for context:

```bash
curl -sG 'https://loki.ablz.au/loki/api/v1/query_range' \
  --data-urlencode 'query={host="<h>", unit="nixos-upgrade.service"}' \
  --data-urlencode "start=$START" --data-urlencode "end=$END" \
  --data-urlencode 'limit=500' --data-urlencode 'direction=forward' \
  | jq -r '.data.result[].values[] | "[\((.[0]|tonumber)/1e9|todate)] \(.[1])"' | tail -50
```

Then classify manually using the same three-bucket scheme (upstream / actionable / transient).

Both diagnoses follow the same three-label format produced by the system prompt:

```
**Classification**: upstream | actionable | transient
**Summary**: 1-2 sentences ...
**Fix**: file:line + change, or "wait for nixpkgs", or "retry on next run"
```

## Step 1b: Audit Gotify pings (last ~30h)

Run **in parallel** with Step 1. The two channels (Loki nightly diagnoses + Gotify pings) overlap but don't fully duplicate.

Read the Gotify pings via the **`gotify-triage`** wrapper on doc2. doc2 now has a
deliberate full `NOPASSWD` host override, but this scoped fixed-query wrapper is
still the least-privilege interface: it cannot run arbitrary SQL or shell. Do not
replace it with `sudo sqlite3`, whose `.shell`/`.system` dot-commands provide a
root shell. Defined in
`modules/nixos/services/gotify-server.nix`.

```bash
ssh doc2 "sudo gotify-triage recent 30"
```

App ids (cache locally if you want; they're stable):

```
1=Proxmox  2=Tower  3=Domain-Monitor  4=Uptime-Kuma  5=KopiaMum
6=Youtube Playlist  7=claude  8=HA
```

For each ping with `priority >= 5` (warning+), pull the full message body:

```bash
ssh doc2 "sudo gotify-triage msg 123,124,125"
```

**Cross-check with Loki** — it's the source of truth for anything that logs there,
and lets you trace a ping's *real* cause rather than its (often misleading) title
(`$START`/`$END` are set in Step 1):

```bash
# Service / NFS watchdog trips (the "NFS watchdog tripped" pages):
curl -sG 'https://loki.ablz.au/loki/api/v1/query_range' \
  --data-urlencode 'query={unit=~".+-nfs-watchdog\\.service"} |~ "(?i)stale|recover|restart|fail"' \
  --data-urlencode "start=$START" --data-urlencode "end=$END" \
  --data-urlencode 'limit=500' --data-urlencode 'direction=forward' \
  | jq -r '.data.result[] | "=== \(.stream.host)/\(.stream.unit) ===", (.values[] | "[\((.[0]|tonumber)/1e9|todate)] \(.[1])")'
# A watchdog "recovering" line names the failed service — query THAT unit in the
# ±5min window for the real cause (e.g. mailarchive failing on transient Gmail IMAP, not NFS).
#
# alert-bridge (app 7 = claude) rules fire off Loki errorPatterns; the Grafana
# alert rules that page live in grafana.service logs:
#   {host="doc2", unit="grafana.service"} |~ "fromAlert=true"
```

Pings with no Loki trail (Kuma flaps → `https://kuma.ablz.au`; Domain-Monitor app 3
→ `dig` / `openssl s_client`; Proxmox app 1; Tower app 2; KopiaMum app 5) are exactly
what `gotify-triage` is for — Loki won't have them.

**Skip-list (low signal, don't bother diagnosing):**
- App 8 (HA) — garage door, doorbell, presence pings. Not infra.
- Priority < 5 — informational; ignore unless the user explicitly asks.
- Duplicate Kuma flaps within the same 5-minute window — count, don't list.

For everything else, cross-reference with Loki / journalctl to find the actual root cause. The Gotify message title is alert-bridge's pattern-matched summary, often correct in spirit but misleading in framing (e.g. an alert titled "NFS watchdog tripped" may actually reflect a config error that took the service down, not an NFS blip). **Always trace each ping back to the underlying journal lines on the source host before reporting.**

Common cross-reference patterns:
- App 7 (claude) titled `[critical|warning] <service> ...` → alert-bridge rule, defined in `modules/nixos/services/alert-bridge.nix`. Query Loki for the service's unit log in the ±5 min window around the ping.
- App 4 (Uptime-Kuma) → query Loki for the matching service over Tailscale / nginx access logs; check `https://kuma.ablz.au` for the monitor's down/up timing if needed.
- App 3 (Domain-Monitor) → DNS / cert expiry; check the domain in question with `dig` / `openssl s_client`.
- App 7 titled `rolling flake update failed` → already covered by Step 1 query C; don't double-report.
- App 7 titled `nixos-upgrade failed on <host>` → already covered by Step 1 query A; don't double-report.

If everything is HA garage doors and Kuma flaps → "Gotify clean overnight (X HA pings, no infra alerts)" and move on.

See `docs/wiki/services/gotify.md` for the sqlite schema, why we don't use the HTTP API (no client token in repo), and the full reading workflow.

## Step 1c: Collect + review auto-generated RCA fix PRs (Forgejo)

Run **in parallel** with Steps 1 and 1b. Overnight, a critical alert doesn't just
get a Gotify RCA — when the root cause has a mechanical fix, the RCA pipeline
**opens a Forgejo PR** with the patch. Flow: `alert-bridge` (doc2) forwards the
enriched alert context to **Hermes** via webhook (`homelab.services.alert-bridge.rcaWebhookUrl`);
Hermes runs the LLM RCA, opens a PR authored by `nixbot`, and posts the RCA back to
Gotify with a `PR:` link. So a morning cluster often arrives with a candidate fix
already written — your job is to **review it and recommend merge / hold / changes**,
not to re-derive the fix from scratch.

Find them two ways (they agree):

```bash
TOKEN=$(cat /run/secrets/forgejo/nixbot-token)   # doc1 only; 0400 abl030
# 1. RCA Gotify bodies carry the link — grep the Step 1b `gotify-triage msg` output
#    for "PR: https://git.ablz.au/.../pulls/<N>".
# 2. List open PRs directly (authoritative):
curl -sG "https://git.ablz.au/api/v1/repos/abl030/nixosconfig/pulls" \
  -H "Authorization: token $TOKEN" \
  --data-urlencode "state=open" --data-urlencode "limit=20" \
  | jq -r '.[] | "#\(.number) [\(.user.login)] \(.title)\n  \(.head.ref) -> \(.base.ref) | mergeable=\(.mergeable) draft=\(.draft) | updated \(.updated_at)"'
```

Focus on PRs authored by `nixbot` and updated inside the triage window. Older open
PRs are usually human WIP — mention them once, don't review them unless asked.

**Review each candidate PR — do NOT trust the diff alone:**

```bash
curl -sG "https://git.ablz.au/api/v1/repos/abl030/nixosconfig/pulls/<N>.diff" \
  -H "Authorization: token $TOKEN"
git fetch origin "refs/pull/<N>/head:pr<N>"      # local ref to inspect + sign-check
git log -1 --format='%G? %an | %s' pr<N>          # MUST be G — see Step 4 caveat
```

Verify **five** things before recommending merge:

1. **Root cause is real.** Confirm the RCA's claimed cause against the *live* module
   file (not just the diff hunk) — e.g. `hardenOptions` genuinely lacks the mount
   the fix adds; the Kuma window math (`intervalSecs + maxretries * retryInterval`,
   defaults `retryInterval=60`/`maxretries=10` in `monitoring_sync.nix`) really
   produces the flap the RCA describes. Trace it like any Step 1b ping.
2. **The fix addresses it** and is the minimal change (no scope creep).
3. **Signed by a hosts.nix key** (`%G?` → `G`). An unsigned PR commit CANNOT be
   deployed — signed deploys are enforced fleet-wide, so merging it would loud-fail
   the next `nixos-upgrade` / `fleet-deploy`.
4. **Least-privilege / blast-radius audit** (CLAUDE.md rule): does it touch auth,
   secrets, image trust, network exposure, file ownership, or shared resources? A
   container flag like `--tmpfs=/run` should stay `nosuid,nodev`, size-capped, and
   add no new caps.
5. **Is the service still down?** Re-probe live (HTTP / Kuma). A still-down service
   makes its PR urgent (deploy now); a self-recovered flap makes its PR routine.

## Step 2: Summarise to the user

For each host/unit that fired (Loki, Step 1), report:

- **Host + unit + time** (parse from the journal line timestamp)
- **Classification + summary** (claude's text, verbatim)
- **Proposed fix** (claude's text, verbatim)
- **Your verification step**: if `actionable`, run `git log --since='36 hours ago' --oneline` to confirm the commit claude is blaming is real, and read the named file at the proposed line.

For each Gotify ping (Step 1b) that you didn't skip-list:

- **App + time + priority + title** (one line)
- **Your traced root cause** — not just the ping title. Cross-reference the unit log in the ±5min window, check whether a recent commit changed the relevant module, and state the real cause. If the alert title is misleading (e.g. "NFS watchdog tripped" when the actual cause was a config error), say so explicitly.
- **Current state** — did it self-recover, is the service active now, was it the watchdog's job to recover it.

For each auto-generated RCA PR (Step 1c):

- **PR # + title + author + affected host/service** (one line).
- **Your review verdict** — `merge` / `hold` / `needs-changes`, with the one-line reason (root cause confirmed against live code? fix minimal? signed? least-privilege ok?).
- **Urgency** — is the service still down (deploy now) or did it self-recover (routine, land it to stop the recurrence).

If nothing fired in the 12h window and Gotify is just HA/Kuma noise: report "no overnight failures, both jobs green, Gotify clean" and stop.

## Step 3: Offer to fix

After the summary, ask in plain chat: *"Want to walk through them one by one?"* When the user says `yes`, take the first item, dig into it, propose a fix, **wait for explicit approval**, then move to the next. One issue per turn. Do **not** use structured-question UIs. RCA fix PRs (Step 1c) are walked through here too — but you *review and merge* them (Step 4), you don't hand-edit them.

For each `actionable` entry, present the diff that would implement claude's suggested fix and ask the user to approve. Do **not** auto-apply — the overnight diagnosis is advisory, the morning fix is intentional. Same rule for RCA PRs: present the verdict, wait for `go`, then merge per Step 4.

For `transient` entries: report and move on (next nightly run will retry).

For `upstream` entries: open or update a GitHub issue (`gh issue list --search 'in:title <package>'` first to dedupe) noting the failure and that we're waiting for nixpkgs.

## Step 4: Merge & deploy approved RCA PRs

Only after the user says `go` on a specific PR (Step 3's one-at-a-time approval
applies — the overnight fix is advisory, the morning merge is intentional).

**CRITICAL — merge signed, never via the Forgejo "Merge" button.** Forgejo's
server-side merge creates an *unsigned* merge commit, which loud-fails signed-deploy
enforcement on every host's nightly `nixos-upgrade`. Merge locally on doc1 so every
commit landing on master stays SSH-signed by a `hosts.nix` key:

```bash
# work from a clean doc1 checkout on master, fast-forwarded to origin/master first
git fetch origin && git checkout master && git merge --ff-only origin/master

# If the PR branch's parent IS the current master tip → fast-forward: keeps the
# original signed SHA and auto-closes the PR.
git merge --ff-only pr<N>

# Otherwise (master moved, or landing several PRs at once) → cherry-pick onto
# master; doc1 re-signs with abl030's key, so the SHA changes (close the PR
# manually after). cherry-pick preserves author + message.
git cherry-pick pr<N> [pr<M> ...]
git log -1 --format='%G?'                  # confirm G BEFORE pushing

# Push to master with the nixbot token header (doc1 has no https cred otherwise):
export GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0="http.https://git.ablz.au.extraHeader" \
  GIT_CONFIG_VALUE_0="Authorization: token $(cat /run/secrets/forgejo/nixbot-token)"
git push origin HEAD:master
```

If a cherry-pick changed the SHA the PR won't auto-close — close it via API with a
pointer to the landed commit (PRs are issues in Forgejo's REST API):

```bash
curl -s -X POST "https://git.ablz.au/api/v1/repos/abl030/nixosconfig/issues/<N>/comments" \
  -H "Authorization: token $TOKEN" -H 'Content-Type: application/json' \
  -d '{"body":"Merged to master as <sha> (signed), deployed to <host>."}'
curl -s -X PATCH "https://git.ablz.au/api/v1/repos/abl030/nixosconfig/issues/<N>" \
  -H "Authorization: token $TOKEN" -H 'Content-Type: application/json' \
  -d '{"state":"closed"}'
```

**Deploy the affected host.** Find it (`grep -rln '<svc>.enable' hosts/`), then from
doc1 deploy the locked sibling with `fleet-deploy <host>` (async, no live build
stream). doc1 itself: `sudo fleet-update`. See CLAUDE.md deploy rules — never
`--target-host`, never deploy from the `github:` mirror.

**Verify** (fleet-deploy is async — you MUST confirm after it settles):
- Re-probe the service with the same HTTP/Kuma check that fired — DOWN → UP.
- Confirm the host built the new rev (deploy log / freshness / `nixos-rebuild
  list-generations`) and the service unit is active.
- For a container fix, confirm the container was recreated with the new flag
  (e.g. `ssh <host> "sudo podman inspect <c> --format '{{.HostConfig.Tmpfs}}'"`).

## Failure modes to recognise

- **`claude triage unavailable`** appears in the Loki output → the host has not been bootstrapped (no `~/.claude.json` for the service user yet), or the claude OAuth token expired, or the network was down at triage time. The raw log tail is included instead. Tell the user the host needs a one-time `sudo -u <user> --login claude` bootstrap if the message has fired more than once.
- **No Loki results for a host that you know failed** → the diagnose unit itself failed to start. Query `{host="<h>"} |~ "nixos-upgrade-diagnose"` to find the systemd-level error.
- **rolling-flake-update fires `transient` repeatedly** → flake-update is rate-limited or hitting upstream throttling. Check the actual `rolling_flake_update.sh` output, not just claude's summary.
- **`epimetheus` and `framework` are usually asleep overnight.** SSH timeouts to those hosts during morning triage are expected — they suspend after idle and don't run the nightly timer until they're woken. If a host hasn't shipped journal lines since yesterday evening, treat it as "didn't run" rather than "failed silently". Don't block triage on reaching them; use Loki labels (`host="<h>"`) to confirm whether they ingested anything overnight before chasing SSH. **To wake epi for a manual rebuild or live debug, send a WOL packet from doc1 directly — `wakeonlan 18:c0:4d:65:86:e8` works fine from any LAN host (no need to hop through caddy). Give it ~20s, then SSH in.**
- **Persistent timer catchup race.** When a sleeping host wakes after missing its scheduled nightly window, `Persistent=true` fires `nixos-upgrade.timer` immediately on resume. The "wait for DNS" gate (`autoupdate/update.nix`) passes as soon as resolv.conf has servers — typically within seconds — but outbound to `api.github.com` can still time out (curl 28 / "Timeout was reached") if the upstream link / Tailscale / DERP hasn't fully reconverged. Classify as **transient**; will succeed on next run once the host has been up for a while. Don't chase a fix for the GitHub fetch — the problem is the timer firing too eagerly post-resume, not the fetcher.
- **Pre-diagnose generation.** Until a host successfully rebuilds *after* the diagnose feature commit lands, its failures will run the legacy inline `notify_failure` path: raw log tail to Gotify, no diagnose unit, nothing under `unit="nixos-upgrade-diagnose.service"` in Loki. You'll only find them via query B (failures in `nixos-upgrade.service` itself). Once the host has one successful rebuild, the new generation activates and future failures route through the diagnose unit normally.
- **`[Diagnose] No failure log at /var/lib/nixos-upgrade/last-failure.log`** — pre-2026-05-25 this could mean the failure log was written but unreadable (mktemp 0600 → cp preserves perms → User=abl030 can't read). Fixed in `daa705d2`: now uses `install -m 0644`, distinguishes missing/unreadable explicitly, and falls back to `journalctl -u nixos-upgrade.service`. Check the diagnosis line for `source=<log_file|journalctl|perm-error>` — `perm-error` should never fire post-fix and indicates a regression in smartUpgrade.
- **Skip-list mid-fix iteration.** When a Gotify ping fires inside a 5-15min window of in-flight commits to the same module (`git log --since='30 minutes' --oneline` shows multiple commits to the cited file), it's almost certainly self-inflicted, not infra. Verify by checking the service is healthy *now*; the watchdog usually recovered it.

## Configuration knobs (for reference)

- Fleet-wide default: `modules/nixos/profiles/base.nix` → `homelab.update.diagnose.enable = lib.mkDefault true`.
- Per-host override: `homelab.update.diagnose.enable = false` in `hosts/<h>/configuration.nix`.
- Bootstrap (one-time per host, required for non-fallback path):
  ```
  ssh <host> 'sudo -u <user> --login claude'
  ```
  Follow the OAuth flow; `~/.claude.json` persists across reboots.
