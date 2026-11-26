---
name: alert-rca
description: "Use when homelab alerts need RCA. Diagnose read-only."
version: 1.0.6
metadata:
  hermes:
    tags: [homelab, alerting, rca, nixosconfig, pr]
---

# Alert RCA Skill

## When to Use

Use for a single alert or alert batch forwarded from the alert bridge. The
payload contains enriched context such as alert identity, severity, Loki lines,
and journal output. This workflow is unattended: investigate with available
evidence, never ask questions, and always deliver the verified RCA to Gotify.

## Goal

1. Read-only investigation to find root cause
2. If the root cause is a fixable nixosconfig issue → open a signed PR
3. Push the RCA summary (+ PR link if any) to Gotify
4. NEVER touch the running system — no deploys, no service restarts, no config changes on live hosts

## Investigation Steps

### 1. Parse the alert payload

The webhook delivers either a single enriched alert or a 10-minute RCA batch.
For batches, treat the whole batch as one incident unless the alert list clearly
contains unrelated failures. Key fields:
- `title` — alert title or batch title (e.g. "Alert batch: 50 alerts in 10m")
- `message` — enriched body with Loki lines / journal output, or a batch body
  containing multiple `--- alert N/M ...` sections
- `priority` — max/representative priority for the batch
- `alertname`, `severity` — for Grafana alerts
- `monitor.name`, `monitor.url`, `heartbeat.msg` — for Kuma alerts

Extract the hostnames, service names, and repeated error signatures from the
message. Search recent Hermes sessions for the exact monitor name and distinctive
error before broad investigation when `session_search` is available. For a
recently diagnosed repeat, use the prior RCA as a hypothesis, then run only the
minimum current probes needed to prove whether the same condition persists; do
not redo broad discovery or invent a new fix merely because another alert fired.
Report how long the condition has persisted and preserve the prior operator
disposition or manual action unless current evidence materially changes it. Carry
forward the disposition, not stale measurements or consumer attribution: remeasure
the previously dominant consumer and its top-level siblings, because cleanup can
shrink one tree while another grows enough to keep the same alert firing.

Before querying a host, resolve which machine actually serves the monitor URL
from DNS, generated proxy configuration, or nixosconfig; the alert-bridge running
on doc2 does not imply that doc2 hosts the failing service. For a batch, look for
the common root first: shared host, shared network path, shared storage, shared
upstream, recent deploy, or one root alert followed by many dependent symptom
alerts. If the evidence instead shows independent failures, keep a separate root
cause and classification for each alert; do not force the batch into one
classification merely because the alerts arrived together.

### 2. Query Loki for more context

Loki is at https://loki.ablz.au (no auth, reachable fleet-wide).

```
curl -s -G "https://loki.ablz.au/loki/api/v1/query_range" \
  --data-urlencode "query=<logql>" \
  --data-urlencode "start=$(date -d '30 min ago' +%s)000000000" \
  --data-urlencode "end=$(date +%s)000000000" \
  --data-urlencode "limit=20" \
  --data-urlencode "direction=backward" | python3 -m json.tool
```

Useful LogQL patterns:
- `{hostname="doc2"} |= "error"` — error logs for a host
- `{unit="podman-foo.service"}` — specific systemd unit
- `{host="prom"} |= "oom"` — OOM messages on a Proxmox host
- `{hostname=~".+"} |= "421"` — fleet-wide text search

Always include a non-empty stream matcher in a Loki selector; bare `{}` is
invalid and can return a non-JSON error body that obscures the actual query
failure.

### 3. Query affected hosts read-only

