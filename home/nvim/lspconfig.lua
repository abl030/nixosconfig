-- ~/custom/configs/lspconfig.lua

local nvlsp = require("nvchad.configs.lspconfig")
-- local lspconfig = require("lspconfig") -- DEPRECATED: usage replaced by vim.lsp.config

-- Load NvChad's default LSP configurations
nvlsp.defaults()

-- Create custom on_attach to preserve NvChad's keymaps + add inlay hints
local custom_on_attach = function(client, bufnr)
	nvlsp.on_attach(client, bufnr) -- Preserve default keymaps
	vim.lsp.inlay_hint.enable(true) -- Your custom inlay hints
end

-- Helper function to configure and enable LSP using the new API
local function setup_lsp(name, opts)
	vim.lsp.config(name, opts)
	vim.lsp.enable(name)
end

-- List of standard LSP servers with default config
local default_servers = {
	"html",
	"cssls",
	"ts_ls",
	"marksman",
	"pyright",
	-- "bashls",
	"jsonls",
}

-- Configure default servers
for _, lsp in ipairs(default_servers) do
	setup_lsp(lsp, {
		on_attach = custom_on_attach,
		on_init = nvlsp.on_init,
		capabilities = nvlsp.capabilities,
	})
end

-- Special configurations ------------------------------------------------------

-- This allows us to specify which filetypes it should attach to.
setup_lsp("bashls", {
	on_attach = custom_on_attach,
	on_init = nvlsp.on_init,
	capabilities = nvlsp.capabilities,
	filetypes = { "sh", "zsh" }, -- This is the key change!
})

-- Nixd configuration
local username = vim.fn.getenv("USER") or "user"
local hostname = vim.fn.hostname()

setup_lsp("nixd", {
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

-- Gave up on merging the default NVChad LSP config for Lua. All we are doing here is recreating the NVChad
-- default on_attach and adding the inlay hints.
setup_lsp("lua_ls", {
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

-- 2) YAML LS with Docker Compose schema + schemastore
setup_lsp("yamlls", {
	on_attach = custom_on_attach,
	on_init = nvlsp.on_init,
	capabilities = nvlsp.capabilities,
	settings = {
		yaml = {
			validate = true,
			hover = true,
			completion = true,
			-- Pull lots of common schemas automatically (GitHub Actions, Ansible, etc.)
			schemaStore = {
				enable = true,
				url = "https://www.schemastore.org/api/json/catalog.json",
			},
			-- Explicit Compose schema mapping (v2 spec)
			schemas = {
				-- Official Compose JSON Schema:
				["https://raw.githubusercontent.com/compose-spec/compose-spec/master/schema/compose-spec.json"] = {
					"docker-compose*.y*ml",
					"compose*.y*ml",
				},
			},
		},
	},
})
