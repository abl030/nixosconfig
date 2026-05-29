# modules/home-manager/profiles/base.nix
# Base Home Manager profile automatically imported for all hosts
{
  config,
  lib,
  inputs,
  pkgs,
  ...
}: {
  # ---------------------------------------------------------
  # CLAUDE CODE  (native programs.claude-code — see issue #261)
  # ---------------------------------------------------------
  # We use the upstream home-manager module instead of a hand-rolled one, but
  # deliberately leave `settings`/`marketplaces` UNSET. The native module only
  # seizes ~/.claude/settings.json (as a read-only /nix/store symlink) when
  # those are set — which would clobber runtime-mutable state the CLI owns
  # (effortLevel, interactively-installed plugins, /config changes). With them
  # empty the module still installs the package, loads plugins (force-enabled
  # via --plugin-dir), wires mcp-nixos, and symlinks the skill, while never
  # touching settings.json. The 4 privacy env keys (which must reach the
  # systemd `claude -p` diagnosis runs, so they can't be shell env vars) are
  # merged in by the tiny idempotent `claudePrivacy` activation below.
  programs.claude-code = {
    enable = lib.mkDefault true;
    # Sadjow's auto-updating flake (via overlay) — ships releases hours after
    # upstream; nixpkgs-unstable lags days. Keep it as the module package.
    package = lib.mkDefault pkgs.claude-code;
    # Shared programs.mcp.servers (mcp-nixos) → claude's main-chat MCP set.
    enableMcpIntegration = lib.mkDefault true;
    # Plugins load via `--plugin-dir <store-path>` on a wrapped `claude`.
    # This force-enables them (no enabledPlugins entry needed) and reads fine
    # from read-only store paths. ha-skills' repo root is itself a single
    # plugin (has .claude-plugin/plugin.json); compound-engineering is a
    # multi-plugin marketplace, so we point at the plugin subdir directly.
    plugins = lib.mkDefault [
      inputs.claude-plugin-ha-skills
      "${inputs.claude-plugin-compound-engineering}/plugins/compound-engineering"
    ];
    # Fleet-global skill: symlinked into ~/.claude/skills/talk-to-me so it's
    # available regardless of CWD. Shared one-and-only source, also consumed
    # by programs.codex.skills (home/utils/common.nix).
    skills = lib.mkDefault {
      talk-to-me = ../../../.claude/skills/talk-to-me;
    };
  };

  # Shared MCP definitions consumed by both Claude (enableMcpIntegration) and,
  # in principle, Codex. mcp-nixos is the only main-chat MCP; the noisy
  # subagent-only servers (unifi/pfsense/playwright/HA) stay scoped to
  # .claude/agents/, and vinsight is per-repo via that repo's .mcp.json.
  programs.mcp = {
    enable = lib.mkDefault true;
    servers.mcp-nixos = lib.mkDefault {
      command = "uvx";
      args = ["mcp-nixos"];
    };
  };

  # Privacy + agentTeams cleanup + auto-memory for the runtime-mutable
  # ~/.claude/settings.json. Idempotently merges ONLY the keys we manage,
  # leaving everything the user/CLI writes (effortLevel, enabledPlugins for
  # interactively-installed plugins, hooks, etc.) intact. Replaces the
  # ~360-line settings/plugin machinery of the retired homelab.claudeCode.
  home.activation.claudePrivacy = lib.hm.dag.entryAfter ["writeBoundary"] ''
    SETTINGS="${config.home.homeDirectory}/.claude/settings.json"
    run mkdir -p "$(dirname "$SETTINGS")"
    [ -f "$SETTINGS" ] || run sh -c "echo '{}' > '$SETTINGS'"
    # Privacy opt-outs (telemetry/error-reporting/survey/autoupdater); drop the
    # experimental agent-teams flag (kills spurious TaskCreate nudges); and
    # strip stale enabledPlugins entries. compound-engineering + ha-skills are
    # now served from --plugin-dir (@inline) so their marketplace entries are
    # redundant; episodic-memory is retired. All three lost their marketplace
    # dirs, so leaving them throws "cache-miss" on every session. pyright-lsp
    # (working, claude-plugins-official) and any other entries are untouched.
    run ${pkgs.jq}/bin/jq '
      .env = ((.env // {}) + {
        "DISABLE_TELEMETRY": "1",
        "DISABLE_ERROR_REPORTING": "1",
        "DISABLE_AUTOUPDATER": "1",
        "CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY": "1"
      })
      | del(.env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS)
      | if has("enabledPlugins") then
          .enabledPlugins |=
            (del(.["compound-engineering@everyinc-compound-engineering"])
             | del(.["home-assistant-skills@homeassistant-ai-skills"])
             | del(.["episodic-memory@episodic-memory-dev"]))
        else . end
    ' "$SETTINGS" > "$SETTINGS.tmp" && run mv "$SETTINGS.tmp" "$SETTINGS"

    # Drop the matching stale marketplace/installed-plugin records so
    # `claude plugin list` no longer shows them as failed-to-load. These files
    # are runtime-mutable and claude-owned; we only delete the retired entries,
    # never recreate the machinery.
    PLUGINS_DIR="${config.home.homeDirectory}/.claude/plugins"
    if [ -f "$PLUGINS_DIR/known_marketplaces.json" ]; then
      run ${pkgs.jq}/bin/jq \
        'del(.["everyinc-compound-engineering"]) | del(.["homeassistant-ai-skills"]) | del(.["episodic-memory-dev"])' \
        "$PLUGINS_DIR/known_marketplaces.json" > "$PLUGINS_DIR/known_marketplaces.json.tmp" \
        && run mv "$PLUGINS_DIR/known_marketplaces.json.tmp" "$PLUGINS_DIR/known_marketplaces.json"
    fi
    if [ -f "$PLUGINS_DIR/installed_plugins.json" ]; then
      run ${pkgs.jq}/bin/jq \
        '.plugins |= (del(.["compound-engineering@everyinc-compound-engineering"]) | del(.["home-assistant-skills@homeassistant-ai-skills"]) | del(.["episodic-memory@episodic-memory-dev"]))' \
        "$PLUGINS_DIR/installed_plugins.json" > "$PLUGINS_DIR/installed_plugins.json.tmp" \
        && run mv "$PLUGINS_DIR/installed_plugins.json.tmp" "$PLUGINS_DIR/installed_plugins.json"
    fi

    # Auto-memory: point Claude at the git-tracked .claude/memory dir via the
    # project's (gitignored) settings.local.json. Project-scoped + idempotent;
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
