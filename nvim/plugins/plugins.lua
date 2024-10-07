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
	{
		--this is a working linting config. You may need to install linting programs as a nic package.
		--But basically it's gonna be language by language here.
		--For instance that JSON linter doesn't really provide much more info that the LSP JOSNLS
		--So why use it! The nix linter is working, but I've never seen it actually do _anything_
		-- I got this from here: https://docs.rockylinux.org/books/nvchad/
		"mfussenegger/nvim-lint",
		enabled = true,
		event = "VeryLazy",
		config = function()
			require("lint").linters_by_ft = {
				markdown = { "markdownlint" },
				yaml = { "yamllint" },
				nix = { "nix" },
				-- json = { "jsonlint" },
			}

			vim.api.nvim_create_autocmd({ "BufWritePost" }, {
				callback = function()
					require("lint").try_lint()
				end,
			})
		end,
	},
	{
		"arnamak/stay-centered.nvim",
		event = { "BufRead", "BufNewFile" },
		opts = {
			skip_filetypes = {},
		},
	},
}

return plugins
