# pfSense MCP Server Integration

MCP (Model Context Protocol) server for querying and managing pfSense firewalls via Claude Code.

## Overview

This integration allows Claude Code to:
- Query system status (CPU, memory, uptime)
- Search DHCP leases and static mappings
- View and manage firewall rules
- Search firewall logs and blocked traffic
- Manage aliases

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  NixOS Host                                                     │
│                                                                 │
│  ┌──────────────────┐    ┌──────────────────────────────────┐  │
│  │ Claude Code      │───▶│ scripts/mcp-pfsense.sh           │  │
│  │ (.mcp.json)      │    │ (wrapper script)                 │  │
│  └──────────────────┘    └───────────────┬──────────────────┘  │
│                                          │                      │
│  ┌──────────────────┐                    ▼                      │
│  │ /run/secrets/mcp │    ┌──────────────────────────────────┐  │
│  │ /pfsense.env     │───▶│ ~/.local/share/pfsense-mcp-server│  │
│  │ (decrypted)      │    │ (git clone + venv)               │  │
│  └──────────────────┘    └───────────────┬──────────────────┘  │
│                                          │                      │
└──────────────────────────────────────────┼──────────────────────┘
                                           │
                                           ▼
                                 ┌──────────────────┐
                                 │ pfSense REST API │
                                 │ (port 443)       │
                                 └──────────────────┘
```

## Setup

### 1. pfSense REST API Package

Install the REST API package on pfSense:
- **Package**: `pfSense-pkg-RESTAPI` from [pfrest/pfSense-pkg-RESTAPI](https://github.com/pfrest/pfSense-pkg-RESTAPI)
- **Not** the older `pfSense-pkg-API` — that's a different project

After installation, create an API key:
1. System → REST API → Settings
2. Create a new API key with appropriate permissions
3. Note the key for the secrets file

### 2. SOPS Secret

Create `secrets/pfsense-mcp.env` with:

```bash
PFSENSE_HOST=https://your-pfsense-ip
PFSENSE_API_KEY=your-api-key-here
PFSENSE_VERIFY_SSL=false
```

Encrypt with SOPS:
```bash
cd secrets
sops pfsense-mcp.env
```

### 3. NixOS Module

Enabled by default in `modules/nixos/profiles/base.nix`:

```nix
homelab.mcp = {
  enable = lib.mkDefault true;
  pfsense.enable = lib.mkDefault true;
};
```

To disable on a specific host:
```nix
homelab.mcp.pfsense.enable = false;
```

### 4. Rebuild

```bash
sudo nixos-rebuild switch --flake .#<hostname>
```

The activation script decrypts the secret to `/run/secrets/mcp/pfsense.env`.

## Design Decisions

### Secrets: Decrypt at Rebuild, Not Runtime

**Problem**: MCP servers run as the user, but SOPS secrets typically require either:
- Runtime sudo access (security risk)
- sops-nix which outputs individual keys (awkward for dotenv format)

**Solution**: Use a NixOS activation script that:
1. Runs as root during `nixos-rebuild switch`
2. Converts the host SSH key to an Age key via `ssh-to-age`
3. Decrypts the SOPS file using `sops -d --output-type dotenv`
4. Writes to `/run/secrets/mcp/pfsense.env` with `chmod 400`
5. Owned by the configured user

This limits the blast radius — the secret is only readable by the specific user, not via passwordless sudo for all secrets.

See: `modules/nixos/services/mcp.nix`

### MCP Server: Forked Repository

**Problem**: The upstream [gensecaihq/pfsense-mcp-server](https://github.com/gensecaihq/pfsense-mcp-server) has incorrect API endpoint paths that don't match pfSense REST API v2.

**Solution**: We maintain a fork at [abl030/pfsense-mcp-server](https://github.com/abl030/pfsense-mcp-server) that includes:
- [PR #3](https://github.com/gensecaihq/pfsense-mcp-server/pull/3) endpoint fixes (merged)
- Future fixes for write operations (planned)

The wrapper script (`scripts/mcp-pfsense.sh`):
1. Clones our fork to `~/.local/share/pfsense-mcp-server`
2. Creates a Python venv and installs dependencies
3. Runs the MCP server in stdio mode

**Endpoint fixes included**:
| Broken (upstream) | Fixed (fork) |
|-------------------|--------------|
| `/status/interface` | `/status/interfaces` |
| `/firewall/rule` | `/firewall/rules` |
| `/firewall/alias` | `/firewall/aliases` |
| `/services/dhcpd/lease` | `/status/dhcp_server/leases` |
| `/diagnostics/log/firewall` | `/status/logs/firewall` |

### Updating the Fork

To pull in upstream changes or new fixes:

```bash
cd /tmp
git clone https://github.com/abl030/pfsense-mcp-server.git
cd pfsense-mcp-server
git remote add upstream https://github.com/gensecaihq/pfsense-mcp-server.git
git fetch upstream
git merge upstream/main -m "Merge upstream changes"
git push origin main
```

### Write Operations - API Quirks

The pfSense REST API v2 has some non-obvious requirements for write operations:

| Requirement | Details |
|-------------|---------|
| `interface` | Must be an **array**: `["lan"]` not `"lan"` |
| Field names | Use `source`/`destination`/`destination_port` (not `src`/`dst`/`dstport`) |
| DELETE body | ID goes in request body `{"id": 40}`, NOT in URL path `/rule/40` |
| NAT create | Requires `source` field (use `"any"` as default) |

See [pfrest.org API docs](https://pfrest.org/api-docs/) for complete schemas.

## Testing & Debugging the Fork

### The Testing Workflow

When fixing issues in the fork, follow this cycle:

1. **Make changes** in the fork repo and push
2. **Delete cached clone** on the machine running Claude Code:
   ```bash
   rm -rf ~/.local/share/pfsense-mcp-server
   ```
3. **Restart Claude Code** (triggers fresh clone + venv setup)
4. **Test via MCP tools** or curl

### Testing API Calls Directly with curl

When MCP tools return errors, test the API directly to see the actual error message:

```bash
# Load the API key
PFSENSE_API_KEY=$(grep PFSENSE_API_KEY /run/secrets/mcp/pfsense.env | cut -d= -f2-)

