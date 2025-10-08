#!/usr/bin/env bash
# scripts/linting.sh
# Semi-automated Nix cleanup for PR branches:
# 1) deadnix --edit + statix fix (in place)
# 2) Re-run to gather remaining findings
# 3) Build single LLM-ready prompt with errors + full files (no diffs)
# 4) Autocommit any changes (autofixes + prompt)
#
# Modes:
#   - No args           -> scan whole repo (tracked *.nix)
#   - ARGS              -> only those files
#   - --files-from -    -> read newline-separated file list from stdin
#
# Safety toggles (env vars):
#   SAFE_CI_ONLY=1              # refuse outside CI (default 1)
#   REQUIRE_EXPLICIT_ON_LOCAL=1 # require explicit file list when local (default 1)
#   NO_COMMIT=0                 # 1 = do not commit (dry-run)
#   FAIL_ON_REMAINING=1         # 1 = exit 1 if findings remain (default 1)
#   WRITE_STEP_SUMMARY=1        # 1 = append summary to $GITHUB_STEP_SUMMARY if set

set -euo pipefail

# --- config ---------------------------------------------------------------
REPORT_PATH="${REPORT_PATH:-.github/llm/NIX_LINT_PATCH_PROMPT.txt}"
AUTHOR_NAME="${AUTHOR_NAME:-nix-cleanup-bot}"
AUTHOR_EMAIL="${AUTHOR_EMAIL:-ci@ablz.au}"

# Safety rails
SAFE_CI_ONLY="${SAFE_CI_ONLY:-1}"
REQUIRE_EXPLICIT_ON_LOCAL="${REQUIRE_EXPLICIT_ON_LOCAL:-1}"
NO_COMMIT="${NO_COMMIT:-0}"
FAIL_ON_REMAINING="${FAIL_ON_REMAINING:-1}"
WRITE_STEP_SUMMARY="${WRITE_STEP_SUMMARY:-1}"

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

# CI guard
if [[ "$SAFE_CI_ONLY" = "1" && -z "${GITHUB_ACTIONS:-}${CI:-}" ]]; then
  echo "✖ Refusing to run outside CI. Set SAFE_CI_ONLY=0 to override." >&2
  exit 2
fi

# --- input handling -------------------------------------------------------
INPUT_MODE="auto"
declare -a INPUT_FILES=()

while (($# > 0)); do
  case "${1:-}" in
  --files-from)
    shift
    src="${1:-}"
    [[ -z "$src" ]] && {
      echo "✖ --files-from requires a path or '-'" >&2
      exit 2
    }
    if [[ "$src" == "-" ]]; then
      while IFS= read -r line; do
        [[ -n "$line" ]] && INPUT_FILES+=("${line%$'\r'}")
      done
    else
      while IFS= read -r line; do
        [[ -n "$line" ]] && INPUT_FILES+=("${line%$'\r'}")
      done <"$src"
    fi
    INPUT_MODE="explicit"
    shift || true
    ;;
  --)
    shift
    while (($# > 0)); do
      INPUT_FILES+=("$1")
      shift
    done
    INPUT_MODE="explicit"
    ;;
  -*)
    echo "✖ Unknown option: $1" >&2
    exit 2
    ;;
  *)
    INPUT_FILES+=("$1")
    INPUT_MODE="explicit"
    shift
    ;;
  esac
done

# Local guard: require explicit list if not CI
if [[ -z "${GITHUB_ACTIONS:-}${CI:-}" && "$REQUIRE_EXPLICIT_ON_LOCAL" = "1" && "$INPUT_MODE" = "auto" ]]; then
  echo "✖ Local run requires an explicit file list (args or --files-from -). Set REQUIRE_EXPLICIT_ON_LOCAL=0 to override." >&2
  exit 2
fi

