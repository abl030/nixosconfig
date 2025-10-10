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
