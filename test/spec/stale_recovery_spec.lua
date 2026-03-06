-- test/spec/stale_recovery_spec.lua
-- Tests for the stale highlight recovery system: when DB positions no longer
-- match the current buffer contents, recover_highlight() searches nearby lines
-- for the same word_text and returns the closest match.
--
-- Coverage:
--   SR1  Exact match — no recovery needed, word applied at original position
--   SR2  Line shifted down — word found on nearby line
--   SR3  Line shifted up — word found above original line
--   SR4  Column shifted — word found at different column on same line
--   SR5  Word deleted — no match, highlight skipped
--   SR6  Word renamed — no match for original text, skipped
--   SR7  Multiple candidates — picks closest to original position
--   SR8  Pre-migration data (empty word_text) — no recovery attempted, uses raw position
--   SR9  Already occupied position — recovery still works (multiple highlights)
--   SR10 Large shift (beyond RECOVERY_RADIUS) — not found
--   SR11 Full lifecycle: save → shift lines → re-enter → highlights recovered
--   SR12 Recovery notification shown when highlights recovered
--   SR13 Recovery with gradient color
--   SR14 Recovery count in notification is accurate
--   SR15 Property-based: random line shifts never crash
--   SR16 Edge: word_text at very start/end of buffer
--   SR17 Edge: single-character word recovery
--   SR18 Recovery ignores partial word matches (word boundary)
--   SR19 Multiple words recovered in same load_for_buffer call
--   SR20 Recovery with note attached — note restored at new position

local function reset_modules()
  for _, m in ipairs({ "auditor", "auditor.init", "auditor.db", "auditor.highlights", "auditor.ts" }) do
    package.loaded[m] = nil
  end
end

local function capture_notify()
  local messages = {}
  local orig = vim.notify
  vim.notify = function(msg, level)
    table.insert(messages, { msg = msg, level = level })
  end
  return function()
    vim.notify = orig
  end, messages
end

-- Deterministic PRNG for property-based tests.
local function make_rng(seed)
  local s = math.abs(seed) + 1
  return function(lo, hi)
    s = (s * 1664525 + 1013904223) % (2 ^ 32)
    return lo + math.floor(s * (hi - lo + 1) / (2 ^ 32))
  end
end

