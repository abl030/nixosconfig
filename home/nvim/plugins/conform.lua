return {
	"stevearc/conform.nvim",

	-- So we've got an autoload on file save for conform so technically we don't need this.
	-- But we have it load on opening buffers because now we can check :ConformInfo
	-- and see what conform is using for all files types.
	event = { "BufReadPost", "BufNewFile" },

	opts = {
		formatters_by_ft = {
			rust = { "rustfmt" },
			yaml = { "prettierd", lsp_format = "prettierd" },
			sh = { "shfmt", "beautysh" },
			nix = { "alejandra" },
			json = { "jq" },
			zsh = { "shfmt", "beautysh" },
		},
	},
}
