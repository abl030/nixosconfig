---
name: triage-overnight
description: Pull overnight failure diagnoses (claude -p output) for nightly nixos-upgrade and rolling-flake-update from Loki and summarise them. Use when the user says "triage last night", "triage overnight", "what failed overnight", "what broke last night", or similar morning-ritual phrasing.
version: 1.0.0
---

# Triage Overnight Failures

Two nightly jobs run claude -p on failure and emit a structured diagnosis to journal → Loki:

1. **`rolling-flake-update.service`** on `proxmox-vm` (doc1) at 22:15 AWST (14:15 UTC). Updates flake inputs, builds, pushes if green. On failure → claude triage → Gotify.
2. **`nixos-upgrade.service`** on every NixOS host between 01:00 and 02:00 local. Pulls the latest flake and rebuilds. On failure → `nixos-upgrade-diagnose.service` runs claude -p → Gotify.

Both diagnoses land in journal as plain text and ship to Loki. Your job in the morning is to pull them out, summarise, and propose fixes.

## Step 1: Query Loki for failures, last 24h, all hosts

Run all three queries in parallel. Time format: RFC3339, anchor ~24h before now.

**Critical:** the diagnose unit only fires if the *currently-active* system generation has it. A host whose rebuild has failed since the diagnose feature landed will never activate it — its failures show up under `nixos-upgrade.service` only, and the Gotify ping comes from the inline `notify_failure` fallback. Always query both unit names.

```bash
START=$(date -u -d '24 hours ago' '+%Y-%m-%dT%H:%M:%SZ')
END=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# A. nixos-upgrade-diagnose: claude triage (when the diagnose unit fires)
curl -sG 'https://loki.ablz.au/loki/api/v1/query_range' \
  --data-urlencode "query={unit=\"nixos-upgrade-diagnose.service\"}" \
  --data-urlencode "start=$START" --data-urlencode "end=$END" \
  --data-urlencode 'limit=2000' --data-urlencode 'direction=forward' \
  | jq -r '.data.result[] | "=== \(.stream.host // "?") ===", (.values[] | .[1])'

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
  | jq -r '.values[] | .[1]'
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

## Step 2: Summarise to the user

For each host/unit that fired, report:

- **Host + unit + time** (parse from the journal line timestamp)
- **Classification + summary** (claude's text, verbatim)
- **Proposed fix** (claude's text, verbatim)
- **Your verification step**: if `actionable`, run `git log --since='36 hours ago' --oneline` to confirm the commit claude is blaming is real, and read the named file at the proposed line.

If nothing fired in the last 24h: report "no overnight failures, both jobs green" and stop.

## Step 3: Offer to fix

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

## Configuration knobs (for reference)

- Fleet-wide default: `modules/nixos/profiles/base.nix` → `homelab.update.diagnose.enable = lib.mkDefault true`.
- Per-host override: `homelab.update.diagnose.enable = false` in `hosts/<h>/configuration.nix`.
- Bootstrap (one-time per host, required for non-fallback path):
  ```
  ssh <host> 'sudo -u <user> --login claude'
  ```
  Follow the OAuth flow; `~/.claude.json` persists across reboots.
