# Claude Code - Unified declarative management of package, settings, and plugins
#
# Usage in home.nix:
#   homelab.claudeCode = {
#     enable = true;
#     agentTeams = true;          # sets CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
#     settings = {};              # arbitrary attrs merged into ~/.claude/settings.json
#     plugins = [{
#       source = inputs.claude-plugin-foo;
#       marketplaceName = "org-repo";
#       pluginName = "my-plugin";
#     }];
#   };
#
# ============================================================================
# Beads Issue Tracking — Centralised Dolt Backend
# ============================================================================
#
# This module installs beads (bd) and runs a Dolt SQL server as a user service.
# Beads is the project's issue tracker — it replaces markdown TODOs, external
# trackers, etc.
#
# ## Architecture (centralised model)
#
# doc1 (proxmox-vm) runs the single Dolt SQL server. All other hosts connect
# to it over Tailscale. There is no per-host database or JSONL sync.
#
#   framework ──┐
#   wsl ────────┤
#   epimetheus ─┼──> doc1 dolt-server (100.89.160.60:3307) ──> ~/.local/share/dolt/beads/
#   igpu ───────┤
#   dev ────────┘
#
# The Dolt server binds 0.0.0.0:3307. Access is restricted to Tailscale — the
# tailscale module sets trustedInterfaces = ["tailscale0"], so port 3307 is
# reachable over Tailscale but NOT on the LAN.
#
# The dolt-server systemd user service starts on every host that enables this
# module, but only doc1's instance is the "source of truth". Other hosts can
# either:
#   a) Point bd at doc1's Tailscale IP (recommended), or
#   b) Run a local dolt-server for offline work and sync later
#
# ## Migration History
#
# 1. SQLite era: beads used .beads/beads.db per clone (fragile, no sync)
# 2. Dolt + JSONL sync era (commit db8a125): each host ran local dolt-server,
#    synced via JSONL on the beads-sync git branch
# 3. Centralised Dolt era (current): single server on doc1, all hosts connect
#    over Tailscale. The beads-sync branch and JSONL export are obsolete.
#
# Old .beads/beads.db SQLite files can be safely deleted.
#
# ## doc1 (server) Setup — already done
#
# doc1 runs dolt-server via this module. Data lives in ~/.local/share/dolt/beads/.
# After rebuild, beads was initialised with:
#
#   cd ~/nixosconfig
#   bd init --prefix nixosconfig
#   # Selected: dolt backend, server mode, port 3307, host 127.0.0.1
#   # Database name: beads_nixosconfig
#
#   bd hooks install --force
#   bd config set beads.role maintainer
#   bd config set daemon.auto-commit true
#   bd config set daemon.auto-push true
#   bd config set daemon.auto-pull true
#   bd daemon stop . && bd daemon start
#
# ## Remote Host Setup (framework, wsl, epimetheus, igpu, dev, caddy)
#
# After `nixos-rebuild switch` or `home-manager switch` picks up this flake:
#
#   Step 1: Init beads pointing at doc1's Dolt server
#     cd ~/nixosconfig    # or wherever the repo is cloned
#     bd init --prefix nixosconfig
#     # Select: dolt backend, server mode
#     # Port: 3307
#     # Host: 100.89.160.60  (doc1's Tailscale IP)
#     # Database name: beads_nixosconfig
#
#   Step 2: Install hooks and configure daemon
#     bd hooks install --force
#     bd config set beads.role maintainer
#     bd config set daemon.auto-commit true
#     bd config set daemon.auto-push true
#     bd config set daemon.auto-pull true
#     bd daemon stop . && bd daemon start
#
#   Step 3: Verify
#     bd stats    # Should show all issues immediately (reads from doc1)
#     bd ready    # Should list available work
#
# ## Troubleshooting
#
#   - "LEGACY DATABASE" error: run `bd migrate --update-repo-id`
#   - Can't connect to doc1: check `tailscale ping doc1` and that dolt-server
#     is running on doc1: `ssh doc1 systemctl --user status dolt-server`
#   - Daemon not syncing: check `bd daemon status`, restart with stop/start
#   - Dolt server won't start: check `journalctl --user -u dolt-server`
#     Common cause: stale lock file in ~/.local/share/dolt/beads/
#
# ## Hosts configured
#   - proxmox-vm (doc1) — server, 2026-02-24
#   - All others — connect to doc1 as remote clients (pending setup)
# ============================================================================
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.claudeCode;

  # --- Settings logic ---

  # Build the settings attrset: user settings + agentTeams convenience + enabledPlugins
  effectiveSettings = let
    agentTeamsSettings =
      lib.optionalAttrs cfg.agentTeams
      {env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1";};
    pluginSettings =
      lib.optionalAttrs (cfg.plugins != [])
      {
        enabledPlugins = builtins.listToAttrs (map (plugin: {
            name = "${plugin.pluginName}@${plugin.marketplaceName}";
            value = true;
          })
          resolvedPlugins);
      };
  in
    lib.recursiveUpdate (lib.recursiveUpdate cfg.settings agentTeamsSettings) pluginSettings;

  settingsFile = pkgs.writeText "nix-claude-settings.json" (builtins.toJSON effectiveSettings);

  # --- Plugin logic (absorbed from claude-plugins.nix) ---

  # Patch plugin source to remove invalid fields from marketplace.json
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

      # --- Fix Nix symlink module resolution ---
      # Nix home.file creates per-file symlinks to /nix/store. Node ESM resolves
      # the real path before looking for node_modules, so it searches /nix/store
      # instead of the writable cache dir where npm install ran. --preserve-symlinks
      # tells Node to use the symlink path for module resolution.

      # 1. Patch plugin.json MCP server envs to add --preserve-symlinks
      if [ -f "$out/.claude-plugin/plugin.json" ]; then
        jq 'if .mcpServers then .mcpServers |= with_entries(
          .value.env = (.value.env // {}) + {"NODE_OPTIONS": "--preserve-symlinks --preserve-symlinks-main"}
        ) else . end' \
          "$out/.claude-plugin/plugin.json" > "$out/.claude-plugin/plugin.json.tmp"
        mv "$out/.claude-plugin/plugin.json.tmp" "$out/.claude-plugin/plugin.json"
      fi

      # 2. Remove realpathSync(__filename) from CLI scripts — it resolves symlinks
      #    into /nix/store, breaking module resolution even with --preserve-symlinks
      find "$out" -name "*.js" -type f -exec \
        sed -i 's/dirname(realpathSync(__filename))/dirname(__filename)/g' {} +

      # 3. Patch hooks.json commands to include NODE_OPTIONS so spawned child
      #    processes also resolve modules from the symlink location
      if [ -f "$out/hooks/hooks.json" ]; then
        jq '.hooks |= with_entries(.value |= map(.hooks |= map(
          if .type == "command" and (.command | test("^node "))
          then .command = "NODE_OPTIONS=\"--preserve-symlinks --preserve-symlinks-main\" " + .command
          else . end
        )))' \
          "$out/hooks/hooks.json" > "$out/hooks/hooks.json.tmp"
        mv "$out/hooks/hooks.json.tmp" "$out/hooks/hooks.json"
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
        else getPluginVersion plugin.source;
      source = patchedSource;
    };

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

  knownMarketplacesFile = pkgs.writeText "nix-known-marketplaces.json" knownMarketplacesJson;
  installedPluginsFile = pkgs.writeText "nix-installed-plugins.json" installedPluginsJson;

  # Dolt data directory for beads — initialised lazily by ExecStartPre
  doltDataDir = "${config.home.homeDirectory}/.local/share/dolt/beads";

  doltInitScript = pkgs.writeShellScript "dolt-init" ''
    set -euo pipefail
    export PATH="${lib.makeBinPath [pkgs.coreutils pkgs.dolt pkgs.git]}:$PATH"
    DATA_DIR="${doltDataDir}"
    mkdir -p "$DATA_DIR"

    # Set dolt identity if not already configured
    if ! dolt config --global --get user.name >/dev/null 2>&1; then
      dolt config --global --add user.name "$(git config user.name || echo "$USER")"
    fi
    if ! dolt config --global --get user.email >/dev/null 2>&1; then
      dolt config --global --add user.email "$(git config user.email || echo "$USER@localhost")"
    fi

    # Init dolt repo if not already done
    if [ ! -d "$DATA_DIR/.dolt" ]; then
      cd "$DATA_DIR" && dolt init
    fi
  '';
