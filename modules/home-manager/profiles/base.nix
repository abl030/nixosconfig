# modules/home-manager/profiles/base.nix
# Base Home Manager profile automatically imported for all hosts
{
  config,
  lib,
  inputs,
  pkgs,
  ...
}: let
  # rc-free bash for Claude Code's Bash tool. Claude builds a "shell snapshot"
  # at startup by dumping $SHELL's state (aliases + functions) into
  # ~/.claude/shell-snapshots/, then sources it on every Bash tool call. With
  # $SHELL=zsh that drags in zoxide (__zoxide_z), the `ls`->lsd alias, atuin and
  # starship — whose zsh syntax then misbehaves under the agent's bash and burns
  # tokens fighting the user's config. `--norc --noprofile` reads NO rc files, so
  # the snapshot comes out empty and the agent gets a vanilla, predictable shell.
  # The user's interactive zsh is untouched (this only sets SHELL for `claude`).
  # See docs/wiki/claude-code/clean-bash-shell-snapshot.md.
  claude-clean-bash = pkgs.writeShellScriptBin "claude-clean-bash" ''
    exec ${pkgs.bashInteractive}/bin/bash --norc --noprofile "$@"
  '';

  # `claude-agents`: launch the Agent View (`claude agents` manages background
  # sessions) with the clean shell as the snapshot source. Equivalent to
  # `SHELL=claude-clean-bash claude --verbose agents --dangerously-skip-permissions`.
  # Any extra args pass through.
  claude-agents = pkgs.writeShellScriptBin "claude-agents" ''
    export SHELL=${claude-clean-bash}/bin/claude-clean-bash
    exec ${config.programs.claude-code.package}/bin/claude \
      --verbose agents --dangerously-skip-permissions "$@"
  '';
