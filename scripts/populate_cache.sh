#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---------------------------------------------------------
# Where to store the symlinks (GC Roots).
# As long as files exist here, the Nix Store won't delete the builds.
CI_RESULTS_DIR="/home/abl030/.cache/nix-ci-results"
mkdir -p "$CI_RESULTS_DIR"

# Tag for logs
TAG="nix-ci"

# --- Helpers ---------------------------------------------------------------

# Log to stderr. Systemd picks this up automatically.
# Usage: log "INFO" "Message here"
log() {
    local level="$1"
    shift
    local msg="$*"
    # Print formatted message to stderr
    echo "[$TAG] [$level] $msg" >&2
}

json_eval() {
    nix eval --json --impure --expr "$1"
}

# --- Pre-flight Checks -----------------------------------------------------
if ! command -v jq &>/dev/null; then
    log "ERROR" "jq is missing. Please enter the devshell (nix develop) or install jq."
    exit 1
fi

log "INFO" "Starting cache population run..."
log "INFO" "GC Roots will be saved to: $CI_RESULTS_DIR"

# --- Host Analysis ---------------------------------------------------------
log "INFO" "Evaluating flake for hosts..."

# Pull host lists directly from hosts.nix
NIXOS_HOSTS_JSON=$(json_eval '
  let hosts = import ./hosts.nix;
  in builtins.filter (n: hosts.${n} ? configurationFile) (builtins.attrNames hosts)
')
HM_ONLY_HOSTS_JSON=$(json_eval '
  let hosts = import ./hosts.nix;
  in builtins.filter (n: !(hosts.${n} ? configurationFile)) (builtins.attrNames hosts)
')

mapfile -t NIXOS_HOSTS < <(jq -r '.[]' <<<"$NIXOS_HOSTS_JSON")
mapfile -t HM_ONLY_HOSTS < <(jq -r '.[]' <<<"$HM_ONLY_HOSTS_JSON")

log "INFO" "Found ${#NIXOS_HOSTS[@]} NixOS hosts and ${#HM_ONLY_HOSTS[@]} Home-Manager hosts."

# --- Build NixOS -----------------------------------------------------------
if ((${#NIXOS_HOSTS[@]})); then
    log "INFO" "Building NixOS toplevels..."

    for host in "${NIXOS_HOSTS[@]}"; do
        log "INFO" "Build starting: $host (System)"

        if nix build --keep-going \
            --out-link "${CI_RESULTS_DIR}/${host}-system" \
            ".#nixosConfigurations.${host}.config.system.build.toplevel"; then

            log "SUCCESS" "Built $host"
        else
            log "ERROR" "Failed to build $host"
            # We don't exit immediately, we try to build the rest
            exit 1
        fi
    done
fi

# --- Build Home Manager ----------------------------------------------------
if ((${#HM_ONLY_HOSTS[@]})); then
    log "INFO" "Building Home-Manager activations..."

    for host in "${HM_ONLY_HOSTS[@]}"; do
        log "INFO" "Build starting: $host (Home)"

        if nix build --keep-going \
            --out-link "${CI_RESULTS_DIR}/${host}-home" \
            ".#homeConfigurations.${host}.activationPackage"; then

            log "SUCCESS" "Built $host"
        else
            log "ERROR" "Failed to build $host"
            # We allow HM failures to pass if you want, but strictly:
            exit 1
        fi
    done
fi

log "INFO" "Run complete. All artifacts cached."
