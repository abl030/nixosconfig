#!/usr/bin/env bash
# Wrapper script to launch Soulseek MCP server
# https://glama.ai/mcp/servers/@jotraynor/SoulseekMCP
set -euo pipefail

SECRETS_FILE="${SOULSEEK_MCP_ENV_FILE:-/run/secrets/mcp/soulseek.env}"

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "Error: Secrets file not found: $SECRETS_FILE" >&2
  echo "Create secrets/mcp/soulseek.env with SOULSEEK_USERNAME, SOULSEEK_PASSWORD, DOWNLOAD_PATH" >&2
  exit 1
fi

# Source the decrypted env file
set -a
# shellcheck source=/dev/null
source "$SECRETS_FILE"
set +a

# Set default download path if not specified
export DOWNLOAD_PATH="${DOWNLOAD_PATH:-/tmp/soulseek-downloads}"

exec npx -y @jotraynor/soulseekmcp
