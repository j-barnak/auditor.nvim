-- test/spec/highlights_unit_spec.lua
-- Unit tests for lua/auditor/highlights.lua functions.

local function reset_modules()
  for _, m in ipairs({ "auditor", "auditor.init", "auditor.db", "auditor.highlights", "auditor.ts" }) do
    package.loaded[m] = nil
  end
end

local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- hl_for: color → highlight group mapping
-- ═══════════════════════════════════════════════════════════════════════════════

describe("highlights: hl_for mapping", function()
  local hl

  before_each(function()
    reset_modules()
    hl = require("auditor.highlights")
    hl.setup()
  end)

  it("applies correct hl_group for each color", function()
    local bufnr = make_buf({ "aaa bbb ccc ddd" })

    -- Red always → AuditorRed
    hl.apply_words(bufnr, { { line = 0, col_start = 0, col_end = 3 } }, "red")
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, { details = true })
    assert.equals("AuditorRed", marks[1][4].hl_group)

    vim.api.nvim_buf_clear_namespace(bufnr, hl.ns, 0, -1)
    hl.clear_half_pairs(bufnr)

    -- Blue always → AuditorBlue
    hl.apply_words(bufnr, { { line = 0, col_start = 0, col_end = 3 } }, "blue")
    marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, { details = true })
    assert.equals("AuditorBlue", marks[1][4].hl_group)

    vim.api.nvim_buf_clear_namespace(bufnr, hl.ns, 0, -1)
    hl.clear_half_pairs(bufnr)

    -- Half: each 3-char word gets 1 primary + 2 overlays = 3 extmarks
    hl.apply_words(bufnr, {
      { line = 0, col_start = 0, col_end = 3 },
      { line = 0, col_start = 4, col_end = 7 },
      { line = 0, col_start = 8, col_end = 11 },
    }, "half")
    marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, { details = true })
    -- 3 words × 3 extmarks each = 9 raw extmarks
    assert.equals(9, #marks)
    -- All should be AuditorGrad* groups
    for _, m in ipairs(marks) do
      assert.is_truthy(m[4].hl_group:match("^AuditorGrad"))
    end
    -- collect_extmarks sees 3 logical marks
    local collected = hl.collect_extmarks(bufnr)
    assert.equals(3, #collected)
    for _, c in ipairs(collected) do
      assert.equals("half", c.color)
    end

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- apply_words: edge cases
-- ═══════════════════════════════════════════════════════════════════════════════

describe("highlights: apply_words edge cases", function()
  local hl

  before_each(function()
    reset_modules()
    hl = require("auditor.highlights")
    hl.setup()
  end)

  it("empty words array returns empty ids", function()
    local bufnr = make_buf({ "hello" })
    local ids = hl.apply_words(bufnr, {}, "red")
    assert.same({}, ids)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("skips words where line >= line_count", function()
    local bufnr = make_buf({ "hello" })
    local ids = hl.apply_words(bufnr, {
      { line = 0, col_start = 0, col_end = 5 }, -- valid
      { line = 5, col_start = 0, col_end = 3 }, -- invalid line
    }, "red")
    assert.equals(1, #ids)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("skips words where col_start >= line_len", function()
    local bufnr = make_buf({ "hi" })
    local ids = hl.apply_words(bufnr, {
      { line = 0, col_start = 10, col_end = 15 }, -- past end
    }, "red")
    assert.equals(0, #ids)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("skips words where col_end > line_len", function()
    local bufnr = make_buf({ "hi" })
    local ids = hl.apply_words(bufnr, {
      { line = 0, col_start = 0, col_end = 10 }, -- past end
    }, "red")
    assert.equals(0, #ids)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("returns both ids and applied words", function()
    local bufnr = make_buf({ "hello world" })
    local ids, applied = hl.apply_words(bufnr, {
      { line = 0, col_start = 0, col_end = 5 },
      { line = 0, col_start = 6, col_end = 11 },
    }, "red")
    assert.equals(2, #ids)
    assert.equals(2, #applied)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("partial success: some words applied, some skipped", function()
    local bufnr = make_buf({ "hi" })
    local ids, applied = hl.apply_words(bufnr, {
      { line = 0, col_start = 0, col_end = 2 }, -- valid
      { line = 0, col_start = 5, col_end = 8 }, -- invalid
      { line = 5, col_start = 0, col_end = 3 }, -- invalid line
    }, "red")
    assert.equals(1, #ids)
    assert.equals(1, #applied)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- apply_word: single word edge cases
-- ═══════════════════════════════════════════════════════════════════════════════

describe("highlights: apply_word edge cases", function()
  local hl

  before_each(function()
    reset_modules()
    hl = require("auditor.highlights")
    hl.setup()
  end)

  it("returns nil for line >= line_count", function()
    local bufnr = make_buf({ "hello" })
    local id = hl.apply_word(bufnr, 5, 0, 3, "red", 1)
    assert.is_nil(id)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("returns nil for col_start >= line_len", function()
    local bufnr = make_buf({ "hi" })
    local id = hl.apply_word(bufnr, 0, 10, 15, "red", 1)
    assert.is_nil(id)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("returns nil for col_end > line_len", function()
    local bufnr = make_buf({ "hi" })
    local id = hl.apply_word(bufnr, 0, 0, 10, "red", 1)
    assert.is_nil(id)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("returns nil for empty line", function()
    local bufnr = make_buf({ "" })
    local id = hl.apply_word(bufnr, 0, 0, 5, "red", 1)
    assert.is_nil(id)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("succeeds for valid position", function()
    local bufnr = make_buf({ "hello world" })
    local id = hl.apply_word(bufnr, 0, 0, 5, "red", 1)
    assert.is_not_nil(id)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("half color creates per-character gradient for each word", function()
    local bufnr = make_buf({ "aaa bbb" })
    local id1 = hl.apply_word(bufnr, 0, 0, 3, "half", 1)
    local id2 = hl.apply_word(bufnr, 0, 4, 7, "half", 2)

    -- Each 3-char word: 1 primary + 2 overlays = 3 extmarks; total 6
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, { details = true })
    assert.equals(6, #marks)

    -- Primary extmarks are AuditorGrad00 (first gradient step)
    local groups = {}
    for _, m in ipairs(marks) do
      groups[m[1]] = m[4].hl_group
    end
    assert.equals("AuditorGrad00", groups[id1])
    assert.equals("AuditorGrad00", groups[id2])

    -- collect_extmarks sees 2 logical marks
    local collected = hl.collect_extmarks(bufnr)
    assert.equals(2, #collected)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- collect_extmarks: edge cases
-- ═══════════════════════════════════════════════════════════════════════════════

describe("highlights: collect_extmarks edge cases", function()
  local hl

  before_each(function()
    reset_modules()
    hl = require("auditor.highlights")
    hl.setup()
  end)

  it("returns empty for buffer with no extmarks", function()
    local bufnr = make_buf({ "hello" })
    local result = hl.collect_extmarks(bufnr)
    assert.same({}, result)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("skips extmarks with end_col == col (zero-width)", function()
    local bufnr = make_buf({ "hello" })
    -- Create zero-width extmark
    vim.api.nvim_buf_set_extmark(bufnr, hl.ns, 0, 3, {
      end_row = 0,
      end_col = 3,
      hl_group = "AuditorRed",
    })
    local result = hl.collect_extmarks(bufnr)
    assert.equals(0, #result)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("skips extmarks with no hl_group", function()
    local bufnr = make_buf({ "hello" })
    vim.api.nvim_buf_set_extmark(bufnr, hl.ns, 0, 0, {
      end_row = 0,
      end_col = 5,
      -- no hl_group
    })
    local result = hl.collect_extmarks(bufnr)
    assert.equals(0, #result)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("maps all hl_groups to correct colors (red, blue, gradient)", function()
    local bufnr = make_buf({ "aaaa bbbb cccc" })
    vim.api.nvim_buf_set_extmark(bufnr, hl.ns, 0, 0, {
      end_row = 0, end_col = 4, hl_group = "AuditorRed",
    })
    vim.api.nvim_buf_set_extmark(bufnr, hl.ns, 0, 5, {
      end_row = 0, end_col = 9, hl_group = "AuditorBlue",
    })
    vim.api.nvim_buf_set_extmark(bufnr, hl.ns, 0, 10, {
      end_row = 0, end_col = 14, hl_group = "AuditorGrad08",
    })

    local result = hl.collect_extmarks(bufnr)
    assert.equals(3, #result)

    local color_set = {}
    for _, r in ipairs(result) do
      color_set[r.color] = true
    end
    assert.is_true(color_set["red"] ~= nil)
    assert.is_true(color_set["blue"] ~= nil)
    assert.is_true(color_set["half"] ~= nil)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- highlights.setup: hl group registration
-- ═══════════════════════════════════════════════════════════════════════════════

describe("highlights: setup", function()
  it("registers default highlight groups (solid + gradient)", function()
    reset_modules()
    local hl = require("auditor.highlights")
    hl.setup()

    local groups = {
      "AuditorRed", "AuditorBlue",
      "AuditorGrad00", "AuditorGrad15",
    }
    for _, name in ipairs(groups) do
      local def = vim.api.nvim_get_hl(0, { name = name })
      assert.is_not_nil(def.bg, name .. " should have bg color")
      assert.is_not_nil(def.fg, name .. " should have fg color")
      assert.is_true(def.bold, name .. " should be bold")
    end
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Fuzz: apply_words with random positions
-- ═══════════════════════════════════════════════════════════════════════════════

describe("highlights: fuzz apply_words", function()
  local hl

  before_each(function()
    reset_modules()
    hl = require("auditor.highlights")
    hl.setup()
  end)

  it("never crashes with random positions", function()
    math.randomseed(11011)
    local bufnr = make_buf({
      "short",
      "a longer line with many words",
      "",
      "x",
    })

    local colors = { "red", "blue", "half" }

    for _ = 1, 200 do
      local words = {}
      local n = math.random(0, 10)
      for _ = 1, n do
        table.insert(words, {
          line = math.random(-1, 10),
          col_start = math.random(-1, 50),
          col_end = math.random(0, 60),
        })
      end

      -- Should never crash
      local ok = pcall(hl.apply_words, bufnr, words, colors[math.random(1, 3)])
      assert.is_true(ok)

      vim.api.nvim_buf_clear_namespace(bufnr, hl.ns, 0, -1)
    end

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)