SSH is available to ordinary fleet hosts from doc1. Resolve the unit's **actual deployed name and service-manager scope** from nixosconfig before probing it: alert descriptions and old runbooks can retain a generic or retired unit name after a module rename. Use `systemctl --user` / `journalctl --user` for Home Manager or user units, and plain `systemctl` / `journalctl` for system units. If the expected unit is absent, list narrowly matched system/user services and processes before concluding that the shipper or service is not installed. Do not interpret an absent or inactive same-named unit in the wrong scope as runtime failure. Use READ-ONLY commands only:
- `journalctl -u <unit> --since "30 min ago" -n 50` (add `--user` for a user unit)
- `systemctl status <unit>` (add `--user` for a user unit)
- `systemctl list-units --failed` (add `--user` for user units)
- `docker logs <container> --tail 50` (on doc2 via SSH)
- `zpool status` (on doc2 for ZFS issues)
- `df -h`, `free -h`, `uptime`

**pfSense is the exception:** load the `pfsense` skill before its first probe and
use its MCP tools exclusively. Never SSH, SCP, or run a shell command against the
firewall; a failed login can trigger sshguard and cut off the API and GUI from
doc1. Do not batch a speculative pfSense SSH probe alongside skill loading,
because parallel execution can reach the firewall before the safety rule is read.

NEVER run: systemctl restart, nixos-rebuild, docker restart, rm, write to
config files, or anything that changes system state. This is READ-ONLY. Do not
use `systemd-run` to emulate a unit during investigation: even a short probe
creates transient unit state, and the invoked program may update ledgers or send
alerts. Reproduce parsing and sandbox behavior with scratch fixtures instead.

For service-specific failure recipes (systemd sandbox/namespace failures,
timer-driven oneshots, memory-cgroup OOMs, long initial-sync heartbeat gaps,
boot-time crash notifiers, kernel panics with missing kdump, Alloy
startup/config failures, MariaDB connection stalls, Cratedigger upstream-tip
canaries and live-world integrity failures, HTTP 404/421, Tailscale share peers,
and missing Kuma heartbeats), load
[`references/service-failure-recipes.md`](references/service-failure-recipes.md).

### 4. Check nixosconfig for the relevant config

The operator's primary nixosconfig checkout is at `/home/abl030/nixosconfig`.
Treat it as strictly read-only and operator-owned: never switch branches, reset,
clean, rebase, pull, stash, commit, or edit files there. Read-only searches and
history inspection are allowed. Search for the service config, look at recent
commits, and check whether a config change caused the alert:
- `grep -r <service> modules/nixos/services/`
- `git log --oneline -20 -- <relevant file>`
- `git diff HEAD~5 -- <relevant file>` (recent changes)

### 5. Diagnose rolling flake-update build failures

For rolling update alerts, load
[`references/rolling-update-failures.md`](references/rolling-update-failures.md)
and follow its ownership tests and operational labels before classifying the
incident or proposing a PR.

### 6. Determine root cause

For other alerts, classify the alert:
- **Config issue** — a nixosconfig change caused this (wrong port, missing
  option, broken module, or an undersized declarative resource limit). Fixable
  via PR.
- **Transient** — network blip, temporary workload spike within an otherwise
  appropriate resource budget, or short-lived disk pressure. Often
  self-healing. No PR needed.
- **External** — upstream service down, DNS issue, cert expiry. May need
  manual intervention but not a nixosconfig PR.
- **Hardware** — disk failure, memory error. Needs physical intervention.

## PR Workflow (only for config issues)

If the root cause is a fixable nixosconfig issue, first perform a duplicate and
operator-disposition preflight:

1. Search Forgejo PRs in **all states**, not only open PRs, for the same service,
   error signature, upstream revision, and proposed policy. Inspect the body and
   comments on matching recently closed PRs.
2. Search recent Hermes sessions for the same alert/error signature when the
   `session_search` tool is available.
3. A recently closed PR with an operator disposition such as "wait for upstream",
   "do not pin", or "do not recreate" is authoritative while the running service
   remains healthy and the upstream failure is unchanged. Report the existing
   disposition and do **not** create another PR.
4. If an exact open PR already fixes the live root cause, read it back and verify
   its state, head/base, current head SHA, and mergeability. Do not create another
   branch or PR; report the existing fix as awaiting merge/deployment. Repeated
   alerts before deployment are the same incident unless new evidence changes
   the diagnosis.
