# This file is managed by Nix but edited directly for syntax highlighting.

# Pull dotfiles and rebuild
pull_dotfiles() {
    # Change to the configuration directory or exit if it fails
    cd ~/nixosconfig || return 1

    # Try to pull from the remote
    if ! git pull origin; then
        echo "Error: Git pull failed. Please resolve conflicts."
        return 1
    fi
}

# Edit configuration files
edit() {
    if [[ -z "$1" ]]; then
        echo "Usage: edit <zsh|caddy|diary|cullen|nvim|nix>"
        return 1
    fi

    case "$1" in
        zsh)
            nvim ~/nixosconfig/home/zsh/.zshrc2
            ;;
        caddy)
            nvim ~/DotFiles/Caddy/Caddyfile
            ;;
        diary)
            cd /mnt/data/Life/Zet/Projects/Diary && nvim
            ;;
        nvim)
            nvim ~/nixosconfig/home/nvim/options.lua
            ;;
        nix)
            cd ~/nixosconfig && nvim
            ;;
        *)
            echo "Unknown argument: $1"
            return 1
            ;;
    esac
}

# Rebuilds and switches to a Nix flake configuration
reload() {
    # << CHANGED: Argument handling completely revised >>
    local HOST TARGET
    local _RELOAD_FLAKE_PATH="/home/abl030/nixosconfig/#"
    if [[ $# -eq 0 ]]; then
        # Default behavior: full rebuild on the current host.
        echo "No arguments provided. Performing full rebuild for current host..."
        HOST=$(hostname)
        TARGET="both" # Use a special target for the full rebuild
    elif [[ $# -eq 2 ]]; then
        # Standard behavior: specific host and target.
        HOST="$1"
        TARGET="$2"
    else
        # Invalid number of arguments.
        echo "Usage: reload              (Full rebuild for current host)" >&2
        echo "   or: reload <hostname> <target>" >&2
        echo "Targets: home, config, wsl" >&2
        return 1
    fi

    # Refresh Sudo Timestamp
    sudo -v || return 1

    # Build the command. Note: We now use $_RELOAD_FLAKE_PATH, which was set in .zshrc
    local rebuild_cmd
    case "$TARGET" in
        home)
            rebuild_cmd="home-manager switch --flake '${_RELOAD_FLAKE_PATH}${HOST}'"
            ;;
        config)
            rebuild_cmd="sudo nixos-rebuild switch --flake '${_RELOAD_FLAKE_PATH}${HOST}'"
            ;;
        wsl)
            rebuild_cmd="sudo nixos-rebuild switch --flake '${_RELOAD_FLAKE_PATH}${HOST}' --impure && home-manager switch --flake '${_RELOAD_FLAKE_PATH}${HOST}'"
            ;;
        both) # << CHANGED: This case handles the default full rebuild
            rebuild_cmd="sudo nixos-rebuild switch --flake '${_RELOAD_FLAKE_PATH}${HOST}' && home-manager switch --flake '${_RELOAD_FLAKE_PATH}${HOST}'"
            ;;
        *)
            echo "Error: Unknown target '$TARGET'. Use 'home', 'config', or 'wsl'." >&2
            return 1
            ;;
    esac

    # Execute the Rebuild
    echo "🚀 Executing: $rebuild_cmd"
    if script -q -e -c "$rebuild_cmd" /dev/null; then
        echo "✅ Rebuild successful."
        if [[ -t 1 ]]; then
            echo "Reloading shell..."
            exec zsh
        fi
    else
        echo "❌ Rebuild failed. Check the output above for errors."
        return 1
    fi
}
