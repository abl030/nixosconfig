-- EXAMPLE
local on_attach = require("nvchad.configs.lspconfig").on_attach
local on_init = require("nvchad.configs.lspconfig").on_init
local capabilities = require("nvchad.configs.lspconfig").capabilities

local lspconfig = require("lspconfig")
local servers = { "html", "cssls", "yamlls", "marksman", "pyright", "bashls", "nixd" }

-- lsps with default config
for _, lsp in ipairs(servers) do
	lspconfig[lsp].setup({
		on_attach = on_attach,
		on_init = on_init,
		capabilities = capabilities,
	})
end

-- lspconfig.lua_language_server.setup({
-- 	cmd = { "lua-language-server" }, -- This uses the Nix shell to run the package
-- 	on_attach = on_attach,
-- 	on_init = on_init,
-- 	capabilities = capabilities,
-- })

-- typescript
-- lspconfig.tsserver.setup({
-- 	on_attach = on_attach,
-- 	on_init = on_init,
-- 	capabilities = capabilities,
-- })

local handle = io.popen("whoami")
local username = handle:read("*l")
handle:close()

local nvim_lsp = require("lspconfig")
nvim_lsp.nixd.setup({
	cmd = { "nixd" },
	settings = {
		nixd = {
			options = {

				home_manager = {
					expr = '(builtins.getFlake "/home/'
						.. username
						.. '/nixosconfig").homeConfigurations.'
						.. username
						.. ".options",
				},
			},
		},
	},
})
