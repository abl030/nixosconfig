# modules/home-manager/display/yazi.nix
{
  lib,
  config,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.yazi;
  inherit (config.homelab.theme) colors;
in {
  options.homelab.yazi = {
    enable = mkEnableOption "Enable Yazi TUI file manager themed with homelab.theme.colors";
  };

  config = mkIf cfg.enable {
    programs.yazi = {
      enable = true;
      package = pkgs.yazi;

      # Shell integration: lets Yazi "cd" your shell, etc. :contentReference[oaicite:0]{index=0}
      enableBashIntegration = true;
      enableFishIntegration = true;
      enableZshIntegration = true;

      # Wrapper name: you'll run `y` instead of `yazi` in shells and it will
      # handle the cd integration.
      shellWrapperName = "y";

      # Helpful tools for previewers/openers (images, pdfs, archives, etc.). :contentReference[oaicite:1]{index=1}
      extraPackages = with pkgs; [
        fd
        ripgrep
        fzf
        jq
        zoxide
        poppler
        ffmpeg
        p7zip
        imagemagick
        chafa
      ];

      # Basic behaviour tuning (yazi.toml) :contentReference[oaicite:2]{index=2}
      settings = {
        mgr = {
          show_hidden = true;
          sort_by = "natural";
          sort_dir_first = true;
          sort_reverse = false;
          linemode = "permissions";
          scrolloff = 5;
        };

        preview = {
          wrap = "yes";
          tab_size = 4;
          max_width = 1200;
          max_height = 1200;
        };
      };

      # Theme derived from homelab.theme.colors (theme.toml) :contentReference[oaicite:3]{index=3}
      theme = let
        bg = colors.background;
        bgAlt = colors.backgroundAlt;
        fg = colors.foreground;
        accent = colors.primary;
        secondary = colors.secondary;
        border = colors.border;
        info = colors.info;
        success = colors.success;
        warning = colors.warning;
        urgent = colors.urgent;
      in {
        # Main file list + preview pane styling
        mgr = {
          cwd = {
            fg = accent;
            bg = bg;
            bold = true;
          };
          hovered = {
            fg = fg;
            bg = bgAlt;
            bold = true;
          };
          preview_hovered = {
            fg = fg;
            bg = bgAlt;
          };
          find_keyword = {
            fg = secondary;
            bold = true;
            underline = true;
          };
          find_position = {
            fg = info;
            bold = true;
          };
          marker_selected = {
            fg = secondary;
            bg = bgAlt;
            bold = true;
          };
          marker_copied = {
            fg = info;
            bg = bg;
          };
          marker_cut = {
            fg = warning;
            bg = bg;
          };
          border_symbol = "│";
          border_style = {fg = border;};
        };

        # Tabs (if you use multiple panes)
        tabs = {
          active = {
            fg = bg;
            bg = accent;
            bold = true;
          };
          inactive = {
            fg = fg;
            bg = bgAlt;
          };
          sep_inner = {
            open = "[";
            close = "]";
          };
          sep_outer = {
            open = "";
            close = "";
          };
        };

        # Mode indicator (normal/select/etc) in status
        mode = {
          normal_main = {
            fg = bg;
            bg = accent;
            bold = true;
          };
          normal_alt = {
            fg = fg;
            bg = bgAlt;
          };
          select_main = {
            fg = bg;
            bg = secondary;
            bold = true;
          };
          select_alt = {
            fg = fg;
            bg = bgAlt;
          };
          unset_main = {
            fg = bg;
            bg = border;
          };
          unset_alt = {
            fg = fg;
            bg = bgAlt;
          };
        };

        # Status bar (permissions, progress, etc.)
        status = {
          overall = {
            fg = fg;
            bg = bgAlt;
          };
          perm_type = {fg = secondary;};
          perm_read = {fg = info;};
          perm_write = {fg = warning;};
          perm_exec = {fg = success;};
          perm_sep = {fg = border;};

          progress_label = {
            fg = fg;
            bold = true;
          };
          progress_normal = {
            fg = bg;
            bg = accent;
          };
          progress_error = {
            fg = bg;
            bg = urgent;
          };

          sep_left = {
            open = "";
            close = "│";
          };
          sep_right = {
            open = "│";
            close = "";
          };
        };

        # “Which-key” helper popup
        which = {
          cols = 2;
          mask = {
            fg = "reset";
            bg = bg;
          };
          cand = {
            fg = accent;
            bold = true;
          };
          rest = {fg = fg;};
          desc = {fg = secondary;};
          separator = " → ";
          separator_style = {fg = border;};
        };

        # Generic input prompts (search, filter, rename, etc.)
        input = {
          border = {fg = border;};
          title = {
            fg = accent;
            bold = true;
          };
          value = {
            fg = fg;
            bg = bg;
          };
          selected = {
            fg = bg;
            bg = accent;
            bold = true;
          };
        };

        # Yes/No confirmations (delete, trash, quit)
        confirm = {
          border = {fg = border;};
          title = {
            fg = accent;
            bold = true;
          };
          content = {fg = fg;};
          list = {fg = fg;};
          btn_yes = {
            fg = bg;
            bg = success;
            bold = true;
          };
          btn_no = {
            fg = bg;
            bg = urgent;
          };
          btn_labels = ["Yes" "No"];
        };

        # Small one-shot pickers (open with…)
        pick = {
          border = {fg = border;};
          active = {
            fg = bg;
            bg = accent;
            bold = true;
          };
          inactive = {
            fg = fg;
            bg = bg;
          };
        };

        # Background task list UI
        tasks = {
          border = {fg = border;};
          title = {
            fg = accent;
            bold = true;
          };
          hovered = {
            fg = bg;
            bg = bgAlt;
            bold = true;
          };
        };

        # Help screen
        help = {
          on = {
            fg = accent;
            bold = true;
          };
          run = {fg = info;};
          desc = {fg = fg;};
          hovered = {
            fg = bg;
            bg = bgAlt;
          };
          footer = {fg = border;};
          icon_info = "";
          icon_warn = "";
          icon_error = "";
        };

        # Notifications / toasts
        notify = {
          title_info = {
            fg = info;
            bold = true;
          };
          title_warn = {
            fg = warning;
            bold = true;
          };
          title_error = {
            fg = urgent;
            bold = true;
          };
        };

        # File type colouring (inherits from theme; we just bias some types)
        filetype = {
          rules = [
            # Directories
            {
              name = "*/";
              fg = secondary;
            }

            # Media
            {
              mime = "image/*";
              fg = info;
            }
            {
              mime = "video/*";
              fg = warning;
            }
            {
              mime = "audio/*";
              fg = warning;
            }

            # Archives
            {
              mime = "application/zip";
              fg = info;
            }

            # Empty file
            {
              mime = "inode/empty";
              fg = info;
            }

            # Default
            {
              name = "*";
              fg = fg;
            }
          ];
        };
      };
    };
  };
}
