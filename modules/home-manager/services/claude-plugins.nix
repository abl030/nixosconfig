# Claude Code Plugins - Declarative plugin management via flake inputs
#
# Usage in flake.nix:
#   inputs.claude-plugin-foo = { url = "github:org/repo"; flake = false; };
#
# Usage in home.nix:
#   homelab.claudePlugins = {
#     enable = true;
#     plugins = [{
#       source = inputs.claude-plugin-foo;
#       marketplaceName = "org-repo";
#       pluginName = "my-plugin";
#       # version is auto-detected from .claude-plugin/plugin.json
#     }];
#   };
#
# Update: nix flake update claude-plugin-foo && nixos-rebuild switch
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.claudePlugins;

  # Patch plugin source to remove invalid fields from marketplace.json
  # Claude Code silently fails on unknown fields (metadata, skills in plugin entries)
  patchPluginSource = name: source:
    pkgs.runCommand "claude-plugin-${name}-patched" {
      nativeBuildInputs = [pkgs.jq];
    } ''
      cp -r ${source} $out
      chmod -R u+w $out

      # Patch marketplace.json if it exists - remove invalid fields
      if [ -f "$out/.claude-plugin/marketplace.json" ]; then
        jq 'del(.metadata) | .plugins = [.plugins[] | del(.skills)]' \
          "$out/.claude-plugin/marketplace.json" > "$out/.claude-plugin/marketplace.json.tmp"
        mv "$out/.claude-plugin/marketplace.json.tmp" "$out/.claude-plugin/marketplace.json"
      fi
    '';

  # Read version from plugin's plugin.json if it exists
  getPluginVersion = source: let
    pluginJsonPath = "${source}/.claude-plugin/plugin.json";
    pluginJson =
      if builtins.pathExists pluginJsonPath
      then builtins.fromJSON (builtins.readFile pluginJsonPath)
      else {};
  in
    pluginJson.version or "1.0.0";

  # Plugin submodule type
  pluginType = lib.types.submodule {
    options = {
      source = lib.mkOption {
        type = lib.types.path;
        description = "Path to the plugin source (typically a flake input)";
      };
      marketplaceName = lib.mkOption {
        type = lib.types.str;
        description = "Name of the marketplace (used in directory structure)";
      };
      pluginName = lib.mkOption {
        type = lib.types.str;
        description = "Name of the plugin within the marketplace";
      };
      version = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Version string for the plugin. If null, reads from plugin.json automatically.";
      };
    };
  };

  # Resolve plugin with actual version and patched source
  resolvePlugin = plugin: let
    patchedSource = patchPluginSource plugin.pluginName plugin.source;
  in
    plugin
    // {
      version =
        if plugin.version != null
        then plugin.version
        else getPluginVersion plugin.source; # Use original source for version detection
      source = patchedSource; # Use patched source for installation
    };

  # Resolved plugins with versions and patched sources
  resolvedPlugins = map resolvePlugin cfg.plugins;

  # Generate known_marketplaces.json content
  knownMarketplacesJson =
    builtins.toJSON
    (builtins.listToAttrs (map (plugin: {
        name = plugin.marketplaceName;
        value = {
          source = {
            source = "directory";
            path = "${config.home.homeDirectory}/.claude/plugins/marketplaces/${plugin.marketplaceName}";
          };
          installLocation = "${config.home.homeDirectory}/.claude/plugins/marketplaces/${plugin.marketplaceName}";
          lastUpdated = "2026-01-01T00:00:00.000Z";
        };
      })
      resolvedPlugins));

  # Cache path for a plugin: cache/<marketplace>/<plugin>/<version>/
  pluginCachePath = plugin: "${config.home.homeDirectory}/.claude/plugins/cache/${plugin.marketplaceName}/${plugin.pluginName}/${plugin.version}";

  # Generate installed_plugins.json content
  installedPluginsJson =
    builtins.toJSON
    {
      version = 2;
      plugins = builtins.listToAttrs (map (plugin: {
          name = "${plugin.pluginName}@${plugin.marketplaceName}";
          value = [
            {
              scope = "user";
              installPath = pluginCachePath plugin;
              inherit (plugin) version;
              installedAt = "2026-01-01T00:00:00.000Z";
              lastUpdated = "2026-01-01T00:00:00.000Z";
            }
          ];
        })
        resolvedPlugins);
    };

  # Generate enabledPlugins map for settings.json merge
  enabledPluginsJson =
    builtins.toJSON
    {
      enabledPlugins = builtins.listToAttrs (map (plugin: {
          name = "${plugin.pluginName}@${plugin.marketplaceName}";
          value = true;
        })
        resolvedPlugins);
    };

  # Write the JSON files to nix store for the activation script to use
  knownMarketplacesFile = pkgs.writeText "nix-known-marketplaces.json" knownMarketplacesJson;
  installedPluginsFile = pkgs.writeText "nix-installed-plugins.json" installedPluginsJson;
  enabledPluginsFile = pkgs.writeText "nix-enabled-plugins.json" enabledPluginsJson;
