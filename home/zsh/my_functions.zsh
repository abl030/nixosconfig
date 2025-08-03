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
    local HOST TARGET
    if [[ $# -eq 0 ]]; then
        echo "No arguments provided. Performing full rebuild for current host..."
        HOST=$(hostname)
        TARGET="both"
    elif [[ $# -eq 2 ]]; then
        HOST="$1"
        TARGET="$2"
    else
        echo "Usage: reload              (Full rebuild for current host)" >&2
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
        config | both) # 'both' and 'config' may need sudo
            # Start keep-alive loop only for sudo commands
            while true; do
                sudo -n true
                sleep 60
            done &
            local sudo_keepalive_pid=$!
            trap "kill $sudo_keepalive_pid &> /dev/null" EXIT

            if [[ "$TARGET" == "config" ]]; then
                rebuild_cmd="sudo nixos-rebuild switch --flake '${_RELOAD_FLAKE_PATH}${HOST}'"
            else # both
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
    # << THE FIX IS HERE: Use 'eval' instead of the 'script' wrapper >>
    if eval "$rebuild_cmd"; then
        # Stop keep-alive if it was started
        [[ -n "$sudo_keepalive_pid" ]] && kill $sudo_keepalive_pid &>/dev/null && trap - EXIT

        echo "✅ Rebuild successful."
        if [[ -t 1 ]]; then
            echo "Reloading shell..."
            exec zsh
        fi
    else
        # Stop keep-alive if it was started
        [[ -n "$sudo_keepalive_pid" ]] && kill $sudo_keepalive_pid &>/dev/null && trap - EXIT

        echo "❌ Rebuild failed. Check the output above for errors."
        return 1
    fi
}

# Pulls dotfiles, updates flake, and performs a full system rebuild.
update() {
    # 1. Get the initial sudo password from the user.
    echo "🔑 Checking sudo credentials..."
    sudo -v || return 1

    # 2. Start a background loop to keep the sudo timestamp alive.
    while true; do
        sudo -n true
        sleep 60
    done &
    local sudo_keepalive_pid=$!
    trap "kill $sudo_keepalive_pid &> /dev/null" EXIT

    # 3. Perform the long-running tasks.
    echo "⬇️  Pulling latest dotfiles..."
    if ! pull_dotfiles; then
        echo "❌ Error pulling dotfiles."
        return 1
    fi

    echo "❄️  Updating flake inputs..."
    if ! nix flake update; then
        echo "❌ Error updating flake inputs."
        return 1
    fi

    # 4. The main work is done, stop the keep-alive loop.
    kill $sudo_keepalive_pid &>/dev/null
    trap - EXIT

    # 5. Prepare and execute the rebuild.
    echo "🛠️  Preparing to rebuild system..."
    local HOST=$(hostname)
    local rebuild_cmd="sudo nixos-rebuild switch --flake '${_RELOAD_FLAKE_PATH}${HOST}' && home-manager switch --flake '${_RELOAD_FLAKE_PATH}${HOST}'"

    echo "🚀 Executing full system update and rebuild..."
    # << THE FIX IS HERE: Use 'eval' instead of the 'script' wrapper >>
    if eval "$rebuild_cmd"; then
        echo "✅ Update and rebuild successful!"
        if [[ -t 1 ]]; then
            echo "Reloading shell..."
            exec zsh
        fi
    else
        echo "❌ Rebuild failed. Check the output above for errors."
        return 1
    fi
}

# Tees piped input to the screen and to the clipboard.
teec() {
    # This command works identically in Zsh as it does in Fish.
    tee /dev/tty | xclip -selection clipboard -target UTF8_STRING
}

# Copies file/directory context to the clipboard. Supports piped input.
copyc() {
    # Handle piped input first.
    # '[[ ! -t 0 ]]' is the Zsh equivalent of 'not isatty stdin'.
    if [[ ! -t 0 ]]; then
        xclip -selection clipboard -target UTF8_STRING
        echo "Piped input copied to clipboard." >&2
        return 0
    fi

    # Set target to the first argument ($1), or default to "." if it's not provided.
    # This is a common and clean Zsh/Bash idiom.
    local target="${1:-.}"

    if [[ ! -e "$target" ]]; then
        echo "Error: '$target' does not exist." >&2
        return 1
    fi

    # Handle directories
    if [[ -d "$target" ]]; then
        # We use a subshell '( ... )' so that 'cd' is temporary. No need for pushd/popd.
        (
            cd "$target" || return 1
            command ls -la .
            echo
            echo "FILE CONTENTS"
            for f in *; do
                if [[ -f "$f" ]]; then
                    # Check if file is text (-I) and non-empty (.), quietly (-q).
                    if grep -Iq . "$f"; then
                        echo "===== $f ====="
                        cat "$f"
                        echo
                    else
                        echo "===== $f (SKIPPED BINARY) =====" >&2
                    fi
                fi
            done
        ) | xclip -selection clipboard -target UTF8_STRING

        echo "Directory '$target' context copied to clipboard." >&2
        return 0
    fi

    # Handle regular files
    if [[ -f "$target" ]]; then
        # Use command grouping '{...}' to pipe the output of several commands.
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

# Recursively copies file/directory context to the clipboard.
copycr() {
    # Handle piped input first.
    if [[ ! -t 0 ]]; then
        xclip -selection clipboard -target UTF8_STRING
        echo "Piped input copied to clipboard." >&2
        return 0
    fi

    local target="${1:-.}"

    if [[ ! -e "$target" ]]; then
        echo "Error: '$target' does not exist." >&2
        return 1
    fi

    # Handle single files directly
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

    # Handle directories recursively
    if [[ -d "$target" ]]; then
        ( # Use a subshell to make the 'cd' temporary
            cd "$target" || return 1
            command ls -laR .
            echo
            echo "FILE CONTENTS"
            # The `find` command is the same, but the command substitution syntax
            # changes from `(find ...)` in Fish to `$(find ...)` in Zsh.
            for f in $(find . \( -name .git -o -name result -o -name node_modules \) -prune -o -type f -print); do
                if grep -Iq . "$f"; then
                    echo "===== $f ====="
                    cat "$f"
                    echo
                else
                    echo "===== $f (SKIPPED BINARY) =====" >&2
                fi
            done
        ) | xclip -selection clipboard -target UTF8_STRING

        echo "Recursive directory '$target' context copied to clipboard." >&2
        return 0
    fi

    echo "Error: '$target' is not a regular file or directory." >&2
    return 1
}

# # Downloads YouTube subtitles and pipes them to the screen and clipboard.
# ytsum() {
#     # 1. Check for arguments. In Zsh, $# is the argument count.
#     if [[ $# -eq 0 ]]; then
#         echo "Usage: ytsum <YouTube URL>" >&2
#         return 1
#     fi
#
#     # 2. Create a unique temporary directory.
#     # The 'mktemp' command is identical. We use a local variable.
#     local tmpdir
#     tmpdir=$(mktemp -d -t ytsum-XXXXXX)
#
#     # 3. THE IDIOMATIC ZSH IMPROVEMENT: Set a trap for cleanup.
#     # This command will run AUTOMATICALLY when the function exits, whether it's
#     # due to success, failure (return 1), or user interruption (Ctrl+C).
#     # This is more robust than manually calling 'rm' on every exit path.
#     trap 'rm -rf "$tmpdir"' EXIT
#
#     # 4. Download the subtitle file into our unique directory.
#     # We use '$1' for the first argument and check the command's success directly.
#     if ! yt-dlp --write-auto-sub --skip-download --sub-format "vtt" --output "$tmpdir/%(title)s.%(ext)s" "$1"; then
#         echo "yt-dlp failed to download subtitles." >&2
#         return 1 # The trap will execute and clean up the directory.
#     fi
#
#     # 5. Find the subtitle file. '$(...)' is Zsh's command substitution.
#     # This is reliable because it's the only .vtt file in our unique directory.
#     local subfile
#     subfile=$(find "$tmpdir" -type f -iname "*.vtt" -print -quit)
#
#     if [[ -f "$subfile" ]]; then
#         # 6. The main logic: cat the file to our existing 'teec' function.
#         cat "$subfile" | teec
#         # The function will now exit successfully, and the trap will clean up.
#     else
#         echo "Error: Subtitle file was not created by yt-dlp." >&2
#         return 1 # The trap will execute and clean up the directory.
#     fi
# }

# Downloads YouTube subtitles and pipes them to the screen and clipboard.
ytsum() {
    # 1. Check for arguments.
    if [[ $# -eq 0 ]]; then
        echo "Usage: ytsum <YouTube URL>" >&2
        return 1
    fi

    # 2. Create a unique temporary directory.
    local tmpdir
    tmpdir=$(mktemp -d -t ytsum-XXXXXX)

    # 3. Set a trap for cleanup.
    trap 'rm -rf "$tmpdir"' EXIT

    echo "ℹ️ Using patched yt-dlp to avoid impersonation errors..."

    # 4. Download the subtitle file using the patched command directly.
    # The '--' separates nix run options from yt-dlp options.
    # This is THE FIX: call the command directly instead of through a variable.
    if ! nix run github:nmouha/nixpkgs/patch-1#yt-dlp -- \
        --write-auto-sub \
        --skip-download \
        --sub-format "vtt" \
        --output "$tmpdir/%(title)s.%(ext)s" \
        "$1"; then
        echo "❌ yt-dlp failed to download subtitles." >&2
        return 1
    fi

    # 5. Find the subtitle file.
    local subfile
    subfile=$(find "$tmpdir" -type f -iname "*.vtt" -print -quit)

    if [[ -f "$subfile" ]]; then
        # 6. The main logic: cat the file to our existing 'teec' function.
        cat "$subfile" | teec
    else
        echo "❌ Error: Subtitle file was not created by yt-dlp." >&2
        return 1
    fi
}