5. Reconsider a closed disposition only when materially new evidence exists:
   upstream changed, the runtime (not merely an atomic upgrade attempt) is
   unhealthy, or the operator explicitly requests the previously rejected
   mitigation.

This prevents unattended retries from reopening the same workaround every time a
nightly update encounters an unchanged upstream failure.

### 1. Create an isolated worktree and branch

Always make fixes in a dedicated worktree based on current `origin/master`, even
when the primary checkout appears clean. Never create or check out the RCA branch
in `/home/abl030/nixosconfig`.

```bash
cd /home/abl030/nixosconfig
git fetch origin
worktree_root=/home/abl030/.cache/hermes/worktrees
mkdir -p "$worktree_root"
worktree=$(mktemp -d "$worktree_root/alert-rca-XXXXXX")
rmdir "$worktree"
branch=fix/<short-description>
git worktree add -b "$branch" "$worktree" origin/master
cd "$worktree"
git -C /home/abl030/nixosconfig status --short --branch >"$(git rev-parse --path-format=absolute --git-path primary-status-baseline)"
```

Use `git -C "$worktree" ...` or remain inside `$worktree` for every edit,
verification, commit, and push. Fetch **before** creating the worktree, then capture
the primary status only **after** entering it: fetching can legitimately change the
branch's `[behind N]` annotation, while `git rev-parse --path-format=absolute --git-path`
stores the baseline in this worktree's administrative Git directory. Always request
the absolute path: a relative Git path can resolve against the wrong checkout during
final cleanup. The absolute path survives separate tool calls without relying on a
temporary variable or shell function.

Execute the exact `status | cmp` command below immediately before committing and
again after the Forgejo PR readback. If either command returns non-zero, do not
commit or repair, reset, or clean the primary checkout. Compare the saved and
current status read-only to classify the mismatch:

- If tracked/untracked content changed, or the cause is unclear, stop, preserve
  the worktree, and report the checkout-safety failure in Gotify.
- If the only difference is the branch tracking annotation because
  `origin/master` advanced concurrently, inspect the newly visible commits and
  Forgejo PRs before reporting failure. If the exact fix has already landed,
  preserve the uncommitted RCA worktree, verify the landed commit's signature and
  runtime deployment, and report the existing fix without creating a duplicate
  PR. If the advance is unrelated, stop and report the safety failure as above.

Remove the administrative baseline only after the final comparison passes.

### 2. Make the fix

Edit the relevant .nix file(s). Keep changes minimal and focused on the
root cause. Do not refactor or touch unrelated code.

### 3. Verify the change

- Check NixOS syntax: `nix-instantiate --parse <file>` (basic parse check).
- For changes to systemd directives, build and inspect the generated unit, then
  run `systemd-analyze verify` on it. Do not trust the Nix value or parse check
  alone: Nix-to-unit rendering and systemd tokenization can change its meaning.
  If verification reports unrelated missing dependencies because the unit is
  checked outside its target host, require both no parser warning for the changed
  directive and a successful host dry-build; never ignore a targeted warning.
- If possible, build the affected host's config in dry-run:
  `nixos-rebuild dry-build --flake .#<hostname>` (read-only, no switch).

### 4. Commit and sign

doc1 signs automatically (gpg.format=ssh, commit.gpgsign=true). Run the
checkout comparison as its own executable command immediately before commit, then
verify the signature:
```bash
git add <file>
# Run this as its own command after staging, immediately before git commit.
git -C /home/abl030/nixosconfig status --short --branch | cmp -s "$(git rev-parse --path-format=absolute --git-path primary-status-baseline)" -
git commit -m "fix: <short description of the fix>"
git log -1 --format=%G?  # must print 'G'
```

### 5. Push to Forgejo

Use the shared executable boundary for the feature-branch push. It checks the
exact fetch/push URLs before reading the doc1-only nixbot token and preserves the
push exit status:

