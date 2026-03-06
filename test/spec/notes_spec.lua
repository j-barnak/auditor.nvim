-- test/spec/notes_spec.lua
-- Tests for virtual text notes feature: add, delete, persist, mode transitions,
-- interaction with undo/clear, stale recovery.
--
-- Coverage:
--   N1  add_note() requires audit mode
--   N2  add_note() requires highlight under cursor
--   N3  add_note() attaches note to highlighted word
--   N4  delete_note() removes note from word
--   N5  delete_note() on word without note warns
--   N6  Notes persist through AuditSave
--   N7  Notes restored on load_for_buffer
--   N8  Notes survive enter/exit mode transitions
--   N9  AuditUndo removes associated note
--   N10 AuditClear removes all notes
--   N11 Note on gradient highlight
--   N12 Multiple notes on different words
--   N13 Note virtual text does not appear in buffer text
--   N14 Re-mark (dedup) removes old note
--   N15 Note on word, save, exit, re-enter — note restored
--   N16 Note with save, modify buffer, re-enter — stale recovery restores note
--   N17 BufDelete cleans up notes
--   N18 Commands registered
--   N19 Empty note input is ignored
--   N20 Note on re-marked word (new extmark ID, same position)

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

local function extmark_count(bufnr, ns)
  return #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
end

