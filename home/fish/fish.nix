# ~/nixosconfig/fish.nix (or wherever this file is located)
{ config, pkgs, ... }:

let
  scriptsPath = "${config.home.homeDirectory}/nixosconfig/scripts";
in
{
  imports = [
    ../zsh/starship.nix
  ];

  programs.fish = {
    enable = true;

    shellAliases = {
      "epi!" = "ssh abl030@caddy 'wakeonlan 18:c0:4d:65:86:e8'"; # Quoted due to '!'
      epi = "wakeonlan 18:c0:4d:65:86:e8";
      cd = "z";
      cdi = "zi";
      restart_bluetooth = "bash ${scriptsPath}/bluetooth_restart.sh";
      tb = "bash ${scriptsPath}/trust_buds.sh";
      cb = "bluetoothctl connect 24:24:B7:58:C6:49";
      dcb = "bluetoothctl disconnect 24:24:B7:58:C6:49";
      ytlisten = "mpv --no-video --ytdl-format=bestaudio --msg-level=ytdl_hook=debug";
      ssh_epi = "epi!; and ssh epi";
      clear_dots = "git stash; and git stash clear";
      clear_flake = "git restore flake.lock && pull_dotfiles";
      lzd = "lazydocker";
      v = "nvim";
      ls = "lsd -A -F -l --group-directories-first --color=always";
    };

    functions = {
      fish_greeting = ""; # Your existing greeting override

      push_dotfiles = ''
        cd ~/nixosconfig/; or return 1
        echo "Enter commit message: "
        read commit_message
        git add --all
        git commit -m "$commit_message"
        git push origin
      '';

      pull_dotfiles = ''
        cd ~/nixosconfig/; or return 1
        git pull origin
        if test $status -ne 0
          echo "Error: Git pull failed. Please resolve conflicts."
          return 1
        end
      '';

      edit = ''
        switch "$argv[1]"
          case zsh
            nvim ~/nixosconfig/home/zsh/.zshrc2
          case caddy
            nvim ~/DotFiles/Caddy/Caddyfile
          case diary
            cd /mnt/data/Life/Zet/Projects/Diary; and nvim
          case cullen
            cd /mnt/data/Life/Zet/Cullen; and nvim
          case nvim
            nvim ~/nixosconfig/home/nvim/options.lua
          case nix
            cd ~/nixosconfig/; and nvim
          case '*'
            echo "Unknown argument: $argv[1]"
        end
      '';

      reload = ''
        set -l HOST "$argv[1]"
        set -l TARGET "$argv[2]"
        sudo -v
        if test $status -ne 0; return 1; end
        pull_dotfiles
        if test $status -ne 0; return 1; end
        nix flake update
        set -l flake_path_prefix "${config.home.homeDirectory}/nixosconfig#"
        if test "$TARGET" = "home"
          home-manager switch --flake "$flake_path_prefix$HOST"
          if test $status -eq 0; exec fish; else; return 1; end
        else if test "$TARGET" = "wsl"
          sudo nixos-rebuild switch --flake "$flake_path_prefix$HOST" --impure
          if test $status -eq 0
            home-manager switch --flake "$flake_path_prefix$HOST"
            if test $status -eq 0; exec fish; else; return 1; end
          else
            return 1
          end
        else # System rebuild
          sudo nixos-rebuild switch --flake "$flake_path_prefix$HOST"
          if test $status -eq 0
            home-manager switch --flake "$flake_path_prefix$HOST"
            if test $status -eq 0; exec fish; else; return 1; end
          else
            return 1
          end
        end
      '';


      copy-directory = ''
        # In fish, use 'begin' and 'end' to group commands for a pipe.
        begin
          # 1. List the directory contents
          command ls -la
          echo
          echo "========================================"
          echo "           FILE CONTENTS"
          echo "========================================"
          echo

          # 2. Loop through and concatenate file contents
          for f in *
            # Only process regular files, not directories or symlinks
            if test -f "$f"
              echo "===== $f ====="
              cat "$f"
              echo # Add a blank line for readability
            end
          end
        end | xclip -selection clipboard

        # This confirmation message prints to your terminal, not the clipboard.
        echo "Directory listing and file contents copied to clipboard."
      '';

    };

    shellInit = ''
    '';
  };

  programs.zoxide = {
    enable = true;
    enableFishIntegration = true;
  };
}

