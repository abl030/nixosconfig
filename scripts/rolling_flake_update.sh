#!/usr/bin/env bash
set -Eeuo pipefail

# Rolling flake update — grouped, fail-isolated.
#
# Instead of one all-or-nothing `nix flake update` + build, we update inputs in
# independent GROUPS, each its own transaction: update -> flake check -> build ->
# commit-or-revert. A red group is reverted and skipped; green groups still land.
# One bundled Gotify notification is sent at the end summarising the night.
#
# See design + rationale: GitHub issue #260, and #259 for the deadlock this fixes.
#
# Group order is fixed: core (nixpkgs+home-manager) first so llm/rest build on the
# cached new world, then llm (claude-code/codex — always wins through), then rest
# (everything else; computed = all inputs - core - llm, so new inputs auto-fall in).

# --- Configuration ---------------------------------------------------------
LOCAL_REPO_DIR="${REPO_DIR:-/home/abl030/nixosconfig}"
BRANCH="${BASE_BRANCH:-master}"
REMOTE_URL_OVERRIDE="${RFU_REMOTE_URL:-}"
# Forgejo push token (nixbot). Sent as an Authorization header on push only, not
# embedded in the remote URL. Falls back to the legacy GH_TOKEN_FILE name.
PUSH_TOKEN_FILE="${RFU_PUSH_TOKEN_FILE:-${GH_TOKEN_FILE:-}}"
PUSH_TOKEN=""
GIT_USER_NAME="${GIT_USER_NAME:-nix bot}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-acme@ablz.au}"
GIT_SIGNING_KEY="${RFU_GIT_SIGNING_KEY:-}"
ALLOWED_SIGNERS_FILE="${RFU_ALLOWED_SIGNERS_FILE:-/etc/fleet-update/allowed_signers}"
REQUIRE_SIGNED_BASE="${RFU_REQUIRE_SIGNED_BASE:-0}"
HEARTBEAT_FILE="${RFU_HEARTBEAT_FILE:-fleet/freshness.json}"
SKIP_HEARTBEAT="${RFU_SKIP_HEARTBEAT:-0}"
STATE_DIR="${RFU_STATE_DIR:-}"
BASE_ANCHOR_FILE="${RFU_BASE_ANCHOR_FILE:-${STATE_DIR:+$STATE_DIR/last-verified-base}}"
FAILURE_DIR="${RFU_FAILURE_DIR:-${STATE_DIR:+$STATE_DIR/failures}}"
TAG="nix-rolling"

# Group membership (space-separated input names). Overridable from the nix module.
GROUP_CORE="${RFU_GROUP_CORE:-nixpkgs home-manager}"
GROUP_LLM="${RFU_GROUP_LLM:-claude-code-nix codex-cli-nix claude-plugin-compound-engineering claude-plugin-ha-skills}"

# Notification / triage knobs (passed by the module; empty = skip that bit).
GOTIFY_URL="${GOTIFY_URL:-}"
GOTIFY_TOKEN_FILE="${GOTIFY_TOKEN_FILE:-}"
TRIAGE_PROMPT_FILE="${RFU_TRIAGE_PROMPT_FILE:-}"
RFU_HOSTNAME="${RFU_HOSTNAME:-$(cat /proc/sys/kernel/hostname 2>/dev/null || echo unknown)}"
RCA_WEBHOOK_URL="${RFU_RCA_WEBHOOK_URL:-}"
RCA_WEBHOOK_SECRET="${RFU_RCA_WEBHOOK_SECRET:-}"

# Testing knobs: NO_COMMIT=1 (build but never commit/push), ONLY_GROUP=<name>.
ONLY_GROUP="${ONLY_GROUP:-}"

# --- Helpers ---------------------------------------------------------------
log() { echo "[$TAG] $1"; }

signed_base_required() {
    [ "$REQUIRE_SIGNED_BASE" = "1" ] || [ "$REQUIRE_SIGNED_BASE" = "true" ]
}

verify_commit() {
    local rev="$1"

    if [ ! -r "$ALLOWED_SIGNERS_FILE" ]; then
        log "❌ signed-base gate requires readable allowed_signers: $ALLOWED_SIGNERS_FILE"
        return 1
    fi

    if ! git -c "gpg.ssh.allowedSignersFile=$ALLOWED_SIGNERS_FILE" verify-commit "$rev" >/dev/null 2>&1; then
        log "❌ commit $rev does not verify against $ALLOWED_SIGNERS_FILE"
        git -c "gpg.ssh.allowedSignersFile=$ALLOWED_SIGNERS_FILE" verify-commit "$rev" || true
        return 1
    fi
}

