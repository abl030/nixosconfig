# Neovim Configuration

NixOS-managed Neovim configuration based on NvChad framework with custom plugins and LSP setup.

## Module Structure

```
home/nvim/
├── nvim.nix                    # Main Nix configuration file
├── plugins/
│   ├── plugins.lua            # Plugin definitions and configurations
│   ├── treesitter.lua         # Treesitter language configuration
│   └── conform.lua            # Code formatter configuration
├── lspconfig.lua              # LSP server configurations
├── options.lua                # Neovim options and settings
├── diary.lua                  # Diary-specific configurations
├── vim.vim                    # Legacy vim keybindings
└── chadrc_editor.lua          # NvChad editor UI configuration
```

## Key Modules

### nvim.nix
Entry point for Home Manager. Defines:
- Package dependencies (LSPs, formatters, linters)
- NvChad4nix integration
- File mappings to `~/.config/nvim/`
- Extra configuration loading

### plugins/plugins.lua
Plugin definitions using lazy.nvim format:
- **OSC52 Clipboard**: Cross-platform clipboard support for SSH sessions
- **improved-ft.nvim**: Enhanced f/t motions
- **LSP Config**: Language server protocol setup
- **render-markdown**: Markdown rendering (configured to avoid treesitter directive issues)
- **nvim-lint**: Linting with markdownlint, yamllint, etc.
- **supermaven**: AI code completion
- **rustaceanvim**: Rust development tools

### plugins/treesitter.lua
Defines installed treesitter parsers:
- bash, yaml, ssh_config
- rust, python, nix, jq

### lspconfig.lua
LSP server configurations for:
- Nix (nixd), YAML, Markdown (marksman)
- Python (pyright), Bash, JSON
- Web (typescript, eslint, CSS, HTML)
