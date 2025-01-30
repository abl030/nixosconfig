local on_attach = require("nvchad.configs.lspconfig").on_attach
local on_init = require("nvchad.configs.lspconfig").on_init
local capabilities = require("nvchad.configs.lspconfig").capabilities

local lspconfig = require("lspconfig")
local servers = { "ts_ls", "yamlls", "marksman", "pyright", "bashls", "jsonls" }

-- Create a custom on_attach that wraps the default one
-- This allows inlay hints to be enabled for all LSPs
local custom_on_attach = function(client, bufnr)
	-- Call the default NvChad on_attach first
	on_attach(client, bufnr)

	-- Generic handling for other LSPs
	if client.server_capabilities.inlayHintProvider then
		vim.lsp.inlay_hint.enable(true)
	end
end

-- lsps with default config
for _, lsp in ipairs(servers) do
	lspconfig[lsp].setup({
		on_attach = custom_on_attach,
		on_init = on_init,
		capabilities = capabilities,
	})
end

-- Get username with nil checks
local username = "abl030"
local handle_username = io.popen("whoami")
if handle_username then
	username = handle_username:read("*l") or username
	handle_username:close()
end

-- Get hostname with nil checks
local hostname = "localhost"
local handle_hostname = io.popen("hostname")
if handle_hostname then
	hostname = handle_hostname:read("*l") or hostname
	handle_hostname:close()
end

-- Set up nixd with error handling
local nvim_lsp = require("lspconfig")
local flake_path = "/home/" .. username .. "/nixosconfig"

nvim_lsp.nixd.setup({
	cmd = { "nixd", "--inlay-hints=true" }, -- Add the flag here
	settings = {
		nixd = {
			nixpkgs = {
				expr = "import <nixpkgs> { }",
			},
			options = {
				home_manager = {
					expr = '(builtins.getFlake ("git+file://" + toString "'
						.. flake_path
						.. '")).homeConfigurations."'
						.. hostname
						.. '".options',
				},
			},
		},
	},
	on_attach = custom_on_attach,
	on_init = on_init,
	capabilities = capabilities,
})

require("lspconfig").lua_ls.setup({
	settings = {
		Lua = {
			hint = {
				enable = true,
			},
		},
	},
})