verify_commit_range() {
    local base="$1"
    local target="$2"
    local rev

    while IFS= read -r rev; do
        [ -n "$rev" ] || continue
        verify_commit "$rev"
    done < <(git rev-list "$base..$target")
}

verify_base_anchor() {
    if ! signed_base_required || [ -z "$BASE_ANCHOR_FILE" ]; then
        return 0
    fi

    if [ ! -s "$BASE_ANCHOR_FILE" ]; then
        log "❌ missing bot base anchor: $BASE_ANCHOR_FILE"
        log "   Seed it with the expected signed master SHA before enabling RFU_REQUIRE_SIGNED_BASE."
        return 1
    fi

    local anchor
    anchor="$(tr -d '[:space:]' <"$BASE_ANCHOR_FILE")"
    if [[ ! "$anchor" =~ ^[0-9a-fA-F]{40}$ ]]; then
        log "❌ bot base anchor is not a commit SHA: $BASE_ANCHOR_FILE"
        return 1
    fi
    if ! git cat-file -e "$anchor^{commit}" 2>/dev/null; then
        log "❌ bot base anchor $anchor is not present in fetched history."
        return 1
    fi
    if ! git merge-base --is-ancestor "$anchor" HEAD; then
        log "❌ fetched base $(git rev-parse HEAD) does not descend from bot anchor $anchor"
        return 1
    fi
    verify_commit_range "$anchor" HEAD
}

write_base_anchor() {
    if ! signed_base_required || [ -z "$BASE_ANCHOR_FILE" ]; then
        return 0
    fi

    local tmp
    mkdir -p "$(dirname "$BASE_ANCHOR_FILE")"
    tmp="$BASE_ANCHOR_FILE.tmp"
    git rev-parse HEAD >"$tmp"
    mv "$tmp" "$BASE_ANCHOR_FILE"
}

configure_git_signing() {
    if [ -z "$GIT_SIGNING_KEY" ]; then
        if signed_base_required; then
            log "❌ RFU_REQUIRE_SIGNED_BASE is set but RFU_GIT_SIGNING_KEY is empty."
            return 1
        fi
        log "⚠️  No RFU_GIT_SIGNING_KEY configured; generated commits use ambient git config."
        return 0
    fi

    if [ ! -r "$GIT_SIGNING_KEY" ]; then
        log "❌ Git signing key missing or unreadable: $GIT_SIGNING_KEY"
        return 1
    fi

    git config gpg.format ssh
    git config user.signingkey "$GIT_SIGNING_KEY"
    git config commit.gpgsign true
    git config tag.gpgsign true
    git config gpg.ssh.allowedSignersFile "$ALLOWED_SIGNERS_FILE"
}

verify_new_commits() {
    if ! signed_base_required; then
        return 0
    fi

    local rev
    while IFS= read -r rev; do
        [ -n "$rev" ] || continue
        verify_commit "$rev"
    done < <(git rev-list "origin/$BRANCH..HEAD")
}

write_heartbeat() {
    local previous_epoch=0
    local now_epoch heartbeat_epoch timestamp tmp status failed_count summary_count

    if [ -f "$HEARTBEAT_FILE" ]; then
        previous_epoch="$(jq -r '.epoch // 0' "$HEARTBEAT_FILE" 2>/dev/null || echo 0)"
        case "$previous_epoch" in
            ''|*[!0-9]*) previous_epoch=0 ;;
        esac
    fi

    now_epoch="$(date -u +%s)"
    heartbeat_epoch="$now_epoch"
    if [ "$heartbeat_epoch" -le "$previous_epoch" ]; then
        heartbeat_epoch=$((previous_epoch + 1))
    fi
    timestamp="$(date -u -d "@$heartbeat_epoch" '+%Y-%m-%dT%H:%M:%SZ')"
    if [ "$ANY_FAIL" -eq 0 ]; then
        status="green"
    else
        status="partial_failure"
    fi
    summary_count=${#SUMMARY_LINES[@]}
    failed_count=$(printf '%s\n' "${SUMMARY_LINES[@]:-}" | grep -c '^❌' || true)

    mkdir -p "$(dirname "$HEARTBEAT_FILE")"
    tmp="$HEARTBEAT_FILE.tmp"
    jq -n \
        --argjson epoch "$heartbeat_epoch" \
        --arg timestamp "$timestamp" \
        --arg actor "$GIT_USER_NAME <$GIT_USER_EMAIL>" \
        --arg host "$RFU_HOSTNAME" \
        --arg status "$status" \
        --argjson failed_groups "$failed_count" \
        --argjson summary_lines "$summary_count" \
        '{epoch: $epoch, timestamp: $timestamp, actor: $actor, host: $host, status: $status, failed_groups: $failed_groups, summary_lines: $summary_lines}' >"$tmp"
    mv "$tmp" "$HEARTBEAT_FILE"
}

