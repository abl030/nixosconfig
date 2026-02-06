# Claude Code - Declarative Package, Settings & Plugin Management

This module provides unified declarative management of Claude Code: the package itself, `settings.json` entries, and plugins via Nix flake inputs.

## Quick Start

```nix
homelab.claudeCode = {
  enable = true;
  agentTeams = true;  # sets CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
  settings = {};      # arbitrary attrs merged into ~/.claude/settings.json
  plugins = [{
    source = inputs.claude-plugin-foo;
    marketplaceName = "org-repo";
    pluginName = "my-plugin";
  }];
};
```

## Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Master toggle. Installs `pkgs.claude-code` and activates settings/plugin management. |
| `agentTeams` | bool | `false` | Convenience flag. Sets `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in `settings.json` env. |
| `settings` | attrs | `{}` | Arbitrary attrset deep-merged into `~/.claude/settings.json`. |
| `plugins` | list of plugin | `[]` | List of Claude Code plugins to install. |

### Plugin Sub-Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `source` | path | (required) | Path to the plugin source (typically a flake input) |
| `marketplaceName` | string | (required) | Name of the marketplace (used in directory structure) |
| `pluginName` | string | (required) | Name of the plugin within the marketplace |
| `version` | string or null | `null` | Version string. If null, auto-detected from `plugin.json`. |

## How It Works

### Package
When `enable = true`, `pkgs.claude-code` is added to `home.packages`.

### Settings
The `settings` attrset, `agentTeams` env var, and `enabledPlugins` map are merged together and deep-merged into any existing `~/.claude/settings.json` on activation.

### Plugins

1. **Patches plugin sources** - Removes invalid fields from `marketplace.json` that cause silent loading failures
2. **Auto-detects version** - Reads version from `.claude-plugin/plugin.json` to prevent version mismatch errors
3. **Installs to cache path** - Uses `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/` to match Claude's expected structure
4. **Merges JSON configs** - Updates `known_marketplaces.json`, `installed_plugins.json`, and `settings.json`

## Adding a Plugin

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
homelab.claudeCode = {
  enable = true;
  plugins = [{
    source = inputs.claude-plugin-foo;
    marketplaceName = "org-repo";
    pluginName = "my-plugin";
  }];
};
```

### 3. Update plugin

```bash
nix flake update claude-plugin-foo
sudo nixos-rebuild switch --flake .#<host>
# Restart Claude Code
```

## Custom Settings

```nix
homelab.claudeCode = {
  enable = true;
  settings = {
    env = {
      MY_CUSTOM_VAR = "value";
    };
  };
};
```

## Plugin Structure Requirements

Claude Code expects this structure:

```
plugin-root/
+-- .claude-plugin/
|   +-- plugin.json        # Required - plugin metadata
|   +-- marketplace.json   # Required - marketplace config
+-- skills/
|   +-- <skill-name>/
|       +-- SKILL.md       # Skill definition
|       +-- references/    # Optional reference docs
+-- commands/              # Optional slash commands
```

## Troubleshooting

### Plugin shows "failed to load, error"

Almost always caused by **invalid fields in marketplace.json**. The module automatically patches known invalid fields (`metadata`, `skills`).

### Plugin marked as "orphaned"

Version mismatch between `installed_plugins.json` and `plugin.json`. The module auto-detects version; if you override `version` manually, ensure it matches.

### Debugging Steps

```bash
# Check settings were merged
cat ~/.claude/settings.json | jq '.env'
cat ~/.claude/settings.json | jq '.enabledPlugins'

# Check plugin install paths
cat ~/.claude/plugins/installed_plugins.json | jq .

# Check for orphaned markers
find ~/.claude/plugins/cache -name ".orphaned_at"

# Run /doctor in Claude Code for diagnostics
```

## File Locations

| File | Purpose |
|------|---------|
| `~/.claude/settings.json` | Merged settings, env vars, enabled plugins |
| `~/.claude/plugins/marketplaces/<name>/` | Marketplace source (for discovery) |
| `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/` | Installed plugin (installPath) |
| `~/.claude/plugins/known_marketplaces.json` | Registered marketplaces |
| `~/.claude/plugins/installed_plugins.json` | Installed plugins with versions |

## References

- [Claude Code Plugin Reference](https://code.claude.com/docs/en/plugins-reference)
- [Issue #20409 - Silent skill loading failure](https://github.com/anthropics/claude-code/issues/20409)
- [Official Anthropic Marketplace](https://github.com/anthropics/claude-plugins-official)
- [Plugin Template](https://github.com/ivan-magda/claude-code-plugin-template)
