#!/usr/bin/env bash
# Wrapper script to launch pfSense MCP server with SOPS-decrypted credentials
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SECRETS_FILE="$REPO_ROOT/secrets/pfsense-mcp.env"

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "Error: Secrets file not found: $SECRETS_FILE" >&2
  exit 1
fi

# Decrypt and exec the MCP server with the secrets as environment variables
exec sops exec-env "$SECRETS_FILE" 'uvx pfsense-mcp-server'
