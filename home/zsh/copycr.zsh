# Interactive, multi-select TUI + safe recursive copier for context snapshots.
# Depends on: xclip. Prefers fzf; falls back to gum if available.

# ──────────────────────────────────────────────────────────────────────────────
# Select subdirectories via TUI and print selections (one per line).
# Args:
#   $1 = depth (integer, >=1)
#   $2 = include_hidden ("1" to include, else exclude)
# Returns non-zero on abort or empty selection.
# ──────────────────────────────────────────────────────────────────────────────
_copycr_select_dirs() {
    local depth="${1:-1}"
    local include_hidden="${2:-0}"

    # Build find command for directories up to depth
    local -a find_args=(. -mindepth 1 -maxdepth "$depth" -type d)
    if [[ "$include_hidden" != "1" ]]; then
        # Exclude any path segment that begins with a dot at any level
        find_args+=(-not -path "*/.*")
    fi

    local -a dirs
    local d
    while IFS= read -r d; do dirs+=("$d"); done < <(
        find "${find_args[@]}" -printf '%P\n' | LC_ALL=C sort
    )

    if ((${#dirs[@]} == 0)); then
        echo "No subdirectories found in $PWD (depth=$depth). Pass explicit paths to copycr." >&2
        return 1
    fi

    local header="Depth=$depth • Space=toggle • Enter=copy • Ctrl-A=all • Ctrl-D=none • Esc=abort"
    local out
    if command -v fzf >/dev/null 2>&1; then
        out=$(
            printf '%s\n' "${dirs[@]}" | fzf \
                --multi \
                --marker='✓' \
                --bind 'space:toggle,ctrl-a:select-all,ctrl-d:deselect-all' \
                --header "$header" \
                --height=80% \
                --reverse \
                --preview 'ls -la --color=always {} | sed -n "1,200p"' \
                --preview-window 'right:60%:wrap'
        )
    elif command -v gum >/dev/null 2>&1; then
        out=$(
            printf '%s\n' "${dirs[@]}" | gum choose --no-limit --header "Select directories ($header)"
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
# Parse options for interactive mode (simple, robust, no double-shifts):
#   -d N | --depth N         choose directories up to depth N (default 1)
#   --include-hidden         include hidden directories
# Leaves non-option args in COPYCR_REST_ARGS (global).
# ──────────────────────────────────────────────────────────────────────────────
_copycr_parse_opts() {
    typeset -g COPYCR_DEPTH=1
    typeset -g COPYCR_INCLUDE_HIDDEN=0
    typeset -g COPYCR_REST_ARGS=()

    local -a ARGS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d | --depth)
                if [[ $# -lt 2 ]]; then
                    echo "Missing value for $1" >&2
                    return 1
                fi
                local val="$2"
                if ! [[ "$val" =~ ^[0-9]+$ ]] || [[ "$val" -lt 1 ]]; then
                    echo "Invalid depth: $val" >&2
                    return 1
                fi
                COPYCR_DEPTH="$val"
                shift 2
                ;;
            --include-hidden)
                COPYCR_INCLUDE_HIDDEN=1
                shift
                ;;
            --)
                shift
                # everything after -- are positional args
                while [[ $# -gt 0 ]]; do
                    ARGS+=("$1")
                    shift
                done
                ;;
            -*)
                echo "Unknown option: $1" >&2
                return 1
                ;;
            *)
                ARGS+=("$1")
                shift
                ;;
        esac
    done

    COPYCR_REST_ARGS=("${ARGS[@]}")
}

# ──────────────────────────────────────────────────────────────────────────────
# Public: copycr
# Behavior:
#   - If piped input: copy stdin to clipboard (no TUI).
#   - If args given (paths after options): dump those paths recursively (no TUI).
#   - Else (TTY): show TUI to pick subdirs up to configured depth (default 1).
# Output is piped once to xclip, preserving prior clipboard behavior.
# ──────────────────────────────────────────────────────────────────────────────
copycr() {
    # Piped input → copy as-is
    if [[ ! -t 0 ]]; then
        xclip -selection clipboard -target UTF8_STRING
        echo "Piped input copied to clipboard." >&2
        return 0
    fi

    # Parse options (affects interactive mode / header)
    _copycr_parse_opts "$@" || return 1
    # Use parsed positional args
    set -- "${COPYCR_REST_ARGS[@]}"

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
        selections=$(_copycr_select_dirs "$COPYCR_DEPTH" "$COPYCR_INCLUDE_HIDDEN") || return 1

        {
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
