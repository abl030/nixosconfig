{ config, pkgs, lib, ... }:

{
  programs.starship.enable = true;

  programs.starship.settings = {
    # --- Main Prompt Format ---
    # Removed the initial static icons.
    # Added $username and $hostname at the beginning.
    # Adjusted the first separator's colors.
    format =
      "$username" + # Display username module
      "$hostname" + # Display hostname module
      # Separator: FG matches hostname BG, BG matches directory BG
      "[](bg:#769ff0 fg:#a3aed2)" +
      "$directory" +
      "[](fg:#769ff0 bg:#394260)" +
      "$git_branch" +
      "$git_status" +
      "[](fg:#394260 bg:#212736)" +
      "$nodejs" +
      "$rust" +
      "$golang" +
      "$php" +
      "[](fg:#212736 bg:#1d2230)" +
      "$time" +
      "[ ](fg:#1d2230)" +
      "\n$character"; # The prompt character itself on a new line

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
      style = "fg:#e3e5e5 bg:#769ff0"; # Light text on darker blue bg
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
      modified = "[++($count)](red)"; # Or "[~($count)](yellow)" etc.
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
} # End main configuration set
