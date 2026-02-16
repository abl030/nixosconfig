#!/usr/bin/env bash
# Wrapper script to launch slskd MCP server
# https://github.com/abl030/slskd-mcp
set -euo pipefail

SECRETS_FILE="${SLSKD_MCP_ENV_FILE:-/run/secrets/mcp/slskd.env}"

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "Error: Secrets file not found: $SECRETS_FILE" >&2
  echo "Ensure homelab.mcp.slskd.enable = true and rebuild." >&2
  exit 1
fi

# Export env vars safely (avoids shell expansion of $, `, ! in values)
while IFS='=' read -r key value; do
  [[ -z "$key" || "$key" == \#* ]] && continue
  export "$key=$value"
done < "$SECRETS_FILE"

exec nix run github:abl030/slskd-mcp
