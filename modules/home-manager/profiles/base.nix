# modules/home-manager/profiles/base.nix
# Base Home Manager profile automatically imported for all hosts
{
  lib,
  inputs,
  pkgs,
  ...
}: {
  # ---------------------------------------------------------
  # CLAUDE CODE
  # ---------------------------------------------------------
  homelab.claudeCode = {
    enable = lib.mkDefault true;
    agentTeams = lib.mkDefault true;
    repoMemoryDirectory = lib.mkDefault ".claude/memory";
    # Privacy: opt out of telemetry, error reporting, surveys, and the autoupdater.
    # Nix manages the package, so the autoupdater can't write to /nix/store anyway.
    # True ZDR is Enterprise-only; pair this with the training opt-out in
    # claude.ai → Settings → Privacy on each Max account.
    settings = lib.mkDefault {
      env = {
        DISABLE_TELEMETRY = "1";
        DISABLE_ERROR_REPORTING = "1";
        DISABLE_AUTOUPDATER = "1";
        CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY = "1";
      };
    };
    plugins = lib.mkDefault [
      {
        source = inputs.claude-plugin-ha-skills;
        marketplaceName = "homeassistant-ai-skills";
        pluginName = "home-assistant-skills";
        # version auto-detected from plugin.json
      }
      {
        source = inputs.claude-plugin-compound-engineering;
        marketplaceName = "everyinc-compound-engineering";
        pluginName = "compound-engineering";
        # version auto-detected from plugin.json
      }
      # episodic-memory disabled: npm deps require manual install which breaks
      # Nix-managed Claude Code (see MEMORY.md). Re-evaluate when upstream
      # plugin dep management improves or we have credits to justify the effort.
      # {
      #   source = inputs.episodic-memory;
      #   marketplaceName = "episodic-memory-dev";
      #   pluginName = "episodic-memory";
      # }
    ];
    # Fleet-global skills: symlinked into ~/.claude/skills/<name> so they're
    # available regardless of CWD (the matching .claude/skills/<name> entry
    # in the nixosconfig repo is project-local and only works when claude
    # runs from this checkout).
    skills = lib.mkDefault [
      {
        name = "talk-to-me";
        source = ../../../.claude/skills/talk-to-me;
      }
    ];
  };
  home.packages = [
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
