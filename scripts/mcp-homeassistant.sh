#!/usr/bin/env bash
# Wrapper script to launch Home Assistant MCP server via mcp-proxy
# Uses mcp-proxy as a stdio-to-HTTP bridge since Claude Code doesn't
# support Authorization headers in HTTP MCP config.
set -euo pipefail

SECRETS_FILE="${HOMEASSISTANT_MCP_ENV_FILE:-/run/secrets/mcp/homeassistant.env}"

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "Error: Secrets file not found: $SECRETS_FILE" >&2
  echo "Ensure homelab.mcp.homeassistant.enable = true and rebuild." >&2
  exit 1
fi

# Source the decrypted env file
set -a
# shellcheck source=/dev/null
source "$SECRETS_FILE"
set +a

# mcp-proxy reads API_ACCESS_TOKEN for Bearer auth
export API_ACCESS_TOKEN="${HA_TOKEN:-}"

exec uvx mcp-proxy --transport=streamablehttp https://home.ablz.au/api/mcp
