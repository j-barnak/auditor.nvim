-- test/spec/half_split_spec.lua
-- Tests for the half-and-half gradient: per-character red→blue gradient.

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
-- Gradient setup: highlight groups are created
-- ═══════════════════════════════════════════════════════════════════════════════

describe("half gradient: setup", function()
  local hl

  before_each(function()
    reset_modules()
    hl = require("auditor.highlights")
    hl.setup()
  end)

  it("creates 16 gradient highlight groups", function()
    for i = 0, hl._GRAD_STEPS - 1 do
      local name = string.format("AuditorGrad%02d", i)
      local group = vim.api.nvim_get_hl(0, { name = name })
      assert.is_not_nil(group.bg, name .. " should have bg")
      assert.is_true(group.bold, name .. " should be bold")
    end
  end)

  it("first gradient step is red, last is blue", function()
    local first = vim.api.nvim_get_hl(0, { name = "AuditorGrad00" })
    local last = vim.api.nvim_get_hl(0, { name = string.format("AuditorGrad%02d", hl._GRAD_STEPS - 1) })
    -- AuditorGrad00 bg should be close to #CC0000 (red)
    -- AuditorGrad15 bg should be close to #0055CC (blue)
    assert.is_not_nil(first.bg)
    assert.is_not_nil(last.bg)
    -- Red component: first should be high, last should be low
    assert.is_true(first.bg > last.bg)
  end)

  it("grad_for returns midpoint group for 1-char words", function()
    local mid = math.floor(hl._GRAD_STEPS / 2)
    local expected = string.format("AuditorGrad%02d", mid)
    assert.equals(expected, hl._grad_for(0, 1))
  end)

  it("grad_for returns first group for char 0 of multi-char words", function()
    assert.equals("AuditorGrad00", hl._grad_for(0, 5))
  end)

  it("grad_for returns last group for last char of multi-char words", function()
    local last = string.format("AuditorGrad%02d", hl._GRAD_STEPS - 1)
    assert.equals(last, hl._grad_for(4, 5))
  end)

  it("grad_for is monotonically non-decreasing", function()
    for word_len = 2, 20 do
      local prev_step = -1
      for j = 0, word_len - 1 do
        local group = hl._grad_for(j, word_len)
        local step = tonumber(group:match("AuditorGrad(%d+)"))
        assert.is_true(step >= prev_step,
          string.format("non-monotonic at word_len=%d, j=%d: %d < %d", word_len, j, step, prev_step))
        prev_step = step
      end
    end
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Gradient: apply_words per-character extmarks
-- ═══════════════════════════════════════════════════════════════════════════════

describe("half gradient: apply_words", function()
  local hl

  before_each(function()
    reset_modules()
    hl = require("auditor.highlights")
    hl.setup()
  end)

  it("1-char word: single extmark with midpoint gradient", function()
    local bufnr = make_buf({ "x" })
    local ids = hl.apply_words(bufnr, { { line = 0, col_start = 0, col_end = 1 } }, "half")

    assert.equals(1, #ids)
    local marks = get_marks(bufnr, hl.ns)
    assert.equals(1, #marks) -- no secondaries for 1-char
    local group = marks[1][4].hl_group
    assert.is_truthy(group:match("^AuditorGrad"))
    -- Should be midpoint
    local step = tonumber(group:match("AuditorGrad(%d+)"))
    assert.equals(math.floor(hl._GRAD_STEPS / 2), step)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("2-char word: 2 extmarks (primary + 1 overlay)", function()
    local bufnr = make_buf({ "ab" })
    local ids = hl.apply_words(bufnr, { { line = 0, col_start = 0, col_end = 2 } }, "half")

    assert.equals(1, #ids)
    local marks = get_marks(bufnr, hl.ns)
    assert.equals(2, #marks)
    -- Primary: full word, AuditorGrad00
    assert.equals(0, marks[1][3])
    assert.equals(2, marks[1][4].end_col)
    assert.equals("AuditorGrad00", marks[1][4].hl_group)
    assert.equals(100, marks[1][4].priority)
    -- Overlay for char 1: AuditorGrad15
    assert.equals(1, marks[2][3])
    assert.equals(2, marks[2][4].end_col)
    assert.is_truthy(marks[2][4].hl_group:match("^AuditorGrad"))
    assert.equals(101, marks[2][4].priority)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("5-char word: 5 extmarks with gradient", function()
    local bufnr = make_buf({ "hello" })
    local ids = hl.apply_words(bufnr, { { line = 0, col_start = 0, col_end = 5 } }, "half")

    assert.equals(1, #ids)
    local marks = get_marks(bufnr, hl.ns)
    -- 1 primary + 4 overlays = 5
    assert.equals(5, #marks)
    -- Primary covers full word
    assert.equals(0, marks[1][3])
    assert.equals(5, marks[1][4].end_col)
    assert.equals("AuditorGrad00", marks[1][4].hl_group)
    -- Each overlay covers 1 character
    for i = 2, 5 do
      local m = marks[i]
      assert.equals(i - 1, m[3]) -- col = char index
      assert.equals(i, m[4].end_col) -- end_col = col + 1
      assert.equals(101, m[4].priority)
      assert.is_truthy(m[4].hl_group:match("^AuditorGrad"))
    end
    -- Last char should be the final gradient step (blue)
    local last_group = marks[5][4].hl_group
    local last_step = tonumber(last_group:match("AuditorGrad(%d+)"))
    assert.equals(hl._GRAD_STEPS - 1, last_step)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("red and blue are unaffected", function()
    local bufnr = make_buf({ "hello world" })
    hl.apply_words(bufnr, { { line = 0, col_start = 0, col_end = 5 } }, "red")
    hl.apply_words(bufnr, { { line = 0, col_start = 6, col_end = 11 } }, "blue")

    local marks = get_marks(bufnr, hl.ns)
    assert.equals(2, #marks)
    assert.equals("AuditorRed", marks[1][4].hl_group)
    assert.equals("AuditorBlue", marks[2][4].hl_group)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("multiple half words each get their own gradient", function()
    local bufnr = make_buf({ "aaa bbb" })
    local ids = hl.apply_words(bufnr, {
      { line = 0, col_start = 0, col_end = 3 },
      { line = 0, col_start = 4, col_end = 7 },
    }, "half")

    assert.equals(2, #ids)
    -- Each 3-char word: 1 primary + 2 overlays = 3 extmarks each, total 6
    local marks = get_marks(bufnr, hl.ns)
    assert.equals(6, #marks)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Gradient: apply_word (single word, DB reload path)
-- ═══════════════════════════════════════════════════════════════════════════════

describe("half gradient: apply_word", function()
  local hl

  before_each(function()
    reset_modules()
    hl = require("auditor.highlights")
    hl.setup()
  end)

  it("4-char word creates gradient", function()
    local bufnr = make_buf({ "test" })
    local id = hl.apply_word(bufnr, 0, 0, 4, "half", 1)

    assert.is_not_nil(id)
    local marks = get_marks(bufnr, hl.ns)
    -- 1 primary + 3 overlays = 4
    assert.equals(4, #marks)
    assert.equals("AuditorGrad00", marks[1][4].hl_group)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("1-char word uses midpoint gradient", function()
    local bufnr = make_buf({ "a" })
    local id = hl.apply_word(bufnr, 0, 0, 1, "half", 1)

    assert.is_not_nil(id)
    local marks = get_marks(bufnr, hl.ns)
    assert.equals(1, #marks)
    local step = tonumber(marks[1][4].hl_group:match("AuditorGrad(%d+)"))
    assert.equals(math.floor(hl._GRAD_STEPS / 2), step)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("word_index does not affect gradient", function()
    local bufnr = make_buf({ "aaaa bbbb" })
    local id1 = hl.apply_word(bufnr, 0, 0, 4, "half", 1)
    local id2 = hl.apply_word(bufnr, 0, 5, 9, "half", 2)

    assert.is_not_nil(id1)
    assert.is_not_nil(id2)
    local marks = get_marks(bufnr, hl.ns)
    -- 2 words × 4 extmarks each = 8
    assert.equals(8, #marks)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Gradient: collect_extmarks
-- ═══════════════════════════════════════════════════════════════════════════════

describe("half gradient: collect_extmarks", function()
  local hl

  before_each(function()
    reset_modules()
    hl = require("auditor.highlights")
    hl.setup()
  end)

  it("returns 1 logical mark for 1 half word", function()
    local bufnr = make_buf({ "hello" })
    hl.apply_words(bufnr, { { line = 0, col_start = 0, col_end = 5 } }, "half")

    local collected = hl.collect_extmarks(bufnr)
    assert.equals(1, #collected)
    assert.equals("half", collected[1].color)
    assert.equals(0, collected[1].col_start)
    assert.equals(5, collected[1].col_end)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("returns N logical marks for N half words", function()
    local bufnr = make_buf({ "aaa bbb ccc" })
    hl.apply_words(bufnr, {
      { line = 0, col_start = 0, col_end = 3 },
      { line = 0, col_start = 4, col_end = 7 },
      { line = 0, col_start = 8, col_end = 11 },
    }, "half")

    local collected = hl.collect_extmarks(bufnr)
    assert.equals(3, #collected)
    for _, c in ipairs(collected) do
      assert.equals("half", c.color)
    end

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("mixed colors collected correctly", function()
    local bufnr = make_buf({ "aaa bbb ccc" })
    hl.apply_words(bufnr, { { line = 0, col_start = 0, col_end = 3 } }, "red")
    hl.apply_words(bufnr, { { line = 0, col_start = 4, col_end = 7 } }, "half")
    hl.apply_words(bufnr, { { line = 0, col_start = 8, col_end = 11 } }, "blue")

    local collected = hl.collect_extmarks(bufnr)
    assert.equals(3, #collected)

    local colors = {}
    for _, c in ipairs(collected) do
      colors[c.color] = (colors[c.color] or 0) + 1
    end
    assert.equals(1, colors["red"])
    assert.equals(1, colors["half"])
    assert.equals(1, colors["blue"])

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("1-char half word collected correctly", function()
    local bufnr = make_buf({ "x" })
    hl.apply_words(bufnr, { { line = 0, col_start = 0, col_end = 1 } }, "half")

    local collected = hl.collect_extmarks(bufnr)
    assert.equals(1, #collected)
    assert.equals("half", collected[1].color)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Gradient: del_half_pair cleans up all secondaries
-- ═══════════════════════════════════════════════════════════════════════════════

describe("half gradient: del_half_pair", function()
  local hl

  before_each(function()
    reset_modules()
    hl = require("auditor.highlights")
    hl.setup()
  end)

  it("removes all gradient overlay extmarks", function()
    local bufnr = make_buf({ "hello" })
    local ids = hl.apply_words(bufnr, { { line = 0, col_start = 0, col_end = 5 } }, "half")

    -- Before: 5 raw extmarks
    assert.equals(5, #get_marks(bufnr, hl.ns))

    vim.api.nvim_buf_del_extmark(bufnr, hl.ns, ids[1])
    hl.del_half_pair(bufnr, ids[1])

    -- After: 0 extmarks
    assert.equals(0, #get_marks(bufnr, hl.ns))

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("no-op for non-half extmarks", function()
    local bufnr = make_buf({ "hello" })
    local ids = hl.apply_words(bufnr, { { line = 0, col_start = 0, col_end = 5 } }, "red")

    hl.del_half_pair(bufnr, ids[1])
    assert.equals(1, #get_marks(bufnr, hl.ns))

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("safe when bufnr has no pairs", function()
    hl.del_half_pair(999, 123)
  end)

  it("removes correct pair when multiple words exist", function()
    local bufnr = make_buf({ "aaa bbb" })
    local ids = hl.apply_words(bufnr, {
      { line = 0, col_start = 0, col_end = 3 },
      { line = 0, col_start = 4, col_end = 7 },
    }, "half")

    -- Total: 2 words × 3 extmarks = 6
    assert.equals(6, #get_marks(bufnr, hl.ns))

    -- Delete first word's extmarks
    vim.api.nvim_buf_del_extmark(bufnr, hl.ns, ids[1])
    hl.del_half_pair(bufnr, ids[1])

    -- Only second word remains: 3 extmarks
    assert.equals(3, #get_marks(bufnr, hl.ns))

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Gradient: end-to-end with init.lua
-- ═══════════════════════════════════════════════════════════════════════════════

describe("half gradient: end-to-end", function()
  local auditor, db, hl

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
    hl = require("auditor.highlights")
  end)

  it("mark → save → exit → enter preserves gradient", function()
    local bufnr, filepath = make_buf({ "hello world" })
    auditor.enter_audit_mode()

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("half")

    auditor.audit()
    auditor.exit_audit_mode()
    auditor.enter_audit_mode()

    local rows = db.get_highlights(filepath)
    assert.equals(1, #rows)
    assert.equals("half", rows[1].color)

    -- "hello" = 5 chars → 5 raw extmarks, 1 logical
    local raw_marks = get_marks(bufnr, hl.ns)
    assert.equals(5, #raw_marks)
    local collected = hl.collect_extmarks(bufnr)
    assert.equals(1, #collected)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("undo removes all gradient extmarks", function()
    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("half")

    assert.equals(5, #get_marks(bufnr, hl.ns))

    auditor.undo_at_cursor()
    assert.equals(0, #get_marks(bufnr, hl.ns))

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("re-mark half → red cleans up gradient", function()
    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("half")
    assert.equals(5, #get_marks(bufnr, hl.ns))

    auditor.highlight_cword_buffer("red")
    assert.equals(1, #get_marks(bufnr, hl.ns))
    assert.equals("AuditorRed", get_marks(bufnr, hl.ns)[1][4].hl_group)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("re-mark red → half creates gradient", function()
    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    assert.equals(1, #get_marks(bufnr, hl.ns))

    auditor.highlight_cword_buffer("half")
    assert.equals(5, #get_marks(bufnr, hl.ns))

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("function-scoped half highlights all occurrences with gradients", function()
    local bufnr = make_buf({ "foo bar foo baz foo" })
    auditor.enter_audit_mode()

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword("half")

    -- "foo" (3 chars) × 3 occurrences = 3 words × 3 extmarks = 9 raw
    local raw = get_marks(bufnr, hl.ns)
    assert.equals(9, #raw)

    local collected = hl.collect_extmarks(bufnr)
    assert.equals(3, #collected)
    for _, c in ipairs(collected) do
      assert.equals("half", c.color)
    end

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("clear_buffer removes all gradient extmarks", function()
    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("half")
    auditor.audit()

    auditor.clear_buffer()
    assert.equals(0, #get_marks(bufnr, hl.ns))

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("mixed red/half/blue all persist correctly", function()
    local bufnr, filepath = make_buf({ "aaa bbb ccc" })
    auditor.enter_audit_mode()

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    vim.api.nvim_win_set_cursor(0, { 1, 4 })
    auditor.highlight_cword_buffer("half")
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    auditor.highlight_cword_buffer("blue")

    auditor.audit()
    auditor.exit_audit_mode()
    auditor.enter_audit_mode()

    local rows = db.get_highlights(filepath)
    local color_counts = {}
    for _, r in ipairs(rows) do
      color_counts[r.color] = (color_counts[r.color] or 0) + 1
    end
    assert.equals(1, color_counts["red"])
    assert.equals(1, color_counts["half"])
    assert.equals(1, color_counts["blue"])

    -- Raw: red(1) + half("bbb"=3 chars→3 extmarks) + blue(1) = 5
    assert.equals(5, #get_marks(bufnr, hl.ns))
    assert.equals(3, #hl.collect_extmarks(bufnr))

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("1-char half word round-trips through DB", function()
    local bufnr, filepath = make_buf({ "a b c" })
    auditor.enter_audit_mode()

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("half")

    auditor.audit()
    auditor.exit_audit_mode()
    auditor.enter_audit_mode()

    local rows = db.get_highlights(filepath)
    assert.equals(1, #rows)
    assert.equals("half", rows[1].color)

    -- 1-char: 1 raw extmark (midpoint gradient, no overlays)
    assert.equals(1, #get_marks(bufnr, hl.ns))
    local group = get_marks(bufnr, hl.ns)[1][4].hl_group
    assert.is_truthy(group:match("^AuditorGrad"))

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Gradient: property-based
-- ═══════════════════════════════════════════════════════════════════════════════

describe("half gradient: property-based", function()
  local hl

  before_each(function()
    reset_modules()
    hl = require("auditor.highlights")
    hl.setup()
  end)

  it("property: word of length N creates exactly N raw extmarks", function()
    for word_len = 1, 20 do
      local word = string.rep("x", word_len)
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { word })
      hl.clear_half_pairs(bufnr)

      hl.apply_words(bufnr, { { line = 0, col_start = 0, col_end = word_len } }, "half")

      local marks = get_marks(bufnr, hl.ns)
      assert.equals(word_len, #marks,
        "word_len=" .. word_len .. " expected " .. word_len .. " extmarks, got " .. #marks)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end)

  it("property: collect_extmarks always returns 1 logical mark per word", function()
    for word_len = 1, 20 do
      local word = string.rep("x", word_len)
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { word })
      hl.clear_half_pairs(bufnr)

      hl.apply_words(bufnr, { { line = 0, col_start = 0, col_end = word_len } }, "half")

      local collected = hl.collect_extmarks(bufnr)
      assert.equals(1, #collected, "word_len=" .. word_len)
      assert.equals("half", collected[1].color)
      assert.equals(0, collected[1].col_start)
      assert.equals(word_len, collected[1].col_end)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end)

  it("property: gradient colors span from step 0 to step N-1", function()
    for word_len = 2, 15 do
      local word = string.rep("x", word_len)
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { word })
      hl.clear_half_pairs(bufnr)

      hl.apply_words(bufnr, { { line = 0, col_start = 0, col_end = word_len } }, "half")

      local marks = get_marks(bufnr, hl.ns)
      -- First extmark (primary) should be AuditorGrad00
      assert.equals("AuditorGrad00", marks[1][4].hl_group,
        "word_len=" .. word_len .. " first should be Grad00")
      -- Last overlay should be AuditorGrad15 (or close to it)
      local last_group = marks[#marks][4].hl_group
      local last_step = tonumber(last_group:match("AuditorGrad(%d+)"))
      assert.equals(hl._GRAD_STEPS - 1, last_step,
        "word_len=" .. word_len .. " last should be Grad" .. (hl._GRAD_STEPS - 1))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end)

  it("property: all overlay extmarks are single-char width", function()
    for word_len = 2, 15 do
      local word = string.rep("x", word_len)
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { word })
      hl.clear_half_pairs(bufnr)

      hl.apply_words(bufnr, { { line = 0, col_start = 0, col_end = word_len } }, "half")

      local marks = get_marks(bufnr, hl.ns)
      -- Skip primary (index 1); all overlays should be 1 char wide
      for i = 2, #marks do
        local m = marks[i]
        assert.equals(1, m[4].end_col - m[3],
          string.format("word_len=%d overlay %d is not 1-char wide", word_len, i - 1))
      end

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end)

  it("property: ids count matches words count for half", function()
    for n = 1, 10 do
      local parts = {}
      local words = {}
      local col = 0
      for i = 1, n do
        local w = string.rep(string.char(96 + i), 3)
        parts[i] = w
        words[i] = { line = 0, col_start = col, col_end = col + 3 }
        col = col + 4
      end

      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { table.concat(parts, " ") })
      hl.clear_half_pairs(bufnr)

      local ids = hl.apply_words(bufnr, words, "half")
      local collected = hl.collect_extmarks(bufnr)

      assert.equals(n, #ids, "ids for n=" .. n)
      assert.equals(n, #collected, "collected for n=" .. n)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end)

  it("fuzz: 100 random half operations never crash", function()
    math.randomseed(42)
    for iter = 1, 100 do
      local n_words = math.random(1, 8)
      local parts = {}
      local words = {}
      local col = 0
      for i = 1, n_words do
        local len = math.random(1, 10)
        parts[i] = string.rep("a", len)
        words[i] = { line = 0, col_start = col, col_end = col + len }
        col = col + len + 1
      end

      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { table.concat(parts, " ") })
      hl.clear_half_pairs(bufnr)

      local ok, err = pcall(function()
        local ids = hl.apply_words(bufnr, words, "half")
        local collected = hl.collect_extmarks(bufnr)
        assert.equals(#ids, #collected)
      end)
      assert(ok, "crash at iteration " .. iter .. ": " .. tostring(err))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end)

  it("fuzz: gradient monotonicity for 200 random word lengths", function()
    math.randomseed(123)
    for _ = 1, 200 do
      local word_len = math.random(2, 30)
      local word = string.rep("x", word_len)
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { word })
      hl.clear_half_pairs(bufnr)

      hl.apply_words(bufnr, { { line = 0, col_start = 0, col_end = word_len } }, "half")

      local marks = get_marks(bufnr, hl.ns)
      local prev_step = -1
      for _, m in ipairs(marks) do
        local step = tonumber(m[4].hl_group:match("AuditorGrad(%d+)"))
        assert(step, "expected AuditorGrad group, got " .. tostring(m[4].hl_group))
        assert(step >= prev_step,
          string.format("non-monotonic gradient at word_len=%d: step %d < %d", word_len, step, prev_step))
        prev_step = step
      end

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end)
end)
