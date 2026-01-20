_: {
  programs.starship = {
    enable = true;
    enableFishIntegration = true;
    settings = {
      # --- Main Prompt Format ---
      # Separator: FG matches hostname BG, BG matches directory BG
      format = ''
        $username$hostname[](bg:#769ff0 fg:#394260)$directory[](fg:#769ff0 bg:#394260)$all[](fg:#212736 bg:#1d2230)$time[ ](fg:#1d2230)
        $character
      '';

      # --- Module Configurations ---
      username = {
        # Style depends on whether you are root or regular user
        style_user = "bg:#a3aed2 fg:#090c0c"; # Dark text on light blue bg
        style_root = "bg:#a3aed2 fg:#ff0000"; # Red text for root
        format = "[ $user ]($style)"; # Format: [ user ]
        disabled = false; # Ensure it's not disabled
        show_always = true; # IMPORTANT: Show even if default user/not SSH
      };

      hostname = {
        style = "bg:#a3aed2 fg:#090c0c"; # Match username style for a cohesive block
        format = "[@$hostname]($style)"; # Format: [@hostname]
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
      };
    };
  };
}
