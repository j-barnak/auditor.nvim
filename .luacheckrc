cache = true
std = "luajit"
codes = true
self = false

-- Match stylua column_width.
max_line_length = 120

-- Neovim sets vim.wo.* fields that luacheck considers read-only globals.
ignore = { "122" }

-- vim is a global injected by Neovim's Lua runtime.
read_globals = { "vim" }

-- Only check plugin and test code, not cloned deps.
exclude_files = { "deps/" }

-- Test files additionally have busted globals available.
files["test/spec/**/*.lua"] = {
  std = "luajit+busted",
}
