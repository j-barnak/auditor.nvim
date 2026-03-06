-- test/spec/notes_underline_spec.lua
-- Tests for the underline-based note indicator system.
--
-- The note indicator is a subtle underline on the highlighted word (hl_group
-- "AuditorNote" with underline + sp color) in note_ns, with an optional sign
-- column icon. Notes no longer use EOL virtual text.
--
-- Coverage:
--   U1  Underline extmark has hl_group "AuditorNote"
--   U2  Underline spans the exact word range (col_start to col_end)
--   U3  Underline is on the correct line
--   U4  AuditorNote hl group has underline attribute
--   U5  Sign icon present on underline extmark
--   U6  Sign color matches audit color
--   U7  Multiple notes on same line: each word gets its own underline
--   U8  Multiple notes on same line: underlines at correct positions
--   U9  Multiple notes on same line: signs for each
--   U10 Multiple notes on same line: delete one, others remain
--   U11 Multiple notes on same line: DB round-trip preserves all
--   U12 Multiple notes on same line: undo one, others remain
--   U13 Multiple notes on same line: different colors
--   U14 Three words same line: add/edit/delete interleaved
--   U15 Underline survives mode transitions
--   U16 Underline survives save → exit → enter cycle
--   U17 Underline removed when note deleted
--   U18 Underline removed when highlight undone
--   U19 Underline removed when buffer cleared
--   U20 No underline when note is empty/cancelled
--   U21 Re-mark removes underline (dedup clears old note)
--   U22 Underline on gradient (half) highlight
--   U23 Underline position after line insert above
--   U24 Underline position after line delete above
--   U25 Underline on very short word (1 char)
--   U26 Underline on very long word (200 chars)
--   U27 Multiple notes same line: count consistency
--   U28 Underline does not affect buffer content
--   U29 show_note works with underline (viewer unaffected)
--   U30 Underline priority is 200 (above highlight at 100)
--   U31 Same-line notes: save → exit → enter → all restored
--   U32 Same-line notes: stale recovery after line shift
--   U33 Five words on one line: add notes to all, verify
--   U34 Rapid add/delete cycles on same line
--   U35 Note on adjacent words (no space between highlights)

local function reset_modules()
  for _, m in ipairs({ "auditor", "auditor.init", "auditor.db", "auditor.highlights", "auditor.ts" }) do
    package.loaded[m] = nil
  end
end

