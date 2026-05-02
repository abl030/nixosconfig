# Neovim — Debugging Recipes & Known Issues

**Audience:** AI agents debugging the user's NvChad/Lazy-based nvim config under `home/nvim/`. The user's nvim is built via `programs.nvchad`-style flake (NvChad4nix), so plugin code lives in the nix store and `:Lazy` lockfile is read-only — repro from CLI, fix in `home/nvim/plugins/*.lua`.

## Reproducing errors without bothering the user

The user generally won't paste error text. Repro headlessly and read the captured messages yourself:

```bash
rm -f /tmp/nvim-msgs.txt
nvim --headless \
  -c 'set verbosefile=/tmp/nvim-msgs.txt' \
  -c 'set verbose=1' \
  -c 'edit /path/to/file.ext' \
  -c 'sleep 3' \
  -c 'redir >> /tmp/nvim-msgs.txt' \
  -c 'silent messages' \
  -c 'redir END' \
  -c 'qa!' 2>&1 | tail -200
# Plugin/treesitter errors land on stderr (the 2>&1) AND in /tmp/nvim-msgs.txt
# verbose=1 captures autocmd / source events; sleep 3 lets render plugins fire
```

Tweaks worth knowing:
- For an LSP issue specifically, drop `:LspLog` to a file:
  `-c 'edit /path/to/foo.nix' -c 'sleep 5' -c 'lua vim.cmd("write! /tmp/lsplog.txt | call writefile(readfile(vim.lsp.get_log_path()), "/tmp/lsplog.txt")")'`
  Or just `cat ~/.local/state/nvim/lsp.log` after running interactively.
- `:checkhealth` headlessly: `nvim --headless -c 'checkhealth' -c 'write! /tmp/health.txt' -c 'qa!'`.
- Bisect the plugin set: `nvim --clean /path/to/file` (no plugins). If errors disappear, it's a plugin. Then re-enable groups in `home/nvim/plugins/plugins.lua` to isolate.
- `ft=markdown` plugins (like render-markdown) only fire on markdown filetypes — repro must use a `.md` file or `set ft=markdown`.

## Where things live

- `home/nvim/nvim.nix` — entrypoint; wires NvChad4nix + extra Nix-managed LSPs/formatters. `home.file.".config/nvim/lua/..."` lines map repo files into `~/.config/nvim/`.
- `home/nvim/plugins/plugins.lua` — Lazy plugin spec. This is the file you usually edit.
- `home/nvim/plugins/treesitter.lua` — `ensure_installed` parsers list.
- `home/nvim/lspconfig.lua` — LSP server configs.
- `home/nvim/options.lua` — vim options (sourced as `options2.lua`).

## Resolved: `render-markdown.nvim` crashes on every `.md` file (nvim 0.12.1)

**Status:** **fixed 2026-05-02** in `home/nvim/plugins/treesitter.lua` (issue [#226](https://github.com/abl030/nixosconfig/issues/226)). Below is the full pathology — keep it for the next breakage in this area.

**Symptom (full repro confirmed via headless recipe above):**

```
Error in command line:
vim.schedule callback: …/lua/vim/treesitter.lua:196: attempt to call method 'range' (a nil value)
stack traceback:
  …/lua/vim/treesitter.lua:196: in function 'get_range'
  …/lua/vim/treesitter.lua:231: in function 'get_node_text'
  …/nvim-treesitter/lua/nvim-treesitter/query_predicates.lua:141: in function 'handler'
  …/lua/vim/treesitter/query.lua:868: in function '_apply_directives'
  …/lua/vim/treesitter/languagetree.lua:1123: in function '_get_injections'
  …/lazy/render-markdown/lua/render-markdown/request/view.lua:62: in function 'parse'
  …/lazy/render-markdown/lua/render-markdown/core/ui.lua:{159,132,115,81} in render/run

Decoration provider "conceal_line" (ns=nvim.treesitter.highlighter):
Lua: …same `:range()` nil error, via …/treesitter/highlighter.lua:529
```

**Root cause — neovim 0.12 query API change:**

In nvim 0.12+, the `_apply_directives` runtime in `$VIMRUNTIME/lua/vim/treesitter/query.lua` passes captures to handlers as `table<integer, TSNode[]>` — a *list* of TSNodes per capture id, regardless of how the directive was registered. The legacy `add_directive(name, fn, opts)` `opts.all = false` flag is dead — neovim 0.12's `add_directive` only honors `opts.force` (see runtime `query.lua` `M.add_directive` and search for the assignment to `directive_handlers[name]`).

The legacy `master` branch of `nvim-treesitter` (`lua/nvim-treesitter/query_predicates.lua`) still treats `match[capture_id]` as a single TSNode:

```lua
local node = match[capture_id]
if not node then return end           -- table is truthy, passes
local text = vim.treesitter.get_node_text(node, bufnr):lower()
                                       -- ↑ get_range(node) → node:range(true) → crash
                                       --   because `node` is a Lua table, not TSNode userdata
```

Six handlers in that file are affected:
- predicates: `nth?`, `is?`, `kind-eq?`
- directives: `set-lang-from-mimetype!`, `set-lang-from-info-string!`, `downcase!`

`set-lang-from-info-string!` is the one that lights up on every `.md` open: nvim-treesitter's `queries/markdown/injections.scm` uses it on every `fenced_code_block` to map ` ```bash` → bash parser. render-markdown.nvim's render tick parses the buffer, which evaluates that injection query, which trips the directive. The treesitter highlighter's `conceal_line` decoration provider re-runs it on every redraw, hence the spam in `:messages`.

A previous mitigation in `home/nvim/plugins/plugins.lua` (`code = { … }` block) is unrelated — those are visual code-block options, not injection toggles. The "language_pad / set-lang-from-info-string" comment there was misleading and got fixed in the same change as the directive patch.

**The fix (current solution):**

`home/nvim/plugins/treesitter.lua` re-registers all six handlers in the nvim-treesitter plugin spec's `config = function`. Each patched handler unwraps `match[id]` if it's a table (new format) or uses it directly (legacy). Registered with `{ force = true }` to override nvim-treesitter's broken versions. Ships with the plugin's own setup so the override always lands after upstream registration.

**When to revisit:**

- nvim-treesitter ships its own fix on `master` (unlikely — branch is in maintenance).
- We migrate off `nvim-treesitter` `master` to its `main` branch (rewrite of the plugin, requires NvChad4nix support).
- The `vim.treesitter.query.add_directive` API changes again on a future neovim release, in which case the handler signature in `treesitter.lua` may need updating.

Validate any change with the headless repro recipe above on a real repo `.md` file (e.g. `CLAUDE.md`, `docs/wiki/**/*.md`) — `wc -l /tmp/nvim-stderr.txt` should be 0.

## Changelog

- 2026-05-02 — Initial doc and fix. Captured render-markdown / treesitter `:range()` crash on nvim 0.12.1; root-caused to nvim 0.12's `match[id]` format change; patched the six broken nvim-treesitter `master` handlers in `home/nvim/plugins/treesitter.lua`. Issue [#226](https://github.com/abl030/nixosconfig/issues/226) closed.
