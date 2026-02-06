#!/usr/bin/env bash
# Wrapper script to launch *arr MCP server (Lidarr, Sonarr, Radarr, etc.)
# https://www.npmjs.com/package/mcp-arr-server
set -euo pipefail

SECRETS_FILE="${ARR_MCP_ENV_FILE:-/run/secrets/mcp/arr.env}"

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "Error: Secrets file not found: $SECRETS_FILE" >&2
  echo "Create secrets/mcp/arr.env with LIDARR_URL and LIDARR_API_KEY" >&2
  exit 1
fi

# Source the decrypted env file
set -a
# shellcheck source=/dev/null
source "$SECRETS_FILE"
set +a

exec npx -y mcp-arr-server
