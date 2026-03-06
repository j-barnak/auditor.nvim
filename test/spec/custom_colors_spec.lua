-- test/spec/custom_colors_spec.lua
-- Tests for the extensible color system: custom solid and gradient colors.

local function reset_modules()
  for _, m in ipairs({ "auditor", "auditor.init", "auditor.db", "auditor.highlights", "auditor.ts" }) do
    package.loaded[m] = nil
  end
end

local function make_buf(lines, name)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local filepath = name or (vim.fn.tempname() .. ".lua")
  vim.api.nvim_buf_set_name(bufnr, filepath)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr, filepath
end

local function get_marks(bufnr, ns)
  return vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- Default colors: backward compatibility
-- ═══════════════════════════════════════════════════════════════════════════════

describe("custom colors: defaults", function()
  local hl

  before_each(function()
    reset_modules()
    hl = require("auditor.highlights")
    hl.setup() -- no args = DEFAULT_COLORS
  end)

  it("registers red as solid", function()
    assert.is_true(hl.is_registered("red"))
    assert.is_false(hl.is_gradient("red"))
  end)

  it("registers blue as solid", function()
    assert.is_true(hl.is_registered("blue"))
    assert.is_false(hl.is_gradient("blue"))
  end)

  it("registers half as gradient", function()
    assert.is_true(hl.is_registered("half"))
    assert.is_true(hl.is_gradient("half"))
  end)

  it("unknown colors are not registered", function()
    assert.is_false(hl.is_registered("green"))
    assert.is_false(hl.is_gradient("green"))
  end)

  it("creates AuditorRed and AuditorBlue hl groups", function()
    local red = vim.api.nvim_get_hl(0, { name = "AuditorRed" })
    local blue = vim.api.nvim_get_hl(0, { name = "AuditorBlue" })
    assert.is_not_nil(red.bg)
    assert.is_not_nil(blue.bg)
    assert.is_true(red.bold)
    assert.is_true(blue.bold)
  end)

  it("creates AuditorGrad00..15 for half", function()
    for i = 0, hl._GRAD_STEPS - 1 do
      local name = string.format("AuditorGrad%02d", i)
      local g = vim.api.nvim_get_hl(0, { name = name })
      assert.is_not_nil(g.bg, name .. " should have bg")
    end
  end)

  it("color registry has exactly 3 entries", function()
    local count = 0
    for _ in pairs(hl._color_registry) do
      count = count + 1
    end
    assert.equals(3, count)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Custom solid colors
-- ═══════════════════════════════════════════════════════════════════════════════

describe("custom colors: solid registration", function()
  local hl

  before_each(function()
    reset_modules()
    hl = require("auditor.highlights")
    hl.setup({
      { name = "red", label = "Red", hl = { bg = "#CC0000", fg = "#FFFFFF", bold = true } },
      { name = "green", label = "Green", hl = { bg = "#00CC00", fg = "#FFFFFF", bold = true } },
      { name = "yellow", label = "Yellow", hl = { bg = "#CCCC00", fg = "#000000", bold = false } },
    })
  end)

  it("registers all custom solid colors", function()
    assert.is_true(hl.is_registered("red"))
    assert.is_true(hl.is_registered("green"))
    assert.is_true(hl.is_registered("yellow"))
    assert.is_false(hl.is_gradient("green"))
    assert.is_false(hl.is_gradient("yellow"))
  end)

  it("does not register colors not in the list", function()
    assert.is_false(hl.is_registered("blue"))
    assert.is_false(hl.is_registered("half"))
  end)

  it("creates AuditorGreen hl group", function()
    local g = vim.api.nvim_get_hl(0, { name = "AuditorGreen" })
    assert.is_not_nil(g.bg)
    assert.is_true(g.bold)
  end)

  it("creates AuditorYellow with correct attrs", function()
    local y = vim.api.nvim_get_hl(0, { name = "AuditorYellow" })
    assert.is_not_nil(y.bg)
    -- bold = false means nvim returns nil for bold
    assert.is_not_true(y.bold)
  end)

  it("apply_words works with custom solid color", function()
    local bufnr = make_buf({ "hello world" })
    local ids = hl.apply_words(bufnr, { { line = 0, col_start = 0, col_end = 5 } }, "green")
    assert.equals(1, #ids)

    local marks = get_marks(bufnr, hl.ns)
    assert.equals(1, #marks)
    assert.equals("AuditorGreen", marks[1][4].hl_group)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("collect_extmarks resolves custom solid color", function()
    local bufnr = make_buf({ "hello" })
    hl.apply_words(bufnr, { { line = 0, col_start = 0, col_end = 5 } }, "green")

    local collected = hl.collect_extmarks(bufnr)
    assert.equals(1, #collected)
    assert.equals("green", collected[1].color)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("apply_word works with custom solid color", function()
    local bufnr = make_buf({ "hello" })
    local id = hl.apply_word(bufnr, 0, 0, 5, "green", 1)
    assert.is_not_nil(id)

    local marks = get_marks(bufnr, hl.ns)
    assert.equals("AuditorGreen", marks[1][4].hl_group)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("apply_words returns empty for unregistered color", function()
    local bufnr = make_buf({ "hello" })
    local ids = hl.apply_words(bufnr, { { line = 0, col_start = 0, col_end = 5 } }, "blue")
    assert.equals(0, #ids)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("apply_word returns nil for unregistered color", function()
    local bufnr = make_buf({ "hello" })
    local id = hl.apply_word(bufnr, 0, 0, 5, "blue", 1)
    assert.is_nil(id)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Custom gradient colors
-- ═══════════════════════════════════════════════════════════════════════════════

describe("custom colors: gradient registration", function()
  local hl

  before_each(function()
    reset_modules()
    hl = require("auditor.highlights")
    hl.setup({
      { name = "red", label = "Red", hl = { bg = "#CC0000", fg = "#FFFFFF", bold = true } },
      { name = "warm", label = "Warm", gradient = { "#FF0000", "#FFFF00" }, hl = { fg = "#000000", bold = true } },
      { name = "cool", label = "Cool", gradient = { "#0000FF", "#00FFFF" } },
    })
  end)

  it("registers custom gradients", function()
    assert.is_true(hl.is_registered("warm"))
    assert.is_true(hl.is_gradient("warm"))
    assert.is_true(hl.is_registered("cool"))
    assert.is_true(hl.is_gradient("cool"))
  end)

  it("creates Auditor<Name>Grad00..15 groups for custom gradients", function()
    for i = 0, hl._GRAD_STEPS - 1 do
      local wname = string.format("AuditorWarmGrad%02d", i)
      local cname = string.format("AuditorCoolGrad%02d", i)
      local wg = vim.api.nvim_get_hl(0, { name = wname })
      local cg = vim.api.nvim_get_hl(0, { name = cname })
      assert.is_not_nil(wg.bg, wname .. " should have bg")
      assert.is_not_nil(cg.bg, cname .. " should have bg")
    end
  end)

  it("custom gradient fg follows hl.fg", function()
    local wg = vim.api.nvim_get_hl(0, { name = "AuditorWarmGrad00" })
    -- fg = "#000000" -> 0
    assert.equals(0, wg.fg)
  end)

  it("custom gradient defaults fg to white when no hl", function()
    local cg = vim.api.nvim_get_hl(0, { name = "AuditorCoolGrad00" })
    -- fg = "#FFFFFF" -> 0xFFFFFF = 16777215
    assert.equals(16777215, cg.fg)
  end)

  it("grad_for_color works for custom gradient", function()
    local first = hl._grad_for_color("warm", 0, 5)
    local last = hl._grad_for_color("warm", 4, 5)
    assert.equals("AuditorWarmGrad00", first)
    assert.equals(string.format("AuditorWarmGrad%02d", hl._GRAD_STEPS - 1), last)
  end)

  it("grad_for_color returns nil for solid colors", function()
    assert.is_nil(hl._grad_for_color("red", 0, 5))
  end)

  it("grad_for_color returns nil for unknown colors", function()
    assert.is_nil(hl._grad_for_color("nonexistent", 0, 5))
  end)

  it("apply_words creates per-character gradient for custom gradient", function()
    local bufnr = make_buf({ "hello" })
    local ids = hl.apply_words(bufnr, { { line = 0, col_start = 0, col_end = 5 } }, "warm")

    assert.equals(1, #ids)
    local marks = get_marks(bufnr, hl.ns)
    -- 5-char word: 1 primary + 4 overlays = 5
    assert.equals(5, #marks)
    -- Primary should be AuditorWarmGrad00
    assert.equals("AuditorWarmGrad00", marks[1][4].hl_group)
    -- Last overlay should be AuditorWarmGrad15
    local last = marks[5][4].hl_group
    assert.equals(string.format("AuditorWarmGrad%02d", hl._GRAD_STEPS - 1), last)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("collect_extmarks resolves custom gradient color name", function()
    local bufnr = make_buf({ "hello" })
    hl.apply_words(bufnr, { { line = 0, col_start = 0, col_end = 5 } }, "warm")

    local collected = hl.collect_extmarks(bufnr)
    assert.equals(1, #collected)
    assert.equals("warm", collected[1].color)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("del_half_pair cleans up custom gradient overlays", function()
    local bufnr = make_buf({ "hello" })
    local ids = hl.apply_words(bufnr, { { line = 0, col_start = 0, col_end = 5 } }, "warm")

    assert.equals(5, #get_marks(bufnr, hl.ns))
    vim.api.nvim_buf_del_extmark(bufnr, hl.ns, ids[1])
    hl.del_half_pair(bufnr, ids[1])
    assert.equals(0, #get_marks(bufnr, hl.ns))

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("1-char word uses midpoint for custom gradient", function()
    local bufnr = make_buf({ "x" })
    hl.apply_words(bufnr, { { line = 0, col_start = 0, col_end = 1 } }, "cool")

    local marks = get_marks(bufnr, hl.ns)
    assert.equals(1, #marks)
    local step = tonumber(marks[1][4].hl_group:match("AuditorCoolGrad(%d+)"))
    assert.equals(math.floor(hl._GRAD_STEPS / 2), step)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Picker integration
-- ═══════════════════════════════════════════════════════════════════════════════

describe("custom colors: picker integration", function()
  it("default setup produces 3 picker entries", function()
    reset_modules()
    local auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })

    assert.equals(3, #auditor._colors)
    assert.equals("Red", auditor._colors[1].label)
    assert.equals("red", auditor._colors[1].color)
    assert.equals("Blue", auditor._colors[2].label)
    assert.equals("blue", auditor._colors[2].color)
    assert.equals("Gradient", auditor._colors[3].label)
    assert.equals("half", auditor._colors[3].color)
  end)

  it("custom colors override picker entries", function()
    reset_modules()
    local auditor = require("auditor")
    auditor.setup({
      db_path = vim.fn.tempname() .. ".db",
      keymaps = false,
      colors = {
        { name = "green", label = "Go Green", hl = { bg = "#00CC00", fg = "#FFFFFF", bold = true } },
        { name = "hot", label = "Hot!", gradient = { "#FF0000", "#FF8800" } },
      },
    })

    assert.equals(2, #auditor._colors)
    assert.equals("Go Green", auditor._colors[1].label)
    assert.equals("green", auditor._colors[1].color)
    assert.equals("Hot!", auditor._colors[2].label)
    assert.equals("hot", auditor._colors[2].color)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- End-to-end with init.lua: custom solid colors
-- ═══════════════════════════════════════════════════════════════════════════════

describe("custom colors: E2E solid", function()
  local auditor, db, hl

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({
      db_path = vim.fn.tempname() .. ".db",
      keymaps = false,
      colors = {
        { name = "red", label = "Red", hl = { bg = "#CC0000", fg = "#FFFFFF", bold = true } },
        { name = "blue", label = "Blue", hl = { bg = "#0055CC", fg = "#FFFFFF", bold = true } },
        { name = "green", label = "Green", hl = { bg = "#00CC00", fg = "#FFFFFF", bold = true } },
        { name = "yellow", label = "Yellow", hl = { bg = "#CCCC00", fg = "#000000", bold = true } },
        { name = "half", label = "Gradient",
          gradient = { "#CC0000", "#0055CC" }, hl = { fg = "#FFFFFF", bold = true } },
      },
    })
    db = require("auditor.db")
    hl = require("auditor.highlights")
  end)

  it("mark custom color → save → reload preserves it", function()
    local bufnr, filepath = make_buf({ "hello world" })
    auditor.enter_audit_mode()

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("green")
    auditor.audit()

    auditor.exit_audit_mode()
    auditor.enter_audit_mode()

    local rows = db.get_highlights(filepath)
    assert.equals(1, #rows)
    assert.equals("green", rows[1].color)

    local marks = get_marks(bufnr, hl.ns)
    assert.equals(1, #marks)
    assert.equals("AuditorGreen", marks[1][4].hl_group)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("undo custom solid color works", function()
    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("yellow")
    assert.equals(1, #get_marks(bufnr, hl.ns))

    auditor.undo_at_cursor()
    assert.equals(0, #get_marks(bufnr, hl.ns))

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("re-mark green → red works", function()
    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("green")
    assert.equals("AuditorGreen", get_marks(bufnr, hl.ns)[1][4].hl_group)

    auditor.highlight_cword_buffer("red")
    local marks = get_marks(bufnr, hl.ns)
    assert.equals(1, #marks)
    assert.equals("AuditorRed", marks[1][4].hl_group)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("mixed custom + built-in colors all persist", function()
    local bufnr, filepath = make_buf({ "aaa bbb ccc ddd" })
    auditor.enter_audit_mode()

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    vim.api.nvim_win_set_cursor(0, { 1, 4 })
    auditor.highlight_cword_buffer("green")
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    auditor.highlight_cword_buffer("yellow")
    vim.api.nvim_win_set_cursor(0, { 1, 12 })
    auditor.highlight_cword_buffer("blue")

    auditor.audit()
    auditor.exit_audit_mode()
    auditor.enter_audit_mode()

    local rows = db.get_highlights(filepath)
    local colors = {}
    for _, r in ipairs(rows) do
      colors[r.color] = (colors[r.color] or 0) + 1
    end
    assert.equals(1, colors["red"])
    assert.equals(1, colors["green"])
    assert.equals(1, colors["yellow"])
    assert.equals(1, colors["blue"])

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("function-scoped highlight with custom color", function()
    local bufnr = make_buf({ "foo bar foo baz foo" })
    auditor.enter_audit_mode()

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword("green")

    local collected = hl.collect_extmarks(bufnr)
    assert.equals(3, #collected)
    for _, c in ipairs(collected) do
      assert.equals("green", c.color)
    end

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("clear_buffer removes custom colors", function()
    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("green")
    vim.api.nvim_win_set_cursor(0, { 1, 6 })
    auditor.highlight_cword_buffer("yellow")
    auditor.audit()

    auditor.clear_buffer()
    assert.equals(0, #get_marks(bufnr, hl.ns))

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- End-to-end: custom gradient colors
-- ═══════════════════════════════════════════════════════════════════════════════

describe("custom colors: E2E gradient", function()
  local auditor, db, hl

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({
      db_path = vim.fn.tempname() .. ".db",
      keymaps = false,
      colors = {
        { name = "red", label = "Red", hl = { bg = "#CC0000", fg = "#FFFFFF", bold = true } },
        { name = "warm", label = "Warm", gradient = { "#FF0000", "#FFFF00" } },
        { name = "cool", label = "Cool", gradient = { "#0000FF", "#00FFFF" } },
      },
    })
    db = require("auditor.db")
    hl = require("auditor.highlights")
  end)

  it("mark custom gradient → save → reload preserves it", function()
    local bufnr, filepath = make_buf({ "hello world" })
    auditor.enter_audit_mode()

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("warm")
    auditor.audit()

    auditor.exit_audit_mode()
    auditor.enter_audit_mode()

    local rows = db.get_highlights(filepath)
    assert.equals(1, #rows)
    assert.equals("warm", rows[1].color)

    -- "hello" = 5 chars → 5 raw extmarks
    local marks = get_marks(bufnr, hl.ns)
    assert.equals(5, #marks)
    assert.equals("AuditorWarmGrad00", marks[1][4].hl_group)

    local collected = hl.collect_extmarks(bufnr)
    assert.equals(1, #collected)
    assert.equals("warm", collected[1].color)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("undo custom gradient removes all overlays", function()
    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("cool")
    assert.equals(5, #get_marks(bufnr, hl.ns))

    auditor.undo_at_cursor()
    assert.equals(0, #get_marks(bufnr, hl.ns))

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("re-mark gradient → solid cleans up gradient", function()
    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("warm")
    assert.equals(5, #get_marks(bufnr, hl.ns))

    auditor.highlight_cword_buffer("red")
    local marks = get_marks(bufnr, hl.ns)
    assert.equals(1, #marks)
    assert.equals("AuditorRed", marks[1][4].hl_group)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("re-mark solid → gradient creates gradient", function()
    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    assert.equals(1, #get_marks(bufnr, hl.ns))

    auditor.highlight_cword_buffer("cool")
    assert.equals(5, #get_marks(bufnr, hl.ns))

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("multiple custom gradients in same buffer", function()
    local bufnr, filepath = make_buf({ "hello world" })
    auditor.enter_audit_mode()

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("warm")
    vim.api.nvim_win_set_cursor(0, { 1, 6 })
    auditor.highlight_cword_buffer("cool")

    auditor.audit()

    local rows = db.get_highlights(filepath)
    local colors = {}
    for _, r in ipairs(rows) do
      colors[r.color] = (colors[r.color] or 0) + 1
    end
    assert.equals(1, colors["warm"])
    assert.equals(1, colors["cool"])

    -- "hello" (5) + "world" (5) = 10 raw extmarks
    assert.equals(10, #get_marks(bufnr, hl.ns))
    local collected = hl.collect_extmarks(bufnr)
    assert.equals(2, #collected)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Override built-in color definitions
-- ═══════════════════════════════════════════════════════════════════════════════

describe("custom colors: override defaults", function()
  local hl

  before_each(function()
    reset_modules()
    hl = require("auditor.highlights")
  end)

  it("can redefine red with a different shade", function()
    hl.setup({
      { name = "red", label = "Bright Red", hl = { bg = "#FF0000", fg = "#FFFFFF", bold = true } },
    })

    local g = vim.api.nvim_get_hl(0, { name = "AuditorRed" })
    -- #FF0000 -> 0xFF0000 = 16711680
    assert.equals(16711680, g.bg)
    assert.is_true(hl.is_registered("red"))
  end)

  it("can replace all defaults with completely custom colors", function()
    hl.setup({
      { name = "pass", label = "Pass", hl = { bg = "#00FF00", fg = "#000000", bold = true } },
      { name = "fail", label = "Fail", hl = { bg = "#FF0000", fg = "#FFFFFF", bold = true } },
      { name = "skip", label = "Skip", hl = { bg = "#888888", fg = "#FFFFFF", bold = false } },
    })

    assert.is_true(hl.is_registered("pass"))
    assert.is_true(hl.is_registered("fail"))
    assert.is_true(hl.is_registered("skip"))
    assert.is_false(hl.is_registered("red"))
    assert.is_false(hl.is_registered("blue"))
    assert.is_false(hl.is_registered("half"))

    local count = 0
    for _ in pairs(hl._color_registry) do
      count = count + 1
    end
    assert.equals(3, count)
  end)

  it("can make red a gradient instead of solid", function()
    hl.setup({
      { name = "red", label = "Red Gradient", gradient = { "#FF0000", "#880000" } },
    })

    assert.is_true(hl.is_gradient("red"))
    -- Creates AuditorRedGrad00..15
    local g = vim.api.nvim_get_hl(0, { name = "AuditorRedGrad00" })
    assert.is_not_nil(g.bg)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Edge cases
-- ═══════════════════════════════════════════════════════════════════════════════

describe("custom colors: edge cases", function()
  local hl

  before_each(function()
    reset_modules()
    hl = require("auditor.highlights")
  end)

  it("empty colors array registers nothing", function()
    hl.setup({})

    assert.is_false(hl.is_registered("red"))
    assert.is_false(hl.is_registered("blue"))

    local count = 0
    for _ in pairs(hl._color_registry) do
      count = count + 1
    end
    assert.equals(0, count)
  end)

  it("single solid color only", function()
    hl.setup({
      { name = "only", label = "Only", hl = { bg = "#AABBCC", fg = "#FFFFFF", bold = true } },
    })

    assert.is_true(hl.is_registered("only"))
    local count = 0
    for _ in pairs(hl._color_registry) do
      count = count + 1
    end
    assert.equals(1, count)
  end)

  it("single gradient color only", function()
    hl.setup({
      { name = "rainbow", label = "Rainbow", gradient = { "#FF0000", "#0000FF" } },
    })

    assert.is_true(hl.is_gradient("rainbow"))
    -- Creates AuditorRainbowGrad00..15
    for i = 0, hl._GRAD_STEPS - 1 do
      local name = string.format("AuditorRainbowGrad%02d", i)
      local g = vim.api.nvim_get_hl(0, { name = name })
      assert.is_not_nil(g.bg, name .. " should exist")
    end
  end)

  it("many colors (10+) all register correctly", function()
    local defs = {}
    for i = 1, 12 do
      local hex = string.format("#%02X%02X%02X", i * 20, i * 10, 255 - i * 20)
      table.insert(defs, {
        name = "color" .. i,
        label = "Color " .. i,
        hl = { bg = hex, fg = "#FFFFFF", bold = true },
      })
    end
    hl.setup(defs)

    for i = 1, 12 do
      assert.is_true(hl.is_registered("color" .. i), "color" .. i .. " should be registered")
    end

    local count = 0
    for _ in pairs(hl._color_registry) do
      count = count + 1
    end
    assert.equals(12, count)
  end)

  it("color name with underscores works", function()
    hl.setup({
      { name = "needs_review", label = "Needs Review", hl = { bg = "#FF8800", fg = "#FFFFFF", bold = true } },
    })

    assert.is_true(hl.is_registered("needs_review"))
    -- Group name: AuditorNeeds_review
    local g = vim.api.nvim_get_hl(0, { name = "AuditorNeeds_review" })
    assert.is_not_nil(g.bg)
  end)

  it("gradient with no hl defaults to white fg and bold", function()
    hl.setup({
      { name = "test", label = "Test", gradient = { "#000000", "#FFFFFF" } },
    })

    local g = vim.api.nvim_get_hl(0, { name = "AuditorTestGrad00" })
    assert.equals(16777215, g.fg) -- #FFFFFF
    assert.is_true(g.bold)
  end)

  it("solid with no hl gets default attrs", function()
    hl.setup({
      { name = "bare", label = "Bare" },
    })

    assert.is_true(hl.is_registered("bare"))
    local g = vim.api.nvim_get_hl(0, { name = "AuditorBare" })
    assert.is_not_nil(g.bg) -- fallback gray
  end)

  it("hl_group_to_color reverse map is correct", function()
    hl.setup({
      { name = "red", label = "Red", hl = { bg = "#CC0000", fg = "#FFFFFF", bold = true } },
      { name = "sunset", label = "Sunset", gradient = { "#FF4500", "#FFD700" } },
    })

    assert.equals("red", hl._hl_group_to_color["AuditorRed"])
    assert.equals("sunset", hl._hl_group_to_color["AuditorSunsetGrad00"])
    assert.equals("sunset", hl._hl_group_to_color["AuditorSunsetGrad15"])
  end)

  it("setup() can be called again (clears old registry)", function()
    hl.setup({
      { name = "alpha", label = "A", hl = { bg = "#AA0000", fg = "#FFFFFF", bold = true } },
    })
    assert.is_true(hl.is_registered("alpha"))

    hl.setup({
      { name = "beta", label = "B", hl = { bg = "#00BB00", fg = "#FFFFFF", bold = true } },
    })
    assert.is_false(hl.is_registered("alpha"))
    assert.is_true(hl.is_registered("beta"))
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Property-based tests
-- ═══════════════════════════════════════════════════════════════════════════════

describe("custom colors: property-based", function()
  local hl

  before_each(function()
    reset_modules()
    hl = require("auditor.highlights")
    hl.setup({
      { name = "solid1", label = "S1", hl = { bg = "#FF0000", fg = "#FFFFFF", bold = true } },
      { name = "solid2", label = "S2", hl = { bg = "#00FF00", fg = "#000000", bold = true } },
      { name = "grad1", label = "G1", gradient = { "#FF0000", "#FFFF00" } },
      { name = "grad2", label = "G2", gradient = { "#0000FF", "#00FFFF" } },
    })
  end)

  it("property: solid color always creates exactly 1 extmark per word", function()
    for word_len = 1, 15 do
      local word = string.rep("x", word_len)
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { word })

      hl.apply_words(bufnr, { { line = 0, col_start = 0, col_end = word_len } }, "solid1")
      assert.equals(1, #get_marks(bufnr, hl.ns), "word_len=" .. word_len)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end)

  it("property: custom gradient N chars = N extmarks", function()
    for word_len = 1, 20 do
      local word = string.rep("x", word_len)
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { word })
      hl.clear_half_pairs(bufnr)

      hl.apply_words(bufnr, { { line = 0, col_start = 0, col_end = word_len } }, "grad1")
      assert.equals(word_len, #get_marks(bufnr, hl.ns), "word_len=" .. word_len)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end)

  it("property: custom gradient collect_extmarks = 1 per word", function()
    for word_len = 1, 20 do
      local word = string.rep("x", word_len)
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { word })
      hl.clear_half_pairs(bufnr)

      hl.apply_words(bufnr, { { line = 0, col_start = 0, col_end = word_len } }, "grad2")
      local collected = hl.collect_extmarks(bufnr)
      assert.equals(1, #collected, "word_len=" .. word_len)
      assert.equals("grad2", collected[1].color)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end)

  it("property: custom gradient monotonicity", function()
    for word_len = 2, 20 do
      local word = string.rep("x", word_len)
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { word })
      hl.clear_half_pairs(bufnr)

      hl.apply_words(bufnr, { { line = 0, col_start = 0, col_end = word_len } }, "grad1")
      local marks = get_marks(bufnr, hl.ns)

      local prev_step = -1
      for _, m in ipairs(marks) do
        local step = tonumber(m[4].hl_group:match("AuditorGrad1Grad(%d+)"))
        assert(step, "expected AuditorGrad1Grad group, got " .. tostring(m[4].hl_group))
        assert(step >= prev_step, string.format("non-monotonic at word_len=%d", word_len))
        prev_step = step
      end

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end)

  it("property: mixed solid and gradient collect correctly", function()
    for n = 1, 8 do
      local parts = {}
      local words_s1 = {}
      local words_g1 = {}
      local col = 0
      for i = 1, n do
        local w = string.rep(string.char(96 + i), 3)
        parts[#parts + 1] = w
        if i % 2 == 1 then
          words_s1[#words_s1 + 1] = { line = 0, col_start = col, col_end = col + 3 }
        else
          words_g1[#words_g1 + 1] = { line = 0, col_start = col, col_end = col + 3 }
        end
        col = col + 4
      end

      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { table.concat(parts, " ") })
      hl.clear_half_pairs(bufnr)

      hl.apply_words(bufnr, words_s1, "solid1")
      hl.apply_words(bufnr, words_g1, "grad1")

      local collected = hl.collect_extmarks(bufnr)
      assert.equals(n, #collected, "n=" .. n)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Fuzz tests
-- ═══════════════════════════════════════════════════════════════════════════════

describe("custom colors: fuzz", function()
  local hl

  before_each(function()
    reset_modules()
    hl = require("auditor.highlights")
    hl.setup({
      { name = "s1", label = "S1", hl = { bg = "#FF0000", fg = "#FFFFFF", bold = true } },
      { name = "s2", label = "S2", hl = { bg = "#00FF00", fg = "#000000", bold = true } },
      { name = "g1", label = "G1", gradient = { "#FF0000", "#FFFF00" } },
      { name = "g2", label = "G2", gradient = { "#0000FF", "#00FFFF" } },
    })
  end)

  it("fuzz: 200 random apply/collect operations never crash", function()
    math.randomseed(99)
    local colors = { "s1", "s2", "g1", "g2" }

    for _ = 1, 200 do
      local n_words = math.random(1, 6)
      local parts = {}
      local words = {}
      local col = 0
      for i = 1, n_words do
        local len = math.random(1, 8)
        parts[i] = string.rep("a", len)
        words[i] = { line = 0, col_start = col, col_end = col + len }
        col = col + len + 1
      end

      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { table.concat(parts, " ") })
      hl.clear_half_pairs(bufnr)

      local color = colors[math.random(1, #colors)]
      local ok, err = pcall(function()
        local ids = hl.apply_words(bufnr, words, color)
        local collected = hl.collect_extmarks(bufnr)
        assert.equals(#ids, #collected)
      end)
      assert(ok, "crash: " .. tostring(err))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end)

  it("fuzz: random color definitions never crash setup", function()
    math.randomseed(77)

    for _ = 1, 50 do
      local defs = {}
      local n = math.random(1, 8)
      for i = 1, n do
        local hex1 = string.format("#%02X%02X%02X", math.random(0, 255), math.random(0, 255), math.random(0, 255))
        local hex2 = string.format("#%02X%02X%02X", math.random(0, 255), math.random(0, 255), math.random(0, 255))
        if math.random() > 0.5 then
          table.insert(defs, {
            name = "c" .. i,
            label = "Color " .. i,
            gradient = { hex1, hex2 },
          })
        else
          table.insert(defs, {
            name = "c" .. i,
            label = "Color " .. i,
            hl = { bg = hex1, fg = hex2, bold = math.random() > 0.5 },
          })
        end
      end

      local ok, err = pcall(hl.setup, defs)
      assert(ok, "setup crash: " .. tostring(err))

      -- Verify all registered
      for i = 1, n do
        assert.is_true(hl.is_registered("c" .. i))
      end
    end
  end)

  it("fuzz: mixed operations with custom colors on real buffer", function()
    math.randomseed(42)
    local auditor
    reset_modules()
    auditor = require("auditor")
    auditor.setup({
      db_path = vim.fn.tempname() .. ".db",
      keymaps = false,
      colors = {
        { name = "red", label = "R", hl = { bg = "#CC0000", fg = "#FFFFFF", bold = true } },
        { name = "green", label = "G", hl = { bg = "#00CC00", fg = "#FFFFFF", bold = true } },
        { name = "warm", label = "W", gradient = { "#FF0000", "#FFFF00" } },
      },
    })
    hl = require("auditor.highlights")

    local bufnr = make_buf({ "alpha bravo charlie delta echo foxtrot" })
    auditor.enter_audit_mode()

    local color_names = { "red", "green", "warm" }
    local positions = {
      { 1, 0 }, { 1, 6 }, { 1, 12 }, { 1, 20 }, { 1, 26 }, { 1, 31 },
    }

    for _ = 1, 50 do
      local pos = positions[math.random(1, #positions)]
      vim.api.nvim_win_set_cursor(0, pos)
      local color = color_names[math.random(1, #color_names)]
      local op = math.random(1, 3)
      if op == 1 then
        pcall(auditor.highlight_cword_buffer, color)
      elseif op == 2 then
        pcall(auditor.undo_at_cursor)
      else
        pcall(auditor.audit)
      end
    end

    -- Should not crash
    local ok = pcall(hl.collect_extmarks, bufnr)
    assert.is_true(ok)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Gradient endpoints: first step matches from color, last matches to color
-- ═══════════════════════════════════════════════════════════════════════════════

describe("custom colors: gradient endpoints", function()
  local hl

  before_each(function()
    reset_modules()
    hl = require("auditor.highlights")
  end)

  it("first gradient step bg matches from color", function()
    hl.setup({
      { name = "test", label = "T", gradient = { "#FF0000", "#0000FF" } },
    })
    local g = vim.api.nvim_get_hl(0, { name = "AuditorTestGrad00" })
    -- #FF0000 = 16711680
    assert.equals(16711680, g.bg)
  end)

  it("last gradient step bg matches to color", function()
    hl.setup({
      { name = "test", label = "T", gradient = { "#FF0000", "#0000FF" } },
    })
    local last = string.format("AuditorTestGrad%02d", hl._GRAD_STEPS - 1)
    local g = vim.api.nvim_get_hl(0, { name = last })
    -- #0000FF = 255
    assert.equals(255, g.bg)
  end)

  it("gradient is smooth (each step differs by small amount)", function()
    hl.setup({
      { name = "smooth", label = "S", gradient = { "#000000", "#FFFFFF" } },
    })

    local prev_bg = nil
    for i = 0, hl._GRAD_STEPS - 1 do
      local name = string.format("AuditorSmoothGrad%02d", i)
      local g = vim.api.nvim_get_hl(0, { name = name })
      if prev_bg then
        -- Each step should increase (black → white)
        assert.is_true(g.bg >= prev_bg, name .. " should be >= previous step")
      end
      prev_bg = g.bg
    end
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Backward compatibility: "half" gradient uses AuditorGrad prefix
-- ═══════════════════════════════════════════════════════════════════════════════

describe("custom colors: half backward compat", function()
  local hl

  before_each(function()
    reset_modules()
    hl = require("auditor.highlights")
    hl.setup() -- defaults include "half"
  end)

  it("half gradient uses AuditorGrad00..15 naming", function()
    for i = 0, hl._GRAD_STEPS - 1 do
      local name = string.format("AuditorGrad%02d", i)
      local g = vim.api.nvim_get_hl(0, { name = name })
      assert.is_not_nil(g.bg, name .. " should exist")
    end
  end)

  it("_grad_groups alias points to half groups", function()
    assert.equals("AuditorGrad00", hl._grad_groups[0])
    assert.equals(string.format("AuditorGrad%02d", hl._GRAD_STEPS - 1),
      hl._grad_groups[hl._GRAD_STEPS - 1])
  end)

  it("_grad_for still works for half", function()
    assert.equals("AuditorGrad00", hl._grad_for(0, 5))
    assert.equals(string.format("AuditorGrad%02d", hl._GRAD_STEPS - 1), hl._grad_for(4, 5))
  end)

  it("custom gradient named something else uses different prefix", function()
    hl.setup({
      { name = "half", label = "Gradient", gradient = { "#CC0000", "#0055CC" } },
      { name = "fire", label = "Fire", gradient = { "#FF0000", "#FFFF00" } },
    })

    -- "half" still uses AuditorGrad
    assert.equals("AuditorGrad00", hl._grad_groups[0])

    -- "fire" uses AuditorFireGrad
    local reg = hl._color_registry["fire"]
    assert.equals("AuditorFireGrad00", reg.grad_groups[0])

    -- Both coexist
    local g1 = vim.api.nvim_get_hl(0, { name = "AuditorGrad00" })
    local g2 = vim.api.nvim_get_hl(0, { name = "AuditorFireGrad00" })
    assert.is_not_nil(g1.bg)
    assert.is_not_nil(g2.bg)
  end)
end)
