-- ln -s plugins.lua ~/.config/nvim/lua/plugins

local plugins = {
	{
		"nvim-treesitter/nvim-treesitter",
		opts = override,
	},
	{
		"tpope/vim-sensible",
		lazy = false,
	},
	-- {
	-- 	"preservim/nerdtree",
	-- 	lazy = false,
	-- },
	{
		"tpope/vim-surround",
		lazy = false,
	},
	-- {
	-- 	"aymericbeaumet/vim-symlink",
	-- 	lazy = false,
	-- },
	-- {
	-- 	"moll/vim-bbye",
	-- 	lazy = false,
	-- },
	{ "backdround/improved-ft.nvim", event = { "BufRead", "BufNewFile" } },
	{
		"neovim/nvim-lspconfig",
		config = function()
			require("nvchad.configs.lspconfig").defaults()
			require("configs.lspconfig")
		end,
	},
	-- {
	-- 	"mfussenegger/nvim-lint",
	-- 	event = { "BufReadPre", "BufNewFile" },
	-- 	config = function()
	-- 		local lint = require("lint")
	--
	-- 		lint.linters_by_ft = {
	-- 			javascript = { "eslint_d" },
	-- 			typescript = { "eslint_d" },
	-- 			javascriptreact = { "eslint_d" },
	-- 			typescriptreact = { "eslint_d" },
	-- 			svelte = { "eslint_d" },
	-- 			python = { "pylint" },
	-- 			nix = { "nix" },
	-- 		}
	--
	-- 		local lint_augroup = vim.api.nvim_create_augroup("lint", { clear = true })
	--
	-- 		vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "InsertLeave" }, {
	-- 			group = lint_augroup,
	-- 			callback = function()
	-- 				lint.try_lint()
	-- 			end,
	-- 		})
	--
	-- 		vim.keymap.set("n", "<leader>l", function()
	-- 			lint.try_lint()
	-- 		end, { desc = "Trigger linting for current file" })
	-- 	end,
	-- },
	--
	{
		"MeanderingProgrammer/markdown.nvim",
		main = "render-markdown",
		opts = {},
		name = "render-markdown", -- Only needed if you have another plugin named markdown.nvim
		-- dependencies = { "nvim-treesitter/nvim-treesitter", "echasnovski/mini.nvim" }, -- if you use the mini.nvim suite
		-- dependencies = { 'nvim-treesitter/nvim-treesitter', 'echasnovski/mini.icons' }, -- if you use standalone mini plugins
		dependencies = { "nvim-treesitter/nvim-treesitter", "nvim-tree/nvim-web-devicons" }, -- if you prefer nvim-web-devicons
		lazy = false,
	},
}

return plugins
