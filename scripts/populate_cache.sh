#!/usr/bin/env bash
set -euo pipefail

# Verify and build everything the fleet needs in ONE pass, then GC-root every
# host closure so doc1 serves it to the fleet (push-deploy reads the
# <host>-system roots).
#
# nix-eval-jobs evaluates the flake's checks, packages, dev shells, every NixOS
# system and every Home Manager activation in parallel workers, purely from the
# flake (no --impure, so FULL_CHECK/HOST_CHECKS are unset and checks are the
# audit set; hosts are built directly instead). A single `nix build` then builds
# every derivation with doc1's full parallelism, so one slow package no longer
# serialises the fleet. This replaces `FULL_CHECK=1 nix flake check` plus a
# host-by-host build loop, which evaluated the fleet twice on one core per
# rolling-update group. See docs/wiki/infrastructure/rolling-flake-update.md.

# --- Configuration ---------------------------------------------------------
# Where to store the symlinks (GC Roots).
# As long as files exist here, the Nix Store won't delete the builds.
CI_RESULTS_DIR="${RFU_CI_RESULTS_DIR:-/home/abl030/.cache/nix-ci-results}"
SYSTEM="${CI_SYSTEM:-x86_64-linux}"
# A big host evaluates in ~7 GiB; workers x memory is nix-eval-jobs' combined
# budget, kept under the updater unit's MemoryHigh.
WORKERS="${CI_EVAL_WORKERS:-3}"
WORKER_MEMORY_MB="${CI_EVAL_WORKER_MEMORY_MB:-6144}"
EVAL_JOBS="${NIX_EVAL_JOBS:-nix-eval-jobs}"
mkdir -p "$CI_RESULTS_DIR"

# Tag for logs
TAG="nix-ci"

# Log to stderr. Systemd picks this up automatically.
# Usage: log "INFO" "Message here"
log() {
    local level="$1"
    shift
    echo "[$TAG] [$level] $*" >&2
}

for tool in jq "$EVAL_JOBS"; do
    if ! command -v "$tool" &>/dev/null; then
        log "ERROR" "$tool is missing. Please enter the devshell (nix develop) or install it."
        exit 1
    fi
done

JOBS_FILE="$(mktemp)"
trap 'rm -f "$JOBS_FILE"' EXIT

# Home Manager activations are built for every homeConfigurations entry, as the
# old FULL_CHECK host checks did; <host>-home roots keep them cached.
# shellcheck disable=SC2016  # Nix ${...} interpolation, not shell
SELECT='outputs: let
  s = "'"$SYSTEM"'";
  pick = name: if builtins.hasAttr name outputs && builtins.hasAttr s outputs.${name} then outputs.${name}.${s} else {};
in {
  checks = pick "checks";
  packages = pick "packages";
  devShells = pick "devShells";
  system = builtins.mapAttrs (_: c: c.config.system.build.toplevel) (outputs.nixosConfigurations or {});
  home = builtins.mapAttrs (_: h: h.activationPackage) (outputs.homeConfigurations or {});
}'

log "INFO" "Evaluating checks, packages, dev shells and every host ($WORKERS workers)..."
"$EVAL_JOBS" --flake '.#' --select "$SELECT" --force-recurse \
    --workers "$WORKERS" --max-memory-size "$WORKER_MEMORY_MB" >"$JOBS_FILE"

errors="$(jq -r 'select(.error) | "\(.attr): \(.error)"' "$JOBS_FILE")"
if [ -n "$errors" ]; then
    log "ERROR" "Evaluation failed:"
    printf '%s\n' "$errors" >&2
    exit 1
fi

mapfile -t DRVS < <(jq -r 'select(.drvPath) | "\(.drvPath)^*"' "$JOBS_FILE")
if [ "${#DRVS[@]}" -eq 0 ]; then
    log "ERROR" "Evaluation produced no derivations."
    exit 1
fi

log "INFO" "Building ${#DRVS[@]} top-level derivations in one invocation..."
if ! nix build --no-link --keep-going --print-build-logs "${DRVS[@]}"; then
    log "ERROR" "Build failed (see above)."
    exit 1
fi

log "INFO" "Refreshing GC roots in $CI_RESULTS_DIR..."
while read -r kind host drv; do
    nix build --out-link "${CI_RESULTS_DIR}/${host}-${kind}" "${drv}^out"
done < <(jq -r 'select(.drvPath and (.attrPath[0] == "system" or .attrPath[0] == "home"))
    | "\(.attrPath[0]) \(.attrPath[1]) \(.drvPath)"' "$JOBS_FILE")

log "INFO" "Run complete. All artifacts cached."
