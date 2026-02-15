#!/usr/bin/env bash
# Wrapper script to launch Soulseek MCP server
# https://glama.ai/mcp/servers/@jotraynor/SoulseekMCP
set -euo pipefail

SECRETS_FILE="${SOULSEEK_MCP_ENV_FILE:-/run/secrets/mcp/soulseek.env}"

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "Error: Secrets file not found: $SECRETS_FILE" >&2
  echo "Ensure homelab.mcp.soulseek.enable = true and rebuild." >&2
  exit 1
fi

# Export env vars safely (avoids shell expansion of $, `, ! in values)
while IFS='=' read -r key value; do
  [[ -z "$key" || "$key" == \#* ]] && continue
  export "$key=$value"
done < "$SECRETS_FILE"

# Set default download path if not specified
export DOWNLOAD_PATH="${DOWNLOAD_PATH:-/tmp/soulseek-downloads}"

exec npx -y @jotraynor/soulseekmcp