persist_group_failure() {
    local name="$1"
    local logf="$2"
    local dir

    if [ -z "$FAILURE_DIR" ]; then
        return 0
    fi

    dir="$FAILURE_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$name"
    mkdir -p "$dir"
    chmod 700 "$dir"
    cp "$logf" "$dir/build.log"
    git rev-parse HEAD >"$dir/head-rev.txt" 2>/dev/null || true
    git status --short >"$dir/git-status.txt" 2>/dev/null || true
    printf '%s\n' "$dir"
}

# shellcheck disable=SC2329  # Invoked indirectly from cleanup_work_dir through the EXIT trap.
redacted_remote_url() {
    printf '%s\n' "$1" | sed -E 's#^(https?://)[^/@]+@#\1redacted@#'
}

push_with_retries() {
    local attempt rc
    local -a auth=()
    # Apply the push token as a header, scoped to this invocation only. Empty
    # token (e.g. dry-run, or anonymous) falls through to an unauthenticated
    # push, which fails loudly rather than leaking anything.
    if [ -n "${PUSH_TOKEN:-}" ]; then
        auth=(-c "http.extraHeader=Authorization: token ${PUSH_TOKEN}")
    fi
    for attempt in 1 2 3; do
        if git "${auth[@]}" push origin "$BRANCH"; then
            return 0
        fi
        log "⚠️  push attempt $attempt failed."
        if [ "$attempt" -lt 3 ]; then
            # A rejected push is usually a commit race: an interactive push
            # landed on master during the multi-hour build window (the run
            # clones at 23:00, evening pushes overlap). If the remote moved,
            # rebase onto the new tip and retry immediately; otherwise back
            # off and retry (transient network / Forgejo blip).
            rc=0
            rebase_onto_moved_remote || rc=$?
            case "$rc" in
                0) ;;          # rebased; retry the push immediately
                2) break ;;    # unrecoverable (conflict / untrusted commits)
                *) sleep $((attempt * 10)) ;;
            esac
        fi
    done
    SUMMARY_LINES+=("❌ push — gave up; our commits are preserved in the workdir")
    return 1
}

# Condition-safe range verification. verify_commit_range relies on `set -e` to
# abort on a bad commit, which is suspended when called inside a condition —
# this variant explicitly fails if ANY commit in base..target fails to verify.
verify_range_strict() {
    local rev ok=0
    while IFS= read -r rev; do
        [ -n "$rev" ] || continue
        verify_commit "$rev" || ok=1
    done < <(git rev-list "$1..$2")
    return "$ok"
}

# Handle the commit race: master gained commits while we were building. Fetch,
# verify the new commits against allowed_signers, and rebase our bot commits on
# top — commit.gpgsign re-signs them with the bot key during the rewrite.
# Returns 0 if a rebase happened (caller retries the push at once), 1 if the
# remote never moved (not a race — plain retry), 2 if unrecoverable.
rebase_onto_moved_remote() {
    local new_tip nnew
    git fetch origin "$BRANCH" || return 1
    new_tip="$(git rev-parse "origin/$BRANCH")" || return 1
    if git merge-base --is-ancestor "$new_tip" HEAD; then
        return 1 # remote did not move; rejection was not a commit race
    fi
    nnew="$(git rev-list --count "HEAD..$new_tip" 2>/dev/null || echo '?')"
    log "🔀 Commit race: master gained $nnew commit(s) mid-run; verifying and rebasing onto ${new_tip:0:12}..."
    if signed_base_required && ! verify_range_strict HEAD "$new_tip"; then
        SUMMARY_LINES+=("❌ push — commit race: new master tip ${new_tip:0:12} contains unverified commits; refusing to rebase")
        return 2
    fi
    if ! git rebase "$new_tip"; then
        git rebase --abort 2>/dev/null || true
        SUMMARY_LINES+=("❌ push — commit race: rebase onto ${new_tip:0:12} conflicted; manual merge needed from preserved workdir")
        return 2
    fi
    if signed_base_required && ! verify_range_strict "origin/$BRANCH" HEAD; then
        SUMMARY_LINES+=("❌ push — commit race: rebased commits failed signature re-verification")
        return 2
    fi
    log "🔀 Rebase complete; retrying push."
    SUMMARY_LINES+=("🔀 push — commit race: $nnew commit(s) landed on master mid-run; rebased ours on top")
    return 0
}

