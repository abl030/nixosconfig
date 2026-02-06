#!/usr/bin/env bash
# Wrapper script to launch UniFi MCP server with pre-decrypted credentials
# Secrets are decrypted at NixOS build time via sops-nix to /run/secrets/
set -euo pipefail

SECRETS_FILE="${UNIFI_MCP_ENV_FILE:-/run/secrets/mcp/unifi.env}"

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "Error: Secrets file not found: $SECRETS_FILE" >&2
  echo "Ensure homelab.mcp.unifi.enable = true and rebuild." >&2
  exit 1
fi

# Export env vars safely (avoids shell expansion of $, `, ! in values)
while IFS='=' read -r key value; do
  [[ -z "$key" || "$key" == \#* ]] && continue
  export "$key=$value"
done < "$SECRETS_FILE"

exec unifi-mcp
