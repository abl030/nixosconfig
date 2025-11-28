{
  lib,
  config,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.waybar;
in {
  options.homelab.waybar = {
    enable = mkEnableOption "Enable Waybar Status Bar";
  };

  config =
    mkIf cfg.enable {
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
            height = 36; # Increased slightly to accommodate borders
            spacing = 4;

            modules-left = ["hyprland/workspaces" "hyprland/window"];
            modules-center = ["clock"];
            modules-right = ["network" "cpu" "memory" "pulseaudio" "tray"];

            "hyprland/workspaces" = {
              disable-scroll = true;
              on-click = "activate";
            };

            "clock" = {
              tooltip-format = "<big>{:%Y %B}</big>
<tt><small>{:%Y-%m-%d}</small></tt>";
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
              # Shows download/upload speed
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
          /* Colors from inspiration */
          @define-color background #2C2A24;
          @define-color second-background #3A372F;
          @define-color text #DDD5C4;
          @define-color borders #A0907A;
          @define-color focused #D08B57;
          @define-color focused2 #BFAA80;
          @define-color color1 #7699A3;
          @define-color color2 #8D7AAE;
          @define-color color3 #78997A;
          @define-color urgent #B05A5A;

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