describe("stale recovery", function()
  local auditor, db, hl

  before_each(function()
    reset_modules()
    local tmp_db = vim.fn.tempname() .. ".db"
    auditor = require("auditor")
    auditor.setup({ db_path = tmp_db, keymaps = false })
    auditor._note_input_override = true
    db = require("auditor.db")
    hl = require("auditor.highlights")
  end)

  -- ── SR1: Exact match — no recovery needed ───────────────────────────────
  describe("SR1: exact match", function()
    it("applies at original position when text matches", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(bufnr)

      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      auditor.audit()
      auditor.exit_audit_mode()

      -- Re-enter without modifying buffer
      auditor.enter_audit_mode()

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, { details = true })
      assert.is_true(#marks >= 1)
      assert.equals(0, marks[1][3]) -- col_start
      assert.equals(5, marks[1][4].end_col) -- col_end

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── SR2: Line shifted down ──────────────────────────────────────────────
  describe("SR2: line shifted down", function()
    it("recovers highlight on shifted line", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(bufnr)

      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      auditor.audit()
      auditor.exit_audit_mode()

      -- Insert 3 blank lines before the original line
      vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "", "", "" })

      auditor.enter_audit_mode()

      -- "hello" should now be on line 3 (0-indexed)
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, { details = true })
      assert.is_true(#marks >= 1)
      assert.equals(3, marks[1][2]) -- row
      assert.equals(0, marks[1][3]) -- col_start
      assert.equals(5, marks[1][4].end_col)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── SR3: Line shifted up ───────────────────────────────────────────────
  describe("SR3: line shifted up", function()
    it("recovers highlight when lines removed above", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "line1",
        "line2",
        "line3",
        "hello world",
      })
      vim.api.nvim_set_current_buf(bufnr)

      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 4, 0 }) -- "hello" on line 4
      auditor.highlight_cword_buffer("red")
      auditor.audit()
      auditor.exit_audit_mode()

      -- Remove first 2 lines — "hello world" shifts from line 3 to line 1
      vim.api.nvim_buf_set_lines(bufnr, 0, 2, false, {})

      auditor.enter_audit_mode()

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, { details = true })
      assert.is_true(#marks >= 1)
      assert.equals(1, marks[1][2]) -- row (was 3, now 1)
      assert.equals(0, marks[1][3])
      assert.equals(5, marks[1][4].end_col)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── SR4: Column shifted ────────────────────────────────────────────────
  describe("SR4: column shifted", function()
    it("recovers when word moves to different column", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(bufnr)

      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      auditor.audit()
      auditor.exit_audit_mode()

      -- Change line so "hello" starts at col 4
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "    hello world" })

      auditor.enter_audit_mode()

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, { details = true })
      assert.is_true(#marks >= 1)
      assert.equals(4, marks[1][3]) -- col_start shifted
      assert.equals(9, marks[1][4].end_col)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── SR5: Word deleted ──────────────────────────────────────────────────
  describe("SR5: word deleted", function()
    it("highlight is skipped when word is gone", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(bufnr)

      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      auditor.audit()
      auditor.exit_audit_mode()

      -- Replace with content that doesn't contain "hello"
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "goodbye world" })

      auditor.enter_audit_mode()

      -- No highlight since "hello" doesn't exist
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, {})
      assert.equals(0, #marks)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── SR6: Word renamed ─────────────────────────────────────────────────
  describe("SR6: word renamed", function()
    it("original highlight not recovered after rename", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "foo bar" })
      vim.api.nvim_set_current_buf(bufnr)

      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("blue")
      auditor.audit()
      auditor.exit_audit_mode()

      -- Rename "foo" to "baz"
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "baz bar" })

      auditor.enter_audit_mode()

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, {})
      assert.equals(0, #marks)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── SR7: Multiple candidates — picks closest ──────────────────────────
  describe("SR7: multiple candidates, picks closest", function()
    it("picks the occurrence nearest to original position", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "local x = 1",
        "local hello = 2",
        "local y = 3",
      })
      vim.api.nvim_set_current_buf(bufnr)

      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 2, 6 }) -- "hello" on line 2
      auditor.highlight_cword_buffer("red")
      auditor.audit()
      auditor.exit_audit_mode()

      -- Now "hello" appears on lines far apart; the one on line 3 is closest to original line 1
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "hello far away", -- line 0
        "local x = 1",
        "local hello = 2", -- line 2 (was line 1)
        "local y = 3",
        "hello also far", -- line 4
      })

      auditor.enter_audit_mode()

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, { details = true })
      assert.is_true(#marks >= 1)
      -- Closest to original (line=1, col=6) should be line 2, col 6
      assert.equals(2, marks[1][2])
      assert.equals(6, marks[1][3])

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── SR8: Pre-migration data (empty word_text) ─────────────────────────
  describe("SR8: empty word_text — no recovery, raw position used", function()
    it("uses raw position when word_text is empty", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })

      -- Insert directly into DB with empty word_text (simulates pre-migration data)
      db.save_words(filepath, { { line = 0, col_start = 0, col_end = 5 } }, "red")

      auditor.enter_audit_mode()
      auditor.load_for_buffer(bufnr)

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, { details = true })
      assert.is_true(#marks >= 1)
      assert.equals(0, marks[1][3])
      assert.equals(5, marks[1][4].end_col)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── SR9: Already occupied position ────────────────────────────────────
  describe("SR9: recovery with occupied positions", function()
    it("multiple highlights can be recovered independently", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(bufnr)

      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red") -- hello
      vim.api.nvim_win_set_cursor(0, { 1, 6 })
      auditor.highlight_cword_buffer("blue") -- world
      auditor.audit()
      auditor.exit_audit_mode()

      -- Shift both words down by one line
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "new line", "hello world" })

      auditor.enter_audit_mode()

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, { details = true })
      -- Both should be recovered on line 1
      assert.is_true(#marks >= 2)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── SR10: Large shift beyond RECOVERY_RADIUS ──────────────────────────
  describe("SR10: beyond recovery radius", function()
    it("highlight is skipped when word moves too far", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(bufnr)

      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      auditor.audit()
      auditor.exit_audit_mode()

      -- Build a buffer where "hello" is 100 lines away
      local lines = {}
      for i = 1, 100 do
        lines[i] = "nothing here"
      end
      lines[101] = "hello world"
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

      auditor.enter_audit_mode()

      -- Word is beyond radius — should not be found
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, {})
      assert.equals(0, #marks)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── SR11: Full lifecycle with line shift ──────────────────────────────
  describe("SR11: full lifecycle", function()
    it("save, shift, re-enter — highlights recovered", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "function test()",
        "  local x = hello",
        "end",
      })
      vim.api.nvim_set_current_buf(bufnr)

      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 2, 12 })
      auditor.highlight_cword_buffer("blue")
      auditor.audit()
      auditor.exit_audit_mode()

      -- Insert a comment at the top
      vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "-- header comment" })

      auditor.enter_audit_mode()

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, { details = true })
      assert.is_true(#marks >= 1)
      -- "hello" is now on line 2 (was 1)
      assert.equals(2, marks[1][2])

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── SR12: Recovery notification ───────────────────────────────────────
  describe("SR12: recovery notification", function()
    it("shows notification when highlights are recovered", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(bufnr)

      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      auditor.audit()
      auditor.exit_audit_mode()

      -- Shift the line down
      vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "new line" })

      local restore, msgs = capture_notify()
      auditor.enter_audit_mode()
      restore()

      local found = false
      for _, m in ipairs(msgs) do
        if m.msg:match("Recovered") then
          found = true
        end
      end
      assert.is_true(found)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── SR13: Recovery with gradient color ────────────────────────────────
  describe("SR13: gradient recovery", function()
    it("gradient highlights recovered after line shift", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "gradient test" })
      vim.api.nvim_set_current_buf(bufnr)

      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("half")
      auditor.audit()
      auditor.exit_audit_mode()

      vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "inserted" })

      auditor.enter_audit_mode()

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, { details = true })
      -- Gradient creates multiple extmarks; at least the primary should exist
      assert.is_true(#marks >= 1)
      -- Should be on line 1 (shifted from 0)
      assert.equals(1, marks[1][2])

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── SR14: Recovery count accuracy ────────────────────────────────────
  describe("SR14: recovery count accuracy", function()
    it("notification shows correct count", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "aaa bbb ccc" })
      vim.api.nvim_set_current_buf(bufnr)

      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      vim.api.nvim_win_set_cursor(0, { 1, 4 })
      auditor.highlight_cword_buffer("blue")
      auditor.audit()
      auditor.exit_audit_mode()

      -- Shift
      vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "new" })

      local restore, msgs = capture_notify()
      auditor.enter_audit_mode()
      restore()

      local found_msg = nil
      for _, m in ipairs(msgs) do
        if m.msg:match("Recovered %d+ stale") then
          found_msg = m.msg
        end
      end
      assert.is_not_nil(found_msg)
      assert.is_truthy(found_msg:match("Recovered 2 stale"))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── SR15: Property-based: random line shifts never crash ──────────────
  describe("SR15: property — random shifts never crash (100 iterations)", function()
    it("recover_highlight never errors", function()
      local bufnr = vim.api.nvim_create_buf(false, true)

      for seed = 1, 100 do
        local rng = make_rng(seed)
        local n_lines = rng(1, 20)
        local lines = {}
        local words = { "hello", "world", "foo", "bar", "test" }
        for i = 1, n_lines do
          lines[i] = words[rng(1, #words)] .. " " .. words[rng(1, #words)]
        end
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

        local row = {
          line = rng(0, n_lines + 5),
          col_start = rng(0, 20),
          col_end = rng(0, 30),
          word_text = words[rng(1, #words)],
          color = "red",
          word_index = 1,
        }

        local ok, err = pcall(auditor._recover_highlight, bufnr, row)
        assert(ok, string.format("seed=%d: recover_highlight errored: %s", seed, tostring(err)))
      end

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── SR16: Word at very start/end of buffer ───────────────────────────
  describe("SR16: edge positions", function()
    it("recovers word at line 0", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "target here" })

      local row = {
        line = 5, col_start = 0, col_end = 6,
        word_text = "target", color = "red", word_index = 1,
      }
      local result = auditor._recover_highlight(bufnr, row)
      assert.is_not_nil(result)
      assert.equals(0, result.line)
      assert.equals(0, result.col_start)
      assert.equals(6, result.col_end)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("recovers word at last line", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "other", "other", "target" })

      local row = {
        line = 0, col_start = 0, col_end = 6,
        word_text = "target", color = "red", word_index = 1,
      }
      local result = auditor._recover_highlight(bufnr, row)
      assert.is_not_nil(result)
      assert.equals(2, result.line)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── SR17: Single-character word ────────────────────────────────────────
  describe("SR17: single-character word", function()
    it("recovers single character word", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "a = b + c" })

      local row = {
        line = 5, col_start = 0, col_end = 1,
        word_text = "a", color = "red", word_index = 1,
      }
      local result = auditor._recover_highlight(bufnr, row)
      assert.is_not_nil(result)
      assert.equals(0, result.line)
      assert.equals(0, result.col_start)
      assert.equals(1, result.col_end)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── SR18: Word boundary respected ─────────────────────────────────────
  describe("SR18: word boundary", function()
    it("does not match partial words", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "request required" })

      local row = {
        line = 0, col_start = 0, col_end = 3,
        word_text = "req", color = "red", word_index = 1,
      }
      local result = auditor._recover_highlight(bufnr, row)
      -- "req" doesn't appear as a whole word, only as prefix of "request"/"required"
      assert.is_nil(result)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── SR19: Multiple words recovered ────────────────────────────────────
  describe("SR19: multiple words recovered", function()
    it("all shifted words recovered in one load", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "alpha beta",
        "gamma delta",
      })
      vim.api.nvim_set_current_buf(bufnr)

      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red") -- alpha
      vim.api.nvim_win_set_cursor(0, { 1, 6 })
      auditor.highlight_cword_buffer("blue") -- beta
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      auditor.highlight_cword_buffer("red") -- gamma
      auditor.audit()
      auditor.exit_audit_mode()

      -- Add 2 lines at top
      vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "new1", "new2" })

      auditor.enter_audit_mode()

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, {})
      assert.equals(3, #marks) -- all three recovered

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── SR20: Recovery with note attached ─────────────────────────────────
  describe("SR20: recovery with note", function()
    it("note is restored at recovered position", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(bufnr)

      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")

      -- Add note via stubbed input
      local orig_input = vim.ui.input
      vim.ui.input = function(_, cb) cb("recover me") end
      auditor.add_note()
      vim.ui.input = orig_input

      auditor.audit()
      auditor.exit_audit_mode()

      -- Shift "hello world" down
      vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "inserted" })

      auditor.enter_audit_mode()

      -- Check note virtual text exists on the new line
      local note_marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      local found = false
      for _, m in ipairs(note_marks) do
        local vt = m[4].virt_text
        if vt then
          for _, chunk in ipairs(vt) do
            if chunk[1]:match("recover me") then
              found = true
            end
          end
        end
      end
      assert.is_true(found)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── Unit test: recover_highlight function directly ────────────────────
  describe("recover_highlight unit tests", function()
    it("returns nil when word_text is empty", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })

      local result = auditor._recover_highlight(bufnr, {
        line = 0, col_start = 0, col_end = 5,
        word_text = "", color = "red", word_index = 1,
      })
      assert.is_nil(result)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("returns nil when word_text is nil", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })

      local result = auditor._recover_highlight(bufnr, {
        line = 0, col_start = 0, col_end = 5,
        word_text = nil, color = "red", word_index = 1,
      })
      assert.is_nil(result)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("returns position when word is found at exact location", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })

      local result = auditor._recover_highlight(bufnr, {
        line = 0, col_start = 0, col_end = 5,
        word_text = "hello", color = "red", word_index = 1,
      })
      assert.is_not_nil(result)
      assert.equals(0, result.line)
      assert.equals(0, result.col_start)
      assert.equals(5, result.col_end)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("picks closest of multiple matches", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "hello", "other", "other", "other", "hello",
      })

      -- Original at line 1 — closest is line 0
      local result = auditor._recover_highlight(bufnr, {
        line = 1, col_start = 0, col_end = 5,
        word_text = "hello", color = "red", word_index = 1,
      })
      assert.is_not_nil(result)
      assert.equals(0, result.line)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("returns nil for empty buffer", function()
      local bufnr = vim.api.nvim_create_buf(false, true)

      local result = auditor._recover_highlight(bufnr, {
        line = 0, col_start = 0, col_end = 5,
        word_text = "hello", color = "red", word_index = 1,
      })
      assert.is_nil(result)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)
end)
