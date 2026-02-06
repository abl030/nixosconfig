# modules/home-manager/profiles/base.nix
# Base Home Manager profile automatically imported for all hosts
{
  lib,
  inputs,
  ...
}: {
  # ---------------------------------------------------------
  # CLAUDE CODE
  # ---------------------------------------------------------
  homelab.claudeCode = {
    enable = lib.mkDefault true;
    agentTeams = lib.mkDefault true;
    plugins = lib.mkDefault [
      {
        source = inputs.claude-plugin-ha-skills;
        marketplaceName = "homeassistant-ai-skills";
        pluginName = "home-assistant-skills";
        # version auto-detected from plugin.json
      }
    ];
  };
}
