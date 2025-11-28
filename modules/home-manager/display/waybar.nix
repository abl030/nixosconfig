{
  lib,
  config,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.waybar;
  inherit (config.homelab.theme) colors;
in {
  options.homelab.waybar = {
    enable = mkEnableOption "Enable Waybar Status Bar";
  };

  config = mkIf cfg.enable {
    # 1. Install Waybar dependencies
    # (The waybar package itself is installed by programs.waybar.enable = true)
    home.packages = with pkgs; [
      font-awesome # Icons for the bar
    ];

    # 2. Configure Waybar
    programs.waybar = {
      enable = true;
      systemd.enable = false; # Disable systemd to let Hyprland exec-once handle startup

      settings = {
        mainBar = {
          layer = "top";
          position = "top";
          height = 36;
          spacing = 4;

          modules-left = ["hyprland/workspaces" "hyprland/window"];
          modules-center = ["clock"];
          modules-right = ["network" "cpu" "memory" "pulseaudio" "tray"];

          "hyprland/workspaces" = {
            disable-scroll = true;
            on-click = "activate";
          };

          "clock" = {
            tooltip-format = "<big>{:%Y %B}</big>\n<tt><small>{:%Y-%m-%d}</small></tt>";
            format-alt = "{:%Y-%m-%d}";
          };

          "cpu" = {
            interval = 5;
            format = "CPU {usage}%";
            tooltip = true;
          };

          "memory" = {
            interval = 30;
            format = "RAM {}%";
          };

          "network" = {
            interval = 2;
            format-ethernet = "In: {bandwidthDownBytes} Out: {bandwidthUpBytes}";
            format-wifi = "{essid} ({signalStrength}%) ⬇{bandwidthDownBytes} ⬆{bandwidthUpBytes}";
            format-disconnected = "Disconnected";
            tooltip-format = "{ifname} via {gwaddr}";
          };

          "pulseaudio" = {
            format = "Vol {volume}%";
            format-muted = "Muted";
            on-click = "pavucontrol";
          };

          "tray" = {
            spacing = 10;
          };
        };
      };

      style = ''
        /* Colors mapped from theme.nix */
        @define-color background ${colors.background};
        @define-color second-background ${colors.backgroundAlt};
        @define-color text ${colors.foreground};
        @define-color borders ${colors.border};
        @define-color focused ${colors.primary};
        @define-color focused2 ${colors.secondary};
        @define-color color1 ${colors.info};
        @define-color color2 ${colors.warning};
        @define-color color3 ${colors.success};
        @define-color urgent ${colors.urgent};

        * {
            border: none;
            border-radius: 0;
            font-family: "Iosevka Nerd Font", "JetBrainsMono Nerd Font", "Roboto", sans-serif;
            font-size: 14px;
            min-height: 0;
        }

        window#waybar {
            background-color: transparent; /* Transparent so we see the islands */
            color: @text;
            transition: background-color 0.5s;
        }

        /* ISLAND STYLING: mimic the structure of the inspiration */
        .modules-left, .modules-center, .modules-right {
            background-color: @background;
            border: 2px solid @focused; /* The orange border */
            border-radius: 10px;
            padding: 2px 10px;
            margin-top: 5px;
            margin-bottom: 0px;
        }

        .modules-left {
            margin-left: 10px;
        }

        .modules-right {
            margin-right: 10px;
        }

        /* Workspaces */
        #workspaces button {
            padding: 0 8px;
            color: @text;
            background-color: transparent;
        }

        #workspaces button:hover {
            background-color: @second-background;
            border-radius: 5px;
        }

        #workspaces button.active {
            color: @focused2;
            background-color: @second-background;
            border-radius: 5px;
        }

        #workspaces button.urgent {
            background-color: @urgent;
        }

        /* Standard Modules (CPU, RAM, Net, etc) - Remove individual backgrounds */
        #clock,
        #cpu,
        #memory,
        #network,
        #pulseaudio,
        #tray,
        #window {
            padding: 0 10px;
            background-color: transparent;
            color: @text;
        }

        /* Hover effects from inspiration */
        #clock:hover,
        #cpu:hover,
        #memory:hover,
        #network:hover,
        #pulseaudio:hover,
        #tray:hover {
            color: @color1; /* Blue accent on hover */
        }

        /* Network specific colors */
        #network.disconnected {
            color: @urgent;
        }

        /* Audio specific */
        #pulseaudio.muted {
            color: @color2; /* Purpleish for muted */
        }
      '';
    };
  };
}
