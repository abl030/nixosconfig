---
name: triage-overnight
description: Pull overnight failure diagnoses (claude -p output) for nightly nixos-upgrade and rolling-flake-update from Loki AND audit recent Gotify pings on doc2, then summarise. Use when the user says "triage last night", "triage overnight", "what failed overnight", "what broke last night", or similar morning-ritual phrasing.
version: 1.3.0
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

Three things to check every morning:

1. **`rolling-flake-update.service`** on `proxmox-vm` (doc1) at 22:15 AWST (14:15 UTC). Updates flake inputs, builds, pushes if green. On failure → claude triage → Gotify.
2. **`nixos-upgrade.service`** on every NixOS host between 01:00 and 02:00 local. Pulls the latest flake and rebuilds. On failure → `nixos-upgrade-diagnose.service` runs claude -p → Gotify.
3. **Gotify pings** on doc2. Picks up the long tail — watchdogs, alert-bridge, Grafana alerts, Domain-Monitor, Kuma — that isn't a nightly job but did wake the phone overnight.

The nightly-job diagnoses land in journal as plain text and ship to Loki. Gotify pings are stored on doc2 in sqlite. Your job in the morning is to pull them all out, summarise, and propose fixes.

## Step 1: Query Loki for failures, last 12h, all hosts

Run all three queries in parallel. Time format: RFC3339, anchor 12h before now.

The 12h window covers the rolling-flake-update at 22:15 AWST and every host's nixos-upgrade run between 01:00–02:00 local with a little slack on either side, without bleeding into the *previous* night's run (a 24h window run in the morning will overlap both nights and you cannot tell them apart from log content alone). If you're triaging late in the day, widen the window deliberately.

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

Run **in parallel** with Step 1. The two channels (Loki nightly diagnoses + Gotify pings) overlap but don't fully duplicate — alert-bridge alerts, Kuma flaps, watchdogs, Domain-Monitor, HA notifications only show up in Gotify. Always pull both.

```bash
ssh doc2 "sudo sqlite3 /mnt/virtio/gotify/data/gotify.db \
  \"SELECT id, application_id, datetime(date) AS d, priority, substr(title,1,80) \
    FROM messages WHERE date >= datetime('now', '-30 hours') ORDER BY date DESC;\""
```

App ids (cache locally if you want; they're stable):

```
1=Proxmox  2=Tower  3=Domain-Monitor  4=Uptime-Kuma  5=KopiaMum
6=Youtube Playlist  7=claude  8=HA
```

For each ping with `priority >= 5` (warning+), pull the full message:

```bash
ssh doc2 "sudo sqlite3 -line /mnt/virtio/gotify/data/gotify.db \
  \"SELECT id, title, message FROM messages WHERE id IN (X, Y, Z);\""
```

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

If nothing fired in the 12h window and Gotify is just HA/Kuma noise: report "no overnight failures, both jobs green, Gotify clean" and stop.

## Step 3: Offer to fix

After the summary, ask in plain chat: *"Want to walk through them one by one?"* When the user says `yes`, take the first item, dig into it, propose a fix, **wait for explicit approval**, then move to the next. One issue per turn. Do **not** use structured-question UIs.

For each `actionable` entry, present the diff that would implement claude's suggested fix and ask the user to approve. Do **not** auto-apply — the overnight diagnosis is advisory, the morning fix is intentional.

For `transient` entries: report and move on (next nightly run will retry).

For `upstream` entries: open or update a GitHub issue (`gh issue list --search 'in:title <package>'` first to dedupe) noting the failure and that we're waiting for nixpkgs.

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
