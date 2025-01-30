local on_attach = require("nvchad.configs.lspconfig").on_attach
local on_init = require("nvchad.configs.lspconfig").on_init
local capabilities = require("nvchad.configs.lspconfig").capabilities

local lspconfig = require("lspconfig")
local servers = { "ts_ls", "yamlls", "marksman", "pyright", "bashls", "jsonls" }

-- lsps with default config
for _, lsp in ipairs(servers) do
	lspconfig[lsp].setup({
		on_attach = on_attach,
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
	cmd = { "nixd" },
	settings = {
		nixd = {
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
	on_attach = on_attach,
	on_init = on_init,
	capabilities = capabilities,
})
