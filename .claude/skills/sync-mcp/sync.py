#!/usr/bin/env python3
"""Sync .mcp.json (source of truth) into ~/.codex/config.toml.

Merges MCP server entries into the Codex user config without clobbering
any existing non-MCP settings or MCP servers defined elsewhere.
"""

import json
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
MCP_JSON = REPO_ROOT / ".mcp.json"
CODEX_CONFIG = Path.home() / ".codex" / "config.toml"


def read_mcp_json() -> dict:
    with open(MCP_JSON) as f:
        data = json.load(f)
    return data.get("mcpServers", {})


def read_codex_toml() -> str:
    if CODEX_CONFIG.exists():
        return CODEX_CONFIG.read_text()
    return ""


def remove_mcp_blocks(toml_text: str, names: list[str]) -> str:
    """Remove existing [mcp_servers.<name>] blocks for servers we manage."""
    for name in names:
        header = f"[mcp_servers.{name}]"
        if header not in toml_text:
            continue
        # Find the block: from header to next [section] or EOF
        pattern = re.compile(
            rf"^(\[mcp_servers\.{re.escape(name)}\]).*?(?=^\[|\Z)",
            re.MULTILINE | re.DOTALL,
        )
        toml_text = pattern.sub("", toml_text)
    # Clean up excessive blank lines
    toml_text = re.sub(r"\n{3,}", "\n\n", toml_text).strip()
    return toml_text


def server_to_toml(name: str, cfg: dict) -> str:
    lines = [f"[mcp_servers.{name}]"]
    for key, value in cfg.items():
        if key == "type":
            # Codex uses 'url' presence to imply HTTP transport
            continue
        if isinstance(value, str):
            lines.append(f'{key} = "{value}"')
        elif isinstance(value, list):
            items = ", ".join(f'"{v}"' for v in value)
            lines.append(f"{key} = [{items}]")
        elif isinstance(value, dict):
            for k, v in value.items():
                lines.append(f'{key}.{k} = "{v}"')
    return "\n".join(lines)


def main():
    servers = read_mcp_json()
    if not servers:
        print("No MCP servers found in .mcp.json")
        return

    CODEX_CONFIG.parent.mkdir(parents=True, exist_ok=True)
    existing = read_codex_toml()

    # Remove old versions of servers we're about to write
    cleaned = remove_mcp_blocks(existing, list(servers.keys()))

    # Build new TOML blocks
    new_blocks = "\n\n".join(server_to_toml(n, c) for n, c in servers.items())

    if cleaned:
        result = cleaned + "\n\n" + new_blocks + "\n"
    else:
        result = new_blocks + "\n"

    CODEX_CONFIG.write_text(result)

    for name in servers:
        print(f"  -> {name}")
    print(f"\nSynced {len(servers)} server(s) to {CODEX_CONFIG}")


if __name__ == "__main__":
    main()
