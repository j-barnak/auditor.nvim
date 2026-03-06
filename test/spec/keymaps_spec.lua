-- test/spec/keymaps_spec.lua
-- Tests for configurable keymaps via setup({ keymaps = ... })

local function reset_modules()
  for _, m in ipairs({ "auditor", "auditor.init", "auditor.db", "auditor.highlights", "auditor.ts" }) do
    package.loaded[m] = nil
  end
end

-- Check if a normal-mode keymap exists for a given lhs.
---@param lhs string
---@return vim.api.keyset.keymap?
local function get_nmap(lhs)
  local maps = vim.api.nvim_get_keymap("n")
  for _, m in ipairs(maps) do
    if m.lhs == lhs or m.lhs == vim.api.nvim_replace_termcodes(lhs, true, true, true) then
      return m
    end
  end
  return nil
end

-- Delete a normal-mode keymap if it exists (cleanup helper).
local function del_nmap(lhs)
  pcall(vim.keymap.del, "n", lhs)
end

-- All default LHS values.
local DEFAULT_MAPS = {
  "<leader>ar",
  "<leader>ab",
  "<leader>ah",
  "<leader>am",
  "<leader>aS",
  "<leader>aX",
}

-- ═══════════════════════════════════════════════════════════════════════════
-- DEFAULTS
-- ═══════════════════════════════════════════════════════════════════════════

