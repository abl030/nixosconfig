# `copycr` & `copycf` — selective context copiers (with TUI)

## User guide

**What they do:** Create a snapshot of files or directories for your clipboard in a stable, LLM-friendly text format.

*   **`copycr`** (Copy Context **Recursive**): Select **directories** to dump recursively.
*   **`copycf`** (Copy Context **Files**): Select specific **files** to dump individually.

**Invocation modes**

*   **Pipe:** `… | copycr` (or `copycf`) → copies stdin as-is. *(No TUI.)*
*   **Args:** `copycr [options] <path …>` → copies those paths. *(No TUI.)*
*   **Interactive:** `copycr` or `copycf` [options] → opens a TUI to pick targets.

**Options**

*   `-d N`, `--depth N` — show targets up to depth **N** in the TUI (default `1`).
*   `--include-hidden` — include hidden files/dirs in the TUI.
*   `-R`, `--include-root` — also dump the **current directory `.`** (non-recursive).
*   `--` — end of options; everything after is treated as a path.

**Behaviour**

*   **`copycr` (Directories):**
    *   Selected directories are dumped **recursively**.
    *   Prunes noisy trees (`.git`, `result`, `node_modules`) to keep snapshots small.
*   **`copycf` (Files):**
    *   Lists **individual files** for selection.
    *   Aggressively filters noisy files during selection to keep the list usable.
    *   TUI preview shows the first 100 lines of text files.
*   **General:**
    *   `-R/--include-root` dumps **`.` only at top level** (non-recursive).
    *   Binary files are **detected and skipped** with a note.
    *   Output includes an `ls -l` header and a `FILE CONTENTS` section with `===== ./path =====` markers.
    *   TUI controls (fzf): *Space* toggle • *Ctrl-A* select all • *Ctrl-D* deselect all • *Enter* confirm • *Esc* abort.

**Examples**

```bash
# Directory Selection (Recursive)
copycr                      # Pick top-level subdirs
copycr -d 2                 # Pick subdirs up to 2 levels deep
copycr -R docker ha         # Explicit paths + root context

# File Selection (Individual)
copycf                      # Pick files in current dir
copycf -d 4                 # Deep dive to pick specific files anywhere in tree

# Piping
printf 'hello' | copycr     # Copy stdin, no TUI
```

---

## Expected output shape

```text
<ls -laR target>

FILE CONTENTS
===== ./target/sub/file.txt =====
<file contents>

===== ./target/binary.png (SKIPPED BINARY) =====
```

---

## Design decisions (notes to future me)

*   **Non-breaking UX:** pipe → clipboard; args → exact targets; no args → TUI.
*   **Separation of concerns:**
    *   `_copycr_select_dirs` / `_copycr_select_files`: Build TUI lists.
    *   `_copycr_dump_target`: Handles formatting and binary detection.
    *   `copycr` / `copycf`: Thin dispatchers.
*   **Stable, grep-friendly format:** Explicit `./path` markers.
*   **Performance:** `copycf` applies pruning *during* the `find` command to prevent `node_modules` or `.git` internals from flooding `fzf`.
*   **Dependencies:** `xclip` required; **fzf preferred** for TUI (gum fallback supported).

---

## Troubleshooting

*   **"No files/directories selected":** You hit Enter without selecting items (use Space to toggle).
*   **"command not found: --preview":** Ensure you are using the latest version of the script (fixed a comment parsing issue in the fzf arguments).
*   **TUI looks empty:** Check if your depth (`-d`) is high enough, or if `.gitignore` equivalent patterns (like `result` or `node_modules`) are hiding the files you expect.
