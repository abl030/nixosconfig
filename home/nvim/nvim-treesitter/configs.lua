-- TODO: Remove this shim once NvChad (or upstream config) stops requiring
-- `nvim-treesitter.configs`. The module was renamed to `nvim-treesitter.config`,
-- so this keeps the old require path working until upstream updates.
return require("nvim-treesitter.config")
