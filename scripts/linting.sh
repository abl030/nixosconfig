#!/usr/bin/env bash
# scripts/linting.sh
# Semi-automated Nix cleanup for PR branches:
# 1) deadnix --edit + statix fix (in place)
# 2) Re-run to gather remaining findings
# 3) Build single LLM-ready prompt with errors + full files (no diffs)
# 4) Autocommit any changes (autofixes + prompt)

set -euo pipefail

# --- config ---------------------------------------------------------------
REPORT_PATH="${REPORT_PATH:-.github/llm/NIX_LINT_PATCH_PROMPT.txt}"
AUTHOR_NAME="${AUTHOR_NAME:-nix-cleanup-bot}"
AUTHOR_EMAIL="${AUTHOR_EMAIL:-ci@ablz.au}"

# If you prefer pinned tool paths, set STATIX_BIN/DEADNIX_BIN to absolute paths.
run_statix() { ${STATIX_BIN:-nix run --quiet nixpkgs#statix --} "$@"; }
run_deadnix() { ${DEADNIX_BIN:-nix run --quiet nixpkgs#deadnix --} "$@"; }

# Ensure we're at repo root
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${ROOT}" ]]; then
  echo "✖ Must be run inside a git repo." >&2
  exit 1
fi
cd "$ROOT"

# Limit scope to tracked .nix files (avoids vendored dirs etc)
mapfile -d '' NIX_FILES < <(git ls-files -z -- '*.nix' || true)
if ((${#NIX_FILES[@]} == 0)); then
  echo "No tracked .nix files found; nothing to do."
  exit 0
fi

# --- Phase 1: in-place autofix -------------------------------------------
echo "▶ deadnix --edit (autofix)…"
NO_COLOR=1 run_deadnix --edit "${NIX_FILES[@]}" || true

echo "▶ statix fix (autofix)…"
for f in "${NIX_FILES[@]}"; do
  NO_COLOR=1 run_statix fix "$f" || true
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
DEADNIX_JSON="$(mktemp)"
DEADNIX_HUMAN="$(mktemp)"

# statix: single-line format (works well for grep/awk)
NO_COLOR=1 run_statix check -o errfmt . 2>&1 | tee "$STATIX_OUT" || true

# deadnix: machine-parse + human-readable for context slicing
NO_COLOR=1 run_deadnix -o json . >"$DEADNIX_JSON" || true
NO_COLOR=1 run_deadnix -o human-readable . >"$DEADNIX_HUMAN" || true

# Build unique file list from both tools
declare -A NEED_FILES=()

# From statix (errfmt). It may print "path>line:col:..." (or "path:line:col:...").
# Normalize to "path" only and strip leading "./".
if [[ -s "$STATIX_OUT" ]]; then
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    NEED_FILES["$f"]=1
  done < <(sed -E 's#^\./##; s#([>:])[0-9]+:.*$##' "$STATIX_OUT" | awk 'NF' | sort -u)
fi

# From deadnix (json). Extract "file": "…"
if [[ -s "$DEADNIX_JSON" ]]; then
  while IFS= read -r f; do
    [[ -n "$f" ]] && NEED_FILES["$f"]=1
  done < <(grep -oP '"file"\s*:\s*"([^"]+\.nix)"' "$DEADNIX_JSON" |
    sed 's/.*"\(.*\)"/\1/' | sed 's#^\./##' | sort -u)
fi

mkdir -p "$(dirname "$REPORT_PATH")"

if ((${#NEED_FILES[@]} == 0)); then
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

# --- Phase 3: construct LLM prompt (FULL FILES ONLY) ----------------------
FILES=("${!NEED_FILES[@]}")
IFS=$'\n' FILES=($(printf "%s\n" "${FILES[@]}" | sort))
unset IFS

{
  echo "# LLM patch prompt: remaining Nix lints"
  echo
  echo "_Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")_"
  echo
  echo "Autofixes done with:"
  echo "  • deadnix --edit"
  echo "  • statix fix"
  echo
  echo "For each file below, the **lint findings** are listed first, then the **full file**."
  echo
  echo "Return **ONLY full file replacements** (no diffs). For each file, output exactly:"
  echo
  echo "----- BEGIN FILE <path> -----"
  echo '```nix'
  echo "<complete file contents>"
  echo '```'
  echo "----- END FILE <path> -----"
  echo
  echo "Constraints: make the **smallest** changes needed so that:"
  echo "  • \`deadnix\` (no flags) reports zero unused declarations"
  echo "  • \`statix check\` (default) reports zero lints"
  echo "Preserve comments, semantics, and style; avoid churn."
  echo

  for f in "${FILES[@]}"; do
    echo
    echo "================================================================"
    echo "FILE: $f"
    echo "----------------------------------------------------------------"
    echo "Statix (errfmt):"
    (grep -F -e "$f:" -e "./$f:" -e "$f>" -e "./$f>" "$STATIX_OUT" ||
      echo "(no statix findings)") | sed 's/^/  /'
    echo
    echo "Deadnix (context):"
    # Slice the human-readable report to just this file’s blocks
    awk -v target="$f" '
      # Headers look like:  ╭─[path/to/file.nix:12:3]
      match($0, /\[([^]]+\.nix):[0-9]+:[0-9]+\]/, m) {
        curfile = m[1]; printing = (curfile == target)
      }
      printing { print }
    ' "$DEADNIX_HUMAN" | sed 's/^/  /' || true
    echo
    echo "----- BEGIN FILE $f -----"
    echo '```nix'
    cat -- "$f" || true
    echo '```'
    echo "----- END FILE $f -----"
  done

  echo
  echo "== Final instructions to the LLM =="
  echo "Return **only** full file replacements for the files listed above, using the exact markers."
} >"$REPORT_PATH"

# Commit the LLM prompt
git add -A "$REPORT_PATH" || true
if ! git diff --cached --quiet; then
  GIT_AUTHOR_NAME="$AUTHOR_NAME" \
    GIT_AUTHOR_EMAIL="$AUTHOR_EMAIL" \
    GIT_COMMITTER_NAME="$AUTHOR_NAME" \
    GIT_COMMITTER_EMAIL="$AUTHOR_EMAIL" \
    git commit -m "ci: add LLM lint patch prompt for remaining statix/deadnix issues (full files only)"
fi

echo "✓ Wrote $REPORT_PATH"