# Normalize file list
declare -a NIX_FILES=()
if [[ "$INPUT_MODE" == "explicit" ]]; then
  declare -A seen=()
  for p in "${INPUT_FILES[@]}"; do
    p="${p#./}"
    [[ "$p" == *.nix ]] || continue
    [[ -e "$p" ]] || continue
    if [[ -z "${seen[$p]:-}" ]]; then
      NIX_FILES+=("$p")
      seen["$p"]=1
    fi
  done
  if ((${#NIX_FILES[@]} == 0)); then
    echo "✖ No existing .nix files provided." >&2
    exit 0
  fi
  echo "▶ Scoped run: ${#NIX_FILES[@]} file(s)"
else
  mapfile -d '' NIX_FILES < <(git ls-files -z -- '*.nix' || true)
  if ((${#NIX_FILES[@]} == 0)); then
    echo "No tracked .nix files found; nothing to do."
    exit 0
  fi
  echo "▶ Auto-scan: ${#NIX_FILES[@]} tracked .nix file(s)"
fi

# Targets for the re-check step (scope to files if provided)
if [[ "$INPUT_MODE" == "explicit" ]]; then
  STATIX_TARGETS=("${NIX_FILES[@]}")
  DEADNIX_TARGETS=("${NIX_FILES[@]}")
else
  STATIX_TARGETS=(.)
  DEADNIX_TARGETS=(.)
fi

# --- Phase 1: in-place autofix -------------------------------------------
echo "▶ deadnix --edit (autofix)…"
NO_COLOR=1 run_deadnix --edit "${NIX_FILES[@]}" || true

echo "▶ statix fix (autofix)…"
for f in "${NIX_FILES[@]}"; do
  NO_COLOR=1 run_statix fix "$f" || true
done

# Commit autofixed changes (if any)
if [[ "$NO_COMMIT" != "1" ]]; then
  if ! git diff --quiet; then
    git add -A
    GIT_AUTHOR_NAME="$AUTHOR_NAME" \
      GIT_AUTHOR_EMAIL="$AUTHOR_EMAIL" \
      GIT_COMMITTER_NAME="$AUTHOR_NAME" \
      GIT_COMMITTER_EMAIL="$AUTHOR_EMAIL" \
      git commit -m "chore(nix): autofix with deadnix --edit & statix fix"
  fi
else
  echo "↪ NO_COMMIT=1 (skipping autofix commit)"
fi

# --- Phase 2: collect remaining issues -----------------------------------
echo "▶ Re-running linters to collect remaining issues…"
STATIX_OUT="$(mktemp)"
DEADNIX_JSON="$(mktemp)"
DEADNIX_HUMAN="$(mktemp)"

# statix check: single target only → loop for scoped runs; single dot for auto.
: >"$STATIX_OUT"
if [[ "${STATIX_TARGETS[*]}" == "." ]]; then
  NO_COLOR=1 run_statix check -o errfmt . 2>&1 | tee -a "$STATIX_OUT" || true
else
  for f in "${STATIX_TARGETS[@]}"; do
    NO_COLOR=1 run_statix check -o errfmt "$f" 2>&1 >>"$STATIX_OUT" || true
  done
fi

# deadnix machine-parse + human-readable for context slicing
NO_COLOR=1 run_deadnix -o json "${DEADNIX_TARGETS[@]}" >"$DEADNIX_JSON" || true
NO_COLOR=1 run_deadnix -o human-readable "${DEADNIX_TARGETS[@]}" >"$DEADNIX_HUMAN" || true

# Build unique file list from both tools
declare -A NEED_FILES=()

# From statix (errfmt): only accept real *.nix hits with >line:col or :line:col
if [[ -s "$STATIX_OUT" ]]; then
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    NEED_FILES["$f"]=1
  done < <(
    grep -E '(^|/)[^[:space:]]+\.nix([>:])[0-9]+:' "$STATIX_OUT" |
      sed -E 's#^\./##; s#([>:])[0-9]+:.*$##' |
      awk 'NF' | sort -u
  )
fi

# From deadnix (json). Extract "file": "…"
if [[ -s "$DEADNIX_JSON" ]]; then
  while IFS= read -r f; do
    [[ -n "$f" ]] && NEED_FILES["$f"]=1
  done < <(grep -oP '"file"\s*:\s*"([^"]+\.nix)"' "$DEADNIX_JSON" |
    sed 's/.*"\(.*\)"/\1/' | sed 's#^\./##' | sort -u)
fi

mkdir -p "$(dirname "$REPORT_PATH")"

# --- helper: write a brief CI summary if available ------------------------
write_summary() {
  local title="$1"
  shift
  local files=("$@")
  if [[ "$WRITE_STEP_SUMMARY" = "1" && -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      printf "### %s\n\n" "$title"
      if ((${#files[@]})); then
        printf "Files with remaining issues (%d):\n\n" "${#files[@]}"
        for x in "${files[@]}"; do printf " %s\n" "$x"; done
        printf "\nReport saved to \`%s\`.\n" "$REPORT_PATH"
      else
        printf "No remaining issues after autofix.\n"
      fi
    } >>"$GITHUB_STEP_SUMMARY"
  fi
}

# --- Emit "clean" report & exit -------------------------------------------
if ((${#NEED_FILES[@]} == 0)); then
  {
    printf "%s\n\n" "# LLM patch prompt: remaining Nix lints"
    printf "_Generated: %s_\n\n" "$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    printf "%s\n" "No remaining issues after deadnix/statix autofix 🎉"
  } >"$REPORT_PATH"
  if [[ "$NO_COMMIT" != "1" ]]; then
    git add -A "$REPORT_PATH" || true
    if ! git diff --cached --quiet; then
      git commit -m "ci: add lint report (clean)"
    fi
  else
    echo "↪ NO_COMMIT=1 (skipping report commit)"
  fi
  write_summary "Nix lint: clean ✅"
  echo "✓ Clean. Wrote $REPORT_PATH"
  exit 0
fi

# --- Phase 3: construct LLM prompt (FULL FILES ONLY) ----------------------
FILES=("${!NEED_FILES[@]}")
IFS=$'\n' FILES=($(printf "%s\n" "${FILES[@]}" | sort))
unset IFS

# Header
{
  printf "%s\n\n" "# LLM patch prompt: remaining Nix lints"
  printf "_Generated: %s_\n\n" "$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
  printf "%s\n" "Autofixes done with:"
  printf "%s\n" "  • deadnix --edit"
  printf "%s\n\n" "  • statix fix"
  printf "%s\n\n" "For each file below, the **lint findings** are listed first, then the **full file**."
  printf "%s\n" "Return **ONLY full file replacements** (no diffs). For each file, output exactly:"
  printf '%s\n' '----- BEGIN FILE <path> -----'
  printf '%s\n' '```nix'
  printf '%s\n' '<complete file contents>'
  printf '%s\n' '```'
  printf '%s\n\n' '----- END FILE <path> -----'
  printf "%s\n" "Constraints: make the **smallest** changes needed so that:"
  printf "%s\n" "  • \`deadnix\` (no flags) reports zero unused declarations"
  printf "%s\n" "  • \`statix check\` (default) reports zero lints"
  printf "%s\n" "Preserve comments, semantics, and style; avoid churn."
} >"$REPORT_PATH"

# Per-file sections
for f in "${FILES[@]}"; do
  {
    printf "\n%s\n" "================================================================"
    printf "FILE: %s\n" "$f"
    printf "%s\n" "----------------------------------------------------------------"
    printf "%s\n" "Statix (errfmt):"
    STATIX_LINES="$(
      { grep -F -e "$f:" -e "./$f:" -e "$f>" -e "./$f>" "$STATIX_OUT" || true; } |
        awk '!seen[$0]++'
    )"
    if [[ -z "$STATIX_LINES" ]]; then
      printf "  %s\n" "(no statix findings)"
    else
      printf "%s\n" "$STATIX_LINES" | sed 's/^/  /'
    fi

    printf "\n%s\n" "Deadnix (context):"
    DEADNIX_BLOCK="$(
      awk -v target="$f" '
        match($0, /\[([^]]+\.nix):[0-9]+:[0-9]+\]/, m) {
          curfile = m[1]; printing = (curfile == target)
        }
        printing { print }
      ' "$DEADNIX_HUMAN" | awk '!seen[$0]++'
    )"
    if [[ -z "$DEADNIX_BLOCK" ]]; then
      printf "  %s\n" "(no deadnix findings)"
    else
      printf "%s\n" "$DEADNIX_BLOCK" | sed 's/^/  /'
    fi

    printf "\n"
    printf '%s\n' "----- BEGIN FILE $f -----"
    printf '%s\n' '```nix'
    cat -- "$f" || true
    printf '%s\n' '```'
    printf '%s\n' "----- END FILE $f -----"
  } >>"$REPORT_PATH"
done

# Commit the LLM prompt
if [[ "$NO_COMMIT" != "1" ]]; then
  git add -A "$REPORT_PATH" || true
  if ! git diff --cached --quiet; then
    GIT_AUTHOR_NAME="$AUTHOR_NAME" \
      GIT_AUTHOR_EMAIL="$AUTHOR_EMAIL" \
      GIT_COMMITTER_NAME="$AUTHOR_NAME" \
      GIT_COMMITTER_EMAIL="$AUTHOR_EMAIL" \
      git commit -m "ci: add LLM lint patch prompt for remaining statix/deadnix issues (full files only, dedup + placeholders)"
  fi
else
  echo "↪ NO_COMMIT=1 (skipping report commit)"
fi

# CI signals: annotate + summary + FAIL if requested
write_summary "Nix lint: manual edits required ❌" "${FILES[@]}"

# GitHub annotation for quick visibility
printf '%s\n' "::error ::Nix lint fails after autofix; manual changes required in ${#FILES[@]} file(s). See ${REPORT_PATH}"

# Exit non-zero to fail the job (unless disabled)
if [[ "$FAIL_ON_REMAINING" = "1" ]]; then
  exit 1
fi

echo "⚠ Findings remain, but FAIL_ON_REMAINING=0 → not failing the job."
exit 0
