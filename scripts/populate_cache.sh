#!/usr/bin/env bash
set -euo pipefail

# --- Helpers ---------------------------------------------------------------
json_eval() {
    nix eval --json --impure --expr "$1"
}

# Pull host lists directly from hosts.nix using only builtins.
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

# --- Build all NixOS toplevels (these already include HM via your flake) ---
if ((${#NIXOS_HOSTS[@]})); then
    echo ">> Building NixOS toplevels: ${NIXOS_HOSTS[*]}"
    nix build --no-link --keep-going --print-out-paths \
        $(printf '.#nixosConfigurations.%s.config.system.build.toplevel ' "${NIXOS_HOSTS[@]}")
else
    echo ">> No nixos hosts found."
fi

# --- Build HM-only hosts (best-effort; don't abort on one failure) ----------
if ((${#HM_ONLY_HOSTS[@]})); then
    echo ">> Building Home-Manager-only activation packages: ${HM_ONLY_HOSTS[*]}"
    for h in "${HM_ONLY_HOSTS[@]}"; do
        echo "   -> $h"
        if ! nix build --no-link --print-out-paths ".#homeConfigurations.${h}.activationPackage"; then
            echo "      WARN: failed to evaluate/build HM for '$h' (continuing)."
        fi
    done
else
    echo ">> No HM-only hosts found."
fi

echo ">> Done."
