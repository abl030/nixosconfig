#!/usr/bin/env bash
# scripts/nix_cleanup.sh
# Semi-automated Nix cleanup for PR branches:
# 1) deadnix --edit + statix fix (in place)
# 2) Re-run to gather remaining findings
# 3) Build single LLM-ready prompt with errors + full files
# 4) Autocommit any changes (autofixes + prompt)

set -euo pipefail

# --- config ---------------------------------------------------------------
REPORT_PATH="${REPORT_PATH:-.github/llm/NIX_LINT_PATCH_PROMPT.txt}"
AUTHOR_NAME="${AUTHOR_NAME:-nix-cleanup-bot}"
AUTHOR_EMAIL="${AUTHOR_EMAIL:-ci@ablz.au}"

# If you prefer your repo's pinned tools, set STATIX_BIN/DEADNIX_BIN to absolute paths.
run_statix() { ${STATIX_BIN:-nix run --quiet nixpkgs#statix --} "$@"; }
run_deadnix() { ${DEADNIX_BIN:-nix run --quiet nixpkgs#deadnix --} "$@"; }

# Limit scope to tracked .nix files (fast + avoids vendored dirs)
mapfile -d '' NIX_FILES < <(git ls-files -z -- '*.nix' || true)

# Ensure we're in a git repo root
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${ROOT}" ]]; then
  echo "✖ Must be run inside a git repo." >&2
  exit 1
fi
cd "$ROOT"

# --- Phase 1: in-place autofix -------------------------------------------
if ((${#NIX_FILES[@]} == 0)); then
  echo "No tracked .nix files found; nothing to do."
  exit 0
fi

echo "▶ deadnix --edit (autofix)…"
# deadnix accepts files/dirs; we pass explicit files to be safe and fast.
run_deadnix --edit "${NIX_FILES[@]}" || true

echo "▶ statix fix (autofix)…"
# statix fix is safe & idempotent; run per-file to avoid arg-limit quirks.
for f in "${NIX_FILES[@]}"; do
  run_statix fix "$f" || true
done

# Commit autofixed changes (if any)
if ! git diff --quiet; then
  git add -A
  GIT_AUTHOR_NAME="$AUTHOR_NAME" \
    GIT_AUTHOR_EMAIL="$AUTHOR_EMAIL" \
    GIT_COMMITTER_NAME="$AUTHOR_NAME" \
    GIT_COMMITTER_EMAIL="$AUTHOR_EMAIL" \
    git commit -m "chore(nix): autofix with deadnix --edit & statix fix"
fi

# --- Phase 2: collect remaining issues -----------------------------------
echo "▶ Re-running linters to collect remaining issues…"
STATIX_OUT="$(mktemp)"
DEADNIX_OUT_HUMAN="$(mktemp)"

# statix: single-line, grep/awk-friendly ('file:line:col: msg')
run_statix check -o errfmt . | tee "$STATIX_OUT" || true

# deadnix: human-readable; we’ll slice per-file blocks with awk
run_deadnix . >"$DEADNIX_OUT_HUMAN" || true

# Build unique file list from both tools
declare -A NEED_FILES=()

# From statix (errfmt)
if [[ -s "$STATIX_OUT" ]]; then
  while IFS=: read -r f _; do
    [[ -n "${f:-}" ]] && NEED_FILES["$f"]=1
  done < <(grep -E '^[^:]+:[0-9]+:[0-9]+:' "$STATIX_OUT" || true)
fi

# From deadnix (human-readable headers like  ╭─[path:line:col])
if [[ -s "$DEADNIX_OUT_HUMAN" ]]; then
  while read -r f; do
    [[ -n "$f" ]] && NEED_FILES["$f"]=1
  done < <(grep -oP '\[(.+?\.nix):\d+:\d+\]' "$DEADNIX_OUT_HUMAN" |
    sed 's/^\[//;s/\]$//' | cut -d: -f1 | sort -u || true)
fi

# If clean, still emit a tiny report (handy in CI logs), then exit 0
if ((${#NEED_FILES[@]} == 0)); then
  mkdir -p "$(dirname "$REPORT_PATH")"
  {
    echo "# LLM patch prompt: remaining Nix lints"
    echo
    echo "_Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")_"
    echo
    echo "No remaining issues after deadnix/statix autofix 🎉"
  } >"$REPORT_PATH"
  git add -A "$REPORT_PATH" || true
  if ! git diff --cached --quiet; then
    git commit -m "ci: add lint report (clean)"
  fi
  echo "✓ Clean. Wrote $REPORT_PATH"
  exit 0
fi

# --- Phase 3: construct LLM patch prompt ----------------------------------
echo "▶ Building LLM patch prompt → $REPORT_PATH"
mkdir -p "$(dirname "$REPORT_PATH")"

# Sorted file list for stable diffs
FILES=("${!NEED_FILES[@]}")
IFS=$'\n' FILES=($(printf "%s\n" "${FILES[@]}" | sort))
unset IFS

{
  echo "# LLM patch prompt: remaining Nix lints"
  echo
  echo "_Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")_"
  echo
  echo "This branch has already applied in-place fixes with:"
  echo "  • deadnix --edit (removes unused bindings/args)"
  echo "  • statix fix (safe suggestions)"
  echo
  echo "Below, for each file: **errors first**, then the **full current file**."
  echo
  echo "Return either:"
  echo "  1) a unified diff (preferred), or"
  echo "  2) full file replacements for only the files listed."
  echo
  echo "Constraints: make the **smallest** changes needed to make both \`deadnix\` and"
  echo "\`statix check\` pass. Preserve comments, semantics, and style; avoid churn."
  echo

  for f in "${FILES[@]}"; do
    echo
    echo "================================================================"
    echo "FILE: $f"
    echo "----------------------------------------------------------------"
    echo "Statix (errfmt):"
    (grep -F -- "$f:" "$STATIX_OUT" || echo "(no statix findings)") | sed 's/^/  /'
    echo
    echo "Deadnix (context):"
    # Print block(s) belonging to this file from the human-readable report.
    awk -v target="$f" '
      # Matches headers like:  ╭─[path/to/file.nix:12:3]
      match($0, /\[([^]]+\.nix):[0-9]+:[0-9]+\]/, m) {
        curfile = m[1]; printing = (curfile == target)
      }
      printing { print }
    ' "$DEADNIX_OUT_HUMAN" | sed 's/^/  /' || true
    echo
    echo "----- BEGIN FILE $f -----"
    echo '```nix'
    cat -- "$f" || true
    echo '```'
    echo "----- END FILE $f -----"
  done

  echo
  echo "== Final instructions to the LLM =="
  echo "Apply surgical edits so that:"
  echo "  • deadnix (no flags) reports zero unused declarations"
  echo "  • statix check (default) reports zero lints"
  echo "Provide either a patch or full-file outputs for ONLY the files above."
} >"$REPORT_PATH"

# Commit the LLM prompt (always commit changes)
git add -A "$REPORT_PATH" || true
if ! git diff --cached --quiet; then
  GIT_AUTHOR_NAME="$AUTHOR_NAME" \
    GIT_AUTHOR_EMAIL="$AUTHOR_EMAIL" \
    GIT_COMMITTER_NAME="$AUTHOR_NAME" \
    GIT_COMMITTER_EMAIL="$AUTHOR_EMAIL" \
    git commit -m "ci: add LLM lint patch prompt for remaining statix/deadnix issues"
fi

echo "✓ Wrote $REPORT_PATH"
