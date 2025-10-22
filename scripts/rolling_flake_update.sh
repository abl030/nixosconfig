#!/usr/bin/env bash
set -euo pipefail

# --- Config (override via env in the systemd unit) ---------------------------
REPO_DIR="${REPO_DIR:-/home/abl030/nixosconfig}"
BASE_BRANCH="${BASE_BRANCH:-master}"
PR_BRANCH="${PR_BRANCH:-bot/rolling-flake-update}"
PR_TITLE="Rolling: nix-flake-update"

GIT_USER_NAME="${GIT_USER_NAME:-nix bot}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-acme@ablz.au}"

# Perth (AWST)
ATTEMPT_DATE="$(TZ=Australia/Perth date +%F)"

# gh auth: prefer GH_TOKEN if set; otherwise gh must already be logged in.
: "${GH_TOKEN:=${GITHUB_TOKEN:-}}"

# --- Helpers -----------------------------------------------------------------
open_pr_url() {
    # Only consider OPEN PRs for this head/base pair.
    gh pr list \
        --base "$BASE_BRANCH" \
        --head "$PR_BRANCH" \
        --state open \
        --json url \
        -q '.[0].url' 2>/dev/null || true
}

# Summarize input changes between two locks
summarize_changes() {
    local old="$1" new="$2"
    # Compatibility: use --rawfile + fromjson so both jq and gojq work (no --argfile required).
    # The OLD file is parsed with a safe fallback to {"nodes":{}} to cover first-run scenarios.
    jq -r --rawfile OLD "$old" --rawfile NEW "$new" '
      (try ($OLD | fromjson) catch {"nodes":{}}) as $OLD
      | ($NEW | fromjson) as $NEW
      | def rev(x):
          (x.locked.rev // x.locked.lastModified // x.locked.narHash // "") | tostring;
      ($OLD.nodes | keys[]) as $k
      | select(($NEW.nodes[$k]? // {}) != ($OLD.nodes[$k] // {}))
    | "\($k): " + (rev($OLD.nodes[$k] // {})[0:7]) + " → " + (rev($NEW.nodes[$k] // {})[0:7])'
}

# --- Prep --------------------------------------------------------------------
cd "$REPO_DIR"
git fetch --prune origin
git checkout "$BASE_BRANCH"
git reset --hard "origin/${BASE_BRANCH}"

# Branch off fresh base every day (force-refresh)
if git rev-parse --verify "$PR_BRANCH" >/dev/null 2>&1; then
    git checkout "$PR_BRANCH"
    git reset --hard "origin/${BASE_BRANCH}"
else
    git checkout -B "$PR_BRANCH" "origin/${BASE_BRANCH}" || git checkout -B "$PR_BRANCH" "${BASE_BRANCH}"
fi

# Snapshot old lock
OLD_LOCK="$(mktemp)"
if [ -f flake.lock ]; then
    cp flake.lock "$OLD_LOCK"
else
    # Emit minimal valid JSON so the summarizer can parse consistently on first run.
    printf '%s\n' '{"nodes":{}}' >"$OLD_LOCK"
fi

# Bot identity (local)
git config user.name "$GIT_USER_NAME"
git config user.email "$GIT_USER_EMAIL"

# Update lock
nix flake update

# If nothing changed, don't push (avoids pointless CI re-runs)
if git diff --quiet -- flake.lock; then
    echo "flake.lock unchanged; leaving PR as-is."
    exit 0
fi

# Commit lockfile update
git add flake.lock
git commit -m "chore: update flake.lock (${ATTEMPT_DATE})"

# Compose PR body for this attempt
NEW_LOCK="$(mktemp)"
cp flake.lock "$NEW_LOCK"
CHANGES="$(summarize_changes "$OLD_LOCK" "$NEW_LOCK")"

BODY_FILE="$(mktemp)"
{
    echo "Last attempted: ${ATTEMPT_DATE}"
    echo
    if [ -n "${CHANGES// /}" ]; then
        echo "Changes in this attempt:"
        while IFS= read -r line; do
            [ -n "$line" ] && echo "- $line"
        done <<<"$CHANGES"
    else
        echo "No input changes detected (lock moved but diff could not be summarized)."
    fi
} >"$BODY_FILE"

# Push branch (force so this branch always represents "today's attempt")
git push -u origin "$PR_BRANCH" --force-with-lease

# Find OPEN PR; create if none
PR_URL="$(open_pr_url)"
if [ -n "${PR_URL:-}" ]; then
    gh pr edit "$PR_URL" --title "$PR_TITLE" --body-file "$BODY_FILE"
else
    # Create without relying on a --json flag here; then resolve the URL via the list query.
    gh pr create --base "$BASE_BRANCH" --head "$PR_BRANCH" \
        --title "$PR_TITLE" --body-file "$BODY_FILE" >/dev/null
    # Re-query to obtain the canonical URL for downstream steps.
    PR_URL="$(open_pr_url)"
fi

# Enable auto-merge (squash) on the OPEN PR
# (If branch protection requires checks, this just arms auto-merge.)
gh pr merge "$PR_URL" --auto --squash --delete-branch=false

git switch master

echo "Updated PR: $PR_URL"
