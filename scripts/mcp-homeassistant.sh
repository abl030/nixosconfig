#!/usr/bin/env bash
# Wrapper script to launch Home Assistant MCP server (ha-mcp)
# https://github.com/homeassistant-ai/ha-mcp
set -euo pipefail

SECRETS_FILE="${HOMEASSISTANT_MCP_ENV_FILE:-/run/secrets/mcp/homeassistant.env}"

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "Error: Secrets file not found: $SECRETS_FILE" >&2
  echo "Ensure homelab.mcp.homeassistant.enable = true and rebuild." >&2
  exit 1
fi

# Source the decrypted env file (contains HA_TOKEN)
set -a
# shellcheck source=/dev/null
source "$SECRETS_FILE"
set +a

# ha-mcp expects HOMEASSISTANT_URL and HOMEASSISTANT_TOKEN
export HOMEASSISTANT_URL="${HA_URL:-https://home.ablz.au}"
export HOMEASSISTANT_TOKEN="${HA_TOKEN:-}"

exec uvx ha-mcp
