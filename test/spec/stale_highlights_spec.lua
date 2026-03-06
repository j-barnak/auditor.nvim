-- test/spec/stale_highlights_spec.lua
-- Exhaustive tests for stale highlight positions: when DB positions no longer
-- match the current buffer contents (e.g. file was edited externally, pasted
-- over, truncated, or lines were removed).
--
-- Coverage:
--   S1  col_end beyond line length — apply_word skips silently
--   S2  col_start beyond line length — apply_word skips silently
--   S3  Line removed (line number beyond buffer) — apply_word skips silently
--   S4  Line shortened — col positions out of range, skipped
--   S5  Empty buffer — all saved highlights skipped
--   S6  Partial stale: some highlights valid, some stale — valid ones applied
--   S7  apply_words (batch) with mixed valid/stale tokens
--   S8  Full lifecycle: save highlights, modify file, re-enter audit mode — no crash
--   S9  All highlights stale — zero extmarks, no crash
--   S10 Edge cases: empty line, col_start == col_end == 0
--   S11 load_for_buffer with stale DB data — no crash, valid rows applied
--   S12 Property: random stale positions never crash apply_word

local function reset_modules()
  for _, m in ipairs({ "auditor", "auditor.init", "auditor.db", "auditor.highlights", "auditor.ts" }) do
    package.loaded[m] = nil
  end
end

-- ── deterministic PRNG ────────────────────────────────────────────────────────

local function make_rng(seed)
  local s = math.abs(seed) + 1
  return function(lo, hi)
    s = (s * 1664525 + 1013904223) % (2 ^ 32)
    return lo + math.floor(s * (hi - lo + 1) / (2 ^ 32))
  end
end

