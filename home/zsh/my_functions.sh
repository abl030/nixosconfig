# This file is managed by Nix but edited directly for syntax highlighting.
# Remember to keep all these functions compliant with BASH.
# It will be imported directly into our bash config as well.
# ──────────────────────────────────────────────────────────────────────────────
#  Pull dotfiles from Git and rebuild helpers
# ──────────────────────────────────────────────────────────────────────────────
pull_dotfiles() {
    cd ~/nixosconfig || return 1
    if ! git pull origin; then
        echo "Error: Git pull failed. Please resolve conflicts."
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
#  Quick “edit” helper – open common configs with one command
# ──────────────────────────────────────────────────────────────────────────────
edit() {
    if [[ -z "$1" ]]; then
        echo "Usage: edit <zsh|caddy|diary|cullen|nvim|nix>"
        return 1
    fi

    case "$1" in
        zsh) nvim ~/nixosconfig/home/zsh/.zshrc2 ;;
        caddy) nvim ~/DotFiles/Caddy/Caddyfile ;;
        diary) cd /mnt/data/Life/Zet/Projects/Diary && nvim ;;
        nvim) nvim ~/nixosconfig/home/nvim/options.lua ;;
        nix) cd ~/nixosconfig && nvim ;;
        *)
            echo "Unknown argument: $1"
            return 1
            ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────────────
