#!/usr/bin/env bash
# scripts/linting.sh
set -euo pipefail

REPORT_PATH="${REPORT_PATH:-.github/llm/NIX_LINT_PATCH_PROMPT.txt}"
AUTHOR_NAME="${AUTHOR_NAME:-nix-cleanup-bot}"
AUTHOR_EMAIL="${AUTHOR_EMAIL:-ci@ablz.au}"

run_statix() { ${STATIX_BIN:-nix run --quiet nixpkgs#statix --} "$@"; }
run_deadnix() { ${DEADNIX_BIN:-nix run --quiet nixpkgs#deadnix --} "$@"; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || {
  echo "✖ Must be in a git repo" >&2
  exit 1
}
cd "$ROOT"

# Scope: tracked .nix files only for autofix
mapfile -d '' NIX_FILES < <(git ls-files -z -- '*.nix' || true)
((${#NIX_FILES[@]})) || {
  echo "No .nix files"
  exit 0
}

echo "▶ deadnix --edit (autofix)…"
NO_COLOR=1 run_deadnix --edit "${NIX_FILES[@]}" || true

echo "▶ statix fix (autofix)…"
for f in "${NIX_FILES[@]}"; do NO_COLOR=1 run_statix fix "$f" || true; done

# Commit autofixes if any
if ! git diff --quiet; then
  git add -A
  GIT_AUTHOR_NAME="$AUTHOR_NAME" GIT_AUTHOR_EMAIL="$AUTHOR_EMAIL" \
    GIT_COMMITTER_NAME="$AUTHOR_NAME" GIT_COMMITTER_EMAIL="$AUTHOR_EMAIL" \
    git commit -m "chore(nix): autofix with deadnix --edit & statix fix"
fi

echo "▶ Re-running linters to collect remaining issues…"
STATIX_OUT="$(mktemp)"
DEADNIX_JSON="$(mktemp)"
DEADNIX_HUMAN="$(mktemp)"

# Robust: capture both stdout/stderr; disable color
NO_COLOR=1 run_statix check -o errfmt . 2>&1 | tee "$STATIX_OUT" || true
NO_COLOR=1 run_deadnix -o json . >"$DEADNIX_JSON" || true            # machine parse
NO_COLOR=1 run_deadnix -o human-readable . >"$DEADNIX_HUMAN" || true # for context

# Collect unique file paths from both tools
declare -A NEED_FILES=()

# From statix (errfmt). Accept absolute, relative, or ./ paths.
if [[ -s "$STATIX_OUT" ]]; then
  while IFS= read -r f; do
    [[ -n "$f" ]] && NEED_FILES["$f"]=1
  done < <(awk -F: 'NF>=4 {print $1}' "$STATIX_OUT" | sed 's#^\./##' | sort -u)
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

# Build the LLM-ready prompt
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
  echo "For each file: **errors first**, then **full file**. Return either:"
  echo "  1) a unified diff (preferred), or"
  echo "  2) full file replacements (only for the files listed)."
  echo
  echo "Constraints: minimal edits to make both \`deadnix\` and \`statix check\` pass."
  echo

  for f in "${FILES[@]}"; do
    echo
    echo "================================================================"
    echo "FILE: $f"
    echo "----------------------------------------------------------------"
    echo "Statix (errfmt):"
    (grep -E "^(|\.\/)?$(printf '%s' "$f" | sed 's/[.[\*^$(){}+?|/\\]/\\&/g'):" "$STATIX_OUT" ||
      echo "(no statix findings)") | sed 's/^/  /'
    echo
    echo "Deadnix (context):"
    # Slice the human-readable report to just this file’s blocks
    awk -v target="$f" '
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
  echo "Apply surgical edits so that:"
  echo "  • deadnix (no flags) reports zero unused declarations"
  echo "  • statix check (default) reports zero lints"
  echo "Output a patch or full-file replacements for ONLY the files above."
} >"$REPORT_PATH"

git add -A "$REPORT_PATH" || true
if ! git diff --cached --quiet; then
  GIT_AUTHOR_NAME="$AUTHOR_NAME" GIT_AUTHOR_EMAIL="$AUTHOR_EMAIL" \
    GIT_COMMITTER_NAME="$AUTHOR_NAME" GIT_COMMITTER_EMAIL="$AUTHOR_EMAIL" \
    git commit -m "ci: add LLM lint patch prompt for remaining statix/deadnix issues"
fi

echo "✓ Wrote $REPORT_PATH"
