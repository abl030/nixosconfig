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

# SoulseekMCP is not published on npm — it must be cloned and built locally.
# See: https://glama.ai/mcp/servers/@jotraynor/SoulseekMCP
# If you have a local build, set SOULSEEKMCP_PATH to the built index.js
if [[ -n "${SOULSEEKMCP_PATH:-}" && -f "$SOULSEEKMCP_PATH" ]]; then
  exec node "$SOULSEEKMCP_PATH"
fi

echo "Error: SoulseekMCP is not available as an npm package." >&2
echo "Clone https://github.com/jotraynor/SoulseekMCP, run 'npm install && npm run build'," >&2
echo "then set SOULSEEKMCP_PATH=/path/to/SoulseekMCP/build/index.js" >&2
exit 1
