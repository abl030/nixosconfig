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
        type = lib.types.str;
        default = "1.0.0";
        description = "Version string for the plugin";
      };
    };
  };

  # Generate known_marketplaces.json content
  knownMarketplacesJson =
    builtins.toJSON
    (builtins.listToAttrs (map (plugin: {
        name = plugin.marketplaceName;
        value = {
          source = {
            source = "nix";
            store_path = toString plugin.source;
          };
          installLocation = "${config.home.homeDirectory}/.claude/plugins/marketplaces/${plugin.marketplaceName}";
          lastUpdated = "2026-01-01T00:00:00.000Z";
        };
      })
      cfg.plugins));

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
              installPath = "${config.home.homeDirectory}/.claude/plugins/marketplaces/${plugin.marketplaceName}";
              inherit (plugin) version;
              installedAt = "2026-01-01T00:00:00.000Z";
              lastUpdated = "2026-01-01T00:00:00.000Z";
            }
          ];
        })
        cfg.plugins);
    };

  # Generate enabledPlugins map for settings.json merge
  enabledPluginsJson =
    builtins.toJSON
    {
      enabledPlugins = builtins.listToAttrs (map (plugin: {
          name = "${plugin.pluginName}@${plugin.marketplaceName}";
          value = true;
        })
        cfg.plugins);
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
    # Create symlinks for each plugin marketplace
    home.file = builtins.listToAttrs (map (plugin: {
        name = ".claude/plugins/marketplaces/${plugin.marketplaceName}";
        value = {
          inherit (plugin) source;
          recursive = true;
        };
      })
      cfg.plugins);

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
