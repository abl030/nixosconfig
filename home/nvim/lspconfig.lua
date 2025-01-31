-- ~/custom/configs/lspconfig.lua

local nvlsp = require("nvchad.configs.lspconfig")
local lspconfig = require("lspconfig")

-- Load NvChad's default LSP configurations
nvlsp.defaults()

-- Create custom on_attach to preserve NvChad's keymaps + add inlay hints
local custom_on_attach = function(client, bufnr)
	nvlsp.on_attach(client, bufnr) -- Preserve default keymaps
	vim.lsp.inlay_hint.enable(true) -- Your custom inlay hints
end

-- List of standard LSP servers with default config
local default_servers = {
	"html",
	"cssls",
	"ts_ls",
	"yamlls",
	"marksman",
	"pyright",
	"bashls",
	"jsonls",
}

-- Configure default servers
for _, lsp in ipairs(default_servers) do
	lspconfig[lsp].setup({
		on_attach = custom_on_attach,
		on_init = nvlsp.on_init,
		capabilities = nvlsp.capabilities,
	})
end

-- Special configurations ------------------------------------------------------

-- Nixd configuration
local username = vim.fn.getenv("USER") or "user"
local hostname = vim.fn.hostname()

lspconfig.nixd.setup({
	cmd = { "nixd", "--inlay-hints=true" },
	on_attach = custom_on_attach,
	capabilities = nvlsp.capabilities,
	settings = {
		nixd = {
			nixpkgs = {
				expr = "import <nixpkgs> { }",
			},
			options = {
				home_manager = {
					expr = '(builtins.getFlake ("git+file://" + toString "/home/'
						.. username
						.. '/nixosconfig")).homeConfigurations."'
						.. hostname
						.. '".options',
				},
			},
		},
	},
})

-- Gave up on mergin the default NVChad LSP config for Lua. All we are doing here is recreating the NVChad
-- default on_attach and adding the inlay hints.
lspconfig.lua_ls.setup({
	on_attach = custom_on_attach,
	capabilities = nvlsp.capabilities,
	on_init = nvlsp.on_init,
	settings = {
		Lua = {
			hint = {
				enable = true,
			},
			diagnostics = {
				globals = { "vim" },
			},
			workspace = {
				checkThirdParty = false,
				library = {
					-- Add any custom paths here
					vim.fn.expand("$VIMRUNTIME/lua"),
					vim.fn.expand("$VIMRUNTIME/lua/vim/lsp"),
					vim.fn.stdpath("data") .. "/lazy/ui/nvchad_types",
					vim.fn.stdpath("data") .. "/lazy/lazy.nvim/lua/lazy",
					"${3rd}/luv/library",
				},
				maxPreload = 100000,
				preloadFileSize = 10000,
			},
		},
	},
})