```bash
FORGEJO_AUTH=./scripts/forgejo-auth.sh
FORGEJO_PUSH_TOKEN_FILE=/run/secrets/forgejo/nixbot-token
FORGEJO_TOKEN_FILE=/run/secrets/forgejo/hermes-token
"$FORGEJO_AUTH" git-push \
  --repo "$worktree" --remote origin \
  --expected-fetch-url "https://git.ablz.au/abl030/nixosconfig.git" \
  --expected-push-url "https://git.ablz.au/abl030/nixosconfig.git" \
  --token-file "$FORGEJO_PUSH_TOKEN_FILE" \
  --refspec "fix/<short-description>"
```

### 6. Open a PR via Forgejo API

Build the payload in a mode-0600 scratch file, then pass it through stdin. Never
embed a Markdown PR body inside a double-quoted shell argument: backticks and
`$(...)` in the body are shell substitutions that can execute commands and
silently corrupt the stored PR.

```bash
payload=$(mktemp "$TMPDIR/forgejo-pr.XXXXXX")
trap 'rm -f "$payload"' EXIT
chmod 600 "$payload"
python3 - "$payload" <<'PY'
import json, pathlib, sys
payload = {
    "title": "fix: <short description>",
    "head": "fix/<short-description>",
    "base": "master",
    "body": """## Root Cause

<explanation>

## Alert

<link to original alert>

## Fix

<what was changed and why>

Auto-generated by alert-rca skill.""",
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(payload))
PY
"$FORGEJO_AUTH" rest \
  --token-file "$FORGEJO_TOKEN_FILE" --method POST --body-stdin \
  --url "https://git.ablz.au/api/v1/repos/abl030/nixosconfig/pulls" \
  <"$payload"
```

Extract `<number>` and `html_url` from the response, then read the PR back and
execute the second checkout comparison in the RCA worktree as separate commands.
Compute the expected head with `expected_head=$(git rev-parse HEAD)` and compare
the API's full `head.sha` to that value; never type or expand a SHA from abbreviated
commit output. If the POST returned a PR but a later parse or assertion failed,
search PRs for the exact head branch and read that PR back before retrying the
POST, because retrying blindly can create a duplicate:

```bash
"$FORGEJO_AUTH" rest --token-file "$FORGEJO_TOKEN_FILE" --method GET \
  --url "https://git.ablz.au/api/v1/repos/abl030/nixosconfig/pulls/<number>"
git -C /home/abl030/nixosconfig status --short --branch | cmp -s "$(git rev-parse --path-format=absolute --git-path primary-status-baseline)" -
rm "$(git rev-parse --path-format=absolute --git-path primary-status-baseline)"
```

Only after the readback confirms the expected open PR, branch, base, and head SHA
and the comparison succeeds does `html_url` go in the Gotify message. Remove only
the dedicated RCA worktree from a surviving directory so the shell is not left in
a deleted current working directory:
```bash
cd /home/abl030/nixosconfig
git worktree remove "$worktree"
```
Keep the remote branch for the PR. If any step fails, preserve the worktree for
manual inspection; never compensate by resetting or cleaning the primary checkout.

## Gotify Delivery

After investigation (with or without a PR), push the RCA summary to Gotify.
The Gotify token is at /run/secrets/gotify/token (format: GOTIFY_TOKEN=xxx).

Capture the returned message ID, then read that exact message back before
claiming delivery. Keep the response in the Hermes scratch directory and never
print the token:

