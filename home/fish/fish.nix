# ~/nixosconfig/fish.nix (or wherever this file is located)
{ config, pkgs, ... }:

let
  scriptsPath = "${config.home.homeDirectory}/nixosconfig/scripts";
in
{
  imports = [
    ../zsh/starship.nix
    ../utils/atuin.nix
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
      rb = "bash ${scriptsPath}/repair_buds.sh";
      pb = "bash ${scriptsPath}/pair_buds.sh";
      ytlisten = "mpv --no-video --ytdl-format=bestaudio --msg-level=ytdl_hook=debug";
      ssh_epi = "epi!; and ssh epi";
      clear_dots = "git stash; and git stash clear";
      clear_flake = "git restore flake.lock && pull_dotfiles";
      lzd = "lazydocker";
      v = "nvim";
      ls = "lsd -A -F -l --group-directories-first --color=always";
      lzg = "lazygit";
    };

    functions = {
      fish_greeting = ""; # Your existing greeting override

      push_dotfiles = ''
        cd ~/nixosconfig/; or return 1
        echo "Enter commit message: "
        read commit_message
        git add --all
        git commit -m "''$commit_message"
        git push origin
      '';

      pull_dotfiles = ''
        cd ~/nixosconfig/; or return 1
        git pull origin
        if test ''$status -ne 0
          echo "Error: Git pull failed. Please resolve conflicts."
          return 1
        end
      '';

      edit = ''
        switch "''$argv[1]"
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
            echo "Unknown argument: ''$argv[1]"
        end
      '';

      # Fast reload. Uses `script` to prevent hanging when piped.
      # Note the ''$ escaping for all shell variables to prevent Nix interpolation.
      reload = ''
        set -l HOST "''$argv[1]"
        set -l TARGET "''$argv[2]"
        sudo -v; or return 1

        set -l flake_path_prefix "${config.home.homeDirectory}/nixosconfig#"
        set -l rebuild_cmd ""

        if test "''$TARGET" = "home"
          set rebuild_cmd "home-manager switch --flake ''$flake_path_prefix''$HOST"
        else if test "''$TARGET" = "wsl"
          set rebuild_cmd "sudo nixos-rebuild switch --flake ''$flake_path_prefix''$HOST --impure; and home-manager switch --flake ''$flake_path_prefix''$HOST"
        else # System rebuild
          set rebuild_cmd "sudo nixos-rebuild switch --flake ''$flake_path_prefix''$HOST; and home-manager switch --flake ''$flake_path_prefix''$HOST"
        end

        if script -q -e -c "''$rebuild_cmd" /dev/null
            if isatty stdout; exec fish; end
        else
            return 1
        end
      '';

      # Full update. Uses `script` to prevent hanging when piped.
      update = ''
        set -l HOST "''$argv[1]"
        set -l TARGET "''$argv[2]"
        sudo -v; or return 1

        pull_dotfiles; or return 1
        echo "Updating flake inputs..."
        nix flake update

        set -l flake_path_prefix "${config.home.homeDirectory}/nixosconfig#"
        set -l rebuild_cmd ""

        if test "''$TARGET" = "home"
          set rebuild_cmd "home-manager switch --flake ''$flake_path_prefix''$HOST"
        else if test "''$TARGET" = "wsl"
          set rebuild_cmd "sudo nixos-rebuild switch --flake ''$flake_path_prefix''$HOST --impure; and home-manager switch --flake ''$flake_path_prefix''$HOST"
        else # System rebuild
          set rebuild_cmd "sudo nixos-rebuild switch --flake ''$flake_path_prefix''$HOST; and home-manager switch --flake ''$flake_path_prefix''$HOST"
        end

        if script -q -e -c "''$rebuild_cmd" /dev/null
            if isatty stdout; exec fish; end
        else
            return 1
        end
      '';

      # Combined context-copying function with pipe support.
      copyc = ''
        if not isatty stdin
          cat | xclip -selection clipboard
          echo "Piped input copied to clipboard." >&2
          return 0
        end
        set -l target "''$argv[1]"; if test -z "''$target"; set target "."; end
        if not test -e "''$target"; echo "Error: ' ''$target' does not exist." >&2; return 1; end
        if test -d "''$target"
          pushd "''$target"; or return 1
          begin; command ls -la .; echo; echo "FILE CONTENTS"; for f in *; if test -f "''$f"; echo "===== ''$f ====="; cat "''$f"; echo; end; end; end | xclip -selection clipboard
          popd
          echo "Directory ' ''$target' context copied to clipboard." >&2; return 0
        end
        if test -f "''$target"
          begin; command ls -l "''$target"; echo; echo "FILE CONTENTS"; cat "''$target"; echo; end | xclip -selection clipboard
          echo "File ' ''$target' context copied to clipboard." >&2; return 0
        end
        echo "Error: ' ''$target' is not a regular file or directory." >&2; return 1
      '';

      # Tees piped input to the screen and to the clipboard.
      teec = ''
        # Use 'tee' to send a copy of the input to the terminal screen (/dev/tty).
        # The original stream continues down the pipe to xclip.
        tee /dev/tty | xclip -selection clipboard
      '';

      ytsum = ''
        # Check for arguments
        if test (count $argv) -eq 0
          echo "Usage: ytsum <YouTube URL>" >&2
          return 1
        end

        # Create a unique temporary directory that will be cleaned up automatically.
        # The 'begin...end' block ensures the $tmpdir variable is local to this scope.
        begin
          # Create a new, unique temporary directory for this specific run.
          set -l tmpdir (mktemp -d -t ytsum-XXXXXX)

          # Download the subtitle file into our unique, empty directory.
          yt-dlp --write-auto-sub --skip-download --sub-format "vtt" --output "$tmpdir/%(title)s.%(ext)s" "$argv[1]"
      
          # Check the exit status of yt-dlp.
          if test $status -ne 0
            echo "yt-dlp failed to download subtitles." >&2
            # Clean up the temp directory on failure
            rm -rf "$tmpdir"
            return 1
          end

          # Find the subtitle file. This is now 100% reliable because it's
          # the only .vtt file that can possibly exist in our unique directory.
          set -l subfile (find "$tmpdir" -type f -iname "*.vtt" -print -quit)

          if test -f "$subfile"
            # The main logic: cat the file to teec
            cat "$subfile" | teec
          else
            echo "Error: Subtitle file was not created by yt-dlp." >&2
            # Clean up the temp directory on failure
            rm -rf "$tmpdir"
            return 1
          end

          # Clean up the temporary directory after success.
          rm -rf "$tmpdir"
        end
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