in {
  options.homelab.claudeCode = {
    enable = lib.mkEnableOption "Claude Code (package, settings, plugins)";

    agentTeams = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable experimental agent teams (sets CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 in settings.json env)";
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Arbitrary attrset deep-merged into ~/.claude/settings.json";
    };

    plugins = lib.mkOption {
      type = lib.types.listOf pluginType;
      default = [];
      description = "List of Claude Code plugins to install";
    };
  };

  config = lib.mkIf cfg.enable {
    home = {
      # Install claude-code and MCP server packages
      packages = [
        pkgs.claude-code
        pkgs.unifi-mcp
        pkgs.pfsense-mcp
        pkgs.loki-mcp
        pkgs.lidarr-mcp
        pkgs.slskd-mcp
        pkgs.vinsight-mcp
        pkgs.beads
        pkgs.dolt
        pkgs.nodejs
      ];

      # Create symlinks for plugins in marketplace (read-only)
      # Cache will be populated as writable copies in activation script
      file = lib.mkIf (cfg.plugins != []) (builtins.listToAttrs (map (plugin: {
          name = ".claude/plugins/marketplaces/${plugin.marketplaceName}";
          value = {
            inherit (plugin) source;
            recursive = true;
          };
        })
        resolvedPlugins));

      # Activation script to merge settings and plugin configs
      activation.claudeCode = lib.hm.dag.entryAfter ["writeBoundary"] ''
        CLAUDE_DIR="${config.home.homeDirectory}/.claude"
        PLUGINS_DIR="$CLAUDE_DIR/plugins"

        # Ensure directories exist
        run mkdir -p "$CLAUDE_DIR"

        # --- Merge settings.json ---
        verboseEcho "Merging Claude Code settings.json..."
        if [ -f "$CLAUDE_DIR/settings.json" ]; then
          run ${pkgs.jq}/bin/jq -s '
            def deepmerge(a; b):
              a as $a | b as $b |
              if ($a | type) == "object" and ($b | type) == "object"
              then [$a, $b] | map(to_entries) | add | group_by(.key) |
                   map(if length == 1 then .[0]
                       else {key: .[0].key, value: deepmerge(.[0].value; .[1].value)}
                       end) | from_entries
              else $b
              end;
            deepmerge(.[0]; .[1])
          ' "$CLAUDE_DIR/settings.json" "${settingsFile}" > "$CLAUDE_DIR/settings.json.tmp"
          run mv "$CLAUDE_DIR/settings.json.tmp" "$CLAUDE_DIR/settings.json"
        else
          run cp "${settingsFile}" "$CLAUDE_DIR/settings.json"
        fi

        ${lib.optionalString (cfg.plugins != []) ''
          # --- Merge plugin JSON configs ---
          run mkdir -p "$PLUGINS_DIR/marketplaces"
          run mkdir -p "$PLUGINS_DIR/cache"

          # --- Copy plugins to writable cache ---
          ${lib.concatMapStringsSep "\n" (plugin: ''
              CACHE_DIR="$PLUGINS_DIR/cache/${plugin.marketplaceName}/${plugin.pluginName}/${plugin.version}"
              if [ ! -d "$CACHE_DIR" ] || [ "${plugin.source}" -nt "$CACHE_DIR" ]; then
                verboseEcho "Copying plugin ${plugin.pluginName} to writable cache..."
                run rm -rf "$CACHE_DIR"
                run mkdir -p "$(dirname "$CACHE_DIR")"
                run cp -r "${plugin.source}" "$CACHE_DIR"
                run chmod -R u+w "$CACHE_DIR"
              fi
            '')
            resolvedPlugins}

          # Merge known_marketplaces.json
          verboseEcho "Merging Claude Code known_marketplaces.json..."
          if [ -f "$PLUGINS_DIR/known_marketplaces.json" ]; then
            run ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$PLUGINS_DIR/known_marketplaces.json" "${knownMarketplacesFile}" > "$PLUGINS_DIR/known_marketplaces.json.tmp"
            run mv "$PLUGINS_DIR/known_marketplaces.json.tmp" "$PLUGINS_DIR/known_marketplaces.json"
          else
            run cp "${knownMarketplacesFile}" "$PLUGINS_DIR/known_marketplaces.json"
          fi

          # Merge installed_plugins.json
          verboseEcho "Merging Claude Code installed_plugins.json..."
          if [ -f "$PLUGINS_DIR/installed_plugins.json" ]; then
            run ${pkgs.jq}/bin/jq -s '
              .[0] * {
                version: (.[1].version // .[0].version // 2),
                plugins: ((.[0].plugins // {}) * (.[1].plugins // {}))
              }
            ' "$PLUGINS_DIR/installed_plugins.json" "${installedPluginsFile}" > "$PLUGINS_DIR/installed_plugins.json.tmp"
            run mv "$PLUGINS_DIR/installed_plugins.json.tmp" "$PLUGINS_DIR/installed_plugins.json"
          else
            run cp "${installedPluginsFile}" "$PLUGINS_DIR/installed_plugins.json"
          fi
        ''}
      '';
    };

    # Dolt SQL server for beads issue tracking
    systemd.user.services.dolt-server = {
      Unit = {
        Description = "Dolt SQL server for beads";
        After = ["default.target"];
      };
      Service = {
        Type = "simple";
        ExecStartPre = "${doltInitScript}";
        ExecStart = "${pkgs.dolt}/bin/dolt sql-server --port 3307 --host 0.0.0.0 --data-dir ${doltDataDir}";
        Restart = "on-failure";
        RestartSec = 5;
      };
      Install.WantedBy = ["default.target"];
    };
  };
}