describe("notes", function()
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

  -- Helper: create a buffer, enter audit mode, place cursor.
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

  -- Helper: stub vim.ui.input to return a canned response.
  local function stub_input(response)
    local orig = vim.ui.input
    vim.ui.input = function(_opts, callback)
      callback(response)
    end
    return function()
      vim.ui.input = orig
    end
  end

  -- ── N1: add_note requires audit mode ────────────────────────────────────
  describe("N1: add_note requires audit mode", function()
    it("notifies and returns when not in audit mode", function()
      local bufnr = setup_buf({ "hello" }, 1, 0)
      auditor.exit_audit_mode()

      local restore, msgs = capture_notify()
      auditor.add_note()
      restore()

      local found = false
      for _, m in ipairs(msgs) do
        if m.msg:match("Cannot") then
          found = true
        end
      end
      assert.is_true(found)
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── N2: add_note requires highlight under cursor ────────────────────────
  describe("N2: add_note requires highlight", function()
    it("warns when no highlight on word", function()
      local bufnr = setup_buf({ "hello" }, 1, 0)

      local restore_input = stub_input("my note")
      local restore, msgs = capture_notify()
      auditor.add_note()
      restore()
      restore_input()

      local found = false
      for _, m in ipairs(msgs) do
        if m.msg:match("No highlight") or m.msg:match("Mark it first") then
          found = true
        end
      end
      assert.is_true(found)
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("warns on whitespace", function()
      local bufnr = setup_buf({ "hello world" }, 1, 5)

      local restore, msgs = capture_notify()
      auditor.add_note()
      restore()

      local found = false
      for _, m in ipairs(msgs) do
        if m.msg:match("No word") then
          found = true
        end
      end
      assert.is_true(found)
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── N3: add_note attaches note ──────────────────────────────────────────
  describe("N3: add_note attaches note", function()
    it("creates note extmark with AuditorNote highlight", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore_input = stub_input("review this")
      auditor.add_note()
      restore_input()

      -- Note extmark should exist in note_ns
      local note_marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      assert.is_true(#note_marks >= 1)

      -- Check that note extmark has AuditorNote highlight
      local found_note = false
      for _, m in ipairs(note_marks) do
        if m[4].hl_group and m[4].hl_group:match("AuditorNote") then
          found_note = true
        end
      end
      assert.is_true(found_note)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("stores note in _notes table", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore_input = stub_input("my note")
      auditor.add_note()
      restore_input()

      assert.is_not_nil(auditor._notes[bufnr])
      local count = 0
      for _ in pairs(auditor._notes[bufnr]) do
        count = count + 1
      end
      assert.equals(1, count)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── N4: delete_note removes note ────────────────────────────────────────
  describe("N4: delete_note removes note", function()
    it("removes the virtual text", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore_input = stub_input("temp note")
      auditor.add_note()
      restore_input()
      assert.is_true(extmark_count(bufnr, hl.note_ns) >= 1)

      auditor.delete_note()
      assert.equals(0, extmark_count(bufnr, hl.note_ns))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("removes from _notes table", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore_input = stub_input("temp note")
      auditor.add_note()
      restore_input()

      auditor.delete_note()

      local count = 0
      if auditor._notes[bufnr] then
        for _ in pairs(auditor._notes[bufnr]) do
          count = count + 1
        end
      end
      assert.equals(0, count)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── N5: delete_note on word without note ────────────────────────────────
  describe("N5: delete_note on word without note", function()
    it("warns the user", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore, msgs = capture_notify()
      auditor.delete_note()
      restore()

      local found = false
      for _, m in ipairs(msgs) do
        if m.msg:match("No note") then
          found = true
        end
      end
      assert.is_true(found)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── N6: Notes persist through AuditSave ─────────────────────────────────
  describe("N6: notes persist through AuditSave", function()
    it("note is stored in DB after save", function()
      local bufnr, filepath = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore_input = stub_input("persist me")
      auditor.add_note()
      restore_input()

      auditor.audit()

      local rows = db.get_highlights(filepath)
      assert.is_true(#rows >= 1)
      local found = false
      for _, r in ipairs(rows) do
        if r.note == "persist me" then
          found = true
        end
      end
      assert.is_true(found)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── N7: Notes restored on load_for_buffer ───────────────────────────────
  describe("N7: notes restored on load", function()
    it("restores note virtual text after clearing and reloading", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore_input = stub_input("reload me")
      auditor.add_note()
      restore_input()

      auditor.audit()

      -- Clear everything
      vim.api.nvim_buf_clear_namespace(bufnr, hl.ns, 0, -1)
      hl.clear_half_pairs(bufnr)
      hl.clear_notes(bufnr)
      auditor._notes[bufnr] = {}
      auditor._db_extmarks[bufnr] = {}

      -- Reload from DB
      auditor.load_for_buffer(bufnr)

      -- Note should be restored
      local note_marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      assert.is_true(#note_marks >= 1)

      local found = false
      if auditor._notes[bufnr] then
        for _, text in pairs(auditor._notes[bufnr]) do
          if text:match("reload me") then
            found = true
          end
        end
      end
      assert.is_true(found)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── N8: Notes survive enter/exit mode transitions ───────────────────────
  describe("N8: notes survive mode transitions", function()
    it("unsaved note survives exit + enter cycle", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore_input = stub_input("survive me")
      auditor.add_note()
      restore_input()

      -- Exit and re-enter
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      -- Note should be back
      local note_marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      assert.is_true(#note_marks >= 1)
      local found = false
      if auditor._notes[bufnr] then
        for _, text in pairs(auditor._notes[bufnr]) do
          if text:match("survive me") then
            found = true
          end
        end
      end
      assert.is_true(found)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("saved note survives exit + enter cycle", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore_input = stub_input("saved note")
      auditor.add_note()
      restore_input()

      auditor.audit()

      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      local note_marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      assert.is_true(#note_marks >= 1)
      local found = false
      if auditor._notes[bufnr] then
        for _, text in pairs(auditor._notes[bufnr]) do
          if text:match("saved note") then
            found = true
          end
        end
      end
      assert.is_true(found)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("multiple enter/exit cycles preserve note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore_input = stub_input("durable")
      auditor.add_note()
      restore_input()

      for _ = 1, 5 do
        auditor.exit_audit_mode()
        auditor.enter_audit_mode()
      end

      local note_marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      assert.is_true(#note_marks >= 1)
      local found = false
      if auditor._notes[bufnr] then
        for _, text in pairs(auditor._notes[bufnr]) do
          if text:match("durable") then
            found = true
          end
        end
      end
      assert.is_true(found)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── N9: AuditUndo removes associated note ───────────────────────────────
  describe("N9: undo removes note", function()
    it("undo clears the note virtual text", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore_input = stub_input("gone with undo")
      auditor.add_note()
      restore_input()

      assert.is_true(extmark_count(bufnr, hl.note_ns) >= 1)

      auditor.undo_at_cursor()

      assert.equals(0, extmark_count(bufnr, hl.note_ns))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("undo removes note from _notes table", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore_input = stub_input("gone")
      auditor.add_note()
      restore_input()

      auditor.undo_at_cursor()

      local count = 0
      if auditor._notes[bufnr] then
        for _ in pairs(auditor._notes[bufnr]) do
          count = count + 1
        end
      end
      assert.equals(0, count)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── N10: AuditClear removes all notes ───────────────────────────────────
  describe("N10: clear removes all notes", function()
    it("clears note virtual text", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore_input = stub_input("clear me")
      auditor.add_note()
      restore_input()

      vim.api.nvim_win_set_cursor(0, { 1, 6 })
      auditor.highlight_cword_buffer("blue")

      restore_input = stub_input("clear me too")
      vim.api.nvim_win_set_cursor(0, { 1, 6 })
      auditor.add_note()
      restore_input()

      auditor.clear_buffer()

      assert.equals(0, extmark_count(bufnr, hl.note_ns))
      assert.same({}, auditor._notes[bufnr])

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── N11: Note on gradient highlight ─────────────────────────────────────
  describe("N11: note on gradient highlight", function()
    it("works with half (gradient) color", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("half")

      local restore_input = stub_input("gradient note")
      auditor.add_note()
      restore_input()

      local note_marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      assert.is_true(#note_marks >= 1)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── N12: Multiple notes on different words ──────────────────────────────
  describe("N12: multiple notes", function()
    it("each word gets its own note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local restore_input = stub_input("note1")
      auditor.add_note()
      restore_input()

      vim.api.nvim_win_set_cursor(0, { 1, 6 })
      auditor.highlight_cword_buffer("blue")
      restore_input = stub_input("note2")
      auditor.add_note()
      restore_input()

      local note_marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      assert.is_true(#note_marks >= 2)
      -- Check that _notes contains both note texts
      local found1, found2 = false, false
      if auditor._notes[bufnr] then
        for _, text in pairs(auditor._notes[bufnr]) do
          if text:match("note1") then found1 = true end
          if text:match("note2") then found2 = true end
        end
      end
      assert.is_true(found1)
      assert.is_true(found2)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── N13: Note virtual text does not appear in buffer text ───────────────
  describe("N13: notes don't affect buffer content", function()
    it("buffer lines are unchanged after adding note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore_input = stub_input("invisible note")
      auditor.add_note()
      restore_input()

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.equals(1, #lines)
      assert.equals("hello world", lines[1])

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── N14: Re-mark removes old note ──────────────────────────────────────
  describe("N14: re-mark removes old note", function()
    it("re-marking same word clears previous note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore_input = stub_input("old note")
      auditor.add_note()
      restore_input()

      -- Re-mark same word with different color — dedup removes old extmark
      auditor.highlight_cword_buffer("blue")

      -- Old note should be gone (extmark was replaced)
      local count = 0
      if auditor._notes[bufnr] then
        for _ in pairs(auditor._notes[bufnr]) do
          count = count + 1
        end
      end
      assert.equals(0, count)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── N15: Full round-trip: note → save → exit → enter ───────────────────
  describe("N15: full round-trip", function()
    it("note survives save → exit → enter", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore_input = stub_input("round trip")
      auditor.add_note()
      restore_input()

      auditor.audit()
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      local note_marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      assert.is_true(#note_marks >= 1)
      local found = false
      if auditor._notes[bufnr] then
        for _, text in pairs(auditor._notes[bufnr]) do
          if text:match("round trip") then
            found = true
          end
        end
      end
      assert.is_true(found)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── N16: Stale recovery restores note ──────────────────────────────────
  describe("N16: stale recovery restores note", function()
    it("note recovered when highlight position shifts", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore_input = stub_input("stale note")
      auditor.add_note()
      restore_input()

      auditor.audit()
      auditor.exit_audit_mode()

      -- Insert a line before "hello world" to shift positions
      vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "new first line" })

      auditor.enter_audit_mode()

      -- Note should be recovered on the shifted line
      local note_marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      assert.is_true(#note_marks >= 1)
      local found = false
      if auditor._notes[bufnr] then
        for _, text in pairs(auditor._notes[bufnr]) do
          if text:match("stale note") then
            found = true
          end
        end
      end
      assert.is_true(found)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── N17: BufDelete cleans up notes ─────────────────────────────────────
  describe("N17: BufDelete cleans up notes", function()
    it("_notes entry removed on buffer delete", function()
      local bufnr = setup_buf({ "hello" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore_input = stub_input("cleanup")
      auditor.add_note()
      restore_input()

      assert.is_not_nil(auditor._notes[bufnr])
      vim.api.nvim_buf_delete(bufnr, { force = true })
      assert.is_nil(auditor._notes[bufnr])
    end)
  end)

  -- ── N18: Commands registered ───────────────────────────────────────────
  describe("N18: commands registered", function()
    it("AuditNote command exists", function()
      assert.equals(2, vim.fn.exists(":AuditNote"))
    end)

    it("AuditNoteDelete command exists", function()
      assert.equals(2, vim.fn.exists(":AuditNoteDelete"))
    end)

    it("AuditNotes command exists", function()
      assert.equals(2, vim.fn.exists(":AuditNotes"))
    end)
  end)

  -- ── N19: Empty note input is ignored ───────────────────────────────────
  describe("N19: empty note ignored", function()
    it("empty string input does not create a note", function()
      local bufnr = setup_buf({ "hello" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore_input = stub_input("")
      auditor.add_note()
      restore_input()

      local count = 0
      if auditor._notes[bufnr] then
        for _ in pairs(auditor._notes[bufnr]) do
          count = count + 1
        end
      end
      assert.equals(0, count)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("nil input (user cancelled) does not create a note", function()
      local bufnr = setup_buf({ "hello" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore_input = stub_input(nil)
      auditor.add_note()
      restore_input()

      local count = 0
      if auditor._notes[bufnr] then
        for _ in pairs(auditor._notes[bufnr]) do
          count = count + 1
        end
      end
      assert.equals(0, count)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── N20: Note survives re-mark at same position ────────────────────────
  describe("N20: add note after re-mark", function()
    it("new note works on re-marked word", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      -- Re-mark same word
      auditor.highlight_cword_buffer("blue")

      local restore_input = stub_input("new color note")
      auditor.add_note()
      restore_input()

      local count = 0
      if auditor._notes[bufnr] then
        for _ in pairs(auditor._notes[bufnr]) do
          count = count + 1
        end
      end
      assert.equals(1, count)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── N21: edit_note ──────────────────────────────────────────────────────
  describe("N21: edit_note", function()
    it("updates existing note text", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore_input = stub_input("original")
      auditor.add_note()
      restore_input()

      -- Edit the note
      restore_input = stub_input("updated")
      auditor.edit_note()
      restore_input()

      -- Verify the note text changed
      local note_marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      assert.is_true(#note_marks >= 1)
      local found = false
      if auditor._notes[bufnr] then
        for _, text in pairs(auditor._notes[bufnr]) do
          if text:match("updated") then
            found = true
          end
        end
      end
      assert.is_true(found)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("editing to empty string removes the note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore_input = stub_input("temp")
      auditor.add_note()
      restore_input()

      restore_input = stub_input("")
      auditor.edit_note()
      restore_input()

      local count = 0
      if auditor._notes[bufnr] then
        for _ in pairs(auditor._notes[bufnr]) do
          count = count + 1
        end
      end
      assert.equals(0, count)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("cancelling edit (nil) preserves original note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore_input = stub_input("keep me")
      auditor.add_note()
      restore_input()

      restore_input = stub_input(nil) -- user pressed Esc
      auditor.edit_note()
      restore_input()

      -- Note should still exist
      local count = 0
      if auditor._notes[bufnr] then
        for _, text in pairs(auditor._notes[bufnr]) do
          if text == "keep me" then
            count = count + 1
          end
        end
      end
      assert.equals(1, count)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("warns when no note exists to edit", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore, msgs = capture_notify()
      auditor.edit_note()
      restore()

      local found = false
      for _, m in ipairs(msgs) do
        if m.msg:match("No note") then
          found = true
        end
      end
      assert.is_true(found)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("warns when no highlight under cursor", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)

      local restore, msgs = capture_notify()
      auditor.edit_note()
      restore()

      local found = false
      for _, m in ipairs(msgs) do
        if m.msg:match("No highlight") then
          found = true
        end
      end
      assert.is_true(found)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("AuditNoteEdit command exists", function()
      assert.equals(2, vim.fn.exists(":AuditNoteEdit"))
    end)

    it("edited note persists through save", function()
      local bufnr, filepath = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore_input = stub_input("original")
      auditor.add_note()
      restore_input()

      restore_input = stub_input("edited")
      auditor.edit_note()
      restore_input()

      auditor.audit()

      local rows = db.get_highlights(filepath)
      local found = false
      for _, r in ipairs(rows) do
        if r.note == "edited" then
          found = true
        end
      end
      assert.is_true(found)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── N22: list_notes opens quickfix with notes ──────────────────────────
  describe("N22: list_notes", function()
    it("populates quickfix with notes sorted by position", function()
      local bufnr = setup_buf({ "hello world foo" }, 1, 0)
      auditor.highlight_cword_buffer("red") -- hello
      local restore_input = stub_input("note on hello")
      auditor.add_note()
      restore_input()

      vim.api.nvim_win_set_cursor(0, { 1, 6 })
      auditor.highlight_cword_buffer("blue") -- world
      restore_input = stub_input("note on world")
      auditor.add_note()
      restore_input()

      auditor.list_notes()

      local qf = vim.fn.getqflist()
      assert.equals(2, #qf)
      -- Sorted by position: hello (col 1) before world (col 7)
      assert.is_truthy(qf[1].text:match("hello"))
      assert.is_truthy(qf[1].text:match("note on hello"))
      assert.is_truthy(qf[2].text:match("world"))
      assert.is_truthy(qf[2].text:match("note on world"))

      -- Check quickfix title
      local info = vim.fn.getqflist({ title = 1 })
      assert.equals("Auditor Notes", info.title)

      vim.cmd("cclose")
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("shows info message when no notes exist", function()
      local bufnr = setup_buf({ "hello" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore, msgs = capture_notify()
      auditor.list_notes()
      restore()

      local found = false
      for _, m in ipairs(msgs) do
        if m.msg:match("No notes") then
          found = true
        end
      end
      assert.is_true(found)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("requires audit mode", function()
      local bufnr = setup_buf({ "hello" }, 1, 0)
      auditor.exit_audit_mode()

      local restore, msgs = capture_notify()
      auditor.list_notes()
      restore()

      local found = false
      for _, m in ipairs(msgs) do
        if m.msg:match("Cannot") then
          found = true
        end
      end
      assert.is_true(found)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("quickfix entries have correct line numbers", function()
      local bufnr = setup_buf({ "aaa", "bbb", "ccc" }, 1, 0)
      auditor.highlight_cword_buffer("red") -- aaa on line 1

      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      auditor.highlight_cword_buffer("blue") -- ccc on line 3

      local restore_input = stub_input("first")
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.add_note()
      restore_input()

      restore_input = stub_input("third")
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      auditor.add_note()
      restore_input()

      auditor.list_notes()

      local qf = vim.fn.getqflist()
      assert.equals(2, #qf)
      assert.equals(1, qf[1].lnum) -- line 1
      assert.equals(3, qf[2].lnum) -- line 3

      vim.cmd("cclose")
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)
end)