in {
  # ---------------------------------------------------------
  # CLAUDE CODE  (native programs.claude-code — see issue #261)
  # ---------------------------------------------------------
  # We use the upstream home-manager module but deliberately leave
  # `settings`/`marketplaces`/`plugins`/`enableMcpIntegration` UNSET, so it
  # installs the package WITHOUT building a `claude` wrapper. Two reasons:
  #
  #   1. Setting `settings`/`marketplaces` makes the module write
  #      ~/.claude/settings.json (and known_marketplaces.json) as read-only
  #      /nix/store symlinks, clobbering runtime-mutable state the CLI owns
  #      (effortLevel, interactively-installed plugins, /config changes).
  #   2. `plugins`/`enableMcpIntegration` force-load via `--plugin-dir`/
  #      `--mcp-config` flags baked into a `claude` WRAPPER. Agent View's
  #      supervisor daemon self-respawns background workers from the UNWRAPPED
  #      binary with a fixed argv, so those flags never reach Agent-View /
  #      `claude --bg` sessions — plugins + MCP were present in the foreground
  #      but MISSING in every background session.
  #
  # Instead, the `claudeConfig` activation below registers the plugins and
  # mcp-nixos as ARGV-INDEPENDENT on-disk config (the pyright-lsp model), so
  # every session reads them the same way: foreground, Agent View, `claude
  # --bg`, and the systemd `claude -p` diagnosis runs (which already invoke the
  # unwrapped pkgs.claude-code). No wrapper, one source of truth.
  # See docs/wiki/claude-code/plugins-in-agent-view.md.
  programs.claude-code = {
    enable = lib.mkDefault true;
    # Sadjow's auto-updating flake (via overlay) — ships releases hours after
    # upstream; nixpkgs-unstable lags days. Keep it as the module package.
    package = lib.mkDefault pkgs.claude-code;
    # Fleet-global skill: symlinked into ~/.claude/skills/talk-to-me so it's
    # available regardless of CWD. Shared one-and-only source, also consumed
    # by programs.codex.skills (home/utils/common.nix).
    skills = lib.mkDefault {
      talk-to-me = ../../../.claude/skills/talk-to-me;
    };
  };

  # Shared MCP definition. Codex consumes programs.mcp directly (home/utils/
  # common.nix). Claude no longer uses enableMcpIntegration (it built a wrapper
  # Agent View bypasses — see above); the `claudeConfig` activation mirrors
  # mcp-nixos into ~/.claude.json user scope for Claude instead, so keep this
  # list and that activation in sync. The noisy subagent-only servers
  # (unifi/pfsense/playwright/HA) stay scoped to .claude/agents/, and vinsight
  # is per-repo via that repo's .mcp.json.
  programs.mcp = {
    enable = lib.mkDefault true;
    servers.mcp-nixos = lib.mkDefault {
      command = "uvx";
      args = ["mcp-nixos"];
    };
  };

  # Idempotent, argv-independent Claude Code config for the runtime-mutable
  # files the CLI owns (~/.claude/settings.json, ~/.claude/plugins/*.json,
  # ~/.claude.json). We merge ONLY the keys we manage and never write a
  # read-only /nix/store symlink, so everything the user/CLI writes (effortLevel,
  # hooks, oauth, history, interactively-installed plugins) is preserved. This
  # replaces the old `--plugin-dir`/`--mcp-config` wrapper, which Agent View's
  # supervisor bypassed (background sessions had no plugins/MCP).
  # See docs/wiki/claude-code/plugins-in-agent-view.md.
  home.activation.claudeConfig = lib.hm.dag.entryAfter ["writeBoundary"] ''
    CLAUDE_DIR="${config.home.homeDirectory}/.claude"
    PLUGINS_DIR="$CLAUDE_DIR/plugins"
    run mkdir -p "$PLUGINS_DIR"

    # --- settings.json: privacy opt-outs, agent-teams cleanup, enabledPlugins -
    # Privacy opt-outs (telemetry/error-reporting/survey/autoupdater); drop the
    # experimental agent-teams flag (kills spurious TaskCreate nudges); enable
    # our two plugins (and clean up the retired marketplace-named entries).
    SETTINGS="$CLAUDE_DIR/settings.json"
    [ -f "$SETTINGS" ] || run sh -c "echo '{}' > '$SETTINGS'"
    run ${pkgs.jq}/bin/jq '
      .env = ((.env // {}) + {
        "DISABLE_TELEMETRY": "1",
        "DISABLE_ERROR_REPORTING": "1",
        "DISABLE_AUTOUPDATER": "1",
        "CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY": "1"
      })
      | del(.env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS)
      | .enabledPlugins = (((.enabledPlugins // {})
          | del(.["compound-engineering@everyinc-compound-engineering"])
          | del(.["home-assistant-skills@homeassistant-ai-skills"])
          | del(.["episodic-memory@episodic-memory-dev"]))
          + {
            "home-assistant-skills@homelab-ha": true,
            "compound-engineering@homelab-ce": true
          })
    ' "$SETTINGS" > "$SETTINGS.tmp" && run mv "$SETTINGS.tmp" "$SETTINGS"

    # --- plugins as on-disk marketplaces pointing straight at /nix/store ------
    # Argv-independent: the unwrapped binary the Agent View supervisor spawns
    # reads these files, so background sessions load the plugins + their skills
    # (verified — the plugin subsystem enables and resolves skills straight from
    # here). installLocation/installPath reference the read-only store paths
    # directly (no copy); rewritten every activation so store-path churn from a
    # rebuild can never leave a stale record. ha-skills' root and the
    # compound-engineering root each carry .claude-plugin/marketplace.json.
    MKT="$PLUGINS_DIR/known_marketplaces.json"
    [ -f "$MKT" ] || run sh -c "echo '{}' > '$MKT'"
    run ${pkgs.jq}/bin/jq \
      --arg ha "${inputs.claude-plugin-ha-skills}" \
      --arg ce "${inputs.claude-plugin-compound-engineering}" '
        del(.["everyinc-compound-engineering"])
        | del(.["homeassistant-ai-skills"])
        | del(.["episodic-memory-dev"])
        | .["homelab-ha"] = { source: { source: "directory", path: $ha }, installLocation: $ha, lastUpdated: "2026-06-26T00:00:00.000Z" }
        | .["homelab-ce"] = { source: { source: "directory", path: $ce }, installLocation: $ce, lastUpdated: "2026-06-26T00:00:00.000Z" }
      ' "$MKT" > "$MKT.tmp" && run mv "$MKT.tmp" "$MKT"

    INST="$PLUGINS_DIR/installed_plugins.json"
    [ -f "$INST" ] || run sh -c "echo '{}' > '$INST'"
    run ${pkgs.jq}/bin/jq \
      --arg ha "${inputs.claude-plugin-ha-skills}" \
      --arg ce "${inputs.claude-plugin-compound-engineering}" '
        .version = (.version // 2)
        | .plugins = ((.plugins // {})
            | del(.["compound-engineering@everyinc-compound-engineering"])
            | del(.["home-assistant-skills@homeassistant-ai-skills"])
            | del(.["episodic-memory@episodic-memory-dev"]))
        | .plugins["home-assistant-skills@homelab-ha"] = [ { scope: "user", installPath: $ha, version: "0.1.0", installedAt: "2026-06-26T00:00:00.000Z", lastUpdated: "2026-06-26T00:00:00.000Z" } ]
        | .plugins["compound-engineering@homelab-ce"] = [ { scope: "user", installPath: $ce, version: "1.0.3", installedAt: "2026-06-26T00:00:00.000Z", lastUpdated: "2026-06-26T00:00:00.000Z" } ]
      ' "$INST" > "$INST.tmp" && run mv "$INST.tmp" "$INST"

    # --- mcp-nixos at user scope in ~/.claude.json (argv-independent) ---------
    # Replaces the old enableMcpIntegration carrier (wrapper-only --mcp-config).
    # tmp+mv guards the large claude-owned state file against a jq failure.
    CLAUDE_JSON="${config.home.homeDirectory}/.claude.json"
    [ -f "$CLAUDE_JSON" ] || run sh -c "echo '{}' > '$CLAUDE_JSON'"
    run ${pkgs.jq}/bin/jq '
      .mcpServers = ((.mcpServers // {}) + {
        "mcp-nixos": { type: "stdio", command: "uvx", args: ["mcp-nixos"] }
      })
    ' "$CLAUDE_JSON" > "$CLAUDE_JSON.tmp" && run mv "$CLAUDE_JSON.tmp" "$CLAUDE_JSON"

    # --- auto-memory: point Claude at the git-tracked .claude/memory dir ------
    # Project-scoped via the (gitignored) settings.local.json; idempotent and
    # preserves any other local keys (e.g. permission allow-lists).
    REPO="${config.home.homeDirectory}/nixosconfig"
    if [ -d "$REPO/.claude" ]; then
      LOCAL="$REPO/.claude/settings.local.json"
      [ -f "$LOCAL" ] || run sh -c "echo '{}' > '$LOCAL'"
      run ${pkgs.jq}/bin/jq --arg dir "$REPO/.claude/memory" \
        '.autoMemoryDirectory = $dir' "$LOCAL" > "$LOCAL.tmp" && run mv "$LOCAL.tmp" "$LOCAL"
    fi
  '';

  home.packages = [
    # Clean-shell launcher for Claude Code (see the `let` block above).
    # `claude-agents` is the everyday entrypoint; `claude-clean-bash` is exposed
    # too so it can be used manually as `SHELL=claude-clean-bash claude …`.
    claude-agents
    claude-clean-bash
    # MCP servers + runtime deps formerly installed by homelab.claudeCode.
    # Kept available even though most are subagent-only (see .claude/agents/).
    pkgs.unifi-mcp
    pkgs.pfsense-mcp
    pkgs.vinsight-mcp # installed but registered per-repo, not globally
    pkgs.playwright-mcp
    pkgs.nodejs
    pkgs.sox # Claude Code /voice mode
    pkgs.whosthere
    pkgs.yq-go
    # Beancount CLI suite — bean-check, bean-format, bean-doctor, bean-extract,
    # bean-identify, bean-file, bean-example, bean-report. bean-query and
    # bean-price were split out of the core package in 3.x.
    pkgs.beancount
    pkgs.beanquery
    pkgs.beanprice
  ];
}
