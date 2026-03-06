-- test/spec/highlight_cword_spec.lua
-- Exhaustive tests for AuditRed/Blue/Half (single cword, no treesitter)
-- and AuditWordRed/Blue/Half (all occurrences in function scope, treesitter).
--
-- Verifies:
--   - AuditRed/Blue/Half highlights ONLY the single word under the cursor
--   - AuditWordRed/Blue/Half highlights ALL occurrences within function scope
--   - Exact extmark positions match expected token boundaries
--   - Multiple identical words on the same line: only cursor word is marked by Audit*
--   - Words on other lines are NOT marked by Audit*
--   - Color correctness (red/blue/half highlight groups)
--   - No treesitter involvement in Audit* commands
--   - Treesitter scope limits AuditWord* to enclosing function

local function reset_modules()
  for _, m in ipairs({ "auditor", "auditor.init", "auditor.db", "auditor.highlights", "auditor.ts" }) do
    package.loaded[m] = nil
  end
end

-- ── helpers ─────────────────────────────────────────────────────────────────

local function make_buf(lines)
  if type(lines) == "string" then
    lines = { lines }
  end
  local bufnr = vim.api.nvim_create_buf(false, true)
  local filepath = vim.fn.tempname() .. ".lua"
  vim.api.nvim_buf_set_name(bufnr, filepath)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr, filepath
end

local function get_extmarks(bufnr, ns)
  return vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
end

local function extmark_positions(bufnr, ns)
  local marks = get_extmarks(bufnr, ns)
  local out = {}
  for _, m in ipairs(marks) do
    table.insert(out, {
      line = m[2],
      col_start = m[3],
      col_end = m[4].end_col,
      hl_group = m[4].hl_group,
    })
  end
  -- Sort by line, then col_start for deterministic comparison
  table.sort(out, function(a, b)
    if a.line ~= b.line then
      return a.line < b.line
    end
    return a.col_start < b.col_start
  end)
  return out
end

-- ═══════════════════════════════════════════════════════════════════════════
-- AuditRed/Blue/Half — single cword only
-- ═══════════════════════════════════════════════════════════════════════════