# Result accumulators.
declare -a SUMMARY_LINES=()
ANY_FAIL=0
ANY_COMMIT=0

# Triage a failed group's build log via headless Claude. Uses opus: this is one
# of the two diagnosis paths (with nixos-upgrade) where an accurate, actionable
# verdict on a nightly build failure is worth the cost — everything else on the
# fleet defaults to haiku. Falls back to a sanitised log tail. Echoes a summary.
triage() {
    local logf="$1"
    local out=""
    if [ -n "$TRIAGE_PROMPT_FILE" ] && [ -r "$TRIAGE_PROMPT_FILE" ] && command -v claude >/dev/null 2>&1; then
        out="$(tail -n 200 "$logf" | timeout 600 claude -p \
            --system-prompt "$(cat "$TRIAGE_PROMPT_FILE")" \
            --model opus \
            --no-session-persistence \
            --tools "" \
            "Triage this NixOS build failure log from stdin." 2>/dev/null || true)"
    fi
    if [ -z "$out" ]; then
        out="(claude triage unavailable) $(tail -n 15 "$logf" | sed 's/[[:cntrl:]]/ /g' | tr '\n' ' ')"
    fi
    echo "$out"
}

# Run one group as an isolated transaction. Never aborts the script (call with || true).
try_group() {
    local name="$1"; shift
    local inputs="$*"

    if [ -n "$ONLY_GROUP" ] && [ "$ONLY_GROUP" != "$name" ]; then
        return 0
    fi
    if [ -z "${inputs// /}" ]; then
        log "⏭️  [$name] no inputs; skipping."
        return 0
    fi

    log "🔄 [$name] updating: $inputs"
    local glog="$WORK_DIR/${name}.build.log"
    # shellcheck disable=SC2086  # $inputs is a space-separated list of input names, splitting is intended
    if ! nix flake update $inputs >"$glog" 2>&1; then
        log "❌ [$name] 'nix flake update' failed; reverting."
        ANY_FAIL=1
        local artifact; artifact="$(persist_group_failure "$name" "$glog")"
        if [ -n "$artifact" ]; then
            SUMMARY_LINES+=("❌ $name — flake update failed: $(triage "$glog") (artifact: $artifact)")
        else
            SUMMARY_LINES+=("❌ $name — flake update failed: $(triage "$glog")")
        fi
        git checkout -- flake.lock 2>/dev/null || true
        return 1
    fi

    if git diff --quiet -- flake.lock; then
        log "➖ [$name] no changes."
        SUMMARY_LINES+=("➖ $name — no changes")
        return 0
    fi

    # jolt's cargo hash lives in nix/overlay.nix and must be refreshed when jolt bumps.
    if [[ " $inputs " == *" jolt "* ]] && [ -x ./scripts/update-jolt.sh ]; then
        log "⚡ [$name] refreshing jolt cargo hash..."
        ./scripts/update-jolt.sh >>"$glog" 2>&1 || true
    fi

    log "🚧 [$name] flake check + build (all hosts)..."
    if FULL_CHECK=1 nix flake check --impure --print-build-logs >>"$glog" 2>&1 \
        && ./scripts/populate_cache.sh >>"$glog" 2>&1; then
        log "✅ [$name] passed."
        git add flake.lock
        git add nix/overlay.nix 2>/dev/null || true
        git commit -q -m "rolling: $name ($DATE)"
        ANY_COMMIT=1
        SUMMARY_LINES+=("✅ $name — ${inputs// /, }")
        return 0
    else
        log "❌ [$name] build failed; reverting group."
        ANY_FAIL=1
        local t; t="$(triage "$glog")"
        local artifact; artifact="$(persist_group_failure "$name" "$glog")"
        git checkout -- flake.lock 2>/dev/null || true
        git checkout -- nix/overlay.nix 2>/dev/null || true
        if [ -n "$artifact" ]; then
            SUMMARY_LINES+=("❌ $name — $t (artifact: $artifact)")
        else
            SUMMARY_LINES+=("❌ $name — $t")
        fi
        return 1
    fi
}

