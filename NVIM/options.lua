require("nvchad.options")

--  This setups conform.vim to work with our filetypes.
require("conform").setup({
	formatters_by_ft = {
		lua = { "stylua" },
		-- Conform will run multiple formatters sequentially
		python = { "isort", "black" },
		-- You can customize some of the format options for the filetype (:help conform.format)
		rust = { "rustfmt", lsp_format = "fallback" },
		-- Conform will run the first available formatter
		javascript = { "prettierd", "prettier", stop_after_first = true },
		yaml = { "yamlfmt", lsp_format = "fallback" },
		sh = { "beautysh" },
		nix = { "nixpkgs_fmt" },
	},
})

-- this will setup our autoconform on save.
vim.api.nvim_create_autocmd("BufWritePre", {
	pattern = "*",
	callback = function(args)
		require("conform").format({ bufnr = args.buf })
	end,
})

require("nvim-treesitter.configs").setup({
	-- A list of parser names, or "all" (the listed parsers MUST always be installed)
	ensure_installed = { "markdown", "markdown_inline" },
})
vim.opt.clipboard = "unnamedplus"
vim.cmd("source ~/vim.vim")
