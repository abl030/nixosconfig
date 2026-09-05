---
name: alert-rca
description: "Read-only root cause analysis for homelab alerts. Investigate, diagnose, and optionally open a signed PR to fix config issues in nixosconfig."
version: 1.0.0
metadata:
  hermes:
    tags: [homelab, alerting, rca, nixosconfig, pr]
---

# Alert RCA Skill

Triggered by an alert forwarded from the alert-bridge (doc2). The alert
payload contains enriched context: alert name, severity, Loki log lines,
and/or journalctl output from the failing service.

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
message. For a batch, look for the common root first: shared host, shared
network path, shared storage, shared upstream, recent deploy, or one root alert
followed by many dependent symptom alerts.

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

### 3. SSH to affected hosts (read-only)

SSH is available to all fleet hosts from doc1. Use READ-ONLY commands only:
- `journalctl -u <unit> --since "30 min ago" -n 50`
- `systemctl status <unit>`
- `systemctl list-units --failed`
- `docker logs <container> --tail 50` (on doc2 via SSH)
- `zpool status` (on doc2 for ZFS issues)
- `df -h`, `free -h`, `uptime`

NEVER run: systemctl restart, nixos-rebuild, docker restart, rm, write to
config files, or anything that changes system state. This is READ-ONLY.

### 4. Check nixosconfig for the relevant config

The operator's primary nixosconfig checkout is at `/home/abl030/nixosconfig`.
Treat it as strictly read-only and operator-owned: never switch branches, reset,
clean, rebase, pull, stash, commit, or edit files there. Read-only searches and
history inspection are allowed. Search for the service config, look at recent
commits, and check whether a config change caused the alert:
- `grep -r <service> modules/nixos/services/`
- `git log --oneline -20 -- <relevant file>`
- `git diff HEAD~5 -- <relevant file>` (recent changes)

### 5. Determine root cause

Classify the alert:
- **Config issue** — a nixosconfig change caused this (wrong port, missing
  option, broken module). Fixable via PR.
- **Transient** — network blip, OOM from temporary load, disk space. Often
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
4. Reconsider only when materially new evidence exists: upstream changed, the
   runtime (not merely an atomic upgrade attempt) is unhealthy, or the operator
   explicitly requests the previously rejected mitigation.

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
git -C /home/abl030/nixosconfig status --short --branch >"$(git rev-parse --git-path primary-status-baseline)"
```

Use `git -C "$worktree" ...` or remain inside `$worktree` for every edit,
verification, commit, and push. Fetch **before** creating the worktree, then capture
the primary status only **after** entering it: fetching can legitimately change the
branch's `[behind N]` annotation, while `git rev-parse --git-path` stores the
baseline in this worktree's administrative Git directory. That path survives
separate tool calls without relying on a temporary variable or shell function.

Execute the exact `status | cmp` command below immediately before committing and
again after the Forgejo PR readback. If either command returns non-zero, stop,
preserve the worktree, report the checkout-safety failure in Gotify, and do not
repair, reset, or clean the primary checkout. Remove the administrative baseline
only after the final comparison passes.

### 2. Make the fix

Edit the relevant .nix file(s). Keep changes minimal and focused on the
root cause. Do not refactor or touch unrelated code.

### 3. Verify the change

- Check NixOS syntax: `nix-instantiate --parse <file>` (basic parse check)
- If possible, build the affected host's config in dry-run:
  `nixos-rebuild dry-build --flake .#<hostname>` (read-only, no switch)

### 4. Commit and sign

doc1 signs automatically (gpg.format=ssh, commit.gpgsign=true). Run the
checkout comparison as its own executable command immediately before commit, then
verify the signature:
```bash
git -C /home/abl030/nixosconfig status --short --branch | cmp -s "$(git rev-parse --git-path primary-status-baseline)" -
git add <file>
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

```bash
python3 -c "
import json
print(json.dumps({
    'title': 'fix: <short description>',
    'head': 'fix/<short-description>',
    'base': 'master',
    'body': '## Root Cause\n\n<explanation>\n\n## Alert\n\n<link to original alert>\n\n## Fix\n\n<what was changed and why>\n\nAuto-generated by alert-rca skill.',
}))
" | "$FORGEJO_AUTH" rest \
  --token-file "$FORGEJO_TOKEN_FILE" --method POST --body-stdin \
  --url "https://git.ablz.au/api/v1/repos/abl030/nixosconfig/pulls"
```

Extract `<number>` and `html_url` from the response, then read the PR back and
execute the second checkout comparison in the RCA worktree as separate commands:

```bash
"$FORGEJO_AUTH" rest --token-file "$FORGEJO_TOKEN_FILE" --method GET \
  --url "https://git.ablz.au/api/v1/repos/abl030/nixosconfig/pulls/<number>"
git -C /home/abl030/nixosconfig status --short --branch | cmp -s "$(git rev-parse --git-path primary-status-baseline)" -
rm "$(git rev-parse --git-path primary-status-baseline)"
```

Only after the readback confirms the expected open PR, branch, base, and head SHA
and the comparison succeeds does `html_url` go in the Gotify message. Remove only
the dedicated RCA worktree with
`git -C /home/abl030/nixosconfig worktree remove "$worktree"`. Keep the remote
branch for the PR. If any step fails, preserve the worktree for manual inspection;
never compensate by resetting or cleaning the primary checkout.

## Gotify Delivery

After investigation (with or without a PR), push the RCA summary to Gotify.
The Gotify token is at /run/secrets/gotify/token (format: GOTIFY_TOKEN=xxx).

```bash
TOKEN=$(grep GOTIFY_TOKEN /run/secrets/gotify/token | cut -d= -f2)
curl -s -X POST "http://192.168.1.35:8050/message?token=$TOKEN" \
  -d "title=RCA: <alertname>" \
  -d "message=<summary>" \
  -d "priority=5"
```

### Message format

If a PR was opened:
```
RCA: <alertname>

Root cause: <one-liner>
Classification: config issue
Fix: <one-liner description>

PR: <html_url>
```

If no fix needed:
```
RCA: <alertname>

Root cause: <one-liner>
Classification: transient/external/hardware
Action: <what was happening, why it self-healed or what manual step is needed>
No PR needed.
```

Keep it phone-readable. Max ~500 chars. The alert-bridge already sent the
raw alert; this is the analysis that replaces "what do I do about this?"

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
