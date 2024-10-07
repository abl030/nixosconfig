-- ln -s plugins.lua ~/.config/nvim/lua/plugins

local plugins = {
	{
		"tpope/vim-sensible",
		event = { "BufRead", "BufNewFile" },
	},

	{
		"tpope/vim-surround",
		event = { "BufRead", "BufNewFile" },
	},

	{
		"backdround/improved-ft.nvim",
		event = { "BufRead", "BufNewFile" },
	},

	{
		"neovim/nvim-lspconfig",
		config = function()
			require("nvchad.configs.lspconfig").defaults()
			require("configs.lspconfig")
		end,
	},

	{
		"MeanderingProgrammer/markdown.nvim",
		main = "render-markdown",
		opts = {},
		name = "render-markdown", -- Only needed if you have another plugin named markdown.nvim
		-- dependencies = { "nvim-treesitter/nvim-treesitter", "echasnovski/mini.nvim" }, -- if you use the mini.nvim suite
		-- dependencies = { 'nvim-treesitter/nvim-treesitter', 'echasnovski/mini.icons' }, -- if you use standalone mini plugins
		dependencies = { "nvim-treesitter/nvim-treesitter", "nvim-tree/nvim-web-devicons" }, -- if you prefer nvim-web-devicons
		ft = "markdown",
	},
}

return plugins
