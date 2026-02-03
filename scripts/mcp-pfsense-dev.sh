#!/usr/bin/env bash
# Dev wrapper - runs MCP server from a local repo checkout (for testing before push)
# Usage: Set MCP_PFSENSE_DEV_DIR to your local checkout path
set -euo pipefail

SECRETS_FILE="${PFSENSE_MCP_ENV_FILE:-/run/secrets/mcp/pfsense.env}"
DEV_DIR="${MCP_PFSENSE_DEV_DIR:-$HOME/pfsense-mcp-server}"

if [[ ! -d "$DEV_DIR" ]]; then
  echo "Error: Dev directory not found: $DEV_DIR" >&2
  echo "Set MCP_PFSENSE_DEV_DIR to your local checkout" >&2
  exit 1
fi

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "Error: Secrets file not found: $SECRETS_FILE" >&2
  exit 1
fi

# Source secrets
set -a
source "$SECRETS_FILE"
set +a

# Map env vars
export PFSENSE_URL="${PFSENSE_HOST:-}"
export PFSENSE_API_CLIENT_ID="${PFSENSE_API_KEY:-}"
export PFSENSE_API_CLIENT_TOKEN="${PFSENSE_API_KEY:-}"
export VERIFY_SSL="${PFSENSE_VERIFY_SSL:-false}"
export PYTHONPATH="$DEV_DIR"

# Run from dev directory
exec python3 "$DEV_DIR/src/main.py"
