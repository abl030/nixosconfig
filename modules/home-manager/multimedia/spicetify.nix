{
  lib,
  config,
  pkgs,
  inputs,
  ...
}:
with lib; let
  cfg = config.homelab.spicetify;
  inherit (config.homelab.theme) colors;

  # Safe helper to remove the '#' from hex codes
  stripHash = hex: lib.removePrefix "#" hex;

  # Get the spicePkgs from the flake input
  spicePkgs = inputs.spicetify-nix.legacyPackages.${pkgs.stdenv.hostPlatform.system};
in {
  # Import the module from the flake input
  imports = [
    inputs.spicetify-nix.homeManagerModules.default
  ];

  options.homelab.spicetify = {
    enable = mkEnableOption "Enable Spicetify (Themed Spotify)";
  };

  config = mkIf cfg.enable {
    # Enable the program
    programs.spicetify = {
      enable = true;

      # Use the "Sleek" theme (The one HyDE/Wallbash uses)
      theme = spicePkgs.themes.sleek;

      # Inject our custom colors
      colorScheme = "custom";
      customColorScheme = {
        # Text
        text = stripHash colors.foreground;
        subtext = stripHash colors.foreground;
        nav-active-text = stripHash colors.primary;

        # Backgrounds
        main = stripHash colors.background;
        sidebar = stripHash colors.background;
        player = stripHash colors.background;
        card = stripHash colors.backgroundAlt;
        shadow = stripHash colors.background;

        # Components
        button = stripHash colors.primary;
        button-active = stripHash colors.primary;
        button-disabled = stripHash colors.border;

        # Misc
        tab-active = stripHash colors.backgroundAlt;
        notification = stripHash colors.primary;
        notification-error = stripHash colors.urgent;
        misc = stripHash colors.backgroundAlt;
      };

      # Useful extensions
      enabledExtensions = with spicePkgs.extensions; [
        fullAppDisplay
        shuffle # Shuffle+ (better shuffle)
        hidePodcasts
      ];
    };
  };
}
