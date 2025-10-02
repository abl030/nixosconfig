# Correct the malformed function signature which was declared twice.
# A Nix module should only have one set of arguments.
{pkgs, ...}: let
  # Base Starship settings (zsh/default). We’ll generate fish/bash variants
  # from this single source of truth to avoid config drift.
  # NOTE: The original content below is your existing settings block verbatim,
  # moved into baseStarshipSettingsReal so we can reuse it for fish/bash.
  baseStarshipSettingsReal = {
    # Enable + configure Starship (default = zsh keeps your current blue theme)
    programs = {
      starship = {
        enable = true;
        enableFishIntegration = true;
        # programs.starship.enableZshIntegration = true;
        settings = {
          # --- Main Prompt Format ---
          # Removed the initial static icons.
          # Added $username and
          # Display username module
          # Display hostname module

          # Separator: FG matches hostname BG, BG matches directory BG
          format = ''
            $username$hostname[](bg:#769ff0 fg:#394260)$directory[](fg:#769ff0 bg:#394260)$all[](fg:#212736 bg:#1d2230)$time[ ](fg:#1d2230)
            $character
          '';

          # --- Module Configurations ---
          # NEW: Username Module Configuration
          username = {
            # Style depends on whether you are root or regular user
            style_user = "bg:#a3aed2 fg:#090c0c"; # Dark text on light blue bg
            style_root = "bg:#a3aed2 fg:#ff0000"; # Red text for root
            format = "[ $user ]($style)"; # Format: [ user ]
            disabled = false; # Ensure it's not disabled
            show_always = true; # IMPORTANT: Show even if default user/not SSH
          };

          # NEW: Hostname Module Configuration
          hostname = {
            style = "bg:#a3aed2 fg:#090c0c"; # Match username style for a cohesive block
            format = "[@$hostname]($style)"; # Format: [@hostname]
            # Optional: Shorten FQDN, e.g. machine.domain.com -> machine
            # trim_at = ".";
            ssh_only = false; # IMPORTANT: Show even if not SSH session
            disabled = false; # Ensure it's not disabled
          };

          directory = {
            style = "fg:#394260 bg:#769ff0"; # Light text on darker blue bg
            format = "[ $path ]($style)";
            truncation_length = 3;
            truncation_symbol = "…/";
            substitutions = {
              "Documents" = "󰈙 ";
              "Downloads" = " ";
              "Music" = " ";
              "Pictures" = " ";
            };
          };

          git_branch = {
            symbol = "";
            style = "bg:#394260";
            format = "[[ $symbol $branch ](fg:#769ff0 bg:#394260)]($style)";
          };

          nodejs = {
            symbol = "";
            style = "bg:#212736";
            format = "[[ $symbol ($version) ](fg:#769ff0 bg:#212736)]($style)";
          };

          rust = {
            symbol = "";
            style = "bg:#212736";
            format = "[[ $symbol ($version) ](fg:#769ff0 bg:#212736)]($style)";
          };

          golang = {
            symbol = "";
            style = "bg:#212736";
            format = "[[ $symbol ($version) ](fg:#769ff0 bg:#212736)]($style)";
          };

          php = {
            symbol = "";
            style = "bg:#212736";
            format = "[[ $symbol ($version) ](fg:#769ff0 bg:#212736)]($style)";
          };

          time = {
            disabled = false;
            time_format = "%R"; # Hour:Minute Format
            style = "bg:#1d2230";
            format = "[[  $time ](fg:#a0a9cb bg:#1d2230)]($style)";
          };

          git_status = {
            staged = "[++($count)](green)";
            modified = "[!($count)](red)"; # Or "[~($count)](yellow)" etc.
            untracked = "🤷";
            conflicted = "🏳";
            renamed = "»";
            deleted = "✘";
            stashed = "$";
            format = ''([$all_status$ahead_behind]($style))'';
            disabled = false;
          }; # End git_status set

          # The $character module is implicitly configured by Starship's defaults
          # (e.g. ❯ for success, ✘ for error) unless you add a 'character = { ... };' block.
        }; # End programs.starship.settings set
      };
    };
  };

  # Minimal-Change generator:
  # We only replace the accent hex "769ff0" in your format string and
  # update the directory bg color. All other settings stay identical.
  mkSettingsWithAccent = accentHex: let
    base = baseStarshipSettingsReal.programs.starship.settings;
    replacedFormat =
      builtins.replaceStrings ["769ff0"] [accentHex] base.format;
    newDirectory = base.directory // {style = "fg:#394260 bg:#${accentHex}";};
  in
    base
    // {
      format = replacedFormat;
      directory = newDirectory;
    };

  # Accent colors
  fishAccent = "f7768e"; # red
  bashAccent = "9ece6a"; # green

  # Derived per-shell settings
  fishSettings = mkSettingsWithAccent fishAccent;
  bashSettings = mkSettingsWithAccent bashAccent;

  toml = pkgs.formats.toml {};
in {
  # Group all starship settings into a single attribute set to avoid re-defining the programs key.
  # Reuse the already-complete subtree to avoid redundant assignments (fixes Statix W04).
  programs.starship = baseStarshipSettingsReal.programs.starship;

  # Declaratively materialize per-shell TOMLs (generated from the same base)
  home.file.".config/starship-fish.toml".source =
    toml.generate "starship-fish.toml" fishSettings;

  home.file.".config/starship-bash.toml".source =
    toml.generate "starship-bash.toml" bashSettings;
}
