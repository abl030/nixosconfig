#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---------------------------------------------------------
# We use the local repo path ONLY to find the remote URL.
LOCAL_REPO_DIR="${REPO_DIR:-/home/abl030/nixosconfig}"
BRANCH="${BASE_BRANCH:-master}"
GIT_USER_NAME="${GIT_USER_NAME:-nix bot}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-acme@ablz.au}"
TAG="nix-rolling"

# --- Helpers ---------------------------------------------------------------
log() {
    echo "[$TAG] $1"
}

# 1. Setup Temporary Workspace
WORK_DIR=$(mktemp -d)
log "📂 Working in temp dir: $WORK_DIR"

# Ensure we clean up the temp dir when the script exits
trap 'rm -rf "$WORK_DIR"' EXIT

# 2. Clone the Repository
if [ ! -d "$LOCAL_REPO_DIR/.git" ]; then
    log "❌ Error: Could not find local repo at $LOCAL_REPO_DIR to determine remote."
    exit 1
fi

REMOTE_URL=$(git -C "$LOCAL_REPO_DIR" remote get-url origin)
log "⬇️  Cloning from: $REMOTE_URL"

git clone --depth 1 --branch "$BRANCH" "$REMOTE_URL" "$WORK_DIR/repo"
cd "$WORK_DIR/repo"

# Configure Git Identity
git config user.name "$GIT_USER_NAME"
git config user.email "$GIT_USER_EMAIL"

# Handle Authentication (Inject Token if present)
if [ -n "${GH_TOKEN:-}" ]; then
    CLEAN_URL="${REMOTE_URL#https://}"
    git remote set-url origin "https://oauth2:${GH_TOKEN}@${CLEAN_URL}"
fi

# 3. Update the Flake
log "🔄 Updating flake.lock..."
nix flake update

# Check if anything changed
if git diff --quiet -- flake.lock; then
    log "✅ flake.lock unchanged. Exiting."
    exit 0
fi

# 3b. Update jolt overlay hash if needed
if [ -x "./scripts/update-jolt.sh" ]; then
    log "⚡ Updating jolt (master) and verifying cargo hash..."
    ./scripts/update-jolt.sh
else
    log "⚠️  jolt update script not found, skipping."
fi

# 4. Full CI gate (format, lint, flake check with host configs)
log "🚧 Lockfile changed. Running full check gate..."
if command -v check >/dev/null 2>&1; then
    check --full
else
    log "⚠️  'check' command not found; running equivalent checks."
    nix run .#fmt-nix -- --check
    nix run .#lint-nix
    FULL_CHECK=1 nix flake check --impure --print-build-logs
fi

# 5. Verify Builds (No linting, no flake check, just builds)
log "🏗️  Verifying builds..."

log "🏗️  Building all hosts (System + Home Manager)..."
# This calls your populate_cache.sh which builds everything and creates GC roots
if ! ./scripts/populate_cache.sh; then
    log "❌ Build failed. Update rejected."
    exit 1
fi

log "✅ All builds passed."

# 6. Capture Hash Baselines
# Since builds passed, capture derivation hashes as baselines
log "📊 Capturing hash baselines..."
if [ -x "./scripts/hash-capture.sh" ]; then
    ./scripts/hash-capture.sh --quiet
    log "✅ Hashes captured."
else
    log "⚠️  Hash capture script not found, skipping."
fi

# 7. Commit and Push
if [ -n "${NO_COMMIT:-}" ]; then
    log "⏭️  NO_COMMIT set; skipping commit and push."
    exit 0
fi

DATE=$(date +%F)
git add flake.lock
git add nix/overlay.nix 2>/dev/null || true
git add hashes/ 2>/dev/null || true  # Add hashes if they exist
git commit -m "chore: update flake.lock ($DATE)"

log "🚀 Pushing update to origin/$BRANCH..."
git push origin "$BRANCH"

log "🎉 Success."
