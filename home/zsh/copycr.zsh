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

    local -a find_args=(. -mindepth 1 -maxdepth "$depth" -type d)
    if [[ "$include_hidden" != "1" ]]; then
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
# Optional arg2: shallow=1 to dump only top-level files (non-recursive).
# NOTE: We no longer `cd` into the target; we run ls/find on the *path* so
#       headings show the actual path (e.g., `ha:` not `.:`).
# ──────────────────────────────────────────────────────────────────────────────
_copycr_dump_target() {
    local target="$1"
    local shallow="${2:-0}"

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
        # Normalize a helper to print with leading "./" (for consistency with prior format)
        _copycr__print_path() {
            local p="$1"
            case "$p" in
                ./*) printf "%s" "$p" ;;
                /*) printf "%s" "$p" ;;  # absolute: leave as-is
                *) printf "./%s" "$p" ;; # relative: add "./"
            esac
        }

        if [[ "$shallow" == "1" ]]; then
            # Non-recursive: list the directory itself and only its top-level files
            command ls -la -- "$target"
            echo
            echo "FILE CONTENTS"

            # top-level files only
            local f
            while IFS= read -r -d '' f; do
                if grep -Iq . "$f"; then
                    echo "===== $(_copycr__print_path "$f") ====="
                    cat -- "$f"
                    echo
                else
                    echo "===== $(_copycr__print_path "$f") (SKIPPED BINARY) =====" >&2
                fi
            done < <(find "$target" -mindepth 1 -maxdepth 1 -type f -print0)

            return 0
        fi

        # Recursive (existing behavior), but run on the path directly so headings include it
        command ls -laR -- "$target"
        echo
        echo "FILE CONTENTS"

        local f
        while IFS= read -r -d '' f; do
            if grep -Iq . "$f"; then
                echo "===== $(_copycr__print_path "$f") ====="
                cat -- "$f"
                echo
            else
                echo "===== $(_copycr__print_path "$f") (SKIPPED BINARY) =====" >&2
            fi
        done < <(find "$target" \( -name .git -o -name result -o -name node_modules \) -prune -o -type f -print0)

        return 0
    fi

    echo "Error: '$target' is not a regular file or directory." >&2
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# Parse options for interactive mode (simple, robust):
#   -d N | --depth N         choose directories up to depth N (default 1)
#   --include-hidden         include hidden directories in the picker
#   -R  | --include-root     ALSO dump '.' (pwd) alongside selections/args (shallow)
# Leaves non-option args in COPYCR_REST_ARGS (global).
# ──────────────────────────────────────────────────────────────────────────────
_copycr_parse_opts() {
    typeset -g COPYCR_DEPTH=1
    typeset -g COPYCR_INCLUDE_HIDDEN=0
    typeset -g COPYCR_INCLUDE_ROOT=0
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
            -R | --include-root)
                COPYCR_INCLUDE_ROOT=1
                shift
                ;;
            --)
                shift
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
# If -R/--include-root is set, also dumps '.' (pwd) **shallow** (non-recursive).
# Output is piped once to xclip, preserving prior clipboard behavior.
# ──────────────────────────────────────────────────────────────────────────────
copycr() {
    if [[ ! -t 0 ]]; then
        xclip -selection clipboard -target UTF8_STRING
        echo "Piped input copied to clipboard." >&2
        return 0
    fi

    _copycr_parse_opts "$@" || return 1
    set -- "${COPYCR_REST_ARGS[@]}"

    if (($# > 0)); then
        local missing=0 p
        for p in "$@"; do
            [[ -e "$p" ]] || {
                echo "Error: '$p' does not exist." >&2
                missing=1
            }
        done
        ((missing)) && return 1

        {
            ((COPYCR_INCLUDE_ROOT == 1)) && _copycr_dump_target "." 1 || true
            for p in "$@"; do
                _copycr_dump_target "$p" || return 1
            done
        } | xclip -selection clipboard -target UTF8_STRING

        echo "Recursive directory context copied to clipboard." >&2
        return 0
    fi

    if [[ -t 1 ]]; then
        local selections sel_rc
        selections=$(_copycr_select_dirs "$COPYCR_DEPTH" "$COPYCR_INCLUDE_HIDDEN")
        sel_rc=$?

        {
            ((COPYCR_INCLUDE_ROOT == 1)) && _copycr_dump_target "." 1 || true

            if ((sel_rc == 0)); then
                local line
                while IFS= read -r line; do
                    _copycr_dump_target "$line" || return 1
                done <<<"$selections"
            else
                ((COPYCR_INCLUDE_ROOT == 1)) || return 1
            fi
        } | xclip -selection clipboard -target UTF8_STRING

        echo "Selected directories' context copied to clipboard." >&2
        return 0
    fi

    echo "No TTY detected and no input provided. Nothing to do." >&2
    return 1
}