# Send ONE bundled Gotify with the whole night's per-group results.
send_summary_notification() {
    [ -z "$GOTIFY_URL" ] && return 0
    [ -z "$GOTIFY_TOKEN_FILE" ] && return 0
    [ ! -r "$GOTIFY_TOKEN_FILE" ] && return 0
    local token; token="$(awk -F= '/^GOTIFY_TOKEN=/{print $2}' "$GOTIFY_TOKEN_FILE")"
    [ -z "$token" ] && return 0

    local nfail ntotal body
    ntotal=${#SUMMARY_LINES[@]}
    nfail=$(printf '%s\n' "${SUMMARY_LINES[@]}" | grep -c '^❌' || true)
    body="$(printf '%s\n' "${SUMMARY_LINES[@]}")"

    curl -fsS -X POST "${GOTIFY_URL}/message?token=$token" \
        -F "title=rolling flake update: ${nfail}/${ntotal} groups failed on ${RFU_HOSTNAME}" \
        -F "message=$body" \
        -F "priority=8" >/dev/null || true
}

# Prefer the unattended RCA agent for rolling-update failures. The agent sends
# the user one phone-readable Gotify with classification + local action; direct
# Gotify here is only the safety fallback if Hermes/webhook delivery is down.
send_rca_notification() {
    [ -z "$RCA_WEBHOOK_URL" ] && return 1
    local nfail ntotal body payload
    ntotal=${#SUMMARY_LINES[@]}
    nfail=$(printf '%s\n' "${SUMMARY_LINES[@]}" | grep -c '^❌' || true)
    body="$(printf '%s\n' "${SUMMARY_LINES[@]}")"
    payload="$(jq -n \
        --arg title "rolling flake update: ${nfail}/${ntotal} groups failed on ${RFU_HOSTNAME}" \
        --arg message "## Rolling flake update failed\nhost: ${RFU_HOSTNAME}\nfailed_groups: ${nfail}/${ntotal}\n\n${body}\n\nInvestigate read-only. Tell the user once: failing package/input, classification, and whether there is anything to do locally." \
        '{title: $title, message: $message, priority: 8}')"

    curl -fsS -X POST "$RCA_WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -H "X-Gitlab-Token: $RCA_WEBHOOK_SECRET" \
        -d "$payload" >/dev/null
}

# shellcheck disable=SC2329  # Invoked by the EXIT trap.
cleanup_work_dir() {
    if [ -z "${WORK_DIR:-}" ] || [ ! -d "$WORK_DIR" ]; then
        return 0
    fi

    if [ "${PRESERVE_WORK_DIR:-0}" = "1" ]; then
        if [ -d "$WORK_DIR/repo/.git" ] && [ -n "${REMOTE_URL:-}" ]; then
            git -C "$WORK_DIR/repo" remote set-url origin "$(redacted_remote_url "$REMOTE_URL")" 2>/dev/null || true
        fi
        log "🧰 Preserving failed workdir for recovery: $WORK_DIR"
        return 0
    fi

    rm -rf "$WORK_DIR"
}

# shellcheck disable=SC2329  # Invoked by the ERR trap.
fatal_error() {
    # shellcheck disable=SC2155  # Must capture the failing status before any other command.
    local code=$?
    local line="${BASH_LINENO[0]:-unknown}"

    trap - ERR
    PRESERVE_WORK_DIR=1
    ANY_FAIL=1
    SUMMARY_LINES+=("❌ fatal — updater aborted near line $line (exit $code); workdir preserved at ${WORK_DIR:-unknown}")
    log "❌ Fatal updater failure near line $line (exit $code)."
    send_summary_notification || true
    exit "$code"
}

# --- Setup -----------------------------------------------------------------
PRESERVE_WORK_DIR=0
WORK_DIR=$(mktemp -d)
log "📂 Working in temp dir: $WORK_DIR"
trap cleanup_work_dir EXIT
trap fatal_error ERR

if [ ! -d "$LOCAL_REPO_DIR/.git" ]; then
    log "❌ Could not find local repo at $LOCAL_REPO_DIR to determine remote."
    false
fi

if [ -n "$REMOTE_URL_OVERRIDE" ]; then
    REMOTE_URL="$REMOTE_URL_OVERRIDE"
else
    REMOTE_URL=$(git -C "$LOCAL_REPO_DIR" remote get-url origin)
fi
log "⬇️  Cloning from: $REMOTE_URL"
git clone --single-branch --branch "$BRANCH" "$REMOTE_URL" "$WORK_DIR/repo"
cd "$WORK_DIR/repo"

git config user.name "$GIT_USER_NAME"
git config user.email "$GIT_USER_EMAIL"
configure_git_signing

# Read the Forgejo push token (clone was anonymous — public repo). The token is
# applied per-push via http.extraHeader, NOT written into the remote URL, so it
# never appears in `git remote -v`, logs, or preserved failure workdirs.
if [ -n "${PUSH_TOKEN_FILE:-}" ] && [ -r "${PUSH_TOKEN_FILE}" ]; then
    PUSH_TOKEN="$(tr -d '\r\n' <"${PUSH_TOKEN_FILE}")"
fi

if signed_base_required; then
    log "🔏 Verifying fetched base commit before updating..."
    verify_commit HEAD
    verify_base_anchor
fi

DATE=$(date +%F)

# Compute the "rest" group = all top-level inputs minus core minus llm.
log "🧮 Computing input groups..."
ALL_INPUTS=$(nix flake metadata --json | jq -r '.locks as $l | ($l.nodes[$l.root].inputs // {}) | keys[]')
NAMED=" $GROUP_CORE $GROUP_LLM "
GROUP_REST=""
for inp in $ALL_INPUTS; do
    case "$NAMED" in
        *" $inp "*) ;;                       # already in core/llm
        *) GROUP_REST="$GROUP_REST $inp" ;;
    esac