describe("stale highlights", function()
  local hl

  before_each(function()
    reset_modules()
    hl = require("auditor.highlights")
    hl.setup()
  end)

  -- ── S1: col_end beyond line length ──────────────────────────────────────

  describe("S1: col_end beyond line length", function()
    it("apply_word returns nil when col_end exceeds line", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "short" }) -- 5 chars

      local id = hl.apply_word(bufnr, 0, 0, 20, "red", 1)
      assert.is_nil(id)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("apply_word returns nil when col_end is line_len + 1", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello" }) -- 5 chars

      local id = hl.apply_word(bufnr, 0, 0, 6, "red", 1)
      assert.is_nil(id)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("apply_word succeeds when col_end == line_len (exact end)", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello" }) -- 5 chars

      local id = hl.apply_word(bufnr, 0, 0, 5, "red", 1)
      assert.is_number(id)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S2: col_start beyond line length ────────────────────────────────────

  describe("S2: col_start beyond line length", function()
    it("apply_word returns nil when col_start >= line_len", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hi" }) -- 2 chars

      local id = hl.apply_word(bufnr, 0, 5, 8, "blue", 1)
      assert.is_nil(id)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("apply_word returns nil when col_start == line_len", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "abc" }) -- 3 chars

      local id = hl.apply_word(bufnr, 0, 3, 5, "red", 1)
      assert.is_nil(id)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("apply_word succeeds when col_start == line_len - 1 (last char)", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "abc" }) -- 3 chars

      local id = hl.apply_word(bufnr, 0, 2, 3, "blue", 1)
      assert.is_number(id)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S3: line beyond buffer ──────────────────────────────────────────────

  describe("S3: line beyond buffer", function()
    it("apply_word returns nil for line beyond buffer", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "only one line" })

      local id = hl.apply_word(bufnr, 5, 0, 3, "red", 1)
      assert.is_nil(id)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("apply_word returns nil for line == line_count", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "a", "b" }) -- 2 lines

      local id = hl.apply_word(bufnr, 2, 0, 1, "blue", 1)
      assert.is_nil(id)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("apply_word succeeds for last line", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "a", "b" }) -- 2 lines

      local id = hl.apply_word(bufnr, 1, 0, 1, "red", 1)
      assert.is_number(id)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S4: line shortened ──────────────────────────────────────────────────

  describe("S4: line shortened after highlight saved", function()
    it("col positions that were valid become stale — no crash", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "long_variable_name = 42" })

      -- This would be valid for the original line
      local id1 = hl.apply_word(bufnr, 0, 0, 18, "red", 1)
      assert.is_number(id1)

      -- Now shorten the line
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "x = 1" })

      -- Old positions are now stale
      local id2 = hl.apply_word(bufnr, 0, 0, 18, "red", 1)
      assert.is_nil(id2)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S5: empty buffer ───────────────────────────────────────────────────

  describe("S5: empty buffer", function()
    it("apply_word on empty buffer returns nil", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      -- Default buffer has one empty line ""

      local id = hl.apply_word(bufnr, 0, 0, 5, "red", 1)
      assert.is_nil(id)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("apply_word for line 0 col 0 to 0 on empty buffer returns nil (col_start >= line_len)", function()
      local bufnr = vim.api.nvim_create_buf(false, true)

      -- Empty line has length 0, so col_start 0 >= line_len 0
      local id = hl.apply_word(bufnr, 0, 0, 0, "red", 1)
      assert.is_nil(id)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("apply_words on empty buffer produces no extmarks", function()
      local bufnr = vim.api.nvim_create_buf(false, true)

      local ids = hl.apply_words(bufnr, {
        { line = 0, col_start = 0, col_end = 5 },
        { line = 1, col_start = 0, col_end = 3 },
      }, "blue")

      assert.equals(0, #ids)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S6: partial stale — some valid, some not ──────────────────────────

  describe("S6: partial stale highlights", function()
    it("valid highlights applied, stale ones skipped", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })

      -- Valid: "hello" at 0-5
      local id1 = hl.apply_word(bufnr, 0, 0, 5, "red", 1)
      assert.is_number(id1)

      -- Stale: col_end way beyond
      local id2 = hl.apply_word(bufnr, 0, 0, 50, "red", 2)
      assert.is_nil(id2)

      -- Stale: line doesn't exist
      local id3 = hl.apply_word(bufnr, 5, 0, 3, "red", 3)
      assert.is_nil(id3)

      -- Valid: "world" at 6-11
      local id4 = hl.apply_word(bufnr, 0, 6, 11, "blue", 1)
      assert.is_number(id4)

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, {})
      assert.equals(2, #marks) -- only the 2 valid ones

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S7: apply_words batch with mixed valid/stale ──────────────────────

  describe("S7: apply_words with mixed valid/stale tokens", function()
    it("returns only ids for valid tokens", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "abc def" })

      local ids = hl.apply_words(bufnr, {
        { line = 0, col_start = 0, col_end = 3 }, -- valid: "abc"
        { line = 0, col_start = 0, col_end = 99 }, -- stale: col_end too far
        { line = 5, col_start = 0, col_end = 3 }, -- stale: line doesn't exist
        { line = 0, col_start = 4, col_end = 7 }, -- valid: "def"
      }, "red")

      assert.equals(2, #ids)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("all stale tokens returns empty id list", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "x" })

      local ids = hl.apply_words(bufnr, {
        { line = 0, col_start = 0, col_end = 99 },
        { line = 5, col_start = 0, col_end = 3 },
        { line = 0, col_start = 50, col_end = 60 },
      }, "blue")

      assert.equals(0, #ids)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("all valid tokens returns all ids", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world test" })

      local ids = hl.apply_words(bufnr, {
        { line = 0, col_start = 0, col_end = 5 },
        { line = 0, col_start = 6, col_end = 11 },
        { line = 0, col_start = 12, col_end = 16 },
      }, "red")

      assert.equals(3, #ids)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S8: full lifecycle — save, modify, re-enter ───────────────────────

  describe("S8: full lifecycle with file modification", function()
    local auditor, db

    before_each(function()
      reset_modules()
      local tmp_db = vim.fn.tempname() .. ".db"
      auditor = require("auditor")
      auditor.setup({ db_path = tmp_db, keymaps = false })
      db = require("auditor.db")
      hl = require("auditor.highlights")
    end)

    it("save highlights, shorten file, re-enter — no crash", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "long_function_name = function()",
        "  local very_long_variable = 42",
        "end",
      })
      vim.api.nvim_set_current_buf(bufnr)

      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      auditor.audit()

      -- Verify saved
      assert.is_true(#db.get_highlights(filepath) >= 1)

      auditor.exit_audit_mode()

      -- Simulate file being replaced with shorter content
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "x = 1" })

      -- Re-enter — old positions are now stale
      local ok = pcall(auditor.enter_audit_mode)
      assert.is_true(ok)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("save highlights, empty the file, re-enter — no crash", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(bufnr)

      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("blue")
      auditor.audit()
      auditor.exit_audit_mode()

      -- Empty the file
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })

      local ok = pcall(auditor.enter_audit_mode)
      assert.is_true(ok)
      -- No extmarks since all positions are stale
      assert.equals(0, #vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, {}))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("save highlights, delete all lines, re-enter — no crash", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "alpha beta gamma",
        "delta epsilon zeta",
      })
      vim.api.nvim_set_current_buf(bufnr)

      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- on "delta" (line 2)
      auditor.highlight_cword_buffer("red")
      auditor.audit()
      auditor.exit_audit_mode()

      -- Replace with single empty line (Neovim always has at least 1 line)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })

      local ok = pcall(auditor.enter_audit_mode)
      assert.is_true(ok)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("save on multiple lines, shorten to 1 line — only valid marks applied", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "aaa bbb ccc",
        "ddd eee fff",
        "ggg hhh iii",
      })
      vim.api.nvim_set_current_buf(bufnr)

      -- Save highlights on all three lines via DB directly
      db.save_words(filepath, {
        { line = 0, col_start = 0, col_end = 3 },
        { line = 1, col_start = 0, col_end = 3 },
        { line = 2, col_start = 0, col_end = 3 },
      }, "red")

      -- Shorten to 1 line that still has "aaa"
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "aaa bbb ccc" })

      auditor.enter_audit_mode()

      -- Only line 0 highlight should be applied
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, {})
      assert.equals(1, #marks)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S9: all highlights stale ──────────────────────────────────────────

  describe("S9: all highlights stale", function()
    it("apply_words with all out-of-range positions produces 0 extmarks", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "ab" })

      local ids = hl.apply_words(bufnr, {
        { line = 0, col_start = 10, col_end = 20 },
        { line = 5, col_start = 0, col_end = 5 },
        { line = 0, col_start = 0, col_end = 50 },
      }, "red")

      assert.equals(0, #ids)
      assert.equals(0, #vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, {}))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S10: edge cases ───────────────────────────────────────────────────

  describe("S10: edge cases", function()
    it("empty line — col_start 0 is out of range (line_len == 0)", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })

      local id = hl.apply_word(bufnr, 0, 0, 0, "red", 1)
      assert.is_nil(id)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("single character line — col 0 to 1 is valid", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "x" })

      local id = hl.apply_word(bufnr, 0, 0, 1, "blue", 1)
      assert.is_number(id)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("single character line — col 0 to 2 is stale", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "x" })

      local id = hl.apply_word(bufnr, 0, 0, 2, "red", 1)
      assert.is_nil(id)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("tab characters — byte length is 1 per tab", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "\thello" }) -- 6 bytes

      local id = hl.apply_word(bufnr, 0, 1, 6, "red", 1)
      assert.is_number(id)

      -- Past end
      local id2 = hl.apply_word(bufnr, 0, 1, 7, "red", 1)
      assert.is_nil(id2)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("unicode multibyte — byte offsets must match actual byte length", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "café" }) -- 5 bytes (é = 2 bytes)

      -- Valid: full "café" is 5 bytes
      local id1 = hl.apply_word(bufnr, 0, 0, 5, "red", 1)
      assert.is_number(id1)

      -- Stale: col_end 6 is beyond
      local id2 = hl.apply_word(bufnr, 0, 0, 6, "red", 2)
      assert.is_nil(id2)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S11: load_for_buffer with stale DB data ───────────────────────────

  describe("S11: load_for_buffer with stale DB data", function()
    local auditor, db

    before_each(function()
      reset_modules()
      local tmp_db = vim.fn.tempname() .. ".db"
      auditor = require("auditor")
      auditor.setup({ db_path = tmp_db, keymaps = false })
      db = require("auditor.db")
      hl = require("auditor.highlights")
    end)

    it("does not crash with stale row where col_end > line length", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hi" })

      -- Insert stale data directly into DB
      db.save_words(filepath, { { line = 0, col_start = 0, col_end = 20 } }, "red")

      local ok = pcall(auditor.load_for_buffer, bufnr)
      assert.is_true(ok)
      assert.equals(0, #vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, {}))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("does not crash with stale row where line > buffer lines", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "only line" })

      db.save_words(filepath, { { line = 10, col_start = 0, col_end = 5 } }, "blue")

      local ok = pcall(auditor.load_for_buffer, bufnr)
      assert.is_true(ok)
      assert.equals(0, #vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, {}))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("applies valid rows and skips stale rows from same file", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })

      -- Mix of valid and stale
      db.save_words(filepath, { { line = 0, col_start = 0, col_end = 5 } }, "red") -- valid
      db.save_words(filepath, { { line = 0, col_start = 0, col_end = 50 } }, "blue") -- stale
      db.save_words(filepath, { { line = 5, col_start = 0, col_end = 3 } }, "red") -- stale
      db.save_words(filepath, { { line = 0, col_start = 6, col_end = 11 } }, "blue") -- valid

      auditor.load_for_buffer(bufnr)

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, {})
      assert.equals(2, #marks) -- only the 2 valid ones

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S12: property-based — random stale positions never crash ──────────

  describe("S12: property — random positions never crash apply_word (500 iterations)", function()
    it("apply_word never errors regardless of position values", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "hello world",
        "foo bar",
        "",
        "x",
      })

      for seed = 1, 500 do
        local rng = make_rng(seed)
        local line = rng(0, 10) -- may be beyond buffer
        local col_start = rng(0, 50)
        local col_end = rng(col_start, 100)
        local colors = { "red", "blue", "half" }
        local color = colors[rng(1, 3)]

        local ok, err = pcall(hl.apply_word, bufnr, line, col_start, col_end, color, rng(1, 10))
        assert(ok, string.format("seed=%d: apply_word errored: %s", seed, tostring(err)))
      end

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("apply_words never errors regardless of position values", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "abc", "def" })

      for seed = 1, 200 do
        local rng = make_rng(seed)
        local n = rng(1, 8)
        local words = {}
        for i = 1, n do
          words[i] = {
            line = rng(0, 10),
            col_start = rng(0, 30),
            col_end = rng(0, 60),
          }
        end
        local colors = { "red", "blue", "half" }

        local ok, err = pcall(hl.apply_words, bufnr, words, colors[rng(1, 3)])
        assert(ok, string.format("seed=%d: apply_words errored: %s", seed, tostring(err)))
      end

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)
end)