# Test a GET (read)
curl -sk "https://192.168.1.1/api/v2/firewall/rules" \
  -H "X-API-Key: $PFSENSE_API_KEY"

# Test a POST (create) - note: interface is an array!
curl -sk -X POST "https://192.168.1.1/api/v2/firewall/rule?apply=true" \
  -H "X-API-Key: $PFSENSE_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"interface":["lan"],"type":"block","ipprotocol":"inet","protocol":"tcp","source":"any","destination":"1.1.1.1","destination_port":"12345","descr":"Test Rule"}'

# Test a DELETE - note: ID in body, not URL!
curl -sk -X DELETE "https://192.168.1.1/api/v2/firewall/rule?apply=true" \
  -H "X-API-Key: $PFSENSE_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"id":40}'
```

The API returns helpful error messages like:
- `"Field 'interface' must be of type 'array'"`
- `"Field 'source' is required"`

### Testing in the Fork Repo (Without MCP)

Create a test script to call the API client directly:

```python
#!/usr/bin/env python3
"""test_api.py - Test API client without MCP layer"""
import asyncio
import os

# Load secrets
with open("/run/secrets/mcp/pfsense.env") as f:
    for line in f:
        if "=" in line and not line.startswith("#"):
            k, v = line.strip().split("=", 1)
            os.environ[k] = v

os.environ["PFSENSE_URL"] = os.environ.get("PFSENSE_HOST", "")
os.environ["PFSENSE_API_CLIENT_ID"] = os.environ.get("PFSENSE_API_KEY", "")
os.environ["PFSENSE_API_CLIENT_TOKEN"] = os.environ.get("PFSENSE_API_KEY", "")
os.environ["VERIFY_SSL"] = os.environ.get("PFSENSE_VERIFY_SSL", "false")

from src.pfsense_api_enhanced import EnhancedPfSenseAPIClient

