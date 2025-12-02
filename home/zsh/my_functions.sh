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

dc() {
    # If caller already exported a SOPS env var, respect it.
    if [[ -n "${SOPS_AGE_KEY_FILE:-}" || -n "${SOPS_AGE_SSH_PRIVATE_KEY_FILE:-}" ]]; then
        if [[ "$(id -u)" -eq 0 ]]; then
            EDITOR=nvim VISUAL=nvim sops "$@"
        else
            sudo EDITOR=nvim VISUAL=nvim sops "$@"
        fi
        return
    fi

    # 1) AGE KEY FILES (SOPS_AGE_KEY_FILE)
    #    - root-only paths checked with sudo test -r
    #    - user-local checked directly
    local keyfile

    # Root-ish keyfile locations (declarative on some hosts; harmless if absent)
    for keyfile in \
        "/root/.config/sops/age/keys.txt" \
        "/var/lib/sops-nix/key.txt"; do
        if sudo test -r "$keyfile" 2>/dev/null; then
            if [[ "$(id -u)" -eq 0 ]]; then
                SOPS_AGE_KEY_FILE="$keyfile" EDITOR=nvim VISUAL=nvim sops "$@"
            else
                sudo SOPS_AGE_KEY_FILE="$keyfile" EDITOR=nvim VISUAL=nvim sops "$@"
            fi
            return
        fi
    done

    # User-local keyfile
    keyfile="$HOME/.config/sops/age/keys.txt"
    if [[ -r "$keyfile" ]]; then
        SOPS_AGE_KEY_FILE="$keyfile" EDITOR=nvim VISUAL=nvim sops "$@"
        return
    fi

    # 2) Ephemeral host SSH → age key (no persistent state)
    #    Use /etc/ssh/ssh_host_ed25519_key if ssh-to-age is available.
    if command -v ssh-to-age >/dev/null 2>&1 &&
    sudo test -r /etc/ssh/ssh_host_ed25519_key 2>/dev/null; then
        local tmp_key rc
        tmp_key="$(mktemp -t dc-sops-XXXXXX.age)"
        # Redirection happens as the user, ssh-to-age runs as root.
        if sudo ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key >"$tmp_key" 2>/dev/null; then
            chmod 600 "$tmp_key"
            if [[ "$(id -u)" -eq 0 ]]; then
                SOPS_AGE_KEY_FILE="$tmp_key" EDITOR=nvim VISUAL=nvim sops "$@"
                rc=$?
            else
                sudo SOPS_AGE_KEY_FILE="$tmp_key" EDITOR=nvim VISUAL=nvim sops "$@"
                rc=$?
            fi
            rm -f "$tmp_key"
            return "$rc"
        else
            rm -f "$tmp_key"
        fi
    fi

    # 3) SSH KEYS via age-plugin-ssh (if present)
    #    These use SOPS_AGE_SSH_PRIVATE_KEY_FILE.
    local sshkey

    sshkey="/etc/ssh/ssh_host_ed25519_key"
    if sudo test -r "$sshkey" 2>/dev/null; then
        sudo SOPS_AGE_SSH_PRIVATE_KEY_FILE="$sshkey" EDITOR=nvim VISUAL=nvim sops "$@"
        return
    fi

    sshkey="/root/.ssh/id_ed25519"
    if sudo test -r "$sshkey" 2>/dev/null; then
        sudo SOPS_AGE_SSH_PRIVATE_KEY_FILE="$sshkey" EDITOR=nvim VISUAL=nvim sops "$@"
        return
    fi

    sshkey="$HOME/.ssh/id_ed25519"
    if [[ -r "$sshkey" ]]; then
        SOPS_AGE_SSH_PRIVATE_KEY_FILE="$sshkey" EDITOR=nvim VISUAL=nvim sops "$@"
        return
    fi

    # 4) Fallback: no explicit key — defer to sops defaults
    if [[ "$(id -u)" -eq 0 ]]; then
        EDITOR=nvim VISUAL=nvim sops "$@"
    else
        sudo EDITOR=nvim VISUAL=nvim sops "$@"
    fi
}

## ──────────────────────────────────────────────────────────────────────────────
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