done
log "   core: $GROUP_CORE"
log "   llm : $GROUP_LLM"
log "   rest:$GROUP_REST"

# --- Run each group as its own transaction ---------------------------------
# shellcheck disable=SC2086  # group vars are space-separated input lists; splitting into args is intended
try_group core $GROUP_CORE || true
# shellcheck disable=SC2086
try_group llm $GROUP_LLM || true
# shellcheck disable=SC2086
try_group rest $GROUP_REST || true

# --- Finalise: hash baselines, single push, single notification ------------
if [ "$ANY_COMMIT" -eq 1 ]; then
    if [ -x ./scripts/hash-capture.sh ]; then
        log "📊 Capturing hash baselines (final state)..."
        ./scripts/hash-capture.sh --quiet || true
        if ! git diff --quiet -- hashes/ 2>/dev/null; then
            git add hashes/
            git commit -q -m "rolling: hash baselines ($DATE)"
        fi
    fi
fi

if [ "$SKIP_HEARTBEAT" != "1" ]; then
    log "💓 Writing signed freshness heartbeat..."
    write_heartbeat
    git add "$HEARTBEAT_FILE"
    if ! git diff --cached --quiet -- "$HEARTBEAT_FILE"; then
        git commit -q -m "rolling: freshness heartbeat ($DATE)"
        ANY_COMMIT=1
        SUMMARY_LINES+=("✅ heartbeat — $HEARTBEAT_FILE")
    else
        log "➖ heartbeat unchanged."
    fi
fi

if [ "$ANY_COMMIT" -eq 1 ]; then
    verify_new_commits

    if [ -n "${NO_COMMIT:-}" ]; then
        log "⏭️  NO_COMMIT set; not pushing ($(git rev-list --count origin/"$BRANCH"..HEAD) commit(s) held locally)."
    else
        log "🚀 Pushing $(git rev-list --count origin/"$BRANCH"..HEAD) commit(s) to origin/$BRANCH..."
        push_with_retries
        write_base_anchor
    fi
else
    log "✅ No group produced a committable change."
    write_base_anchor
fi

# Bundled notification only if something failed.
if [ "$ANY_FAIL" -eq 1 ]; then
    send_rca_notification || send_summary_notification
fi

log "===== summary ====="
for line in "${SUMMARY_LINES[@]:-}"; do
    [ -n "$line" ] && log "$line"
done

if [ "$ANY_FAIL" -eq 1 ]; then
    log "🟡 Completed with $(printf '%s\n' "${SUMMARY_LINES[@]}" | grep -c '^❌' || true) failed group(s)."
else
    log "🎉 All groups succeeded or were no-ops."
fi

# Exit non-zero iff a group failed, so systemd/Loki still flag the night.
exit "$ANY_FAIL"
