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
#  CLIPBOARD SHIM - Makes 'xclip' calls work over SSH (OSC 52) and Wayland
# ──────────────────────────────────────────────────────────────────────────────
xclip() {
    # If standard input is a pipe, read it; otherwise rely on args (though xclip usually reads stdin)
    local input
    # Check if data is being piped in
    if [[ ! -t 0 ]]; then
        input=$(cat)
    else
        # If running interactively without input, just return (or handle args if needed)
        return 0
    fi

    if [[ -n "$SSH_CONNECTION" ]]; then
        # OSC 52 Copy for Ghostty / Windows Terminal / iTerm
        local b64data=$(echo -n "$input" | base64 | tr -d '\n')
        printf "\033]52;c;%s\a" "$b64data"
    elif [[ -n "$WAYLAND_DISPLAY" ]]; then
        # Wayland Local
        echo -n "$input" | wl-copy
    else
        # Fallback to real xclip binary
        # We assume xclip is in the path, possibly via Nix
        if command -v /usr/bin/xclip >/dev/null; then
            echo -n "$input" | /usr/bin/xclip "$@"
        elif command -v xclip >/dev/null; then
            echo -n "$input" | command xclip "$@"
        else
            echo "Error: xclip binary not found" >&2
            return 1
        fi
    fi
}

dc() {
    local uid keyfile tmp_key sshkey rc age_key
    uid="$(id -u)"

    # If caller already exported a SOPS env var, respect it.
    if [[ -n "${SOPS_AGE_KEY_FILE:-}" || -n "${SOPS_AGE_SSH_PRIVATE_KEY_FILE:-}" || -n "${SOPS_AGE_KEY:-}" ]]; then
        EDITOR=nvim VISUAL=nvim sops "$@"
        return
    fi

    # Helper: run sops with our normal editor
    _dc_run_sops() {
        EDITOR=nvim VISUAL=nvim sops "$@"
    }

    # Prerequisite check
    if ! command -v ssh-to-age >/dev/null 2>&1; then
        echo "❌ Error: 'ssh-to-age' is not installed. Please install it to decrypt secrets."
        return 1
    fi

    # 1) AGE KEY FILES (SOPS_AGE_KEY_FILE)
    #    Used by sops-nix system module (usually derived from Host Key)
    for keyfile in "/root/.config/sops/age/keys.txt" "/var/lib/sops-nix/key.txt"; do
        if sudo test -r "$keyfile" 2>/dev/null; then
            if [[ "$uid" -eq 0 ]]; then
                SOPS_AGE_KEY_FILE="$keyfile" _dc_run_sops "$@"
            else
                tmp_key="$(mktemp -t dc-sops-rootkey-XXXXXX.age)"
                sudo cat "$keyfile" >"$tmp_key"
                chmod 600 "$tmp_key"
                SOPS_AGE_KEY_FILE="$tmp_key" _dc_run_sops "$@"
                rc=$?
                rm -f "$tmp_key"
                return "$rc"
            fi
            return
        fi
    done

    # 2) HOST SSH KEY (/etc/ssh/ssh_host_ed25519_key)
    #    Convert Host SSH Key -> Age Key on the fly
    if sudo test -r /etc/ssh/ssh_host_ed25519_key 2>/dev/null; then
        # We capture the output of ssh-to-age running as root
        if age_key=$(sudo ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key 2>/dev/null); then
            # Pass via env var (secure enough for local interactive use)
            SOPS_AGE_KEY="$age_key" _dc_run_sops "$@"
            return
        fi
    fi

    # 3) USER SSH KEY (~/.ssh/id_ed25519)
    #    Convert User SSH Key -> Age Key on the fly (SSH Nirvana method)
    sshkey="$HOME/.ssh/id_ed25519"
    if [[ -r "$sshkey" ]]; then
        if age_key=$(ssh-to-age -private-key -i "$sshkey" 2>/dev/null); then
            SOPS_AGE_KEY="$age_key" _dc_run_sops "$@"
            return
        fi
    fi

    echo "❌ No valid keys found for decryption."
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
#  Quick “edit” helper – open common configs with one command
# ──────────────────────────────────────────────────────────────────────────────
edit() {
    if [[ -z "$1" ]]; then
        echo "Usage: edit <zsh|caddy|diary|nvim|nix|hy>"
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
        hy)
            # Hyprland/Waybar prototype configs in nixosconfig
            local conf_dir="$HOME/nixosconfig/modules/home-manager/display/conf"
            nvim -c "cd $conf_dir"
            ;;
        *)
            echo "Unknown argument: $1"
            return 1
            ;;
    esac
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

    if ! yt-dlp \
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