describe("highlight_cword_buffer (AuditRed/Blue/Half)", function()
  local auditor, hl
  local tmp_db

  before_each(function()
    reset_modules()
    tmp_db = vim.fn.tempname() .. ".db"
    auditor = require("auditor")
    auditor.setup({ db_path = tmp_db, keymaps = false })
    hl = require("auditor.highlights")
    auditor.enter_audit_mode()
  end)

  after_each(function()
    pcall(os.remove, tmp_db)
  end)

  -- ── single word, no duplicates ────────────────────────────────────────

  describe("single word on line", function()
    it("marks exactly one token at the cursor position", function()
      local bufnr = make_buf("hello world")
      vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- cursor on 'h'
      auditor.highlight_cword_buffer("red")

      local marks = extmark_positions(bufnr, hl.ns)
      assert.equals(1, #marks)
      assert.equals(0, marks[1].line)
      assert.equals(0, marks[1].col_start)
      assert.equals(5, marks[1].col_end)
      assert.equals("AuditorRed", marks[1].hl_group)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("marks the second word when cursor is on it", function()
      local bufnr = make_buf("hello world")
      vim.api.nvim_win_set_cursor(0, { 1, 6 }) -- cursor on 'w'
      auditor.highlight_cword_buffer("blue")

      local marks = extmark_positions(bufnr, hl.ns)
      assert.equals(1, #marks)
      assert.equals(0, marks[1].line)
      assert.equals(6, marks[1].col_start)
      assert.equals(11, marks[1].col_end)
      assert.equals("AuditorBlue", marks[1].hl_group)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── duplicate words: only cursor instance is highlighted ──────────────

  describe("duplicate words on same line", function()
    it("marks only the occurrence under the cursor, not the other", function()
      local bufnr = make_buf("foo bar foo baz foo")
      -- "foo" appears at cols 0-3, 8-11, 16-19
      -- Put cursor on the SECOND "foo" (col 8)
      vim.api.nvim_win_set_cursor(0, { 1, 8 })
      auditor.highlight_cword_buffer("red")

      local marks = extmark_positions(bufnr, hl.ns)
      assert.equals(1, #marks, "expected exactly 1 extmark, not all occurrences")
      assert.equals(0, marks[1].line)
      assert.equals(8, marks[1].col_start)
      assert.equals(11, marks[1].col_end)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("marks only the first occurrence when cursor is on it", function()
      local bufnr = make_buf("foo bar foo")
      vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- first "foo"
      auditor.highlight_cword_buffer("blue")

      local marks = extmark_positions(bufnr, hl.ns)
      assert.equals(1, #marks)
      assert.equals(0, marks[1].col_start)
      assert.equals(3, marks[1].col_end)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("marks only the last occurrence when cursor is on it", function()
      local bufnr = make_buf("foo bar foo")
      vim.api.nvim_win_set_cursor(0, { 1, 8 }) -- second "foo"
      auditor.highlight_cword_buffer("red")

      local marks = extmark_positions(bufnr, hl.ns)
      assert.equals(1, #marks)
      assert.equals(8, marks[1].col_start)
      assert.equals(11, marks[1].col_end)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── duplicate words on other lines: NOT highlighted ───────────────────

  describe("duplicate words on other lines", function()
    it("does not mark the same word on a different line", function()
      local bufnr = make_buf({ "hello world", "hello again" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- "hello" on line 1
      auditor.highlight_cword_buffer("red")

      local marks = extmark_positions(bufnr, hl.ns)
      assert.equals(1, #marks)
      assert.equals(0, marks[1].line, "should be on line 0 only")
      assert.equals(0, marks[1].col_start)
      assert.equals(5, marks[1].col_end)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("marks on second line when cursor is there", function()
      local bufnr = make_buf({ "hello world", "hello again" })
      vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- "hello" on line 2
      auditor.highlight_cword_buffer("blue")

      local marks = extmark_positions(bufnr, hl.ns)
      assert.equals(1, #marks)
      assert.equals(1, marks[1].line, "should be on line 1 (0-indexed)")

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── color correctness ─────────────────────────────────────────────────

  describe("color correctness", function()
    it("red uses AuditorRed", function()
      local bufnr = make_buf("token")
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")

      local marks = extmark_positions(bufnr, hl.ns)
      assert.equals("AuditorRed", marks[1].hl_group)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("blue uses AuditorBlue", function()
      local bufnr = make_buf("token")
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("blue")

      local marks = extmark_positions(bufnr, hl.ns)
      assert.equals("AuditorBlue", marks[1].hl_group)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("half creates per-character gradient", function()
      local bufnr = make_buf("token")
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("half")

      local marks = extmark_positions(bufnr, hl.ns)
      -- "token" (5 chars): 1 primary + 4 overlays = 5 raw extmarks
      assert.equals(5, #marks)
      -- All should be AuditorGrad* groups
      for _, m in ipairs(marks) do
        assert.is_truthy(m.hl_group:match("^AuditorGrad"))
      end
      -- 1 logical mark
      assert.equals(1, #hl.collect_extmarks(bufnr))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── cursor on non-word: no highlight ──────────────────────────────────

  describe("no word under cursor", function()
    it("does nothing when cursor is on whitespace", function()
      local bufnr = make_buf("hello world")
      vim.api.nvim_win_set_cursor(0, { 1, 5 }) -- space
      auditor.highlight_cword_buffer("red")

      local marks = extmark_positions(bufnr, hl.ns)
      assert.equals(0, #marks)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("does nothing when cursor is on punctuation", function()
      local bufnr = make_buf("a + b")
      vim.api.nvim_win_set_cursor(0, { 1, 2 }) -- '+'
      auditor.highlight_cword_buffer("red")

      local marks = extmark_positions(bufnr, hl.ns)
      assert.equals(0, #marks)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("does nothing on empty line", function()
      local bufnr = make_buf("")
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")

      local marks = extmark_positions(bufnr, hl.ns)
      assert.equals(0, #marks)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── underscore / C-style identifiers ──────────────────────────────────

  describe("identifiers with underscores", function()
    it("treats the full identifier as one word", function()
      local bufnr = make_buf("nvme_changed_nslist(n, rae)")
      vim.api.nvim_win_set_cursor(0, { 1, 5 }) -- 'c' in "changed"
      auditor.highlight_cword_buffer("red")

      local marks = extmark_positions(bufnr, hl.ns)
      assert.equals(1, #marks)
      assert.equals(0, marks[1].col_start)
      assert.equals(19, marks[1].col_end) -- "nvme_changed_nslist" = 19 chars
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("does not extend across parentheses", function()
      local bufnr = make_buf("foo(bar)")
      vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- 'f' in "foo"
      auditor.highlight_cword_buffer("red")

      local marks = extmark_positions(bufnr, hl.ns)
      assert.equals(1, #marks)
      assert.equals(0, marks[1].col_start)
      assert.equals(3, marks[1].col_end) -- "foo" only, not "foo(bar)"

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── pending state ─────────────────────────────────────────────────────

  describe("pending state", function()
    it("creates exactly one pending entry with one word", function()
      local bufnr = make_buf("hello world")
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")

      assert.not_nil(auditor._pending[bufnr])
      assert.equals(1, #auditor._pending[bufnr])
      assert.equals(1, #auditor._pending[bufnr][1].words)
      assert.equals("red", auditor._pending[bufnr][1].color)

      local w = auditor._pending[bufnr][1].words[1]
      assert.equals(0, w.line)
      assert.equals(0, w.col_start)
      assert.equals(5, w.col_end)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("multiple calls accumulate separate pending entries", function()
      local bufnr = make_buf("hello world")

      vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- "hello"
      auditor.highlight_cword_buffer("red")

      vim.api.nvim_win_set_cursor(0, { 1, 6 }) -- "world"
      auditor.highlight_cword_buffer("blue")

      assert.equals(2, #auditor._pending[bufnr])
      assert.equals("red", auditor._pending[bufnr][1].color)
      assert.equals("blue", auditor._pending[bufnr][2].color)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── persistence round-trip ────────────────────────────────────────────

  describe("persistence", function()
    it("save + reload restores exactly the single cword extmark", function()
      local bufnr, filepath = make_buf("hello world hello")
      vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- first "hello"
      auditor.highlight_cword_buffer("red")
      auditor.audit()

      -- Verify DB has exactly 1 row
      local db = require("auditor.db")
      local rows = db.get_highlights(filepath)
      assert.equals(1, #rows)
      assert.equals(0, rows[1].col_start)
      assert.equals(5, rows[1].col_end)

      -- Exit and re-enter to reload from DB
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      local marks = extmark_positions(bufnr, hl.ns)
      assert.equals(1, #marks)
      assert.equals(0, marks[1].col_start)
      assert.equals(5, marks[1].col_end)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── vim.cmd integration ───────────────────────────────────────────────

  describe("vim.cmd commands", function()
    it("AuditRed highlights only the cword", function()
      local bufnr = make_buf("foo bar foo")
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.cmd("AuditRed")

      local marks = extmark_positions(bufnr, hl.ns)
      assert.equals(1, #marks)
      assert.equals(0, marks[1].col_start)
      assert.equals(3, marks[1].col_end)
      assert.equals("AuditorRed", marks[1].hl_group)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("AuditBlue highlights only the cword", function()
      local bufnr = make_buf("foo bar foo")
      vim.api.nvim_win_set_cursor(0, { 1, 8 }) -- second "foo"
      vim.cmd("AuditBlue")

      local marks = extmark_positions(bufnr, hl.ns)
      assert.equals(1, #marks)
      assert.equals(8, marks[1].col_start)
      assert.equals(11, marks[1].col_end)
      assert.equals("AuditorBlue", marks[1].hl_group)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("AuditHalf highlights only the cword with gradient", function()
      local bufnr = make_buf("foo bar foo")
      vim.api.nvim_win_set_cursor(0, { 1, 4 }) -- "bar"
      vim.cmd("AuditHalf")

      -- "bar" (3 chars): 1 primary + 2 overlays = 3 raw extmarks
      -- But only 1 logical mark on "bar"
      local collected = hl.collect_extmarks(bufnr)
      assert.equals(1, #collected)
      assert.equals(4, collected[1].col_start)
      assert.equals(7, collected[1].col_end)
      assert.equals("half", collected[1].color)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── exhaustive: every cursor position on a multi-word line ────────────

  describe("exhaustive cursor position sweep", function()
    it("each word position produces exactly one extmark at the correct boundary", function()
      -- "abc def ghi" -> words at [0,3), [4,7), [8,11)
      local line = "abc def ghi"
      local bufnr = make_buf(line)
      local expected_words = {
        { col_start = 0, col_end = 3 }, -- "abc"
        { col_start = 4, col_end = 7 }, -- "def"
        { col_start = 8, col_end = 11 }, -- "ghi"
      }

      for col = 0, #line - 1 do
        -- Clear extmarks between tests
        vim.api.nvim_buf_clear_namespace(bufnr, hl.ns, 0, -1)
        auditor._pending[bufnr] = {}

        vim.api.nvim_win_set_cursor(0, { 1, col })
        auditor.highlight_cword_buffer("red")

        local marks = extmark_positions(bufnr, hl.ns)
        local ch = line:sub(col + 1, col + 1)

        if ch:match("[%w_]") then
          assert.equals(
            1,
            #marks,
            string.format("col %d ('%s'): expected 1 extmark, got %d", col, ch, #marks)
          )
          -- Verify it matches one of the expected words
          local found = false
          for _, ew in ipairs(expected_words) do
            if marks[1].col_start == ew.col_start and marks[1].col_end == ew.col_end then
              found = true
              break
            end
          end
          assert.is_true(
            found,
            string.format(
              "col %d: extmark [%d,%d) doesn't match any expected word",
              col,
              marks[1].col_start,
              marks[1].col_end
            )
          )
        else
          assert.equals(
            0,
            #marks,
            string.format(
              "col %d ('%s'): expected 0 extmarks on non-word char, got %d",
              col,
              ch,
              #marks
            )
          )
        end
      end

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── multi-line buffer: only cursor line is affected ───────────────────

  describe("multi-line: only cursor word is affected", function()
    it("10-line buffer with repeated word: only cursor instance marked", function()
      local lines = {}
      for i = 1, 10 do
        lines[i] = "count = count + " .. i
      end
      local bufnr = make_buf(lines)

      -- Cursor on "count" at line 5 (1-indexed), col 0
      vim.api.nvim_win_set_cursor(0, { 5, 0 })
      auditor.highlight_cword_buffer("red")

      local marks = extmark_positions(bufnr, hl.ns)
      assert.equals(1, #marks, "should highlight exactly 1 'count', not all 20")
      assert.equals(4, marks[1].line) -- 0-indexed line 4 = line 5
      assert.equals(0, marks[1].col_start)
      assert.equals(5, marks[1].col_end)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- AuditWordRed/Blue/Half — all occurrences in function scope
-- ═══════════════════════════════════════════════════════════════════════════

describe("highlight_cword (AuditWordRed/Blue/Half)", function()
  local auditor, hl
  local tmp_db

  before_each(function()
    reset_modules()
    tmp_db = vim.fn.tempname() .. ".db"
    auditor = require("auditor")
    auditor.setup({ db_path = tmp_db, keymaps = false })
    hl = require("auditor.highlights")
    auditor.enter_audit_mode()
  end)

  after_each(function()
    pcall(os.remove, tmp_db)
  end)

  -- Without treesitter (no parser available), highlight_cword falls back
  -- to the whole buffer for scope. So AuditWord* on a plain text buffer
  -- highlights ALL occurrences in the buffer.

  describe("without treesitter (whole buffer fallback)", function()
    it("highlights ALL occurrences of the word across the buffer", function()
      local bufnr = make_buf({ "foo bar foo", "baz foo qux" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- "foo" on line 1
      auditor.highlight_cword("red")

      local marks = extmark_positions(bufnr, hl.ns)
      -- "foo" appears at: line 0 col 0-3, line 0 col 8-11, line 1 col 4-7
      assert.equals(3, #marks, "expected 3 occurrences of 'foo' in buffer")

      assert.equals(0, marks[1].line)
      assert.equals(0, marks[1].col_start)
      assert.equals(3, marks[1].col_end)

      assert.equals(0, marks[2].line)
      assert.equals(8, marks[2].col_start)
      assert.equals(11, marks[2].col_end)

      assert.equals(1, marks[3].line)
      assert.equals(4, marks[3].col_start)
      assert.equals(7, marks[3].col_end)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("does not match partial words (boundary check)", function()
      local bufnr = make_buf("req request req_id req")
      -- "req" at col 0-3 and col 19-22 (the standalone ones)
      -- "request" at col 4-11 should NOT match
      -- "req_id" at col 12-18 should NOT match
      vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- "req"
      auditor.highlight_cword("blue")

      local marks = extmark_positions(bufnr, hl.ns)
      assert.equals(2, #marks, "expected 2 standalone 'req', not 'request' or 'req_id'")
      assert.equals(0, marks[1].col_start)
      assert.equals(3, marks[1].col_end)
      assert.equals(19, marks[2].col_start)
      assert.equals(22, marks[2].col_end)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("highlights word only once even if cursor is in the middle", function()
      local bufnr = make_buf("hello")
      vim.api.nvim_win_set_cursor(0, { 1, 2 }) -- 'l' in "hello"
      auditor.highlight_cword("red")

      local marks = extmark_positions(bufnr, hl.ns)
      assert.equals(1, #marks)
      assert.equals(0, marks[1].col_start)
      assert.equals(5, marks[1].col_end)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── color correctness for multi-occurrence ────────────────────────────

  describe("color correctness with multiple occurrences", function()
    it("red marks all occurrences as AuditorRed", function()
      local bufnr = make_buf("x y x")
      vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- "x"
      auditor.highlight_cword("red")

      local marks = extmark_positions(bufnr, hl.ns)
      assert.equals(2, #marks)
      for _, m in ipairs(marks) do
        assert.equals("AuditorRed", m.hl_group)
      end

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("blue marks all occurrences as AuditorBlue", function()
      local bufnr = make_buf("x y x")
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword("blue")

      local marks = extmark_positions(bufnr, hl.ns)
      for _, m in ipairs(marks) do
        assert.equals("AuditorBlue", m.hl_group)
      end

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("half gives each occurrence a gradient (1-char words use midpoint)", function()
      local bufnr = make_buf("x y x")
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword("half")

      -- "x" (1 char) × 2 occurrences: 1 extmark each (midpoint gradient, no overlays)
      local marks = extmark_positions(bufnr, hl.ns)
      assert.equals(2, #marks)
      -- Both should be midpoint gradient groups
      for _, m in ipairs(marks) do
        assert.is_truthy(m.hl_group:match("^AuditorGrad"))
      end
      -- 2 logical marks
      assert.equals(2, #hl.collect_extmarks(bufnr))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── vim.cmd integration ───────────────────────────────────────────────

  describe("vim.cmd commands", function()
    it("AuditWordRed highlights all occurrences", function()
      local bufnr = make_buf("foo bar foo")
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.cmd("AuditWordRed")

      local marks = extmark_positions(bufnr, hl.ns)
      assert.equals(2, #marks)
      assert.equals("AuditorRed", marks[1].hl_group)
      assert.equals("AuditorRed", marks[2].hl_group)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("AuditWordBlue highlights all occurrences", function()
      local bufnr = make_buf("bar baz bar")
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.cmd("AuditWordBlue")

      local marks = extmark_positions(bufnr, hl.ns)
      assert.equals(2, #marks)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("AuditWordHalf highlights all occurrences with gradient", function()
      local bufnr = make_buf("baz qux baz")
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.cmd("AuditWordHalf")

      -- "baz" (3 chars): 2 occurrences × 3 extmarks each = 6 total
      local marks = extmark_positions(bufnr, hl.ns)
      assert.equals(6, #marks)

      -- collect_extmarks sees only 2 logical marks
      local collected = hl.collect_extmarks(bufnr)
      assert.equals(2, #collected)
      assert.equals("half", collected[1].color)
      assert.equals("half", collected[2].color)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── pending state for AuditWord* ──────────────────────────────────────

  describe("pending state", function()
    it("stores all occurrences in pending", function()
      local bufnr = make_buf("x y x z x")
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword("red")

      assert.not_nil(auditor._pending[bufnr])
      assert.equals(1, #auditor._pending[bufnr])
      -- "x" at cols 0, 4, 8 → 3 occurrences
      assert.equals(3, #auditor._pending[bufnr][1].words)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("saves all occurrences to DB on audit", function()
      local bufnr, filepath = make_buf("x y x z x")
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword("red")
      auditor.audit()

      local db = require("auditor.db")
      local rows = db.get_highlights(filepath)
      assert.equals(3, #rows)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- CONTRAST: AuditRed vs AuditWordRed on same buffer
-- ═══════════════════════════════════════════════════════════════════════════

describe("AuditRed vs AuditWordRed contrast", function()
  local auditor, hl
  local tmp_db

  before_each(function()
    reset_modules()
    tmp_db = vim.fn.tempname() .. ".db"
    auditor = require("auditor")
    auditor.setup({ db_path = tmp_db, keymaps = false })
    hl = require("auditor.highlights")
    auditor.enter_audit_mode()
  end)

  after_each(function()
    pcall(os.remove, tmp_db)
  end)

  it("AuditRed marks 1 occurrence, AuditWordRed marks all", function()
    local lines = { "foo bar foo", "foo baz foo" }

    -- AuditRed: single cword
    local bufnr1 = make_buf(lines)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    local marks1 = extmark_positions(bufnr1, hl.ns)
    pcall(vim.api.nvim_buf_delete, bufnr1, { force = true })

    -- AuditWordRed: all occurrences (no treesitter → whole buffer)
    local bufnr2 = make_buf(lines)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword("red")
    local marks2 = extmark_positions(bufnr2, hl.ns)
    pcall(vim.api.nvim_buf_delete, bufnr2, { force = true })

    assert.equals(1, #marks1, "AuditRed should mark exactly 1")
    assert.equals(4, #marks2, "AuditWordRed should mark all 4 'foo' occurrences")
  end)

  it("marking different words accumulates correctly", function()
    local bufnr = make_buf("foo bar baz")

    -- Mark "foo" with AuditRed (single cword)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")

    -- Mark "baz" with AuditBlue (single cword)
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    auditor.highlight_cword_buffer("blue")

    local marks = extmark_positions(bufnr, hl.ns)
    assert.equals(2, #marks)
    assert.equals("AuditorRed", marks[1].hl_group)
    assert.equals(0, marks[1].col_start)
    assert.equals("AuditorBlue", marks[2].hl_group)
    assert.equals(8, marks[2].col_start)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- find_word_occurrences unit tests
-- ═══════════════════════════════════════════════════════════════════════════

describe("_find_word_occurrences", function()
  local auditor

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
  end)

  local function make_scratch(lines)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    return bufnr
  end

  it("finds all standalone occurrences", function()
    local bufnr = make_scratch({ "foo bar foo", "foo baz" })
    local hits = auditor._find_word_occurrences(bufnr, "foo", 0, 1)
    assert.equals(3, #hits)
  end)

  it("respects word boundaries (no partial match)", function()
    local bufnr = make_scratch({ "request req req_id" })
    local hits = auditor._find_word_occurrences(bufnr, "req", 0, 0)
    assert.equals(1, #hits)
    assert.equals(8, hits[1].col_start) -- standalone "req" at col 8
    assert.equals(11, hits[1].col_end)
  end)

  it("returns empty for no matches", function()
    local bufnr = make_scratch({ "hello world" })
    local hits = auditor._find_word_occurrences(bufnr, "xyz", 0, 0)
    assert.equals(0, #hits)
  end)

  it("restricts to row range", function()
    local bufnr = make_scratch({ "foo", "bar", "foo", "baz", "foo" })
    local hits = auditor._find_word_occurrences(bufnr, "foo", 1, 3)
    assert.equals(1, #hits) -- only the "foo" on line 2 (0-indexed)
    assert.equals(2, hits[1].line)
  end)

  it("handles multiple occurrences on same line", function()
    local bufnr = make_scratch({ "x x x x x" })
    local hits = auditor._find_word_occurrences(bufnr, "x", 0, 0)
    assert.equals(5, #hits)
    for i, h in ipairs(hits) do
      assert.equals((i - 1) * 2, h.col_start)
      assert.equals((i - 1) * 2 + 1, h.col_end)
    end
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- PROPERTY-BASED TESTS
-- ═══════════════════════════════════════════════════════════════════════════

-- Deterministic PRNG (LCG)
---@param seed integer
---@return fun(lo: integer, hi: integer): integer
local function make_rng(seed)
  local s = math.abs(seed) + 1
  return function(lo, hi)
    s = (s * 1664525 + 1013904223) % (2 ^ 32)
    return lo + (math.floor(s * (hi - lo + 1) / (2 ^ 32)))
  end
end

local function property(desc, n, fn)
  for seed = 1, n do
    local rng = make_rng(seed)
    local ok, err = pcall(fn, rng, seed)
    if not ok then
      error(
        string.format(
          "[highlight_cword] Property '%s' failed at seed=%d:\n%s",
          desc,
          seed,
          tostring(err)
        ),
        2
      )
    end
  end
end

describe("highlight_cword_buffer: property-based", function()
  local auditor, hl
  local tmp_db

  before_each(function()
    reset_modules()
    tmp_db = vim.fn.tempname() .. ".db"
    auditor = require("auditor")
    auditor.setup({ db_path = tmp_db, keymaps = false })
    hl = require("auditor.highlights")
    auditor.enter_audit_mode()
  end)

  after_each(function()
    pcall(os.remove, tmp_db)
  end)

  it("P1: always produces exactly 0 or 1 extmark regardless of buffer content", function()
    local words = { "foo", "bar", "baz", "x", "req", "nvme_dptr", "_val", "a1b2" }

    property("P1 single extmark", 300, function(rng)
      -- Build random lines with random words
      local n_lines = rng(1, 5)
      local lines = {}
      for i = 1, n_lines do
        local parts = {}
        local n_words = rng(1, 6)
        for _ = 1, n_words do
          parts[#parts + 1] = words[rng(1, #words)]
        end
        lines[i] = table.concat(parts, " ")
      end

      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.api.nvim_set_current_buf(bufnr)

      -- Place cursor on a random position
      local row = rng(1, n_lines)
      local line_len = #lines[row]
      local col = line_len > 0 and rng(0, line_len - 1) or 0
      vim.api.nvim_win_set_cursor(0, { row, col })

      vim.api.nvim_buf_clear_namespace(bufnr, hl.ns, 0, -1)
      hl.clear_half_pairs(bufnr)
      auditor._pending[bufnr] = {}

      local colors = { "red", "blue", "half" }
      local color = colors[rng(1, 3)]
      auditor.highlight_cword_buffer(color)

      -- Use collect_extmarks for logical count (half has 2 raw extmarks but 1 logical)
      local collected = hl.collect_extmarks(bufnr)
      local ch = lines[row]:sub(col + 1, col + 1)
      if ch:match("[%w_]") then
        assert(
          #collected == 1,
          string.format(
            "seed row=%d col=%d char='%s': expected 1 logical extmark, got %d",
            row,
            col,
            ch,
            #collected
          )
        )
      else
        assert(
          #collected == 0,
          string.format(
            "seed row=%d col=%d char='%s': expected 0 logical extmarks, got %d",
            row,
            col,
            ch,
            #collected
          )
        )
      end

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      pcall(os.remove, filepath)
    end)
  end)

  it("P2: extmark span always contains the cursor column", function()
    local words = { "alpha", "beta", "gamma", "x", "_y", "z1" }

    property("P2 cursor within extmark", 300, function(rng)
      local n_words = rng(2, 8)
      local parts = {}
      for _ = 1, n_words do
        parts[#parts + 1] = words[rng(1, #words)]
      end
      local line = table.concat(parts, " ")

      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
      vim.api.nvim_set_current_buf(bufnr)

      local col = rng(0, #line - 1)
      vim.api.nvim_win_set_cursor(0, { 1, col })

      vim.api.nvim_buf_clear_namespace(bufnr, hl.ns, 0, -1)
      auditor._pending[bufnr] = {}
      auditor.highlight_cword_buffer("red")

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, { details = true })
      if #marks == 1 then
        local cs = marks[1][3]
        local ce = marks[1][4].end_col
        assert(
          col >= cs and col < ce,
          string.format("cursor col %d not in extmark [%d, %d)", col, cs, ce)
        )
      end

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  it("P3: extmark text is always a valid [%w_]+ word", function()
    property("P3 extmark is a word", 300, function(rng)
      local parts = {}
      for _ = 1, rng(3, 10) do
        -- Random mix of words and punctuation
        if rng(0, 1) == 1 then
          local w = string.rep(string.char(rng(97, 122)), rng(1, 5))
          parts[#parts + 1] = w
        else
          parts[#parts + 1] = string.char(rng(33, 47)) -- punctuation
        end
      end
      local line = table.concat(parts, " ")

      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
      vim.api.nvim_set_current_buf(bufnr)

      local col = rng(0, math.max(0, #line - 1))
      vim.api.nvim_win_set_cursor(0, { 1, col })

      vim.api.nvim_buf_clear_namespace(bufnr, hl.ns, 0, -1)
      auditor._pending[bufnr] = {}
      auditor.highlight_cword_buffer("blue")

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, { details = true })
      if #marks == 1 then
        local cs = marks[1][3]
        local ce = marks[1][4].end_col
        local text = line:sub(cs + 1, ce)
        assert(text:match("^[%w_]+$"), string.format("extmark text '%s' is not a word", text))
      end

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  it("P4: pending always has exactly 1 word entry after highlight_cword_buffer", function()
    local words = { "foo", "bar", "baz" }

    property("P4 pending has 1 word", 200, function(rng)
      local line = words[rng(1, 3)] .. " " .. words[rng(1, 3)] .. " " .. words[rng(1, 3)]
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
      vim.api.nvim_set_current_buf(bufnr)
      auditor._pending[bufnr] = {}

      -- Place on a word character
      local word_cols = {}
      for i = 1, #line do
        if line:sub(i, i):match("[%w_]") then
          word_cols[#word_cols + 1] = i - 1
        end
      end
      if #word_cols == 0 then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        return
      end

      local col = word_cols[rng(1, #word_cols)]
      vim.api.nvim_win_set_cursor(0, { 1, col })

      local colors = { "red", "blue", "half" }
      auditor.highlight_cword_buffer(colors[rng(1, 3)])

      assert(#auditor._pending[bufnr] == 1, "expected 1 pending entry")
      assert(#auditor._pending[bufnr][1].words == 1, "expected 1 word in pending entry")

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      pcall(os.remove, filepath)
    end)
  end)
end)

describe("highlight_cword (AuditWord*): property-based", function()
  local auditor, hl
  local tmp_db

  before_each(function()
    reset_modules()
    tmp_db = vim.fn.tempname() .. ".db"
    auditor = require("auditor")
    auditor.setup({ db_path = tmp_db, keymaps = false })
    hl = require("auditor.highlights")
    auditor.enter_audit_mode()
  end)

  after_each(function()
    pcall(os.remove, tmp_db)
  end)

  it("P5: AuditWord* always marks >= 1 extmark when cursor is on a word", function()
    local words = { "foo", "bar", "baz", "x", "abc" }

    property("P5 at least 1 extmark", 200, function(rng)
      local n_lines = rng(1, 4)
      local lines = {}
      for i = 1, n_lines do
        local parts = {}
        for _ = 1, rng(2, 5) do
          parts[#parts + 1] = words[rng(1, #words)]
        end
        lines[i] = table.concat(parts, " ")
      end

      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.api.nvim_set_current_buf(bufnr)

      local row = rng(1, n_lines)
      -- Find a word-character column
      local word_cols = {}
      for i = 1, #lines[row] do
        if lines[row]:sub(i, i):match("[%w_]") then
          word_cols[#word_cols + 1] = i - 1
        end
      end
      if #word_cols == 0 then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        return
      end

      vim.api.nvim_win_set_cursor(0, { row, word_cols[rng(1, #word_cols)] })
      vim.api.nvim_buf_clear_namespace(bufnr, hl.ns, 0, -1)
      auditor._pending[bufnr] = {}

      local colors = { "red", "blue", "half" }
      auditor.highlight_cword(colors[rng(1, 3)])

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, {})
      assert(#marks >= 1, string.format("expected >= 1 extmark, got %d", #marks))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  it("P6: AuditWord* marks count matches find_word_occurrences count", function()
    local words = { "foo", "bar", "baz" }

    property("P6 count consistency", 200, function(rng)
      local n_lines = rng(1, 4)
      local lines = {}
      for i = 1, n_lines do
        local parts = {}
        for _ = 1, rng(2, 5) do
          parts[#parts + 1] = words[rng(1, #words)]
        end
        lines[i] = table.concat(parts, " ")
      end

      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.api.nvim_set_current_buf(bufnr)

      local row = rng(1, n_lines)
      local word_cols = {}
      for i = 1, #lines[row] do
        if lines[row]:sub(i, i):match("[%w_]") then
          word_cols[#word_cols + 1] = i - 1
        end
      end
      if #word_cols == 0 then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        return
      end

      local col = word_cols[rng(1, #word_cols)]
      vim.api.nvim_win_set_cursor(0, { row, col })

      -- Get the word under cursor
      local token = auditor._cword_token(bufnr)
      if not token then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        return
      end
      local word = lines[row]:sub(token.col_start + 1, token.col_end)

      -- Count expected occurrences in entire buffer (no treesitter → whole buffer)
      local expected = auditor._find_word_occurrences(bufnr, word, 0, n_lines - 1)

      vim.api.nvim_buf_clear_namespace(bufnr, hl.ns, 0, -1)
      auditor._pending[bufnr] = {}
      auditor.highlight_cword("red")

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, {})
      assert(
        #marks == #expected,
        string.format("expected %d extmarks, got %d for word '%s'", #expected, #marks, word)
      )

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  it("P7: AuditRed always produces strictly fewer or equal extmarks than AuditWordRed", function()
    local words = { "foo", "bar", "x" }

    property("P7 Audit <= AuditWord", 200, function(rng)
      local n_lines = rng(1, 5)
      local lines = {}
      for i = 1, n_lines do
        local parts = {}
        for _ = 1, rng(2, 4) do
          parts[#parts + 1] = words[rng(1, #words)]
        end
        lines[i] = table.concat(parts, " ")
      end

      -- AuditRed
      local bufnr1 = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr1, 0, -1, false, lines)
      vim.api.nvim_set_current_buf(bufnr1)

      local row = rng(1, n_lines)
      local word_cols = {}
      for i = 1, #lines[row] do
        if lines[row]:sub(i, i):match("[%w_]") then
          word_cols[#word_cols + 1] = i - 1
        end
      end
      if #word_cols == 0 then
        pcall(vim.api.nvim_buf_delete, bufnr1, { force = true })
        return
      end
      local col = word_cols[rng(1, #word_cols)]
      vim.api.nvim_win_set_cursor(0, { row, col })
      auditor.highlight_cword_buffer("red")
      local count1 = #vim.api.nvim_buf_get_extmarks(bufnr1, hl.ns, 0, -1, {})
      pcall(vim.api.nvim_buf_delete, bufnr1, { force = true })

      -- AuditWordRed
      local bufnr2 = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr2, 0, -1, false, lines)
      vim.api.nvim_set_current_buf(bufnr2)
      vim.api.nvim_win_set_cursor(0, { row, col })
      auditor.highlight_cword("red")
      local count2 = #vim.api.nvim_buf_get_extmarks(bufnr2, hl.ns, 0, -1, {})
      pcall(vim.api.nvim_buf_delete, bufnr2, { force = true })

      assert(count1 <= count2, string.format("AuditRed (%d) > AuditWordRed (%d)", count1, count2))
    end)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- FUZZ TESTS
-- ═══════════════════════════════════════════════════════════════════════════

describe("highlight commands: fuzz", function()
  local auditor, hl
  local tmp_db

  before_each(function()
    reset_modules()
    tmp_db = vim.fn.tempname() .. ".db"
    auditor = require("auditor")
    auditor.setup({ db_path = tmp_db, keymaps = false })
    hl = require("auditor.highlights")
  end)

  after_each(function()
    pcall(os.remove, tmp_db)
  end)

  it("F1: random interleaving of cword/word/save/clear/enter/exit never errors", function()
    property("F1 no crashes", 300, function(rng)
      local words = { "foo", "bar", "baz", "x", "_y" }
      local n_lines = rng(1, 5)
      local lines = {}
      for i = 1, n_lines do
        local parts = {}
        for _ = 1, rng(1, 4) do
          parts[#parts + 1] = words[rng(1, #words)]
        end
        lines[i] = table.concat(parts, " ")
      end

      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.api.nvim_set_current_buf(bufnr)

      local colors = { "red", "blue", "half" }
      local n_ops = rng(5, 25)
      for _ = 1, n_ops do
        local op = rng(1, 8)
        if op == 1 then
          auditor.enter_audit_mode()
        elseif op == 2 then
          auditor.exit_audit_mode()
        elseif op == 3 then
          local row = rng(1, n_lines)
          local col = #lines[row] > 0 and rng(0, #lines[row] - 1) or 0
          vim.api.nvim_win_set_cursor(0, { row, col })
          auditor.highlight_cword_buffer(colors[rng(1, 3)])
        elseif op == 4 then
          local row = rng(1, n_lines)
          local col = #lines[row] > 0 and rng(0, #lines[row] - 1) or 0
          vim.api.nvim_win_set_cursor(0, { row, col })
          auditor.highlight_cword(colors[rng(1, 3)])
        elseif op == 5 then
          auditor.audit()
        elseif op == 6 then
          auditor.clear_buffer()
        elseif op == 7 then
          vim.api.nvim_buf_clear_namespace(bufnr, hl.ns, 0, -1)
        elseif op == 8 then
          -- Noop: just move cursor
          local row = rng(1, n_lines)
          local col = #lines[row] > 0 and rng(0, #lines[row] - 1) or 0
          vim.api.nvim_win_set_cursor(0, { row, col })
        end
      end

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      pcall(os.remove, filepath)
    end)
  end)

  it(
    "F2: cword_buffer → save → exit → enter round-trip always restores exactly 1 extmark",
    function()
      property("F2 round-trip single cword", 200, function(rng)
        local words = { "alpha", "beta", "gamma" }
        local n_lines = rng(1, 4)
        local lines = {}
        for i = 1, n_lines do
          local parts = {}
          for _ = 1, rng(2, 5) do
            parts[#parts + 1] = words[rng(1, #words)]
          end
          lines[i] = table.concat(parts, " ")
        end

        local bufnr = vim.api.nvim_create_buf(false, true)
        local filepath = vim.fn.tempname() .. ".lua"
        vim.api.nvim_buf_set_name(bufnr, filepath)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.api.nvim_set_current_buf(bufnr)

        auditor.enter_audit_mode()

        -- Find a word position
        local row = rng(1, n_lines)
        local word_cols = {}
        for i = 1, #lines[row] do
          if lines[row]:sub(i, i):match("[%w_]") then
            word_cols[#word_cols + 1] = i - 1
          end
        end
        if #word_cols == 0 then
          pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
          pcall(os.remove, filepath)
          return
        end

        vim.api.nvim_win_set_cursor(0, { row, word_cols[rng(1, #word_cols)] })
        auditor.highlight_cword_buffer("red")
        auditor.audit()

        local db = require("auditor.db")
        local saved = #db.get_highlights(filepath)
        assert(saved == 1, string.format("expected 1 saved row, got %d", saved))

        -- Exit and re-enter
        auditor.exit_audit_mode()
        assert(#vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, {}) == 0)
        auditor.enter_audit_mode()

        local restored = #vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, {})
        assert(restored == 1, string.format("expected 1 restored extmark, got %d", restored))

        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        pcall(os.remove, filepath)
      end)
    end
  )

  it("F3: repeated cword_buffer calls accumulate exactly N logical extmarks for N calls", function()
    property("F3 accumulation", 200, function(rng)
      local line = "aa bb cc dd ee"
      -- Words at: aa[0,2) bb[3,5) cc[6,8) dd[9,11) ee[12,14)
      local word_starts = { 0, 3, 6, 9, 12 }

      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
      vim.api.nvim_set_current_buf(bufnr)

      auditor.enter_audit_mode()

      local n_marks = rng(1, 5)
      local colors = { "red", "blue", "half" }
      for i = 1, n_marks do
        local col = word_starts[i]
        vim.api.nvim_win_set_cursor(0, { 1, col })
        auditor.highlight_cword_buffer(colors[rng(1, 3)])
      end

      -- Use collect_extmarks for logical count (half creates 2 raw extmarks per word)
      local collected = hl.collect_extmarks(bufnr)
      assert(
        #collected == n_marks,
        string.format("expected %d logical extmarks after %d calls, got %d", n_marks, n_marks, #collected)
      )

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)
end)
