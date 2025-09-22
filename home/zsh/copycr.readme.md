# `copycr` — selective context copier (with TUI)

## User guide

**What it does:** Copies a snapshot of files/directories to your clipboard in a stable, LLM-friendly text format.

**Invocation modes**

* **Pipe:** `… | copycr` → copies stdin as-is. *(No TUI.)*
* **Args:** `copycr [options] <path …>` → copies those paths. *(No TUI.)*
* **Interactive:** `copycr [options]` → opens a TUI to pick subdirectories.

**Options**

* `-d N`, `--depth N` — show subdirs up to depth **N** in the TUI (default `1`).
* `--include-hidden` — include hidden dirs in the TUI.
* `-R`, `--include-root` — also dump the **current directory `.`** (non-recursive).
* `--` — end of options; everything after is treated as a path.

**Behaviour**

* Selected/arg **directories** are dumped **recursively** (pruning `.git`, `result`, `node_modules`).
* `-R/--include-root` dumps **`.` only at top level** (non-recursive).
* Selected/arg **files** are dumped directly.
* Binary files are **detected and skipped** with a note.
* Output includes an `ls -la`/`ls -laR` header and a `FILE CONTENTS` section with `===== ./path =====` markers.
* TUI controls (fzf): *Space* toggle • *Ctrl-A* select all • *Ctrl-D* deselect all • *Enter* confirm • *Esc* abort.

**Examples**

```bash
copycr                      # Pick top-level subdirs to copy (recursive)
copycr -d 2                # Pick subdirs up to 2 levels deep
copycr --include-hidden    # Show hidden dirs in the picker
copycr -R                  # Also include '.' (shallow) when copying selection
copycr -R docker ha        # Include '.' (shallow) + recursively dump docker/ and ha/
printf 'hello' | copycr    # Copy stdin, no TUI
```

---

## Expected output shape

* For a directory (recursive):

  ```
  <ls -laR target>

  FILE CONTENTS
  ===== ./target/sub/file.txt =====
  <file contents>
  ```
* For root `.` with `-R` (non-recursive): only `ls -la .` and top-level **files** (no recursion).

---

## Design decisions (notes to future me)

* **Non-breaking UX:** pipe → clipboard; args → exact targets; no args → TUI.
* **Separation of concerns:**

  * `_copycr_select_dirs` builds the TUI list (depth-limited);
  * `_copycr_dump_target` handles dumping (recursive vs shallow);
  * `copycr` is a thin dispatcher.
* **Recursive by default** for selected dirs (so picking `docker` includes all its children).
  Root `.` is **shallow** with `-R` to avoid overwhelming output.
* **Stable, grep-friendly format:** explicit `./path` markers, binary-skip notices.
* **Prunes noisy trees** (`.git`, `result`, `node_modules`) to keep snapshots small.
* **Dependencies:** `xclip` required; **fzf preferred** for TUI (gum fallback supported).

---

## Troubleshooting

* “No directories selected” → you hit Enter without selections; use `-R` if you only want `.`.
* Depth shows wrong number → ensure you’re on the latest version (option parser fixed to be robust).
* Want depth-limited dumps? Add a future `--dump-depth N` to `_copycr_dump_target` (currently always recursive for selections).