# ──────────────────────────────────────────────────────────────────────────────
#  Plays audio from a YouTube URL using mpv without requiring quoted URLs
# ──────────────────────────────────────────────────────────────────────────────
ytlisten() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: ytlisten <YouTube URL>" >&2
        return 1
    fi

    echo "▶️  Starting audio stream for '$1'..."
    if mpv \
        --no-video \
        --ytdl-format='bestaudio/best' \
        --msg-level=ytdl_hook=debug \
        "$1"; then
        echo "✅ Stream finished."
    else
        echo "❌ mpv failed to play the stream." >&2
        return 1
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
#  hypr_proto: copy live Hypr/Waybar configs into repo and replace with symlinks
# ──────────────────────────────────────────────────────────────────────────────
hypr_proto() {
    local mode="${1:-}"

    if [[ "$mode" != "create" ]]; then
        cat <<EOF
Usage: hypr_proto create

  create  - Copy current Hypr/Waybar config files into:
              modules/home-manager/display/conf/
            and replace live configs with symlinks to those files.

This is destructive: existing files/symlinks in ~/.config are replaced.
You can always rebuild/switch to go back to pure Nix.
EOF
        return 1
    fi

    # 1. Find repo root
    local repo_root conf_root
    if ! repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
        echo "hypr_proto: not inside a git repo (run from your nixosconfig tree)" >&2
        return 1
    fi

    conf_root="$repo_root/modules/home-manager/display/conf"
    mkdir -p "$conf_root"

    echo "hypr_proto: repo root is  $repo_root"
    echo "hypr_proto: conf root is  $conf_root"
    echo

    # 2. List of config files we care about
    local files=(
        "$HOME/.config/hypr/hyprland.conf"
        "$HOME/.config/hypr/hypridle.conf"
        "$HOME/.config/hypr/hyprlock.conf"
        "$HOME/.config/hypr/hyprpaper.conf"
        "$HOME/.config/waybar/config"
        "$HOME/.config/waybar/style.css"
    )

    local src rel target
    for src in "${files[@]}"; do
        if [[ ! -e "$src" ]]; then
            echo "[-] Missing, skipping: $src"
            continue
        fi

        # Compute relative path under ~/.config, then mirror that under conf_root
        rel="${src#$HOME/.config/}" # /home/.../.config/hypr/hyprland.conf -> hypr/hyprland.conf
        target="$conf_root/$rel"

        mkdir -p "$(dirname "$target")"

        echo "[*] Copying $src -> $target"
        cp "$src" "$target"

        echo "    Removing $src and creating symlink"
        rm -f "$src"
        ln -s "$target" "$src"
        echo
    done

    echo "hypr_proto: done."
    echo
    echo "Now you can edit files under:"
    echo "  $conf_root"
    echo "and Hyprland/Waybar will read them via the symlinks."
    echo "Use 'hyprctl reload' (and restart hypridle/waybar) to apply changes live."
}

pod() {
    # 1. Check if a URL was provided
    if [ -z "$1" ]; then
        echo "Usage: pod <youtube_url>"
        return 1
    fi

    echo "Sending '$1' to podcast server..."

    # 2. Send the request to the NixOS VM (IP: 192.168.1.29, Port: 9000)
    # -f: Fail silently on server errors (so we don't see raw HTML)
    # -S: Show error message if it fails
    curl -X POST \
        -H "Content-Type: application/json" \
        -d "{\"url\": \"$1\"}" \
        http://192.168.1.29:9000/hooks/download-audio
}

pod_play() {
    # 1. Check if a URL was provided
    if [ -z "$1" ]; then
        echo "Usage: pod_play <playlist_url>"
        return 1
    fi

    echo "Sending playlist '$1' to podcast server..."

    curl -X POST \
        -H "Content-Type: application/json" \
        -d "{\"url\": \"$1\"}" \
        http://192.168.1.29:9000/hooks/download-playlist
}

# ──────────────────────────────────────────────────────────────────────────────
#  Local CI Check - Runs formatting, linting, and flake checks
#  Requires: alejandra, deadnix, statix
# ──────────────────────────────────────────────────────────────────────────────
check() {
    # 0. Ensure we are in a flake repo
    if [[ ! -f "flake.nix" ]]; then
        echo "❌ No flake.nix found in current directory."
        return 1
    fi

    # 1. Dependency Check
    local deps=(alejandra deadnix statix git nix)
    local missing=()
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "❌ Missing dependencies for 'check': ${missing[*]}"
        echo "👉 Please add these to your universal package list."
        return 1
    fi

    # 2. Format Check (Alejandra)
    echo "🧹 Running Format Check (alejandra)..."
    # --check exits non-zero if changes are needed, without modifying files
    if ! alejandra --check --quiet . >/dev/null 2>&1; then
        echo "❌ Formatting issues detected."
        echo "   Run 'nix fmt' or 'alejandra .' to fix them."
        return 1
    fi

    # 3. Linting (Deadnix)
    echo "🔍 Running Linting (deadnix)..."
    # --fail exits non-zero if dead code is found
    if ! deadnix --fail .; then
        return 1
    fi

    # 4. Linting (Statix)
    echo "🔍 Running Linting (statix)..."
    if ! statix check .; then
        return 1
    fi

    # 5. Flake Check
    echo "❄️  Running Flake Checks..."
    # --print-build-logs ensures you see the error if a check fails
    if ! nix flake check --print-build-logs; then
        echo "❌ Flake check failed."
        return 1
    fi

    echo "✅ All local checks passed. Ready to commit."
}
