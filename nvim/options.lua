-- require("nvchad.options")

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
		yaml = { "prettierd", lsp_format = "prettierd" },
		sh = { "beautysh" },
		nix = { "nixpkgs_fmt" },
		json = { "jq" },
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
-- This just forces nvim to use the clipboard all the time. I am unsure if this is the best method

vim.opt.clipboard = "unnamedplus"
--This sources our crusty old vimrc that needs to be updated
vim.cmd("source ~/vim.vim")
-- This keybind finished the swap of : to ; so that we can move through our finds in the buffer.
vim.keymap.set("n", ":", ";", { noremap = true, silent = true })
