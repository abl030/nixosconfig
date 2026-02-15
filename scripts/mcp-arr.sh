#!/usr/bin/env bash
# Wrapper script to launch *arr MCP server (Lidarr, Sonarr, Radarr, etc.)
# https://www.npmjs.com/package/mcp-arr-server
set -euo pipefail

SECRETS_FILE="${ARR_MCP_ENV_FILE:-/run/secrets/mcp/arr.env}"

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "Error: Secrets file not found: $SECRETS_FILE" >&2
  echo "Ensure homelab.mcp.arr.enable = true and rebuild." >&2
  exit 1
fi

# Export env vars safely (avoids shell expansion of $, `, ! in values)
while IFS='=' read -r key value; do
  [[ -z "$key" || "$key" == \#* ]] && continue
  export "$key=$value"
done < "$SECRETS_FILE"

# Workaround: mcp-arr-server lists @modelcontextprotocol/sdk as devDependency
# instead of dependency, so npx doesn't install it. Supply it explicitly.
exec npx -y -p @modelcontextprotocol/sdk -p mcp-arr-server mcp-arr
