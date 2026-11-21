# Second Claude Code login (a work subscription) beside the personal one.
#
# Claude Code keeps its whole state — OAuth credentials, .claude.json, settings,
# transcripts, background-job daemon — in one config dir: $CLAUDE_CONFIG_DIR,
# or ~/.claude (+ ~/.claude.json) when that is UNSET. Note "unset": setting it to
# ~/.claude moves .claude.json to ~/.claude/.claude.json and loses the login.
#
# This module routes by working directory:
#   * a `claude` wrapper (hiPrio over the package's own bin/claude) exports
#     CLAUDE_CONFIG_DIR=<configDir> when started inside one of `directories`
#     and the work account is logged in; anywhere else it leaves the variable
#     unset (personal). An already-set CLAUDE_CONFIG_DIR always wins, so child
#     sessions, subagents and `claude -p` calls stay on their parent's account.
#   * `claude-<name>` forces the work account (use it for the first /login),
#     `claude-me` forces personal.
#   * activation mirrors the fleet-managed Claude config from ~/.claude into the
#     work dir (settings keys, plugins, mcp-nixos) and symlinks the shared global
#     CLAUDE.md, hooks and skills, so both accounts behave identically.
#
# Until the work account has credentials the wrapper falls back to personal
# (with a note on stderr), so deploying this never breaks unattended
# `claude -p` runs such as brain's Ask Claude (brain.act).
# See docs/wiki/claude-code/two-accounts.md.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.claudeWorkAccount;
  home = config.home.homeDirectory;
  workDir = "${home}/${cfg.configDirName}";
  real = "${config.programs.claude-code.package}/bin/claude";
  jq = "${pkgs.jq}/bin/jq";

  casePattern =
    lib.concatMapStringsSep "|" (d: ''"${home}/${d}"|"${home}/${d}/"*'') cfg.directories;

  claudeRouter = pkgs.writeShellScriptBin "claude" ''
    # Account router — homelab.claudeWorkAccount (docs/wiki/claude-code/two-accounts.md).
    if [ -z "''${CLAUDE_CONFIG_DIR+x}" ]; then
      cwd=$(pwd -P 2>/dev/null || pwd)
      case "$cwd" in
        ${casePattern})
          if [ -s "${workDir}/.credentials.json" ]; then
            export CLAUDE_CONFIG_DIR="${workDir}"
          else
            echo "claude: ${cfg.name} account not logged in yet, using personal (run claude-${cfg.name}, then /login)" >&2
          fi
          ;;
      esac
    fi
    exec ${real} "$@"
  '';

  claudeWork = pkgs.writeShellScriptBin "claude-${cfg.name}" ''
    export CLAUDE_CONFIG_DIR="${workDir}"
    exec ${real} "$@"
  '';

  claudeMe = pkgs.writeShellScriptBin "claude-me" ''
    unset CLAUDE_CONFIG_DIR
    exec ${real} "$@"
  '';
in {
  options.homelab.claudeWorkAccount = {
    enable = lib.mkEnableOption "a second (work) Claude Code login, selected by working directory";
    name = lib.mkOption {
      type = lib.types.str;
      default = "work";
      description = "Short name; gives the `claude-<name>` launcher.";
    };
    configDirName = lib.mkOption {
      type = lib.types.str;
      default = ".claude-${cfg.name}";
      description = "Config dir for the work account, relative to $HOME.";
    };
    directories = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Directories (relative to $HOME) whose sessions use the work account, subdirectories included.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [(lib.hiPrio claudeRouter) claudeWork claudeMe];

    # Runs after base.nix's claudeConfig and common.nix's aiAgentNotifications
    # have finished writing ~/.claude, then copies the managed parts across.
    home.activation.claudeWorkAccount = lib.hm.dag.entryAfter ["claudeConfig" "aiAgentNotifications"] ''
      P="${home}/.claude"
      W="${workDir}"
      run mkdir -p "$W/plugins"
      run chmod 700 "$W"

      # Shared global instructions, hooks and skills: one copy, read through links.
      # A real file/dir already in W is left alone.
      for n in CLAUDE.md hooks skills keybindings.json; do
        [ -e "$P/$n" ] || continue
        if [ -L "$W/$n" ] || [ ! -e "$W/$n" ]; then
          run ln -sfn "$P/$n" "$W/$n"
        fi
      done

      # settings.json: first run copies everything (model, effort…); after that
      # only the fleet-managed keys are re-asserted, per-account choices survive.
      S="$W/settings.json"
      [ -f "$S" ] || run cp "$P/settings.json" "$S"
      run ${jq} -s '.[0] + (.[1]
          | {env, statusLine, deniedMcpServers, enabledPlugins, hooks, permissions, skipDangerousModePermissionPrompt}
          | with_entries(select(.value != null)))' \
        "$S" "$P/settings.json" > "$S.tmp" && run mv "$S.tmp" "$S"
      run chmod 600 "$S"

      # Plugin registrations (they point straight at /nix/store).
      for f in known_marketplaces.json installed_plugins.json; do
        [ -f "$P/plugins/$f" ] || continue
        [ -f "$W/plugins/$f" ] || run sh -c "echo '{}' > '$W/plugins/$f'"
        run ${jq} -s '.[0] * .[1]' "$W/plugins/$f" "$P/plugins/$f" > "$W/plugins/$f.tmp" \
          && run mv "$W/plugins/$f.tmp" "$W/plugins/$f"
      done

      # mcp-nixos at user scope (with CLAUDE_CONFIG_DIR set, .claude.json lives inside it).
      CJ="$W/.claude.json"
      [ -f "$CJ" ] || run sh -c "echo '{}' > '$CJ'"
      run ${jq} '.mcpServers = ((.mcpServers // {}) + {
          "mcp-nixos": { type: "stdio", command: "uvx", args: ["mcp-nixos"] }
        })' "$CJ" > "$CJ.tmp" && run mv "$CJ.tmp" "$CJ"
      run chmod 600 "$CJ"
    '';
  };
}
