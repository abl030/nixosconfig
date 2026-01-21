#!/usr/bin/env bash
set -euo pipefail

DATA_ROOT="${DATA_ROOT:-$HOME/podman-data}"
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DATA_ROOT XDG_RUNTIME_DIR

TIMEOUT_S="${TIMEOUT_S:-120}"
VERBOSE="${VERBOSE:-0}"
FORCE="${FORCE:-0}"
RETRIES="${RETRIES:-3}"
BACKOFF_S="${BACKOFF_S:-30}"
PRUNE_BEFORE="${PRUNE_BEFORE:-1}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
report="${repo_root}/docs/podman-test-report.md"

mapfile -t files < <(find "$repo_root/docker" -name "docker-compose.yml" -o -name "docker-compose.yaml" | sort)

if [[ ! -f "$report" ]]; then
  {
    echo "# Podman Stack Test Report"
    echo
    echo "Date: $(date -Iseconds)"
    echo "DATA_ROOT=$DATA_ROOT"
    echo
  } > "$report"
else
  {
    echo
    echo "## Resume: $(date -Iseconds)"
    echo "DATA_ROOT=$DATA_ROOT"
    echo "TIMEOUT_S=$TIMEOUT_S"
    echo
  } >> "$report"
fi

for compose in "${files[@]}"; do
  stack_dir="$(dirname "$compose")"
  stack_name="${stack_dir#$repo_root/}"

  if [[ "$FORCE" != "1" ]] && rg -q "PASS: ${stack_name}|FAIL\\([^)]*\\): ${stack_name}" "$report"; then
    echo "SKIP: $stack_name (already in report)" | tee -a "$report"
    echo >> "$report"
    echo "----" >> "$report"
    echo >> "$report"
    continue
  fi

  echo "Testing $stack_name" | tee -a "$report"

  extra=()
  if [[ "$VERBOSE" == "1" ]]; then
    extra+=("--verbose")
  fi
  if [[ "$PRUNE_BEFORE" != "1" ]]; then
    extra+=("--no-prune")
  fi
  extra+=("--retries" "$RETRIES" "--backoff" "$BACKOFF_S")

  if timeout "$TIMEOUT_S" "$repo_root/scripts/podman-stack-test.sh" "${extra[@]}" "$stack_dir" "$compose" >> "$report" 2>&1; then
    echo "PASS: $stack_name" | tee -a "$report"
  else
    status=$?
    echo "FAIL($status): $stack_name" | tee -a "$report"
  fi
  echo >> "$report"
  echo "----" >> "$report"
  echo >> "$report"
done
