-- lazy.nvim spec for loading auditor.nvim from its local source directory.
return {
  dir = "~/Projects/auditor.nvim",
  dependencies = { "kkharji/sqlite.lua" },
  config = function()
    require("auditor").setup({
      -- db_path    = nil,   -- auto: ~/.local/share/nvim/auditor/<project-hash>.db
      -- node_types = nil,   -- "all" | "named" | { "identifier", "string", ... }
      -- keymaps    = true,  -- set false to disable default <leader>a* maps
    })
  end,
}
