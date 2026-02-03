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

# Source the decrypted env file and exec the MCP server
set -a
# shellcheck source=/dev/null
source "$SECRETS_FILE"
set +a

exec uvx unifi-network-mcp
