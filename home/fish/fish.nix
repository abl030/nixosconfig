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

    # Aliases are moved here
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

    # Functions are moved here
    # The body of the function (between 'function name ...' and 'end') goes here.
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
    };

    # shellInit is now empty as its contents have been moved to more specific options.
    # If you had any other arbitrary shell script to run at init, it would go here.
    shellInit = ''
    '';

    # If you had keybindings like the double-tab or Shift+L:
    # interactiveShellInit = ''
    #   # Example: if __fish_custom_tab_handler is also defined in programs.fish.functions
    #   # bind \t __fish_custom_tab_handler
    #   # bind L 'commandline -f autosuggest-accept'
    # '';

  }; # End of programs.fish

  programs.zoxide = {
    enable = true;
    enableFishIntegration = true; # This provides 'z' and 'zi'
  };

  # If you use starship, this is the Fish-specific way:
  # programs.starship = {
  #   enable = true;
  #   enableFishIntegration = true;
  # };

}