# ──────────────────────────────────────────────────────────────────────────────
# commit_this: turn current HEAD commits into a PR to master with auto-merge
# Usage:
#   commit_this [-w] [-b BRANCH] [-B BASE] [--merge|--rebase]
# Defaults:
#   BASE=master, strategy=squash, BRANCH auto-generated.
# Options:
#   -w/--watch     Watch checks and, when merged, fast-forward local master & prune.
#   -b/--branch    Provide a topic branch name (else we timestamp one).
#   -B/--base      Change base branch (default: master).
#   --merge        Use merge commit instead of squash.
#   --rebase       Use rebase merge instead of squash.
# Requires: git, gh (GitHub CLI) logged in, and origin set.
# ──────────────────────────────────────────────────────────────────────────────
commit_this() {
    local base="master" strategy="squash" watch=0 topic=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -w | --watch)
                watch=1
                shift
                ;;
            -b | --branch)
                topic="$2"
                shift 2
                ;;
            -B | --base)
                base="$2"
                shift 2
                ;;
            --merge)
                strategy="merge"
                shift
                ;;
            --rebase)
                strategy="rebase"
                shift
                ;;
            -h | --help)
                echo "Usage: commit_this [-w] [-b BRANCH] [-B BASE] [--merge|--rebase]"
                return 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                return 1
                ;;
        esac
    done

    # Preconditions
    command -v git >/dev/null 2>&1 || {
        echo "git not found"
        return 1
    }
    command -v gh >/dev/null 2>&1 || {
        echo "gh (GitHub CLI) not found"
        return 1
    }
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
        echo "Not a git repo"
        return 1
    }
    git remote get-url origin >/dev/null 2>&1 || {
        echo "No 'origin' remote"
        return 1
    }

    # Ensure we have no uncommitted changes (including staged + untracked)
    if [[ -n "$(git status --porcelain=v1)" ]]; then
        echo "Working tree is dirty; commit or stash first. Offending paths:" >&2
        git status --short >&2
        return 1
    fi

    # Current branch & fetch latest base
    local cur_branch
    cur_branch="$(git rev-parse --abbrev-ref HEAD)"
    git fetch origin "$base" --quiet || {
        echo "Failed to fetch origin/$base"
        return 1
    }

    # Generate topic branch name if not provided
    if [[ -z "$topic" ]]; then
        local ts
        ts="$(date +%Y%m%d-%H%M%S)"
        topic="ab/auto-${cur_branch}-${ts}"
    fi

    # Create topic branch at current HEAD (where your commits live)
    git switch -c "$topic" || {
        echo "Could not create/switch to $topic"
        return 1
    }

    # (Nice hygiene) If you *were* on $base when you ran this, move local $base back to origin/$base
    if [[ "$cur_branch" == "$base" ]]; then
        git branch -f "$base" "origin/$base" >/dev/null 2>&1 || true
    fi

    # Push topic branch
    git push -u origin HEAD || {
        echo "Push failed"
        return 1
    }

    # Build a sensible PR title/body from the commit range
    local merge_base
    merge_base="$(git merge-base "origin/$base" HEAD)"
    local range="${merge_base}..HEAD"
    local ncommits
    ncommits="$(git rev-list --count "$range")"
    local first_subject
    first_subject="$(git log -1 --pretty='%s')"

    local pr_title pr_body
    if [[ "$ncommits" -eq 1 ]]; then
        pr_title="$first_subject"
    else
        pr_title="PR: ${ncommits} commits → ${base}"
    fi
    pr_body="$(git log --no-decorate --pretty='* %h %s' "$range")"

    # Create PR to base
    if ! gh pr create --base "$base" --title "$pr_title" --body "$pr_body" >/dev/null; then
        echo "Failed to create PR. (Is gh authenticated? Do you have push rights?)" >&2
        return 1
    fi

    # Grab PR number and URL
    local pr_num pr_url
    pr_num="$(gh pr view --json number -q '.number')" || {
        echo "Could not read PR number"
        return 1
    }
    pr_url="$(gh pr view --json url -q '.url')" || pr_url="(unknown url)"

    echo "Opened PR #$pr_num → $pr_url"

    # Enable auto-merge
    if ! gh pr merge "$pr_num" --auto --"$strategy" --delete-branch >/dev/null; then
        echo "Could not enable auto-merge. Ensure repo allows auto-merge and required checks are set." >&2
        echo "PR is still open: $pr_url"
        return 1
    fi
    echo "Auto-merge enabled using strategy: $strategy"

    # Optional: watch checks and finish up if merged
    if [[ "$watch" -eq 1 ]]; then
        echo "Watching checks for PR #$pr_num…"
        gh pr checks --watch "$pr_num" || true
        # Poll merge state (MERGED/CLOSED/OPEN)
        local state
        while true; do
            state="$(gh pr view "$pr_num" --json state -q '.state' 2>/dev/null || echo OPEN)"
            if [[ "$state" == "MERGED" ]]; then
                echo "PR merged. Updating local $base…"
                git fetch --prune --quiet
                git switch "$base" && git pull --ff-only
                # Delete local topic branch if it still exists and is merged
                git branch --merged | grep -q "^[* ]\s\+$topic$" && git branch -d "$topic" || true
                echo "Done."
                break
            elif [[ "$state" == "CLOSED" ]]; then
                echo "PR closed without merge: $pr_url"
                break
            fi
            sleep 5
        done
    else
        echo "PR will merge automatically once checks/reviews pass."
    fi
}
