-- This file  needs to have same structure as nvconfig.lua 
-- https://github.com/NvChad/NvChad/blob/v2.5/lua/nvconfig.lua

---@type ChadrcConfig
local M = {}

M.ui = {
	theme = "onedark",

-- This is actually here : https://github.com/NvChad/starter/blob/main/lua/chadrc.lua
  -- We are overiding the ui.lua here and loading the dashboard on startup. 
  -- Because NVChad now loads NVChad as a plugin.
  nvdash = {
    load_on_startup = true,
  }
	-- hl_override = {
	-- 	Comment = { italic = true },
	-- 	["@comment"] = { italic = true },
	-- },
}

return M