#  Rebuilds and switches to a Nix flake configuration
# ──────────────────────────────────────────────────────────────────────────────
reload() {
    local HOST TARGET

    if [[ $# -eq 0 ]]; then
        echo "No arguments provided. Performing full rebuild for current host..."
        HOST=$(hostname)
        TARGET="both"
    elif [[ $# -eq 2 ]]; then
        HOST="$1"
        TARGET="$2"
    else
        echo "Usage: reload                 (full rebuild for current host)" >&2
        echo "   or: reload <hostname> <target>" >&2
        echo "Targets: home, config, wsl" >&2
        return 1
    fi

    sudo -v || return 1

    local rebuild_cmd
    case "$TARGET" in
        home)
            rebuild_cmd="home-manager switch --flake '${_RELOAD_FLAKE_PATH}${HOST}'"
            ;;
        config | both)
            while true; do
                sudo -n true
                sleep 60
            done &
            local sudo_keepalive_pid=$!
            trap "kill $sudo_keepalive_pid &>/dev/null" EXIT
            if [[ "$TARGET" == "config" ]]; then
                rebuild_cmd="sudo nixos-rebuild switch --flake '${_RELOAD_FLAKE_PATH}${HOST}'"
            else
                rebuild_cmd="sudo nixos-rebuild switch --flake '${_RELOAD_FLAKE_PATH}${HOST}' && home-manager switch --flake '${_RELOAD_FLAKE_PATH}${HOST}'"
            fi
            ;;
        wsl)
            rebuild_cmd="sudo nixos-rebuild switch --flake '${_RELOAD_FLAKE_PATH}${HOST}' --impure && home-manager switch --flake '${_RELOAD_FLAKE_PATH}${HOST}'"
            ;;
        *)
            echo "Error: Unknown target '$TARGET'. Use 'home', 'config', or 'wsl'." >&2
            return 1
            ;;
    esac

    echo "🚀 Executing: $rebuild_cmd"
    if eval "$rebuild_cmd"; then
        [[ -n ${sudo_keepalive_pid-} ]] && kill "$sudo_keepalive_pid" &>/dev/null
        trap - EXIT
        echo "✅ Rebuild successful."
        [[ -t 1 ]] && exec "$SHELL" -l
    else
        [[ -n ${sudo_keepalive_pid-} ]] && kill "$sudo_keepalive_pid" &>/dev/null
        trap - EXIT
        echo "❌ Rebuild failed."
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
#  Pulls dotfiles, updates flake inputs, *then* performs full system rebuild
#  Usage: update [hostname]   # defaults to $(hostname)
# ──────────────────────────────────────────────────────────────────────────────
update() {
    local HOST=${1:-$(hostname)}

    echo "🔑 Checking sudo credentials..."
    sudo -v || return 1
    while true; do
        sudo -n true
        sleep 60
    done &
    local sudo_keepalive_pid=$!
    trap "kill $sudo_keepalive_pid &>/dev/null" EXIT

    echo "⬇️  Pulling latest dotfiles..."
    pull_dotfiles || {
        echo "❌ git pull failed."
        return 1
    }

    echo "❄️  Updating flake inputs..."
    nix flake update || {
        echo "❌ nix flake update failed."
        return 1
    }

    # Build flake reference safely
    local FLAKE_BASE=${_RELOAD_FLAKE_PATH:-"$HOME/nixosconfig"}
    FLAKE_BASE=${FLAKE_BASE%#} # strip trailing '#'
    local FLAKE_REF="${FLAKE_BASE}#${HOST}"

    echo "🛠️  Rebuilding for $FLAKE_REF ..."
    if sudo nixos-rebuild switch --flake "$FLAKE_REF" &&
    home-manager switch --flake "$FLAKE_REF"; then
        echo "✅ Update and rebuild successful!"
        [[ -t 1 ]] && exec "$SHELL" -l
    else
        echo "❌ Rebuild failed."
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
#  Tees piped input to the screen *and* to the clipboard
# ──────────────────────────────────────────────────────────────────────────────
teec() {
    tee /dev/tty | xclip -selection clipboard -target UTF8_STRING
}

# ──────────────────────────────────────────────────────────────────────────────
#  Copies file/directory context to the clipboard (non-recursive)
# ──────────────────────────────────────────────────────────────────────────────
copyc() {
    if [[ ! -t 0 ]]; then
        xclip -selection clipboard -target UTF8_STRING
        echo "Piped input copied to clipboard." >&2
        return 0
    fi

    local target="${1:-.}"
    [[ ! -e "$target" ]] && {
        echo "Error: '$target' does not exist." >&2
        return 1
    }

    if [[ -d "$target" ]]; then
        (
            cd "$target" || return 1
            command ls -la .
            echo
            echo "FILE CONTENTS"
            for f in *; do
                [[ -f "$f" ]] || continue
                if grep -Iq . "$f"; then
                    echo "===== $f ====="
                    cat "$f"
                    echo
                else
                    echo "===== $f (SKIPPED BINARY) =====" >&2
                fi
            done
        ) | xclip -selection clipboard -target UTF8_STRING
        echo "Directory '$target' context copied to clipboard." >&2
        return 0
    fi

    if [[ -f "$target" ]]; then
        {
            command ls -l "$target"
            echo
            echo "FILE CONTENTS"
            cat "$target"
            echo
        } | xclip -selection clipboard -target UTF8_STRING
        echo "File '$target' context copied to clipboard." >&2
        return 0
    fi

    echo "Error: '$target' is not a regular file or directory." >&2
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
#  Downloads YouTube subtitles and pipes them to the screen and clipboard
# ──────────────────────────────────────────────────────────────────────────────
ytsum() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: ytsum <YouTube URL>" >&2
        return 1
    fi

    local tmpdir
    tmpdir=$(mktemp -d -t ytsum-XXXXXX)
    trap 'rm -rf "$tmpdir"' EXIT

    echo "ℹ️ Using patched yt-dlp to avoid impersonation errors..."
    if ! nix run github:nmouha/nixpkgs/patch-1#yt-dlp -- \
        --write-auto-sub \
        --skip-download \
        --sub-format "vtt" \
        --output "$tmpdir/%(title)s.%(ext)s" \
        "$1"; then
        echo "❌ yt-dlp failed to download subtitles." >&2
        return 1
    fi

    local subfile
    subfile=$(find "$tmpdir" -type f -iname "*.vtt" -print -quit)
    [[ -f "$subfile" ]] && cat "$subfile" | teec || {
        echo "❌ Subtitle file not created." >&2
        return 1
    }
}