describe("keymaps: defaults", function()
  local auditor, tmp_db

  before_each(function()
    reset_modules()
    -- Clean up any lingering keymaps from previous tests
    for _, lhs in ipairs(DEFAULT_MAPS) do
      del_nmap(lhs)
    end
    tmp_db = vim.fn.tempname() .. ".db"
  end)

  after_each(function()
    for _, lhs in ipairs(DEFAULT_MAPS) do
      del_nmap(lhs)
    end
    pcall(os.remove, tmp_db)
  end)

  it("registers all 6 default keymaps when keymaps is true", function()
    auditor = require("auditor")
    auditor.setup({ db_path = tmp_db, keymaps = true })

    for _, lhs in ipairs(DEFAULT_MAPS) do
      assert.not_nil(get_nmap(lhs), "expected keymap for " .. lhs)
    end
  end)

  it("registers all 6 default keymaps when keymaps is nil (omitted)", function()
    auditor = require("auditor")
    auditor.setup({ db_path = tmp_db })

    for _, lhs in ipairs(DEFAULT_MAPS) do
      assert.not_nil(get_nmap(lhs), "expected keymap for " .. lhs)
    end
  end)

  it("default keymaps have correct descriptions", function()
    auditor = require("auditor")
    auditor.setup({ db_path = tmp_db, keymaps = true })

    local expected_descs = {
      ["<leader>ar"] = "Audit: red",
      ["<leader>ab"] = "Audit: blue",
      ["<leader>ah"] = "Audit: half&half",
      ["<leader>am"] = "Audit: pick color",
      ["<leader>aS"] = "Audit: save",
      ["<leader>aX"] = "Audit: clear",
    }

    for lhs, desc in pairs(expected_descs) do
      local m = get_nmap(lhs)
      assert.not_nil(m, "expected keymap for " .. lhs)
      assert.equals(desc, m.desc)
    end
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- DISABLED
-- ═══════════════════════════════════════════════════════════════════════════

describe("keymaps: disabled", function()
  local auditor, tmp_db

  before_each(function()
    reset_modules()
    for _, lhs in ipairs(DEFAULT_MAPS) do
      del_nmap(lhs)
    end
    tmp_db = vim.fn.tempname() .. ".db"
  end)

  after_each(function()
    for _, lhs in ipairs(DEFAULT_MAPS) do
      del_nmap(lhs)
    end
    pcall(os.remove, tmp_db)
  end)

  it("registers no keymaps when keymaps is false", function()
    auditor = require("auditor")
    auditor.setup({ db_path = tmp_db, keymaps = false })

    for _, lhs in ipairs(DEFAULT_MAPS) do
      assert.is_nil(get_nmap(lhs), "unexpected keymap for " .. lhs)
    end
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- OVERRIDES
-- ═══════════════════════════════════════════════════════════════════════════

describe("keymaps: overrides", function()
  local auditor, tmp_db
  local custom_maps = {}

  before_each(function()
    reset_modules()
    for _, lhs in ipairs(DEFAULT_MAPS) do
      del_nmap(lhs)
    end
    custom_maps = {}
    tmp_db = vim.fn.tempname() .. ".db"
  end)

  after_each(function()
    for _, lhs in ipairs(DEFAULT_MAPS) do
      del_nmap(lhs)
    end
    for _, lhs in ipairs(custom_maps) do
      del_nmap(lhs)
    end
    pcall(os.remove, tmp_db)
  end)

  it("overrides a single default keymap", function()
    custom_maps = { "<leader>mr" }
    auditor = require("auditor")
    auditor.setup({ db_path = tmp_db, keymaps = { red = "<leader>mr" } })

    -- Custom binding exists
    assert.not_nil(get_nmap("<leader>mr"), "expected custom keymap for <leader>mr")
    -- Original is gone (overridden in the defaults table)
    assert.is_nil(get_nmap("<leader>ar"), "default <leader>ar should not be registered")
    -- Other defaults still exist
    assert.not_nil(get_nmap("<leader>ab"))
    assert.not_nil(get_nmap("<leader>aS"))
  end)

  it("overrides multiple default keymaps", function()
    custom_maps = { "<leader>mr", "<leader>mb", "<leader>ms" }
    auditor = require("auditor")
    auditor.setup({
      db_path = tmp_db,
      keymaps = {
        red = "<leader>mr",
        blue = "<leader>mb",
        save = "<leader>ms",
      },
    })

    assert.not_nil(get_nmap("<leader>mr"))
    assert.not_nil(get_nmap("<leader>mb"))
    assert.not_nil(get_nmap("<leader>ms"))
    assert.is_nil(get_nmap("<leader>ar"))
    assert.is_nil(get_nmap("<leader>ab"))
    assert.is_nil(get_nmap("<leader>aS"))
    -- Unchanged defaults still registered
    assert.not_nil(get_nmap("<leader>ah"))
    assert.not_nil(get_nmap("<leader>am"))
    assert.not_nil(get_nmap("<leader>aX"))
  end)

  it("disables a specific default keymap with false", function()
    auditor = require("auditor")
    auditor.setup({ db_path = tmp_db, keymaps = { half = false } })

    assert.is_nil(get_nmap("<leader>ah"), "<leader>ah should be disabled")
    -- Others still exist
    assert.not_nil(get_nmap("<leader>ar"))
    assert.not_nil(get_nmap("<leader>ab"))
    assert.not_nil(get_nmap("<leader>am"))
    assert.not_nil(get_nmap("<leader>aS"))
    assert.not_nil(get_nmap("<leader>aX"))
  end)

  it("disables multiple defaults with false", function()
    auditor = require("auditor")
    auditor.setup({
      db_path = tmp_db,
      keymaps = {
        red = false,
        blue = false,
        half = false,
        mark = false,
        save = false,
        clear = false,
      },
    })

    for _, lhs in ipairs(DEFAULT_MAPS) do
      assert.is_nil(get_nmap(lhs), "expected no keymap for " .. lhs)
    end
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- EXTRA BINDINGS (no defaults)
-- ═══════════════════════════════════════════════════════════════════════════

describe("keymaps: extra bindings", function()
  local auditor, tmp_db
  local extra_maps = {}

  before_each(function()
    reset_modules()
    for _, lhs in ipairs(DEFAULT_MAPS) do
      del_nmap(lhs)
    end
    extra_maps = {}
    tmp_db = vim.fn.tempname() .. ".db"
  end)

  after_each(function()
    for _, lhs in ipairs(DEFAULT_MAPS) do
      del_nmap(lhs)
    end
    for _, lhs in ipairs(extra_maps) do
      del_nmap(lhs)
    end
    pcall(os.remove, tmp_db)
  end)

  it("binds word_red when provided", function()
    extra_maps = { "<leader>wr" }
    auditor = require("auditor")
    auditor.setup({ db_path = tmp_db, keymaps = { word_red = "<leader>wr" } })

    local m = get_nmap("<leader>wr")
    assert.not_nil(m, "expected keymap for <leader>wr")
    assert.equals("Audit: word red", m.desc)
  end)

  it("binds word_blue when provided", function()
    extra_maps = { "<leader>wb" }
    auditor = require("auditor")
    auditor.setup({ db_path = tmp_db, keymaps = { word_blue = "<leader>wb" } })

    assert.not_nil(get_nmap("<leader>wb"))
  end)

  it("binds word_half when provided", function()
    extra_maps = { "<leader>wh" }
    auditor = require("auditor")
    auditor.setup({ db_path = tmp_db, keymaps = { word_half = "<leader>wh" } })

    assert.not_nil(get_nmap("<leader>wh"))
  end)

  it("binds word_mark when provided", function()
    extra_maps = { "<leader>wm" }
    auditor = require("auditor")
    auditor.setup({ db_path = tmp_db, keymaps = { word_mark = "<leader>wm" } })

    assert.not_nil(get_nmap("<leader>wm"))
  end)

  it("binds enter when provided", function()
    extra_maps = { "<leader>ae" }
    auditor = require("auditor")
    auditor.setup({ db_path = tmp_db, keymaps = { enter = "<leader>ae" } })

    local m = get_nmap("<leader>ae")
    assert.not_nil(m, "expected keymap for <leader>ae")
    assert.equals("Audit: enter mode", m.desc)
  end)

  it("binds exit when provided", function()
    extra_maps = { "<leader>ax" }
    auditor = require("auditor")
    auditor.setup({ db_path = tmp_db, keymaps = { exit = "<leader>ax" } })

    local m = get_nmap("<leader>ax")
    assert.not_nil(m, "expected keymap for <leader>ax")
    assert.equals("Audit: exit mode", m.desc)
  end)

  it("binds toggle when provided", function()
    extra_maps = { "<leader>at" }
    auditor = require("auditor")
    auditor.setup({ db_path = tmp_db, keymaps = { toggle = "<leader>at" } })

    local m = get_nmap("<leader>at")
    assert.not_nil(m, "expected keymap for <leader>at")
    assert.equals("Audit: toggle mode", m.desc)
  end)

  it("binds undo when provided", function()
    extra_maps = { "<leader>au" }
    auditor = require("auditor")
    auditor.setup({ db_path = tmp_db, keymaps = { undo = "<leader>au" } })

    local m = get_nmap("<leader>au")
    assert.not_nil(m, "expected keymap for <leader>au")
    assert.equals("Audit: undo highlight", m.desc)
  end)

  it("binds all extras alongside defaults", function()
    extra_maps = {
      "<leader>wr",
      "<leader>wb",
      "<leader>wh",
      "<leader>wm",
      "<leader>ae",
      "<leader>ax",
      "<leader>at",
      "<leader>au",
    }
    auditor = require("auditor")
    auditor.setup({
      db_path = tmp_db,
      keymaps = {
        word_red = "<leader>wr",
        word_blue = "<leader>wb",
        word_half = "<leader>wh",
        word_mark = "<leader>wm",
        enter = "<leader>ae",
        exit = "<leader>ax",
        toggle = "<leader>at",
        undo = "<leader>au",
      },
    })

    -- Defaults still registered
    for _, lhs in ipairs(DEFAULT_MAPS) do
      assert.not_nil(get_nmap(lhs), "expected default keymap for " .. lhs)
    end
    -- Extras registered
    for _, lhs in ipairs(extra_maps) do
      assert.not_nil(get_nmap(lhs), "expected extra keymap for " .. lhs)
    end
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- FUNCTIONAL: keymaps actually trigger the right actions
-- ═══════════════════════════════════════════════════════════════════════════

describe("keymaps: functional", function()
  local auditor, hl, tmp_db

  before_each(function()
    reset_modules()
    for _, lhs in ipairs(DEFAULT_MAPS) do
      del_nmap(lhs)
    end
    tmp_db = vim.fn.tempname() .. ".db"
    auditor = require("auditor")
    auditor.setup({ db_path = tmp_db, keymaps = true })
    hl = require("auditor.highlights")
  end)

  after_each(function()
    for _, lhs in ipairs(DEFAULT_MAPS) do
      del_nmap(lhs)
    end
    pcall(os.remove, tmp_db)
  end)

  it("<leader>ar triggers highlight_cword_buffer('red')", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    local filepath = vim.fn.tempname() .. ".lua"
    vim.api.nvim_buf_set_name(bufnr, filepath)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })
    vim.api.nvim_set_current_buf(bufnr)
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    -- Execute the mapped keys
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<leader>ar", true, true, true),
      "x",
      false
    )

    local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, { details = true })
    assert.equals(1, #marks)
    assert.equals("AuditorRed", marks[1][4].hl_group)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    pcall(os.remove, filepath)
  end)

  it("<leader>ab triggers highlight_cword_buffer('blue')", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })
    vim.api.nvim_set_current_buf(bufnr)
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<leader>ab", true, true, true),
      "x",
      false
    )

    local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, { details = true })
    assert.equals(1, #marks)
    assert.equals("AuditorBlue", marks[1][4].hl_group)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("<leader>aS triggers audit() (save)", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    local filepath = vim.fn.tempname() .. ".lua"
    vim.api.nvim_buf_set_name(bufnr, filepath)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })
    vim.api.nvim_set_current_buf(bufnr)
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")

    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<leader>aS", true, true, true),
      "x",
      false
    )

    local db = require("auditor.db")
    assert.is_true(#db.get_highlights(filepath) >= 1)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    pcall(os.remove, filepath)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- FUNCTIONAL: custom-mapped extras work
-- ═══════════════════════════════════════════════════════════════════════════

describe("keymaps: custom extras functional", function()
  local auditor, hl, tmp_db
  local extra_maps = { "<leader>wr", "<leader>ae", "<leader>at", "<leader>au" }

  before_each(function()
    reset_modules()
    for _, lhs in ipairs(DEFAULT_MAPS) do
      del_nmap(lhs)
    end
    for _, lhs in ipairs(extra_maps) do
      del_nmap(lhs)
    end
    tmp_db = vim.fn.tempname() .. ".db"
    auditor = require("auditor")
    auditor.setup({
      db_path = tmp_db,
      keymaps = {
        word_red = "<leader>wr",
        enter = "<leader>ae",
        toggle = "<leader>at",
        undo = "<leader>au",
      },
    })
    hl = require("auditor.highlights")
  end)

  after_each(function()
    for _, lhs in ipairs(DEFAULT_MAPS) do
      del_nmap(lhs)
    end
    for _, lhs in ipairs(extra_maps) do
      del_nmap(lhs)
    end
    pcall(os.remove, tmp_db)
  end)

  it("<leader>ae triggers enter_audit_mode", function()
    assert.is_false(auditor._audit_mode)

    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<leader>ae", true, true, true),
      "x",
      false
    )

    assert.is_true(auditor._audit_mode)
  end)

  it("<leader>wr triggers highlight_cword('red') (all occurrences)", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "foo bar foo" })
    vim.api.nvim_set_current_buf(bufnr)
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<leader>wr", true, true, true),
      "x",
      false
    )

    local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, {})
    assert.equals(2, #marks, "expected 2 occurrences of 'foo' via word_red")

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("<leader>at triggers toggle_audit_mode", function()
    assert.is_false(auditor._audit_mode)

    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<leader>at", true, true, true),
      "x",
      false
    )
    assert.is_true(auditor._audit_mode)

    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<leader>at", true, true, true),
      "x",
      false
    )
    assert.is_false(auditor._audit_mode)
  end)

  it("<leader>au triggers undo_at_cursor", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })
    vim.api.nvim_set_current_buf(bufnr)
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")

    local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, {})
    assert.equals(1, #marks)

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<leader>au", true, true, true),
      "x",
      false
    )

    marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, {})
    assert.equals(0, #marks)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- EDGE CASES
-- ═══════════════════════════════════════════════════════════════════════════

describe("keymaps: edge cases", function()
  local tmp_db

  before_each(function()
    reset_modules()
    for _, lhs in ipairs(DEFAULT_MAPS) do
      del_nmap(lhs)
    end
    tmp_db = vim.fn.tempname() .. ".db"
  end)

  after_each(function()
    for _, lhs in ipairs(DEFAULT_MAPS) do
      del_nmap(lhs)
    end
    pcall(os.remove, tmp_db)
  end)

  it("empty keymaps table uses all defaults", function()
    local auditor = require("auditor")
    auditor.setup({ db_path = tmp_db, keymaps = {} })

    for _, lhs in ipairs(DEFAULT_MAPS) do
      assert.not_nil(get_nmap(lhs), "expected default keymap for " .. lhs)
    end
  end)

  it("unknown keys in keymaps table are ignored (no error)", function()
    assert.has_no.errors(function()
      local auditor = require("auditor")
      auditor.setup({ db_path = tmp_db, keymaps = { nonexistent_action = "<leader>zz" } })
    end)
    -- Defaults still registered
    assert.not_nil(get_nmap("<leader>ar"))
  end)

  it("override + disable in same call", function()
    local custom = "<leader>mr"
    local auditor = require("auditor")
    auditor.setup({
      db_path = tmp_db,
      keymaps = {
        red = custom,
        blue = false,
      },
    })

    assert.not_nil(get_nmap(custom))
    assert.is_nil(get_nmap("<leader>ar"), "original red should not be registered")
    assert.is_nil(get_nmap("<leader>ab"), "blue should be disabled")
    assert.not_nil(get_nmap("<leader>ah"), "half should still be default")

    del_nmap(custom)
  end)
end)
