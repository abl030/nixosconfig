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
    settings = lib.mkDefault {
      hooks = {
        SessionStart = [
          {
            hooks = [
              {
                type = "command";
                command = "if [ -d .beads ]; then bd prime 2>/dev/null; fi";
              }
            ];
          }
        ];
        PreCompact = [
          {
            hooks = [
              {
                type = "command";
                command = "if [ -d .beads ]; then bd sync 2>/dev/null; fi";
              }
            ];
          }
        ];
      };
    };
    plugins = lib.mkDefault [
      {
        source = inputs.claude-plugin-ha-skills;
        marketplaceName = "homeassistant-ai-skills";
        pluginName = "home-assistant-skills";
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
  };
  home.packages = [
    pkgs.whosthere
  ];
}