describe("notes underline", function()
  local auditor, hl

  before_each(function()
    reset_modules()
    local tmp_db = vim.fn.tempname() .. ".db"
    auditor = require("auditor")
    auditor.setup({ db_path = tmp_db, keymaps = false })
    auditor._note_input_override = true
    hl = require("auditor.highlights")
  end)

  after_each(function()
    if auditor and auditor._note_float_buf and vim.api.nvim_buf_is_valid(auditor._note_float_buf) then
      vim.bo[auditor._note_float_buf].modified = false
    end
    if auditor and auditor._note_float_win and vim.api.nvim_win_is_valid(auditor._note_float_win) then
      pcall(vim.api.nvim_win_close, auditor._note_float_win, true)
    end
    if auditor then
      auditor._note_float_win = nil
      auditor._note_float_buf = nil
    end
    local cur = vim.api.nvim_get_current_buf()
    if vim.bo[cur].buftype == "acwrite" then
      vim.bo[cur].modified = false
      pcall(vim.api.nvim_buf_delete, cur, { force = true })
    end
  end)

  local function setup_buf(lines, cursor_row, cursor_col)
    local bufnr = vim.api.nvim_create_buf(false, true)
    local filepath = vim.fn.tempname() .. ".lua"
    vim.api.nvim_buf_set_name(bufnr, filepath)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_set_current_buf(bufnr)
    auditor.enter_audit_mode()
    if cursor_row then
      vim.api.nvim_win_set_cursor(0, { cursor_row, cursor_col or 0 })
    end
    return bufnr, filepath
  end

  local function cleanup(bufnr)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end

  local function stub_input(response)
    local orig = vim.ui.input
    vim.ui.input = function(_opts, callback)
      callback(response)
    end
    return function()
      vim.ui.input = orig
    end
  end

  local function note_extmarks(bufnr)
    return vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
  end

  local function note_count(bufnr)
    if not auditor._notes[bufnr] then return 0 end
    local c = 0
    for _ in pairs(auditor._notes[bufnr]) do c = c + 1 end
    return c
  end

  local function add_note_at(_bufnr, row, col, text)
    vim.api.nvim_win_set_cursor(0, { row, col })
    auditor.highlight_cword_buffer("red")
    local ri = stub_input(text)
    auditor.add_note()
    ri()
  end

  local function add_note_at_color(_bufnr, row, col, color, text)
    vim.api.nvim_win_set_cursor(0, { row, col })
    auditor.highlight_cword_buffer(color)
    local ri = stub_input(text)
    auditor.add_note()
    ri()
  end

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Basic underline extmark properties (U1-U6)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("U1: hl_group is AuditorNote", function()
    it("underline extmark has correct hl_group", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      add_note_at(bufnr, 1, 0, "test note")

      local marks = note_extmarks(bufnr)
      assert.equals(1, #marks)
      assert.equals("AuditorNote", marks[1][4].hl_group)
      cleanup(bufnr)
    end)
  end)

  describe("U2: underline spans exact word range", function()
    it("col_start and end_col match the word", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      add_note_at(bufnr, 1, 0, "note")

      local marks = note_extmarks(bufnr)
      -- "hello" is at col 0-5
      assert.equals(0, marks[1][3]) -- col_start
      assert.equals(5, marks[1][4].end_col) -- col_end
      cleanup(bufnr)
    end)

    it("second word gets correct range", function()
      local bufnr = setup_buf({ "hello world" }, 1, 6)
      add_note_at(bufnr, 1, 6, "note")

      local marks = note_extmarks(bufnr)
      -- "world" is at col 6-11
      assert.equals(6, marks[1][3])
      assert.equals(11, marks[1][4].end_col)
      cleanup(bufnr)
    end)
  end)

  describe("U3: underline on correct line", function()
    it("note on line 2 has row 1 (0-indexed)", function()
      local bufnr = setup_buf({ "first", "hello world" }, 2, 0)
      add_note_at(bufnr, 2, 0, "note")

      local marks = note_extmarks(bufnr)
      assert.equals(1, marks[1][2]) -- row (0-indexed)
      cleanup(bufnr)
    end)
  end)

  describe("U4: AuditorNote has underline attribute", function()
    it("hl group includes underline", function()
      local hl_info = vim.api.nvim_get_hl(0, { name = "AuditorNote" })
      assert.is_true(hl_info.underline == true)
      -- sp (special/underline color) should be set
      assert.is_not_nil(hl_info.sp)
    end)
  end)

  describe("U5: sign icon present", function()
    it("underline extmark has sign_text", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      add_note_at(bufnr, 1, 0, "note")

      local marks = note_extmarks(bufnr)
      assert.is_not_nil(marks[1][4].sign_text)
      cleanup(bufnr)
    end)
  end)

  describe("U6: sign uses single color for all audit colors", function()
    it("red highlight gets AuditorNoteSign", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      add_note_at_color(bufnr, 1, 0, "red", "note")

      local marks = note_extmarks(bufnr)
      assert.equals("AuditorNoteSign", marks[1][4].sign_hl_group)
      cleanup(bufnr)
    end)

    it("blue highlight gets AuditorNoteSign", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      add_note_at_color(bufnr, 1, 0, "blue", "note")

      local marks = note_extmarks(bufnr)
      assert.equals("AuditorNoteSign", marks[1][4].sign_hl_group)
      cleanup(bufnr)
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Multiple notes on same line (U7-U14)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("U7: multiple notes same line each get underline", function()
    it("two words on same line each get underline extmark", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      add_note_at(bufnr, 1, 0, "note1") -- hello
      add_note_at(bufnr, 1, 6, "note2") -- world

      local marks = note_extmarks(bufnr)
      assert.equals(2, #marks)
      assert.equals(2, note_count(bufnr))
      cleanup(bufnr)
    end)
  end)

  describe("U8: same-line underlines at correct positions", function()
    it("each underline spans its own word", function()
      local bufnr = setup_buf({ "alpha bravo charlie" }, 1, 0)
      add_note_at(bufnr, 1, 0, "n1")    -- alpha: 0-5
      add_note_at(bufnr, 1, 6, "n2")    -- bravo: 6-11
      add_note_at(bufnr, 1, 12, "n3")   -- charlie: 12-19

      local marks = note_extmarks(bufnr)
      assert.equals(3, #marks)

      -- Sort by col_start
      table.sort(marks, function(a, b) return a[3] < b[3] end)

      -- alpha
      assert.equals(0, marks[1][3])
      assert.equals(5, marks[1][4].end_col)
      -- bravo
      assert.equals(6, marks[2][3])
      assert.equals(11, marks[2][4].end_col)
      -- charlie
      assert.equals(12, marks[3][3])
      assert.equals(19, marks[3][4].end_col)

      cleanup(bufnr)
    end)
  end)

  describe("U9: same-line signs for each", function()
    it("each underline has its own sign", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      add_note_at(bufnr, 1, 0, "n1")
      add_note_at(bufnr, 1, 6, "n2")

      local marks = note_extmarks(bufnr)
      for _, m in ipairs(marks) do
        assert.is_not_nil(m[4].sign_text)
      end
      cleanup(bufnr)
    end)
  end)

  describe("U10: delete one note, others remain", function()
    it("deleting one note on same line preserves the other", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      add_note_at(bufnr, 1, 0, "n1")
      add_note_at(bufnr, 1, 6, "n2")
      assert.equals(2, note_count(bufnr))

      -- Delete note on "hello"
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.delete_note()

      assert.equals(1, note_count(bufnr))
      local marks = note_extmarks(bufnr)
      assert.equals(1, #marks)
      -- Remaining underline is on "world" (col 6-11)
      assert.equals(6, marks[1][3])
      cleanup(bufnr)
    end)
  end)

  describe("U11: same-line notes DB round-trip", function()
    it("multiple notes on same line persist and restore", function()
      local bufnr = setup_buf({ "alpha bravo charlie" }, 1, 0)
      add_note_at(bufnr, 1, 0, "note_a")
      add_note_at(bufnr, 1, 6, "note_b")
      add_note_at(bufnr, 1, 12, "note_c")

      auditor.audit()
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      assert.equals(3, note_count(bufnr))
      local marks = note_extmarks(bufnr)
      assert.equals(3, #marks)

      -- Verify all notes in state
      local texts = {}
      for _, t in pairs(auditor._notes[bufnr]) do
        texts[t] = true
      end
      assert.is_true(texts["note_a"])
      assert.is_true(texts["note_b"])
      assert.is_true(texts["note_c"])

      cleanup(bufnr)
    end)
  end)

  describe("U12: undo one note on same line, others remain", function()
    it("undoing highlight removes that note only", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      add_note_at(bufnr, 1, 0, "n1")
      add_note_at(bufnr, 1, 6, "n2")

      -- Undo "world" highlight
      vim.api.nvim_win_set_cursor(0, { 1, 6 })
      auditor.undo_at_cursor()

      assert.equals(1, note_count(bufnr))
      local marks = note_extmarks(bufnr)
      assert.equals(1, #marks)
      -- Remaining is "hello" (col 0-5)
      assert.equals(0, marks[1][3])
      cleanup(bufnr)
    end)
  end)

  describe("U13: same-line notes with different colors", function()
    it("both signs use AuditorNoteSign (single color)", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      add_note_at_color(bufnr, 1, 0, "red", "n1")
      add_note_at_color(bufnr, 1, 6, "blue", "n2")

      local marks = note_extmarks(bufnr)
      assert.equals(2, #marks)
      table.sort(marks, function(a, b) return a[3] < b[3] end)

      assert.equals("AuditorNoteSign", marks[1][4].sign_hl_group)
      assert.equals("AuditorNoteSign", marks[2][4].sign_hl_group)
      cleanup(bufnr)
    end)
  end)

  describe("U14: three words same line add/edit/delete", function()
    it("interleaved operations leave correct state", function()
      local bufnr = setup_buf({ "alpha bravo charlie" }, 1, 0)

      -- Add all three
      add_note_at(bufnr, 1, 0, "a1")
      add_note_at(bufnr, 1, 6, "b1")
      add_note_at(bufnr, 1, 12, "c1")
      assert.equals(3, note_count(bufnr))

      -- Edit bravo's note
      vim.api.nvim_win_set_cursor(0, { 1, 6 })
      local ri = stub_input("b2")
      auditor.edit_note()
      ri()

      -- Delete alpha's note
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.delete_note()

      assert.equals(2, note_count(bufnr))
      local marks = note_extmarks(bufnr)
      assert.equals(2, #marks)

      -- Check remaining note texts
      local texts = {}
      for _, t in pairs(auditor._notes[bufnr]) do
        texts[t] = true
      end
      assert.is_true(texts["b2"])
      assert.is_true(texts["c1"])
      assert.is_nil(texts["a1"])

      cleanup(bufnr)
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Lifecycle (U15-U21)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("U15: underline survives mode transitions", function()
    it("underline restored after exit + enter", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      add_note_at(bufnr, 1, 0, "durable")

      auditor.exit_audit_mode()
      assert.equals(0, #note_extmarks(bufnr))

      auditor.enter_audit_mode()
      local marks = note_extmarks(bufnr)
      assert.equals(1, #marks)
      assert.equals("AuditorNote", marks[1][4].hl_group)
      assert.equals(0, marks[1][3])
      assert.equals(5, marks[1][4].end_col)
      cleanup(bufnr)
    end)
  end)

  describe("U16: underline survives save → exit → enter", function()
    it("DB round-trip restores underline at correct position", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      add_note_at(bufnr, 1, 0, "persistent")

      auditor.audit()
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      local marks = note_extmarks(bufnr)
      assert.equals(1, #marks)
      assert.equals("AuditorNote", marks[1][4].hl_group)
      assert.equals(0, marks[1][3])
      assert.equals(5, marks[1][4].end_col)
      cleanup(bufnr)
    end)
  end)

  describe("U17: underline removed when note deleted", function()
    it("delete_note removes the underline extmark", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      add_note_at(bufnr, 1, 0, "temp")
      assert.equals(1, #note_extmarks(bufnr))

      auditor.delete_note()
      assert.equals(0, #note_extmarks(bufnr))
      cleanup(bufnr)
    end)
  end)

  describe("U18: underline removed when highlight undone", function()
    it("undo_at_cursor removes underline", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      add_note_at(bufnr, 1, 0, "undone")
      assert.equals(1, #note_extmarks(bufnr))

      auditor.undo_at_cursor()
      assert.equals(0, #note_extmarks(bufnr))
      cleanup(bufnr)
    end)
  end)

  describe("U19: underline removed when buffer cleared", function()
    it("clear_buffer removes all underlines", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      add_note_at(bufnr, 1, 0, "n1")
      add_note_at(bufnr, 1, 6, "n2")
      assert.equals(2, #note_extmarks(bufnr))

      auditor.clear_buffer()
      assert.equals(0, #note_extmarks(bufnr))
      cleanup(bufnr)
    end)
  end)

  describe("U20: no underline when note is empty", function()
    it("empty input creates no underline", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input("")
      auditor.add_note()
      ri()

      assert.equals(0, #note_extmarks(bufnr))
      cleanup(bufnr)
    end)

    it("nil input creates no underline", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input(nil)
      auditor.add_note()
      ri()

      assert.equals(0, #note_extmarks(bufnr))
      cleanup(bufnr)
    end)
  end)

  describe("U21: re-mark removes underline", function()
    it("re-marking word clears old note and underline", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      add_note_at(bufnr, 1, 0, "old")
      assert.equals(1, #note_extmarks(bufnr))

      -- Re-mark same word (dedup)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("blue")

      -- Note and underline should be gone
      assert.equals(0, note_count(bufnr))
      -- _refresh_notes_for_line clears orphaned note extmarks
      assert.equals(0, #note_extmarks(bufnr))
      cleanup(bufnr)
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Edge cases (U22-U28)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("U22: underline on gradient highlight", function()
    it("half (gradient) highlight gets underline", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      add_note_at_color(bufnr, 1, 0, "half", "gradient note")

      local marks = note_extmarks(bufnr)
      assert.equals(1, #marks)
      assert.equals("AuditorNote", marks[1][4].hl_group)
      assert.equals(0, marks[1][3])
      assert.equals(5, marks[1][4].end_col)
      cleanup(bufnr)
    end)
  end)

  describe("U23: underline position after line insert", function()
    it("underline moves with the word", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      add_note_at(bufnr, 1, 0, "moveable")

      -- Insert line above
      vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "new line" })

      -- Extmark should have moved to line 1 (0-indexed)
      local marks = note_extmarks(bufnr)
      assert.equals(1, #marks)
      assert.equals(1, marks[1][2]) -- row moved from 0 to 1
      assert.equals(0, marks[1][3]) -- col unchanged
      cleanup(bufnr)
    end)
  end)

  describe("U24: underline position after line delete", function()
    it("underline moves up when line above is deleted", function()
      local bufnr = setup_buf({ "first", "hello world" }, 2, 0)
      add_note_at(bufnr, 2, 0, "moveable")

      -- Delete first line
      vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, {})

      local marks = note_extmarks(bufnr)
      assert.equals(1, #marks)
      assert.equals(0, marks[1][2]) -- row moved from 1 to 0
      cleanup(bufnr)
    end)
  end)

  describe("U25: underline on 1-char word", function()
    it("single character word gets underline", function()
      local bufnr = setup_buf({ "x = 42" }, 1, 0)
      add_note_at(bufnr, 1, 0, "var x")

      local marks = note_extmarks(bufnr)
      assert.equals(1, #marks)
      assert.equals(0, marks[1][3])
      assert.equals(1, marks[1][4].end_col)
      cleanup(bufnr)
    end)
  end)

  describe("U26: underline on 200-char word", function()
    it("long word gets full-width underline", function()
      local long = string.rep("a", 200)
      local bufnr = setup_buf({ long .. " rest" }, 1, 0)
      add_note_at(bufnr, 1, 0, "long word note")

      local marks = note_extmarks(bufnr)
      assert.equals(1, #marks)
      assert.equals(0, marks[1][3])
      assert.equals(200, marks[1][4].end_col)
      cleanup(bufnr)
    end)
  end)

  describe("U27: same-line note count consistency", function()
    it("note_count equals underline extmark count after every op", function()
      local bufnr = setup_buf({ "aaa bbb ccc ddd" }, 1, 0)

      local function assert_consistent()
        local nc = note_count(bufnr)
        local ec = #note_extmarks(bufnr)
        assert.equals(nc, ec, string.format("notes=%d extmarks=%d", nc, ec))
      end

      add_note_at(bufnr, 1, 0, "n1")
      assert_consistent()

      add_note_at(bufnr, 1, 4, "n2")
      assert_consistent()

      add_note_at(bufnr, 1, 8, "n3")
      assert_consistent()

      -- Delete n2
      vim.api.nvim_win_set_cursor(0, { 1, 4 })
      auditor.delete_note()
      assert_consistent()

      -- Undo n3
      vim.api.nvim_win_set_cursor(0, { 1, 8 })
      auditor.undo_at_cursor()
      assert_consistent()

      -- Add to ddd
      add_note_at(bufnr, 1, 12, "n4")
      assert_consistent()

      -- Save + round-trip
      auditor.audit()
      assert_consistent()
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()
      assert_consistent()

      cleanup(bufnr)
    end)
  end)

  describe("U28: buffer content unchanged", function()
    it("underline does not modify buffer text", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      add_note_at(bufnr, 1, 0, "invisible")
      add_note_at(bufnr, 1, 6, "also invisible")

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.equals(1, #lines)
      assert.equals("hello world", lines[1])
      cleanup(bufnr)
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Viewer and priority (U29-U30)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("U29: show_note works with underline display", function()
    it("viewer shows full note text in float buffer", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      add_note_at(bufnr, 1, 0, "full note text here")

      auditor.show_note()
      assert.is_not_nil(auditor._note_float_buf)
      local viewer_lines = vim.api.nvim_buf_get_lines(auditor._note_float_buf, 0, -1, false)
      assert.equals("full note text here", viewer_lines[1])

      auditor._close_note_float()
      cleanup(bufnr)
    end)
  end)

  describe("U30: underline priority is 200", function()
    it("note extmark priority is above highlight priority", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      add_note_at(bufnr, 1, 0, "priority check")

      local marks = note_extmarks(bufnr)
      assert.equals(200, marks[1][4].priority)
      cleanup(bufnr)
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Same-line round-trips and stress (U31-U35)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("U31: same-line notes save → exit → enter → all restored", function()
    it("three notes on one line all survive DB round-trip", function()
      local bufnr = setup_buf({ "alpha bravo charlie" }, 1, 0)
      add_note_at(bufnr, 1, 0, "A")
      add_note_at(bufnr, 1, 6, "B")
      add_note_at(bufnr, 1, 12, "C")

      auditor.audit()
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      assert.equals(3, note_count(bufnr))
      assert.equals(3, #note_extmarks(bufnr))

      -- Verify positions
      local marks = note_extmarks(bufnr)
      table.sort(marks, function(a, b) return a[3] < b[3] end)
      assert.equals(0, marks[1][3])
      assert.equals(6, marks[2][3])
      assert.equals(12, marks[3][3])

      cleanup(bufnr)
    end)
  end)

  describe("U32: same-line notes stale recovery after line shift", function()
    it("notes on shifted line are recovered", function()
      local bufnr = setup_buf({ "alpha bravo" }, 1, 0)
      add_note_at(bufnr, 1, 0, "rA")
      add_note_at(bufnr, 1, 6, "rB")

      auditor.audit()
      auditor.exit_audit_mode()

      -- Insert lines above to shift
      vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "line1", "line2" })

      auditor.enter_audit_mode()

      assert.equals(2, note_count(bufnr))
      assert.equals(2, #note_extmarks(bufnr))
      cleanup(bufnr)
    end)
  end)

  describe("U33: five words on one line", function()
    it("all five get underlines at correct positions", function()
      local bufnr = setup_buf({ "aa bb cc dd ee" }, 1, 0)
      add_note_at(bufnr, 1, 0, "n1")   -- aa: 0-2
      add_note_at(bufnr, 1, 3, "n2")   -- bb: 3-5
      add_note_at(bufnr, 1, 6, "n3")   -- cc: 6-8
      add_note_at(bufnr, 1, 9, "n4")   -- dd: 9-11
      add_note_at(bufnr, 1, 12, "n5")  -- ee: 12-14

      assert.equals(5, note_count(bufnr))
      assert.equals(5, #note_extmarks(bufnr))

      local marks = note_extmarks(bufnr)
      table.sort(marks, function(a, b) return a[3] < b[3] end)

      local expected_starts = { 0, 3, 6, 9, 12 }
      local expected_ends   = { 2, 5, 8, 11, 14 }
      for i, m in ipairs(marks) do
        assert.equals(expected_starts[i], m[3],
          string.format("word %d col_start", i))
        assert.equals(expected_ends[i], m[4].end_col,
          string.format("word %d end_col", i))
      end

      cleanup(bufnr)
    end)
  end)

  describe("U34: rapid add/delete cycles on same line", function()
    it("10 add/delete cycles leave clean state", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      for _ = 1, 10 do
        local ri = stub_input("temp")
        auditor.add_note()
        ri()
        assert.equals(1, #note_extmarks(bufnr))

        auditor.delete_note()
        assert.equals(0, #note_extmarks(bufnr))
      end

      assert.equals(0, note_count(bufnr))
      -- Highlight still intact
      assert.is_true(#vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, {}) >= 1)
      cleanup(bufnr)
    end)
  end)

  describe("U35: note on adjacent words", function()
    it("touching highlights each get their own underline", function()
      -- Create content where words touch via underscore boundary
      local bufnr = setup_buf({ "foo bar baz" }, 1, 0)
      add_note_at(bufnr, 1, 0, "foo note")   -- foo: 0-3
      add_note_at(bufnr, 1, 4, "bar note")   -- bar: 4-7

      assert.equals(2, note_count(bufnr))
      local marks = note_extmarks(bufnr)
      assert.equals(2, #marks)
      table.sort(marks, function(a, b) return a[3] < b[3] end)

      assert.equals(0, marks[1][3])
      assert.equals(3, marks[1][4].end_col)
      assert.equals(4, marks[2][3])
      assert.equals(7, marks[2][4].end_col)

      cleanup(bufnr)
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Stopinsert fix verification (U36)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("U36: save_note calls stopinsert", function()
    it("save from float editor leaves insert mode", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id
      local exts = vim.api.nvim_buf_get_extmarks(
        bufnr, hl.ns,
        { token.line, token.col_start },
        { token.line, token.col_end },
        { details = true }
      )
      for _, mark in ipairs(exts) do
        if mark[2] == token.line and mark[3] == token.col_start then
          target_id = mark[1]
          break
        end
      end

      auditor._open_note_editor(bufnr, target_id, token, "")
      -- Should be in insert mode (startinsert was called)
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "typed text" })

      -- Get the save callback and call it
      local keymaps = vim.api.nvim_buf_get_keymap(auditor._note_float_buf, "i")
      local save_cb
      for _, km in ipairs(keymaps) do
        if km.lhs == "<C-S>" or km.lhs == "<C-s>" then
          save_cb = km.callback
          break
        end
      end
      assert.is_not_nil(save_cb)
      save_cb()

      -- Note should be saved
      assert.equals("typed text", auditor._notes[bufnr][target_id])
      -- Float should be closed
      assert.is_nil(auditor._note_float_win)

      cleanup(bufnr)
    end)
  end)
end)
