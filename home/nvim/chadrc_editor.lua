--  ok so this function modifies our chadrc file to show the dash
-- Occasionally nvchad will change the old chadrc file, which means our wedge to put in the dash will fail.
-- Not only that but because we load with nix now nix makes the chadrc unwriteable if we just home.file in what we want
-- So, we have to have this function here that every time we load it looks if the nvdash is there and if it isn't it writes it.
-- This lets us use the theme checker too.
-- And with this we have removed all conflicting lua files so nvchad loads fully on first start with the doubel HM run.

local function modify_chadrc()
	-- File path to the chadrc.lua
	local chadrc_path = vim.fn.expand("~/.config/nvim/lua/chadrc.lua")

	-- Open the file for reading
	local file = io.open(chadrc_path, "r")
	if not file then
		print("Could not open chadrc.lua")
		return
	end

	-- Read the entire file
	local content = file:read("*all")
	file:close()

	-- Check if the nvdash config already exists
	if not content:find("M.nvdash") then
		-- Insert the nvdash config before return M
		content = content:gsub(
			"return M",
			[[
M.nvdash = {
    load_on_startup = true, -- Enable nvdash on startup
}

return M]]
		)

		-- Open the file for writing (overwrite mode)
		file = io.open(chadrc_path, "w")
		if file then
			file:write(content)
			file:close()
			-- print("chadrc.lua updated successfully")
		else
			-- print("Could not open chadrc.lua for writing")
		end
	else
		-- print("nvdash config already exists")
	end
end

-- Run the function to modify chadrc.lua
modify_chadrc()
