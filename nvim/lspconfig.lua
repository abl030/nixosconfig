--I originally tried to load this in as a plugin setting.
--but that doesn't work. It's actually some looping lua code to attach lsps to the current buffers.
--it's its own function. Thus load it like this.

local on_attach = require("nvchad.configs.lspconfig").on_attach
local on_init = require("nvchad.configs.lspconfig").on_init
local capabilities = require("nvchad.configs.lspconfig").capabilities

local lspconfig = require("lspconfig")
local servers = { "ts_ls", "yamlls", "marksman", "pyright", "bashls", "nixd", "jsonls" }

-- lsps with default config
for _, lsp in ipairs(servers) do
	lspconfig[lsp].setup({
		on_attach = on_attach,
		on_init = on_init,
		capabilities = capabilities,
	})
end

-- Capture the username and hostname dynamically
local handle_username = io.popen("whoami")
local username = handle_username:read("*l")
handle_username:close()

local handle_hostname = io.popen("hostname")
local hostname = handle_hostname:read("*l")
handle_hostname:close()

-- Set up nixd with dynamic home_manager expression
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
						.. hostname
						.. ".options",
				},
			},
		},
	},
})
