-- Check if the current working directory is called 'Diary'
local function is_in_diary_directory()
	local cwd = vim.loop.cwd() -- Get current working directory
	return vim.fn.fnamemodify(cwd, ":t") == "Diary" -- Get the last part of the path
end

-- Autocmd for Markdown files
vim.api.nvim_create_autocmd("FileType", {
	pattern = "markdown",
	callback = function()
		if is_in_diary_directory() then
			-- Enable spell checking
			vim.opt_local.spell = true

			-- Disable cmp for the current buffer
			require("cmp").setup.buffer({ enabled = false })
		end
	end,
})

-- Autosave function
local function autosave()
	if is_in_diary_directory() then
		vim.cmd("silent! write") -- Save the file silently without messages
	end
end

-- Autosave on InsertLeave (when you exit insert mode) and BufEnter (when you switch buffers)
vim.api.nvim_create_autocmd({ "InsertLeave", "BufEnter" }, {
	callback = autosave,
})

-- -- Autosave when a new line is added
-- vim.api.nvim_create_autocmd("TextChanged", {
-- 	callback = function()
-- 		if is_in_diary_directory() then
-- 			local last_char = vim.fn.getline("."):sub(-1)
-- 			if last_char == "\n" then -- Only save if the last character is a newline
-- 				autosave()
-- 			end
-- 		end
-- 	end,
-- })

-- Optional: Autosave after idle time (CursorHold event)
vim.opt.updatetime = 300 -- Set idle time before CursorHold triggers (milliseconds)
vim.api.nvim_create_autocmd("CursorHold", {
	callback = autosave,
})