async def test():
    client = EnhancedPfSenseAPIClient()

    # Test create
    print("Creating test rule...")
    result = await client.create_firewall_rule({
        "interface": ["lan"],
        "type": "block",
        "ipprotocol": "inet",
        "protocol": "tcp",
        "source": "any",
        "destination": "1.1.1.1",
        "destination_port": "12345",
        "descr": "API Test - DELETE ME"
    })
    print(f"Create: {result}")

    rule_id = result.get("data", {}).get("id")
    if rule_id:
        print(f"Deleting rule {rule_id}...")
        del_result = await client.delete_firewall_rule(rule_id)
        print(f"Delete: {del_result}")

asyncio.run(test())
```

Run with: `python test_api.py`

### Common Issues Found

| Symptom | Cause | Fix |
|---------|-------|-----|
| 400 Bad Request | Wrong field format | Check curl output for specific field error |
| 404 Not Found | Wrong endpoint path | Read vs write endpoints differ (plural vs singular) |
| `AsyncClient.delete() got unexpected keyword argument 'json'` | httpx DELETE doesn't support `json=` | Use `client.request("DELETE", url, json=data)` instead |
| Module not found after restart | pip install failed silently | Wrapper now tests `import fastmcp` and rebuilds venv if needed |

## Usage

Once configured, Claude Code can query pfSense directly:

```
User: What's the pfSense system status?
Claude: [calls mcp__pfsense__system_status]

User: Show me active DHCP leases
Claude: [calls mcp__pfsense__search_dhcp_leases]

User: What firewall rules exist on WAN?
Claude: [calls mcp__pfsense__search_firewall_rules with interface="wan"]
```

### Available Tools

| Tool | Description |
|------|-------------|
| `system_status` | CPU, memory, uptime, disk usage |
| `search_dhcp_leases` | Find DHCP leases by hostname, MAC, IP |
| `search_firewall_rules` | Query rules by interface, source, destination |
| `search_interfaces` | List network interfaces and status |
| `search_aliases` | Find IP/port aliases |
| `analyze_blocked_traffic` | Summarize blocked traffic from logs |
| `search_logs_by_ip` | Find log entries for specific IPs |
| `create_firewall_rule_advanced` | Create new firewall rules |
| `bulk_block_ips` | Block multiple IPs at once |

## Troubleshooting

### MCP Server Won't Connect

1. Check the secret exists:
   ```bash
   ls -la /run/secrets/mcp/pfsense.env
   ```

2. Verify env vars are set:
   ```bash
   echo $PFSENSE_MCP_ENV_FILE
   ```

3. Test the wrapper script manually:
   ```bash
   /home/abl030/nixosconfig/scripts/mcp-pfsense.sh
   # Should output JSON-RPC on stdio
   ```

4. Check if venv needs rebuilding:
   ```bash
   rm -rf ~/.local/share/pfsense-mcp-server/.venv
   # Restart Claude Code
   ```

### API Returns 404/400 Errors

The MCP server may be on the wrong branch:
```bash
cd ~/.local/share/pfsense-mcp-server
git branch --show-current
# Should show: pr-3-api-fixes
```

If not, delete and let it re-bootstrap:
```bash
rm -rf ~/.local/share/pfsense-mcp-server
# Restart Claude Code
```

### SSL Certificate Errors

If using a self-signed cert, ensure `PFSENSE_VERIFY_SSL=false` in the secrets file.

## Files

| File | Purpose |
|------|---------|
| `modules/nixos/services/mcp.nix` | NixOS module for secrets provisioning |
| `scripts/mcp-pfsense.sh` | Wrapper script (bootstrap + run) |
| `secrets/pfsense-mcp.env` | SOPS-encrypted credentials |
| `.mcp.json` | Claude Code MCP server config |

## References

- [pfSense REST API v2](https://github.com/pfrest/pfSense-pkg-RESTAPI)
- [Our fork (abl030)](https://github.com/abl030/pfsense-mcp-server) — use this
- [Upstream MCP server](https://github.com/gensecaihq/pfsense-mcp-server)
- [PR #3: API endpoint fixes](https://github.com/gensecaihq/pfsense-mcp-server/pull/3)
- [pfSense REST API docs](https://pfrest.org/api-docs/)
- [MCP Protocol](https://modelcontextprotocol.io/)
