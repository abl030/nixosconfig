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
		-- nvim-lint plugin
		"mfussenegger/nvim-lint",
		enabled = true,
		event = "VeryLazy",
		config = function()
			-- Function to check if the current directory is 'Diary'
			local function is_in_diary_directory()
				local cwd = vim.loop.cwd() -- Get current working directory
				return vim.fn.fnamemodify(cwd, ":t") == "Diary"
			end

			-- Linter setup
			require("lint").linters_by_ft = {
				markdown = { "markdownlint" },
				yaml = { "yamllint" },
				nix = { "nix" },
				-- json = { "jsonlint" },
			}

			-- Autocmd for linting on BufWritePost, but skip if in 'Diary' directory
			vim.api.nvim_create_autocmd({ "BufWritePost" }, {
				callback = function()
					if not is_in_diary_directory() then
						require("lint").try_lint()
					end
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

	-- Tabby plugin
	-- {
	-- 	"TabbyML/vim-tabby",
	-- 	lazy = false,
	-- 	dependencies = {
	-- 		"neovim/nvim-lspconfig",
	-- 	},
	-- 	init = function()
	-- 		vim.g.tabby_agent_start_command = { "npx", "tabby-agent", "--stdio" }
	-- 		vim.g.tabby_inline_completion_trigger = "auto"
	-- 	end,
	-- },
	-- Codeium
	-- {
	-- 	"Exafunction/codeium.vim",
	-- 	event = "BufEnter",
	-- },
	{
		"supermaven-inc/supermaven-nvim",
		event = "BufEnter",
		config = function()
			require("supermaven-nvim").setup({
				-- disable supermaven for markdown files
				ignore_filetypes = { "markdown" },
			})
		end,
	},
}

return plugins
