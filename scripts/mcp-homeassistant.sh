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

# Export env vars safely (avoids shell expansion of $, `, ! in values)
while IFS='=' read -r key value; do
  [[ -z "$key" || "$key" == \#* ]] && continue
  export "$key=$value"
done < "$SECRETS_FILE"

# ha-mcp expects HOMEASSISTANT_URL and HOMEASSISTANT_TOKEN
export HOMEASSISTANT_URL="${HA_URL:-https://home.ablz.au}"
export HOMEASSISTANT_TOKEN="${HA_TOKEN:-}"

exec uvx ha-mcp