```bash
set -euo pipefail
response=$(mktemp "$TMPDIR/gotify-response.XXXXXX")
readback=$(mktemp "$TMPDIR/gotify-readback.XXXXXX")
# Do not install an EXIT cleanup trap: preserve both files if POST/readback
# verification fails so the same message ID can be repaired without reposting.
chmod 600 "$response" "$readback"
TOKEN=$(grep '^GOTIFY_TOKEN=' /run/secrets/gotify/token | cut -d= -f2-)
code=$(curl --fail-with-body -sS -o "$response" -w '%{http_code}' -X POST \
  "http://192.168.1.35:8050/message?token=$TOKEN" \
  --data-urlencode "title=RCA: <alertname>" \
  --data-urlencode "message=<summary>" \
  --data-urlencode "priority=5")
id=$(python3 - "$response" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["id"])
PY
)
test "$code" = 200
ssh -o BatchMode=yes doc2 "sudo /run/current-system/sw/bin/gotify-triage msg $id" >"$readback"
# Parse and compare id/title/message as described below, then and only then:
rm -f "$response" "$readback"
```

Treat a successful POST without matching readback as incomplete external-state
verification. Confirm the readback title and message match the intended RCA. Keep
the POST response and returned ID until comparison succeeds; if readback parsing
fails after a successful POST, fix the parser and read the same ID again rather
than reposting and creating a duplicate.

`gotify-triage msg` emits aligned human-readable text, not JSON: capture it to a
mode-0600 scratch file and compare the `id:`, `title:`, and `message:` fields.
Parse only those three known top-level labels and allow leading alignment spaces
before each label (for example, `  title:`); anchoring labels at column zero will
miss valid readback fields. After `message:`, collect every remaining continuation
line and remove its entire alignment prefix (for example,
`re.sub(r'^\\s+', '', line)`), not a fixed number of spaces, because the CLI's
column width varies. Do not use a generic `word:` boundary for the message,
because legitimate body lines such as `Root cause:`, `Classification:`, and
`Action:` would be mistaken for new fields. Do not JSON-decode this CLI output.
Remove the response and readback files only after comparison passes.

### Message format

If a PR was opened or an exact existing PR remains the applicable fix:
```
RCA: <alertname>

Root cause: <one-liner>
Classification: config issue
Fix: <one-liner description>

PR: <html_url>
```

If no fix is needed, or an actionable fix landed and deployed concurrently:
```
RCA: <alertname>

Root cause: <one-liner>
Classification: transient/external/hardware/upstream/actionable
Action: <what self-healed, what manual step is needed, or the verified landed fix>
No PR needed. [For actionable incidents, state that the fix is already deployed.]
```

For a mixed batch, send one compact Gotify message with one line per independent
alert, preserving each classification. Include a PR link only for the alert it
fixes and state that the other alert needs no additional fix; do not flatten a
config issue plus a recovered transient into a single misleading classification.

Keep it phone-readable and enforce the limit before any POST setup: save the
intended body to a scratch file and require
`test "$(wc -c < "$summary")" -le 500` before reading the token or invoking
`curl`. If the check fails, shorten and retest that same intended body; do not
enter an ambiguous delivery path with an oversized draft and empty response
files. Count bytes rather than eyeballing characters because Unicode punctuation
is multi-byte. The alert-bridge already sent the raw alert; this is the analysis
that replaces "what do I do about this?"

## Token Budget

Be efficient. Most RCAs should complete in 5-15 tool calls:
- 1-2 Loki queries
- 1-3 SSH commands to affected host
- 1-2 file reads in nixosconfig
- 1 commit + push + PR (if fixable)
- 1 Gotify push

If after 10 tool calls you don't have a clear root cause, summarize what
you found and push that to Gotify. Don't burn tokens spiraling.

## Safety Rules

1. READ-ONLY on all remote hosts. No service restarts, no deploys, no writes.
2. Only nixosconfig repo writes (isolated worktree + branch + commit + push + PR). Never edit or switch the primary checkout, and never push to master directly.
3. Never include secrets/tokens in the Gotify message or PR body.
4. If the alert is a security incident (intrusion, unauthorized access), do NOT investigate further — push to Gotify "SECURITY ALERT — investigate manually" and stop.
5. The PR is a suggestion for the human to review and merge. Do not merge it yourself.
6. This is an UNATTENDED agent. Do NOT use the clarify tool or ask questions. There is no human present. Make your best determination with available data and push the RCA to Gotify.