in {
  options.homelab.claudePlugins = {
    enable = lib.mkEnableOption "Claude Code plugins";

    plugins = lib.mkOption {
      type = lib.types.listOf pluginType;
      default = [];
      description = "List of Claude Code plugins to install";
    };
  };

  config = lib.mkIf cfg.enable {
    # Create symlinks for each plugin in both marketplace and cache locations
    home.file = lib.mkMerge [
      # Marketplace location (for marketplace discovery)
      (builtins.listToAttrs (map (plugin: {
          name = ".claude/plugins/marketplaces/${plugin.marketplaceName}";
          value = {
            inherit (plugin) source;
            recursive = true;
          };
        })
        resolvedPlugins))
      # Cache location (where installPath points - prevents orphaned state)
      (builtins.listToAttrs (map (plugin: {
          name = ".claude/plugins/cache/${plugin.marketplaceName}/${plugin.pluginName}/${plugin.version}";
          value = {
            inherit (plugin) source;
            recursive = true;
          };
        })
        resolvedPlugins))
    ];

    # Activation script to merge JSON configs
    home.activation.claudePlugins = lib.hm.dag.entryAfter ["writeBoundary"] ''
      CLAUDE_DIR="${config.home.homeDirectory}/.claude"
      PLUGINS_DIR="$CLAUDE_DIR/plugins"

      # Ensure directories exist
      run mkdir -p "$PLUGINS_DIR/marketplaces"

      # Helper function to merge JSON files
      merge_json() {
        local target="$1"
        local nix_source="$2"
        local merge_strategy="$3"

        if [ -f "$target" ]; then
          case "$merge_strategy" in
            "shallow")
              # Shallow merge: nix values override existing top-level keys
              run ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$target" "$nix_source" > "$target.tmp"
              ;;
            "plugins")
              # Deep merge for installed_plugins.json: merge the plugins object
              run ${pkgs.jq}/bin/jq -s '
                .[0] * {
                  version: (.[1].version // .[0].version // 2),
                  plugins: ((.[0].plugins // {}) * (.[1].plugins // {}))
                }
              ' "$target" "$nix_source" > "$target.tmp"
              ;;
            "enabledPlugins")
              # Merge enabledPlugins into settings.json
              run ${pkgs.jq}/bin/jq -s '
                .[0] * {
                  enabledPlugins: ((.[0].enabledPlugins // {}) * (.[1].enabledPlugins // {}))
                }
              ' "$target" "$nix_source" > "$target.tmp"
              ;;
          esac
          run mv "$target.tmp" "$target"
        else
          run cp "$nix_source" "$target"
        fi
      }

      # Merge known_marketplaces.json
      verboseEcho "Merging Claude Code known_marketplaces.json..."
      merge_json "$PLUGINS_DIR/known_marketplaces.json" "${knownMarketplacesFile}" "shallow"

      # Merge installed_plugins.json
      verboseEcho "Merging Claude Code installed_plugins.json..."
      merge_json "$PLUGINS_DIR/installed_plugins.json" "${installedPluginsFile}" "plugins"

      # Merge enabledPlugins into settings.json
      verboseEcho "Merging Claude Code settings.json enabledPlugins..."
      if [ -f "$CLAUDE_DIR/settings.json" ]; then
        merge_json "$CLAUDE_DIR/settings.json" "${enabledPluginsFile}" "enabledPlugins"
      else
        # Create minimal settings.json if it doesn't exist
        run cp "${enabledPluginsFile}" "$CLAUDE_DIR/settings.json"
      fi
    '';
  };
}
