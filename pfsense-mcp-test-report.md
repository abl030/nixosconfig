# pfSense MCP Server Test Report

**Date**: 2026-02-09
**Target**: pfsense.local.com (pfSense 2.8.1-RELEASE)

## Test: CRUD Lifecycle on Firewall Alias

Create → Read → Update description → Read → Delete → Apply → Verify gone.

Two MCP servers tested back-to-back on the same firewall with the same test.

---

## Server A: pfsense-mcp-server (hand-written, ~20 custom tools)

Source: `github:abl030/pfsense-mcp-server` (old)

| Step | Tool | Result | Verdict |
|------|------|--------|---------|
| 1. CREATE | `create_alias("mcp_test_alias", host, ["192.168.255.99"])` | id=16 created | PASS |
| 2. READ | `search_aliases(search_term="mcp_test")` | All 17 aliases returned | **BUG**: filter ignored |
| 3. UPDATE desc | (no tool exists) | Cannot update description | **MISSING** |
| 4. UPDATE addrs | `manage_alias_addresses(16, "add", ["10.0.0.99"])` | Replaced instead of appended | **BUG**: data loss |
| 5. READ by field | `find_object_by_field("/api/v2/firewall/alias", ...)` | 404 double-prefix | **BUG** |
| 5b. READ by field | `find_object_by_field("/firewall/alias", ...)` | 400 Bad Request | Expected |
| 5c. READ by IP | `search_aliases(containing_ip="10.0.0.99")` | All 17 aliases returned | **BUG**: filter ignored |
| 6. DELETE | `delete_alias(16)` | Deleted OK | PASS |
| 7. APPLY | `apply_firewall_apply()` | `applied: false` | Confusing |
| 7b. VERIFY APPLY | `get_firewall_apply_status()` | `applied: true` | PASS |
| 8. VERIFY GONE | `search_aliases(alias_type="host")` | Count=16, alias gone | PASS (but filter ignored) |

**Bugs found: 5** (1 HIGH, 2 MEDIUM, 2 LOW)
- HIGH: `manage_alias_addresses("add")` replaces all addresses (data loss)
- MEDIUM: All `search_aliases` filters ignored (search_term, containing_ip, alias_type)
- MEDIUM: No `update_alias` tool — can't change description without delete+recreate
- LOW: `find_object_by_field` double-prefixes `/api/v2` in URL
- LOW: `apply` returns `applied: false` initially (needs status poll)

---

## Server B: pfsense-mcp (auto-generated, 599 tools)

Source: `github:abl030/pfsense-mcp` (new, declarative flake input)

| Step | Tool | Result | Verdict |
|------|------|--------|---------|
| 1. CREATE | `pfsense_create_firewall_alias(name, type_, address, descr, confirm=true)` | id=16 created | PASS |
| 2. READ | `pfsense_get_firewall_alias(id=16)` | Exact object returned | PASS |
| 3. UPDATE desc | `pfsense_update_firewall_alias(id=16, descr="MCP integration test", confirm=true)` | Description updated, address preserved | PASS |
| 4. READ | `pfsense_get_firewall_alias(id=16)` | Updated description confirmed, address intact | PASS |
| 5. DELETE | `pfsense_delete_firewall_alias(id=16, confirm=true)` | Deleted, returns deleted object | PASS |
| 6. APPLY | `pfsense_firewall_apply(confirm=true)` | `applied: false, pending: ["aliases"]` | Expected (async) |
| 7. VERIFY | `pfsense_get_firewall_alias(id=16)` | 404 `OBJECT_NOT_FOUND` | PASS |
| 7b. VERIFY APPLY | `pfsense_get_firewall_apply_status()` | `applied: true, pending: []` | PASS |

**Bugs found: 0**

---

## Head-to-Head Comparison

| Aspect | Server A (hand-written) | Server B (auto-generated) |
|--------|------------------------|--------------------------|
| CRUD steps completed | 4/6 (no update, broken read) | 6/6 (all passed first try) |
| Bugs found | 5 | 0 |
| Tool count | ~20 custom | 599 (1:1 with API) |
| GET by ID | No (only bulk search) | Yes (`pfsense_get_firewall_alias`) |
| PATCH/Update | Missing for aliases | Full PATCH support |
| Confirm gate | No (mutations fire immediately) | Yes (`confirm=true` required) |
| API coverage | Partial (hand-picked endpoints) | Complete (all 677 operations) |
| Response format | Custom wrappers with extra fields | Raw API response passthrough |
| Tool naming | Inconsistent (`search_aliases`, `manage_alias_addresses`) | Consistent (`pfsense_{verb}_{resource_path}`) |
| Nix packaging | git clone + venv bootstrap | Flake with `writeShellApplication` |

## Key Improvements in Server B

1. **PATCH exists**: The old server had no way to update alias metadata. The new one maps PATCH directly, so `update_firewall_alias` just works.

2. **GET by ID**: Instead of listing all aliases and filtering client-side, you can `get_firewall_alias(id=16)` for an exact hit. The 404 response on missing objects is also clean and parseable.

3. **Confirm safety gate**: All mutations require `confirm=true`. This is a major safety improvement — an AI agent can't accidentally mutate the firewall by calling a tool with default params.

4. **No invented abstractions**: Server A's `manage_alias_addresses` and `search_aliases` were custom wrappers with bugs. Server B passes through to the pfSense API directly — no opportunity for wrapper bugs.

5. **Consistent naming**: `pfsense_{http_verb}_{api_path}` makes tools discoverable and predictable. You know `pfsense_create_firewall_alias` maps to `POST /api/v2/firewall/alias`.

## Verdict

Server B is the clear winner. Zero bugs in the CRUD cycle, complete API coverage, safer mutation handling, and better tool ergonomics. The auto-generation approach eliminates an entire class of hand-written wrapper bugs.
