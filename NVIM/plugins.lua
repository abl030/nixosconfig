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
	{
		"preservim/nerdtree",
		lazy = false,
	},
	{
		"tpope/vim-surround",
		lazy = false,
	},
	{
		"aymericbeaumet/vim-symlink",
		lazy = false,
	},
	{
		"moll/vim-bbye",
		lazy = false,
	},
	{ "chrisbra/improvedft", lazy = false },
	-- In order to modify the `lspconfig` configuration:
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
		lazy = false,
	},
}

return plugins
