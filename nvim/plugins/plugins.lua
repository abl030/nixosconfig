-- ln -s plugins.lua ~/.config/nvim/lua/plugins

local plugins = {
	{
		"tpope/vim-sensible",
		event = { "BufRead", "BufNewFile" },
	},

	-- {
	-- 	"tpope/vim-surround",
	-- 	event = { "BufRead", "BufNewFile" },
	-- },

	{
		"backdround/improved-ft.nvim",
		opts = function()
			return {
				-- Maps default f/F/t/T/;/, keys.
				-- default: false
				use_default_mappings = false,
				-- Ignores case of the given characters.
				-- default: false
				ignore_char_case = true,
				-- Takes a last hop direction into account during repetition hops
				-- default: false
				use_relative_repetition = true,
				-- Uses direction-relative offsets during repetition hops.
				-- default: false
				use_relative_repetition_offsets = true,
			}
		end,
		config = function(_, opts)
			local ft = require("improved-ft")
			ft.setup(opts)

			-- Key mapping function
			local map = function(key, fn, description)
				vim.keymap.set({ "n", "x", "o" }, key, fn, {
					desc = description,
					expr = true,
				})
			end

			-- Key mappings
			map("f", ft.hop_forward_to_char, "Hop forward to a given char")
			map("F", ft.hop_backward_to_char, "Hop backward to a given char")
			map("t", ft.hop_forward_to_pre_char, "Hop forward before a given char")
			map("T", ft.hop_backward_to_pre_char, "Hop backward before a given char")
			map(":", ft.repeat_forward, "Repeat hop forward to a last given char")
			map(",", ft.repeat_backward, "Repeat hop backward to a last given char")
		end,
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
