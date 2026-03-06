-- test/minimal_init.lua
-- Minimal Neovim config used by vusted to run the auditor.nvim test suite.
-- Adds the plugin source and its SQLite dependency to the runtime path.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")

-- Plugin source
vim.opt.rtp:prepend(root)

-- sqlite.lua cloned by `make deps`
local sqlite_dep = root .. "/deps/sqlite.lua"
if vim.fn.isdirectory(sqlite_dep) == 1 then
  vim.opt.rtp:prepend(sqlite_dep)
end

vim.opt.swapfile = false
vim.opt.backup = false
