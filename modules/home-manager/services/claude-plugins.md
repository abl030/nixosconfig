# Claude Code Plugins - Declarative Plugin Management

This module enables declarative management of Claude Code plugins via Nix flake inputs.

## Quick Start

### 1. Add plugin as flake input

```nix
# flake.nix
inputs.claude-plugin-foo = {
  url = "github:org/repo";
  flake = false;
};
```

### 2. Configure in home.nix

```nix
homelab.claudePlugins = {
  enable = true;
  plugins = [{
    source = inputs.claude-plugin-foo;
    marketplaceName = "org-repo";
    pluginName = "my-plugin";
    # version is auto-detected from .claude-plugin/plugin.json
  }];
};
```

### 3. Update plugin

```bash
nix flake update claude-plugin-foo
sudo nixos-rebuild switch --flake .#<host>
# Restart Claude Code
```

## How It Works

The module:

1. **Patches plugin sources** - Removes invalid fields from `marketplace.json` that cause silent loading failures
2. **Auto-detects version** - Reads version from `.claude-plugin/plugin.json` to prevent version mismatch errors
3. **Installs to cache path** - Uses `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/` to match Claude's expected structure
4. **Merges JSON configs** - Updates `known_marketplaces.json`, `installed_plugins.json`, and `settings.json`

## Plugin Structure Requirements

Claude Code expects this structure:

```
plugin-root/
├── .claude-plugin/
│   ├── plugin.json        # Required - plugin metadata
│   └── marketplace.json   # Required - marketplace config
├── skills/
│   └── <skill-name>/
│       ├── SKILL.md       # Skill definition
│       └── references/    # Optional reference docs
└── commands/              # Optional slash commands
```

### plugin.json (Required)

```json
{
  "name": "my-plugin",
  "description": "Plugin description",
  "version": "1.0.0",
  "repository": "https://github.com/org/repo",
  "license": "MIT"
}
```

**Valid fields:** `name`, `description`, `version`, `repository`, `license`

### marketplace.json (Required)

```json
{
  "name": "my-plugin",
  "owner": {
    "name": "Organization",
    "email": "support@example.com"
  },
  "plugins": [
    {
      "name": "my-plugin",
      "description": "Plugin description",
      "source": "./",
      "category": "productivity"
    }
  ]
}
```

**Valid root fields:** `$schema`, `name`, `version`, `description`, `owner`, `plugins`

**Valid plugin entry fields:** `name`, `description`, `version`, `author`, `source`, `category`, `homepage`, `strict`, `lspServers`, `tags`

## Troubleshooting

### Plugin shows "failed to load, error"

This is almost always caused by **invalid fields in marketplace.json**. Claude Code silently rejects plugins with unknown fields.

**Common invalid fields to remove:**
- `metadata` at root level
- `skills` array in plugin entries (skills are auto-discovered from `skills/` directory)
- Any non-standard fields

The module automatically patches these out, but if you encounter new invalid fields:

1. Check the official schema: https://github.com/anthropics/claude-code/blob/main/.claude-plugin/marketplace.json
2. Add the field to the `patchPluginSource` function in `claude-plugins.nix`

### Plugin marked as "orphaned"

This happens when `installed_plugins.json` version doesn't match `plugin.json` version.

**Solution:** The module auto-detects version from `plugin.json`. If you override `version` manually, ensure it matches.

### Plugin appears in marketplace but not installed

Check these files:
```bash
# Should show plugin enabled
cat ~/.claude/settings.json | jq '.enabledPlugins'

# Should show correct installPath
cat ~/.claude/plugins/installed_plugins.json | jq .

# Should have no .orphaned_at file
find ~/.claude/plugins/cache -name ".orphaned_at"
```

### Debugging Steps

1. **Check for orphaned markers:**
   ```bash
   find ~/.claude/plugins/cache -name ".orphaned_at"
   ```

2. **Verify marketplace.json is valid:**
   ```bash
   cat ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/.claude-plugin/marketplace.json | jq .
   ```

3. **Check all fields are known:**
   Compare against official schema at https://github.com/anthropics/claude-code/blob/main/.claude-plugin/marketplace.json

4. **Run `/doctor` in Claude Code** for diagnostics

5. **Check plugin structure:**
   ```bash
   ls -la ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/
   ls -la ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/skills/
   ```

## Adding Patches for New Invalid Fields

Edit `patchPluginSource` in `claude-plugins.nix`:

```nix
patchPluginSource = name: source:
  pkgs.runCommand "claude-plugin-${name}-patched" {
    nativeBuildInputs = [pkgs.jq];
  } ''
    cp -r ${source} $out
    chmod -R u+w $out

    if [ -f "$out/.claude-plugin/marketplace.json" ]; then
      # Add new field deletions here
      jq 'del(.metadata) | del(.newInvalidField) | .plugins = [.plugins[] | del(.skills) | del(.anotherBadField)]' \
        "$out/.claude-plugin/marketplace.json" > "$out/.claude-plugin/marketplace.json.tmp"
      mv "$out/.claude-plugin/marketplace.json.tmp" "$out/.claude-plugin/marketplace.json"
    fi
  '';
```

## File Locations

| File | Purpose |
|------|---------|
| `~/.claude/plugins/marketplaces/<name>/` | Marketplace source (for discovery) |
| `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/` | Installed plugin (installPath) |
| `~/.claude/plugins/known_marketplaces.json` | Registered marketplaces |
| `~/.claude/plugins/installed_plugins.json` | Installed plugins with versions |
| `~/.claude/settings.json` | Enabled plugins map |

## References

- [Claude Code Plugin Reference](https://code.claude.com/docs/en/plugins-reference)
- [Issue #20409 - Silent skill loading failure](https://github.com/anthropics/claude-code/issues/20409)
- [Official Anthropic Marketplace](https://github.com/anthropics/claude-plugins-official)
- [Plugin Template](https://github.com/ivan-magda/claude-code-plugin-template)
