# Interactive, multi-select TUI + safe recursive copier for context snapshots.
# Depends on: xclip. Prefers fzf; falls back to gum if available.

# ──────────────────────────────────────────────────────────────────────────────
# Select top-level subdirectories via TUI and print selections (one per line).
# Returns non-zero on abort or empty selection.
# ──────────────────────────────────────────────────────────────────────────────
_copycr_select_dirs() {
    local -a dirs
    local d
    # Top-level subdirs of $PWD (no hidden by default)
    while IFS= read -r d; do dirs+=("$d"); done < <(
        find . -mindepth 1 -maxdepth 1 -type d -printf '%P\n' | LC_ALL=C sort
    )

    if ((${#dirs[@]} == 0)); then
        echo "No subdirectories found in $PWD. Pass explicit paths to copycr." >&2
        return 1
    fi

    local out
    if command -v fzf >/dev/null 2>&1; then
        out=$(
            printf '%s\n' "${dirs[@]}" | fzf \
                --multi \
                --marker='✓' \
                --bind 'space:toggle,ctrl-a:select-all,ctrl-d:deselect-all' \
                --header 'Space=toggle • Enter=copy • Ctrl-A=all • Ctrl-D=none • Esc=abort' \
                --height=80% \
                --reverse \
                --preview 'ls -la --color=always {} | sed -n "1,200p"' \
                --preview-window 'right:60%:wrap'
        )
    elif command -v gum >/dev/null 2>&1; then
        # gum fallback (Space toggles, Enter confirms)
        out=$(
            printf '%s\n' "${dirs[@]}" | gum choose --no-limit --header 'Select directories (Space=toggle, Enter=copy, Esc=abort)'
        )
    else
        echo "fzf (preferred) or gum not found. Install one, or pass explicit paths to copycr." >&2
        return 1
    fi

    [[ -z "$out" ]] && {
        echo "No directories selected. Aborting." >&2
        return 1
    }
    print -r -- "$out"
}

# ──────────────────────────────────────────────────────────────────────────────
# Dump *one* target (file or dir) to STDOUT using the existing copycr format.
# ──────────────────────────────────────────────────────────────────────────────
_copycr_dump_target() {
    local target="$1"
    if [[ ! -e "$target" ]]; then
        echo "Error: '$target' does not exist." >&2
        return 1
    fi

    if [[ -f "$target" ]]; then
        {
            command ls -l -- "$target"
            echo
            echo "FILE CONTENTS"
            cat -- "$target"
            echo
        }
        return 0
    fi

    if [[ -d "$target" ]]; then
        (
            cd -- "$target" || exit 1
            command ls -laR .
            echo
            echo "FILE CONTENTS"

            # Find files (recursively), pruning noisy dirs; handle spaces safely.
            # Matches original behavior, but uses -print0 to avoid word-splitting bugs.
            local f
            while IFS= read -r -d '' f; do
                if grep -Iq . "$f"; then
                    echo "===== $f ====="
                    cat -- "$f"
                    echo
                else
                    echo "===== $f (SKIPPED BINARY) =====" >&2
                fi
            done < <(find . \( -name .git -o -name result -o -name node_modules \) -prune -o -type f -print0)
        )
        return $?
    fi

    echo "Error: '$target' is not a regular file or directory." >&2
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# Public: copycr
# Behavior:
#   - If piped input: copy stdin to clipboard (no TUI).
#   - If args given: dump those paths recursively (no TUI).
#   - Else (TTY): show TUI to pick top-level subdirs of $PWD, then dump them.
# Output is piped once to xclip, preserving prior clipboard behavior.
# ──────────────────────────────────────────────────────────────────────────────
copycr() {
    # Piped input → copy as-is
    if [[ ! -t 0 ]]; then
        xclip -selection clipboard -target UTF8_STRING
        echo "Piped input copied to clipboard." >&2
        return 0
    fi

    # Explicit targets → no TUI
    if (($# > 0)); then
        local missing=0
        local p
        for p in "$@"; do
            [[ -e "$p" ]] || {
                echo "Error: '$p' does not exist." >&2
                missing=1
            }
        done
        ((missing)) && return 1

        {
            for p in "$@"; do
                _copycr_dump_target "$p" || return 1
            done
        } | xclip -selection clipboard -target UTF8_STRING

        echo "Recursive directory context copied to clipboard." >&2
        return 0
    fi

    # Interactive mode (no args, TTY)
    if [[ -t 1 ]]; then
        local selections
        selections=$(_copycr_select_dirs) || return 1

        {
            # Read newline-delimited selections safely
            local line
            while IFS= read -r line; do
                _copycr_dump_target "$line" || return 1
            done <<<"$selections"
        } | xclip -selection clipboard -target UTF8_STRING

        echo "Selected directories' context copied to clipboard." >&2
        return 0
    fi

    echo "No TTY detected and no input provided. Nothing to do." >&2
    return 1
}
