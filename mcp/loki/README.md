# Loki MCP (Codex)

This repo configures Codex to use the Loki MCP server running on the
homelab stack.

## Endpoint

- MCP stream endpoint: `http://loki-mcp.ablz.au:8081/stream`

Codex reads MCP servers from `.codex/config.toml` in the repo. This
project file is the source of truth.

## Notes

- The server is provided by the `loki-mcp` container in the Loki stack.
- The MCP `/sse` and `/mcp` endpoints are available, but Codex should use
  `/stream` for session-based requests.
