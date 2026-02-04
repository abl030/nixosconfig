#!/usr/bin/env bash
# Wrapper script to launch pfSense MCP server with pre-decrypted credentials
# Auto-bootstraps the server from GitHub since it's not on PyPI
set -euo pipefail

SECRETS_FILE="${PFSENSE_MCP_ENV_FILE:-/run/secrets/mcp/pfsense.env}"
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/pfsense-mcp-server"
REPO_URL="https://github.com/abl030/pfsense-mcp-server.git"
VENV_DIR="$INSTALL_DIR/.venv"

# Bootstrap: clone our fork (includes PR #3 fixes for API endpoints)
if [[ ! -d "$INSTALL_DIR" ]]; then
  echo "Bootstrapping pfSense MCP server from fork..." >&2
  git clone "$REPO_URL" "$INSTALL_DIR" >&2
elif [[ "$(git -C "$INSTALL_DIR" remote get-url origin 2>/dev/null)" != "$REPO_URL" ]]; then
  # Existing install from different repo - replace with our fork
  echo "Switching to fork with API fixes..." >&2
  rm -rf "$INSTALL_DIR"
  git clone "$REPO_URL" "$INSTALL_DIR" >&2
  rm -rf "$VENV_DIR"
else
  # Pull latest changes from fork
  local_head=$(git -C "$INSTALL_DIR" rev-parse HEAD 2>/dev/null)
  git -C "$INSTALL_DIR" pull --ff-only origin main >&2 2>/dev/null || true
  new_head=$(git -C "$INSTALL_DIR" rev-parse HEAD 2>/dev/null)
  if [[ "$local_head" != "$new_head" ]]; then
    echo "Updated to $(git -C "$INSTALL_DIR" log -1 --format='%h %s')" >&2
    # Invalidate venv if requirements changed
    if git -C "$INSTALL_DIR" diff --name-only "$local_head" "$new_head" | grep -q requirements.txt; then
      echo "requirements.txt changed, rebuilding venv..." >&2
      rm -rf "$VENV_DIR"
    fi
  fi
fi

# Check for working venv by testing if fastmcp is importable
if ! "$VENV_DIR/bin/python" -c "import fastmcp" 2>/dev/null; then
  echo "Creating/repairing virtual environment..." >&2
  rm -rf "$VENV_DIR"
  python3 -m venv "$VENV_DIR" >&2
  "$VENV_DIR/bin/pip" install -r "$INSTALL_DIR/requirements.txt" >&2
fi

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "Error: Secrets file not found: $SECRETS_FILE" >&2
  echo "Ensure homelab.mcp.pfsense.enable = true and rebuild." >&2
  exit 1
fi

# Source the decrypted env file
set -a
# shellcheck source=/dev/null
source "$SECRETS_FILE"
set +a

# Map our env vars to what pfSense MCP expects
export PFSENSE_URL="${PFSENSE_HOST:-}"
export PFSENSE_API_CLIENT_ID="${PFSENSE_API_KEY:-}"
export PFSENSE_API_CLIENT_TOKEN="${PFSENSE_API_KEY:-}"
export VERIFY_SSL="${PFSENSE_VERIFY_SSL:-false}"
export PYTHONPATH="$INSTALL_DIR"

# Run MCP server in stdio mode (MCP_MODE defaults to stdio in main.py)
exec "$VENV_DIR/bin/python" "$INSTALL_DIR/src/main.py"
