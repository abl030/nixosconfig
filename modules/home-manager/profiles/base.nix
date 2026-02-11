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
      {
        source = inputs.episodic-memory;
        marketplaceName = "episodic-memory-dev";
        pluginName = "episodic-memory";
      }
    ];
  };
  home.packages = [
    pkgs.whosthere
  ];
}
