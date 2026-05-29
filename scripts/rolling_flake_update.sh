#!/usr/bin/env bash
set -euo pipefail

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
GIT_USER_NAME="${GIT_USER_NAME:-nix bot}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-acme@ablz.au}"
TAG="nix-rolling"

# Group membership (space-separated input names). Overridable from the nix module.
GROUP_CORE="${RFU_GROUP_CORE:-nixpkgs home-manager}"
GROUP_LLM="${RFU_GROUP_LLM:-claude-code-nix codex-cli-nix claude-plugin-compound-engineering claude-plugin-ha-skills}"

# Notification / triage knobs (passed by the module; empty = skip that bit).
GOTIFY_URL="${GOTIFY_URL:-}"
GOTIFY_TOKEN_FILE="${GOTIFY_TOKEN_FILE:-}"
TRIAGE_PROMPT_FILE="${RFU_TRIAGE_PROMPT_FILE:-}"
RFU_HOSTNAME="${RFU_HOSTNAME:-$(cat /proc/sys/kernel/hostname 2>/dev/null || echo unknown)}"

# Testing knobs: NO_COMMIT=1 (build but never commit/push), ONLY_GROUP=<name>.
ONLY_GROUP="${ONLY_GROUP:-}"

# --- Helpers ---------------------------------------------------------------
log() { echo "[$TAG] $1"; }

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
        SUMMARY_LINES+=("❌ $name — flake update failed: $(triage "$glog")")
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
        git checkout -- flake.lock 2>/dev/null || true
        git checkout -- nix/overlay.nix 2>/dev/null || true
        SUMMARY_LINES+=("❌ $name — $t")
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

# --- Setup -----------------------------------------------------------------
WORK_DIR=$(mktemp -d)
log "📂 Working in temp dir: $WORK_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT

if [ ! -d "$LOCAL_REPO_DIR/.git" ]; then
    log "❌ Could not find local repo at $LOCAL_REPO_DIR to determine remote."
    exit 1
fi

REMOTE_URL=$(git -C "$LOCAL_REPO_DIR" remote get-url origin)
log "⬇️  Cloning from: $REMOTE_URL"
git clone --depth 1 --branch "$BRANCH" "$REMOTE_URL" "$WORK_DIR/repo"
cd "$WORK_DIR/repo"

git config user.name "$GIT_USER_NAME"
git config user.email "$GIT_USER_EMAIL"

# Inject GitHub token for HTTPS push (read from file if not already in env).
if [ -z "${GH_TOKEN:-}" ] && [ -n "${GH_TOKEN_FILE:-}" ] && [ -r "${GH_TOKEN_FILE}" ]; then
    GH_TOKEN="$(cat "${GH_TOKEN_FILE}")"
fi
if [ -n "${GH_TOKEN:-}" ]; then
    CLEAN_URL="${REMOTE_URL#https://}"
    git remote set-url origin "https://oauth2:${GH_TOKEN}@${CLEAN_URL}"
fi

DATE=$(date +%F)

# Compute the "rest" group = all top-level inputs minus core minus llm.
log "🧮 Computing input groups..."
ALL_INPUTS=$(nix flake metadata --json | jq -r '.locks as $l | $l.nodes[$l.root].inputs | keys[]')
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

    if [ -n "${NO_COMMIT:-}" ]; then
        log "⏭️  NO_COMMIT set; not pushing ($(git rev-list --count origin/"$BRANCH"..HEAD) commit(s) held locally)."
    else
        log "🚀 Pushing $(git rev-list --count origin/"$BRANCH"..HEAD) commit(s) to origin/$BRANCH..."
        git push origin "$BRANCH"
    fi
else
    log "✅ No group produced a committable change."
fi

# Bundled notification only if something failed.
if [ "$ANY_FAIL" -eq 1 ]; then
    send_summary_notification
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
