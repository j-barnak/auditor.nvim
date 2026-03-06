-- auditor/health.lua
-- :checkhealth auditor
-- Verifies that all runtime dependencies are satisfied and that the plugin
-- is configured correctly.

local M = {}

function M.check()
  vim.health.start("auditor.nvim")

  -- ── Neovim version ──────────────────────────────────────────────────────────
  if vim.fn.has("nvim-0.9") == 1 then
    vim.health.ok("Neovim >= 0.9")
  else
    vim.health.error("Neovim >= 0.9 is required")
  end

  -- ── sqlite.lua ──────────────────────────────────────────────────────────────
  local sqlite_ok, sqlite = pcall(require, "sqlite")
  if sqlite_ok then
    vim.health.ok("sqlite.lua is installed")
  else
    vim.health.error("sqlite.lua not found", {
      "Add 'kkharji/sqlite.lua' to your plugin dependencies",
      "Run :Lazy sync to install it",
    })
  end

  -- ── libsqlite3 (native library) ─────────────────────────────────────────────
  if sqlite_ok then
    local db_ok = pcall(function()
      local db = sqlite({ uri = ":memory:", _test = { id = true } })
      db._test:insert({})
    end)
    if db_ok then
      vim.health.ok("libsqlite3 native library is functional")
    else
      vim.health.error("libsqlite3 is missing or non-functional", {
        "Debian/Ubuntu: sudo apt install libsqlite3-dev",
        "macOS:         brew install sqlite",
        "Arch:          sudo pacman -S sqlite",
      })
    end
  end

  -- ── treesitter (optional) ───────────────────────────────────────────────────
  if vim.treesitter and vim.treesitter.get_parser then
    vim.health.ok("treesitter API available — enhanced token extraction enabled")
    vim.health.info("Tip: install parsers with :TSInstall <lang> for richer token boundaries")
  else
    vim.health.warn("treesitter API not available", {
      "Token extraction will use the regex ([%w_]) fallback",
      "This still works correctly for all file types",
    })
  end

  -- ── setup() called ──────────────────────────────────────────────────────────
  if vim.g.auditor_setup_done then
    vim.health.ok("auditor.setup() has been called")
  else
    vim.health.warn("auditor.setup() has not been called yet", {
      "Add require('auditor').setup() to your Neovim config",
    })
  end

  -- ── audit mode status ────────────────────────────────────────────────────────
  local auditor_ok, auditor = pcall(require, "auditor")
  if auditor_ok and vim.g.auditor_setup_done then
    if auditor._audit_mode then
      vim.health.ok("Audit mode is ACTIVE — highlights are visible, marking commands are enabled")
    else
      vim.health.info(
        "Audit mode is INACTIVE — run :EnterAuditMode to show highlights and enable commands"
      )
    end
  end

  -- ── data directory ──────────────────────────────────────────────────────────
  local data_dir = vim.fn.stdpath("data") .. "/auditor"
  if vim.fn.isdirectory(data_dir) == 1 then
    if vim.fn.filewritable(data_dir) == 2 then
      vim.health.ok(string.format("Data directory is writable: %s", data_dir))
    else
      vim.health.error(string.format("Data directory is NOT writable: %s", data_dir))
    end
  else
    vim.health.info(
      string.format("Data directory does not exist yet (created on first setup): %s", data_dir)
    )
  end

  -- ── database file ──────────────────────────────────────────────────────────
  if vim.g.auditor_setup_done then
    local db_ok, db_mod = pcall(require, "auditor.db")
    if db_ok and db_mod._db_path then
      local size = vim.fn.getfsize(db_mod._db_path)
      if size >= 0 then
        vim.health.ok(string.format("DB file: %s (%d bytes)", db_mod._db_path, size))
      else
        vim.health.warn(string.format("DB file not found on disk: %s", db_mod._db_path))
      end
    end
  end

  -- ── pending highlights ──────────────────────────────────────────────────────
  if auditor_ok and vim.g.auditor_setup_done then
    local pending_count = 0
    for _, entries in pairs(auditor._pending) do
      for _, entry in ipairs(entries) do
        pending_count = pending_count + #entry.words
      end
    end
    if pending_count > 0 then
      vim.health.warn(
        string.format("%d pending highlight(s) not yet saved — run :AuditSave", pending_count)
      )
    else
      vim.health.ok("No unsaved pending highlights")
    end
  end

  vim.health.info(
    string.format(
      "Databases are stored in %s — never inside your project, so :AuditSave produces no git diffs",
      data_dir
    )
  )
end

return M
