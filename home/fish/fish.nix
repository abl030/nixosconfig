{ config, pkgs, ... }:
let
  # Your scripts directory, adjust if it's different
  # This assumes your flake root is ~/nixosconfig and this home.nix is relative to it
  # Or, if your flake exposes scripts:
  # config.home.homeDirectory + "/nixosconfig/scripts"
  # For simplicity, assuming absolute path or a well-known relative one for now
  scriptsPath = "${config.home.homeDirectory}/nixosconfig/scripts";
in
{
  imports = [
    ../zsh/starship.nix
  ];

  programs.fish = {
    enable = true;
    functions = {
      fish_greeting = ""; # An empty string for the function body means "do nothing"
    };
    shellInit = ''  
      # Aliases (kept as you had them)
      alias epi! "ssh abl030@caddy 'wakeonlan 18:c0:4d:65:86:e8'"
      # 'cd' and 'cdi' will be handled by zoxide if enableFishIntegration = true
      # alias cd='z'
      # alias cdi='zi'
      alias restart_bluetooth "bash ${scriptsPath}/bluetooth_restart.sh"
      alias tb "bash ${scriptsPath}/trust_buds.sh"
      alias cb "bluetoothctl connect 24:24:B7:58:C6:49"
      alias dcb "bluetoothctl disconnect 24:24:B7:58:C6:49"
      alias ytlisten 'mpv --no-video --ytdl-format=bestaudio --msg-level=ytdl_hook=debug'
      alias ssh_epi 'epi!; and ssh epi'
      alias clear_dots 'git stash; and git stash clear'
      alias lzd 'lazydocker'
      alias v 'nvim'
      alias ls 'lsd -A -F -l --group-directories-first --color=always'

      # --- Simplified Functions ---

      function push_dotfiles
        cd ~/nixosconfig/; or return 1 # Zsh's || return is 'or return 1' in Fish for functions
        echo "Enter commit message: "
        read commit_message # Fish's read is simpler, -P for prompt if needed but echo works
        git add --all
        git commit -m "$commit_message"
        git push origin
      end

      function pull_dotfiles
        cd ~/nixosconfig/; or return 1
        git pull origin
        if test $status -ne 0 # Zsh's if [ $? -ne 0 ]
          echo "Error: Git pull failed. Please resolve conflicts."
          return 1
        end
      end

      function edit
        switch "$argv[1]" # Zsh's case $1 in
          case zsh # Using your original path here
            nvim ~/nixosconfig/home/zsh/.zshrc2
          case caddy
            nvim ~/DotFiles/Caddy/Caddyfile
          case diary
            cd /mnt/data/Life/Zet/Projects/Diary; and nvim
          case cullen # Added this back from your original zshrc
            cd /mnt/data/Life/Zet/Cullen; and nvim
          case nvim
            nvim ~/nixosconfig/home/nvim/options.lua
          case nix
            cd ~/nixosconfig/; and nvim
          case '*' # Zsh's *)
            echo "Unknown argument: $argv[1]"
            # No explicit return needed here, function will end
        end
      end

      function reload
        set -l HOST "$argv[1]"
        set -l TARGET "$argv[2]"

        # Original Zsh had sudo -v upfront
        sudo -v
        if test $status -ne 0; return 1; end # Exit if sudo -v fails

        # Original Zsh: pull_dotfiles || return
        pull_dotfiles
        if test $status -ne 0; return 1; end

        # Original Zsh: nix flake update (no error check, but good practice to have one)
        nix flake update # Assuming flake path is handled by current dir or Nix defaults
        # if test $status -ne 0; echo "nix flake update failed"; return 1; end # Optional stricter check

        set -l flake_path_prefix "${config.home.homeDirectory}/nixosconfig#" # Common prefix

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
        else # Original Zsh 'else' case for system rebuild
          sudo nixos-rebuild switch --flake "$flake_path_prefix$HOST"
          if test $status -eq 0
            home-manager switch --flake "$flake_path_prefix$HOST"
            if test $status -eq 0; exec fish; else; return 1; end
          else
            return 1
          end
        end
        end



    '';

  };

  programs.zoxide = {
    enable = true;
    enableFishIntegration = true;
  };

}
