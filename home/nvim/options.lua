-- this will setup our autoconform on save.
vim.api.nvim_create_autocmd("BufWritePre", {
	pattern = "*",
	callback = function(args)
		require("conform").format({ bufnr = args.buf })
	end,
})

-- This just forces nvim to use the clipboard all the time. I am unsure if this is the best method
-- vim.opt.clipboard = "unnamedplus"

--This sources our crusty old vimrc that needs to be updated
vim.cmd("source ~/vim.vim")

-- This keybind finished the swap of : to ; so that we can move through our finds in the buffer.
vim.keymap.set("n", ":", ";", { noremap = true, silent = true })

-- remap leader o to add in a line break but stay in normal mode
vim.api.nvim_set_keymap("n", "<leader>o", "o<Esc>", { noremap = true, silent = true })

-- Require our diary file. This handles spellcheck, turning completion off and our autosave events.
require("diary")

-- Overrides the default behavior of the tab key.
local cmp = require("cmp")

cmp.setup({
	mapping = cmp.mapping.preset.insert({
		-- Always let Tab pass through to supermaven
		["<Tab>"] = cmp.mapping.abort(), -- This tells cmp to completely ignore Tab

		-- Use Enter for cmp selection
		["<CR>"] = cmp.mapping.confirm({ select = true }),

		-- Keep your other existing mappings
		-- ... other mappings ...
	}),
	-- ... rest of your cmp configuration ...
})

-- Function to toggle diagnostics on and off using the correct API
local function toggle_diagnostics()
	-- is_enabled() is not deprecated and is the correct way to check the current state.
	if vim.diagnostic.is_enabled() then
		-- This is the new, non-deprecated way to disable diagnostics globally.
		vim.diagnostic.enable(false)
		print("Diagnostics Disabled")
	else
		-- This enables diagnostics globally.
		vim.diagnostic.enable(true)
		print("Diagnostics Enabled")
	end
end

-- Map Ctrl-l to toggle diagnostics
vim.keymap.set("n", "<leader>dl", toggle_diagnostics, { noremap = true, silent = false, desc = "Toggle Diagnostics" })
