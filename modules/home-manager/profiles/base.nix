# modules/home-manager/profiles/base.nix
# Base Home Manager profile automatically imported for all hosts
{
  lib,
  inputs,
  ...
}: {
  # ---------------------------------------------------------
  # CLAUDE CODE PLUGINS
  # ---------------------------------------------------------
  homelab.claudePlugins = {
    enable = lib.mkDefault true;
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
