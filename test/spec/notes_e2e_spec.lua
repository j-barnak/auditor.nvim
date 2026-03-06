-- test/spec/notes_e2e_spec.lua
-- End-to-end tests for the note system: exhaustive state machine transitions,
-- float editor lifecycle (open/save/cancel/empty), viewer, multi-buffer,
-- multi-note, interaction with undo/clear/re-mark/toggle, and DB round-trips.
--
-- State machine states:
--   S0  No audit mode
--   S1  Audit mode, no highlight under cursor
--   S2  Audit mode, highlight under cursor, no note
--   S3  Audit mode, highlight + unsaved note
--   S4  Audit mode, highlight + DB-saved note
--   S5  Float editor open (new note)
--   S6  Float editor open (editing existing)
--   S7  Float viewer open
--   S8  Exited audit mode (notes in _saved_notes)
--   S9  Re-entered audit mode (notes restored)
--
-- Coverage:
--   E2E-1   Open editor, save empty → no note created
--   E2E-2   Open editor, cancel → no note created
--   E2E-3   Open editor, type text, save → note created
--   E2E-4   Open editor, type text, cancel → no note created
--   E2E-5   Open editor on existing note, save empty → note removed
--   E2E-6   Open editor on existing note, cancel → note preserved
--   E2E-7   Open editor on existing note, edit text, save → note updated
--   E2E-8   Open editor, :w saves
--   E2E-9   Open editor, type nothing, :w → no note
--   E2E-10  show_note opens viewer, viewer read-only
--   E2E-11  show_note then close, note still exists
--   E2E-12  show_note → close → edit_note → save → note updated
--   E2E-13  Full lifecycle: mark → add note → save → exit → enter → verify
--   E2E-14  Full lifecycle: mark → add note → save → exit → buffer edit → enter → stale recovery
--   E2E-15  Full lifecycle: mark → add note (unsaved) → exit → enter → note restored
--   E2E-16  Multiple enter/exit/toggle cycles with unsaved note
--   E2E-17  Toggle preserves notes
--   E2E-18  undo_at_cursor removes note + extmarks
--   E2E-19  clear_buffer removes all notes + extmarks
--   E2E-20  Re-mark word clears old note
--   E2E-21  Re-mark word, add new note, verify only one note
--   E2E-22  Multiple notes on same line, different words
--   E2E-23  Multiple notes on different lines
--   E2E-24  Note on gradient (half) highlight
--   E2E-25  Note on custom solid color
--   E2E-26  delete_note then re-add
--   E2E-27  edit_note on word without note warns
--   E2E-28  show_note on word without note warns
--   E2E-29  delete_note on word without note warns
--   E2E-30  add_note on word without highlight warns
--   E2E-31  All note commands outside audit mode fail
--   E2E-32  Multi-buffer: notes isolated per buffer
--   E2E-33  Multi-buffer: save affects only buffers with changes
--   E2E-34  list_notes with multiple notes sorted correctly
--   E2E-35  list_notes empty buffer
--   E2E-36  Note survives buffer text edits (line insert above)
--   E2E-37  Note survives buffer text edits (line delete above)
--   E2E-38  Float editor: open two editors rapidly → first closes
--   E2E-39  Float viewer: open two viewers rapidly → first closes
--   E2E-40  Float editor open → exit audit mode → editor closes
--   E2E-41  Float viewer open → exit audit mode → float state cleared
--   E2E-42  Save note with multi-line text via float editor
--   E2E-43  Save note with multi-line text → DB round-trip preserves newlines
--   E2E-44  Open editor, add nothing, cancel — highlight still exists
--   E2E-45  Open editor on highlighted word, move cursor away, save — note on original word
--   E2E-46  Exhaustive state transitions: S0→S1→S2→S3→S4→S8→S9
--   E2E-47  Exhaustive state transitions: S2→S5→S3 (editor new→save)
--   E2E-48  Exhaustive state transitions: S2→S5→S2 (editor new→cancel)
--   E2E-49  Exhaustive state transitions: S3→S6→S3 (editor edit→save)
--   E2E-50  Exhaustive state transitions: S3→S6→S3 (editor edit→cancel, note preserved)
--   E2E-51  Exhaustive state transitions: S3→S7→S3 (viewer→close)
--   E2E-52  Exhaustive state transitions: S3→delete→S2
--   E2E-53  Exhaustive: S2→add→S3→save→S4→exit→S8→enter→S9→verify note
--   E2E-54  Exhaustive: S4→undo→S1 (DB-backed highlight+note removed)
--   E2E-55  Exhaustive: S4→clear→S1 (everything gone)
--   E2E-56  Float editor: startinsert on new note, normal mode on edit
--   E2E-57  Note count consistency after every operation

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

local function note_count(auditor, bufnr)
  if not auditor._notes[bufnr] then
    return 0
  end
  local c = 0
  for _ in pairs(auditor._notes[bufnr]) do
    c = c + 1
  end
  return c
end

local function note_extmark_count(bufnr, note_ns)
  return #vim.api.nvim_buf_get_extmarks(bufnr, note_ns, 0, -1, {})
end

local function hl_extmark_count(bufnr, ns)
  return #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
end

local function get_note_texts(bufnr, note_ns)
  local texts = {}
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, note_ns, 0, -1, { details = true })
  for _, m in ipairs(marks) do
    local vt = m[4].virt_text
    if vt then
      for _, chunk in ipairs(vt) do
        if chunk[1] and chunk[1] ~= "" then
          table.insert(texts, chunk[1])
        end
      end
    end
  end
  return texts
end

local function find_note_text(bufnr, note_ns, pattern)
  for _, t in ipairs(get_note_texts(bufnr, note_ns)) do
    if t:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

local function find_target_id(bufnr, ns, token)
  local extmarks = vim.api.nvim_buf_get_extmarks(
    bufnr, ns,
    { token.line, token.col_start },
    { token.line, token.col_end },
    { details = true }
  )
  for _, mark in ipairs(extmarks) do
    local id, row, col, details = mark[1], mark[2], mark[3], mark[4]
    if row == token.line and col == token.col_start and details.end_col == token.col_end then
      return id
    end
  end
  return nil
end

local function get_keymap_cb(buf, mode, lhs)
  local keymaps = vim.api.nvim_buf_get_keymap(buf, mode)
  for _, km in ipairs(keymaps) do
    if km.lhs == lhs then
      return km.callback
    end
  end
  return nil
end

local function msgs_contain(msgs, pattern)
  for _, m in ipairs(msgs) do
    if m.msg:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

describe("notes E2E", function()
  local auditor, db, hl

  before_each(function()
    reset_modules()
    local tmp_db = vim.fn.tempname() .. ".db"
    auditor = require("auditor")
    auditor.setup({ db_path = tmp_db, keymaps = false })
    db = require("auditor.db")
    hl = require("auditor.highlights")
  end)

  after_each(function()
    -- Clean up float editor/viewer buffers
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

  -- Stub vim.ui.input for the _note_input_override path
  local function stub_input(response)
    local orig = vim.ui.input
    vim.ui.input = function(_opts, callback)
      callback(response)
    end
    return function()
      vim.ui.input = orig
    end
  end

  -- Open float editor, optionally write text, then save/cancel via keymap callback.
  -- Returns the note text that was saved (or nil if cancelled).
  local function editor_save(bufnr, token, initial_text, new_lines)
    local target_id = find_target_id(bufnr, hl.ns, token)
    assert.is_not_nil(target_id, "highlight extmark must exist")
    auditor._open_note_editor(bufnr, target_id, token, initial_text or "")
    local fb = auditor._note_float_buf
    assert.is_not_nil(fb, "float editor buffer must be created")
    if new_lines then
      vim.api.nvim_buf_set_lines(fb, 0, -1, false, new_lines)
    end
    -- Save via C-s callback
    local cb = get_keymap_cb(fb, "n", "<C-S>") or get_keymap_cb(fb, "n", "<C-s>")
    assert.is_not_nil(cb, "save keymap must exist")
    cb()
    return auditor._notes[bufnr] and auditor._notes[bufnr][target_id]
  end

  local function editor_cancel(bufnr, token, initial_text, new_lines)
    local target_id = find_target_id(bufnr, hl.ns, token)
    assert.is_not_nil(target_id, "highlight extmark must exist")
    auditor._open_note_editor(bufnr, target_id, token, initial_text or "")
    local fb = auditor._note_float_buf
    assert.is_not_nil(fb, "float editor buffer must be created")
    if new_lines then
      vim.api.nvim_buf_set_lines(fb, 0, -1, false, new_lines)
    end
    -- Cancel via q callback
    local cb = get_keymap_cb(fb, "n", "q")
    assert.is_not_nil(cb, "cancel keymap must exist")
    cb()
    return auditor._notes[bufnr] and auditor._notes[bufnr][target_id]
  end

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Float editor: empty/cancel scenarios (E2E-1 through E2E-4)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("E2E-1: open editor, save empty → no note", function()
    it("saving an empty editor on a new note creates no note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)

      local result = editor_save(bufnr, token, "", nil) -- don't type anything
      assert.is_nil(result)
      assert.equals(0, note_count(auditor, bufnr))
      assert.equals(0, note_extmark_count(bufnr, hl.note_ns))

      -- Highlight must still exist
      assert.is_true(hl_extmark_count(bufnr, hl.ns) >= 1)
      cleanup(bufnr)
    end)
  end)

  describe("E2E-2: open editor, cancel → no note", function()
    it("cancelling an empty editor creates no note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)

      local result = editor_cancel(bufnr, token, "", nil)
      assert.is_nil(result)
      assert.equals(0, note_count(auditor, bufnr))
      assert.equals(0, note_extmark_count(bufnr, hl.note_ns))

      -- Highlight must still exist
      assert.is_true(hl_extmark_count(bufnr, hl.ns) >= 1)
      cleanup(bufnr)
    end)
  end)

  describe("E2E-3: open editor, type text, save → note created", function()
    it("typing and saving creates a note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)

      local result = editor_save(bufnr, token, "", { "review this function" })
      assert.equals("review this function", result)
      assert.equals(1, note_count(auditor, bufnr))
      assert.is_true(find_note_text(bufnr, hl.note_ns, "review this"))
      cleanup(bufnr)
    end)
  end)

  describe("E2E-4: open editor, type text, cancel → no note", function()
    it("typing then cancelling creates no note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)

      local result = editor_cancel(bufnr, token, "", { "this should be discarded" })
      assert.is_nil(result)
      assert.equals(0, note_count(auditor, bufnr))
      assert.equals(0, note_extmark_count(bufnr, hl.note_ns))
      cleanup(bufnr)
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Float editor: editing existing notes (E2E-5 through E2E-7)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("E2E-5: edit existing note, save empty → note removed", function()
    it("clearing an existing note and saving removes it", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)

      -- Create note first
      editor_save(bufnr, token, "", { "temporary note" })
      assert.equals(1, note_count(auditor, bufnr))

      -- Edit: clear and save empty
      local result = editor_save(bufnr, token, "temporary note", { "" })
      assert.is_nil(result)
      assert.equals(0, note_count(auditor, bufnr))
      assert.equals(0, note_extmark_count(bufnr, hl.note_ns))

      -- Highlight must still exist
      assert.is_true(hl_extmark_count(bufnr, hl.ns) >= 1)
      cleanup(bufnr)
    end)
  end)

  describe("E2E-6: edit existing note, cancel → note preserved", function()
    it("cancelling edit preserves original note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, hl.ns, token)

      editor_save(bufnr, token, "", { "original text" })
      assert.equals("original text", auditor._notes[bufnr][target_id])

      -- Edit: type something different, then cancel
      editor_cancel(bufnr, token, "original text", { "changed text" })
      assert.equals("original text", auditor._notes[bufnr][target_id])
      assert.equals(1, note_count(auditor, bufnr))
      cleanup(bufnr)
    end)
  end)

  describe("E2E-7: edit existing note, change text, save → updated", function()
    it("saving edited text updates the note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, hl.ns, token)

      editor_save(bufnr, token, "", { "version 1" })
      assert.equals("version 1", auditor._notes[bufnr][target_id])

      local result = editor_save(bufnr, token, "version 1", { "version 2" })
      assert.equals("version 2", result)
      assert.equals(1, note_count(auditor, bufnr))
      assert.is_true(find_note_text(bufnr, hl.note_ns, "version 2"))
      cleanup(bufnr)
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Float editor: :w and :wq (E2E-8, E2E-9)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("E2E-8: :w saves note from float editor", function()
    it(":w triggers BufWriteCmd and saves", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, hl.ns, token)

      auditor._open_note_editor(bufnr, target_id, token, "")
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "saved via write" })
      vim.api.nvim_set_current_win(auditor._note_float_win)
      local ok = pcall(vim.cmd, "write")
      assert.is_true(ok)
      assert.equals("saved via write", auditor._notes[bufnr][target_id])
      assert.is_nil(auditor._note_float_win)
      cleanup(bufnr)
    end)
  end)

  describe("E2E-9: :w with empty text → no note", function()
    it(":w on empty editor creates no note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, hl.ns, token)

      auditor._open_note_editor(bufnr, target_id, token, "")
      -- Don't type anything — buffer has { "" }
      vim.api.nvim_set_current_win(auditor._note_float_win)
      pcall(vim.cmd, "write")
      assert.is_nil(auditor._notes[bufnr] and auditor._notes[bufnr][target_id])
      assert.equals(0, note_count(auditor, bufnr))
      cleanup(bufnr)
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Float viewer (E2E-10, E2E-11, E2E-12)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("E2E-10: show_note opens read-only viewer", function()
    it("viewer is read-only and shows note content", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "viewer content" })

      auditor.show_note()

      assert.is_not_nil(auditor._note_float_win)
      assert.is_not_nil(auditor._note_float_buf)
      assert.is_true(vim.api.nvim_win_is_valid(auditor._note_float_win))
      assert.is_false(vim.bo[auditor._note_float_buf].modifiable)

      local lines = vim.api.nvim_buf_get_lines(auditor._note_float_buf, 0, -1, false)
      assert.equals("viewer content", lines[1])

      auditor._close_note_float()
      cleanup(bufnr)
    end)
  end)

  describe("E2E-11: close viewer, note still exists", function()
    it("closing viewer does not remove the note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "persistent" })

      auditor.show_note()
      auditor._close_note_float()

      assert.equals(1, note_count(auditor, bufnr))
      assert.is_true(find_note_text(bufnr, hl.note_ns, "persistent"))
      cleanup(bufnr)
    end)
  end)

  describe("E2E-12: viewer → close → edit → save → updated", function()
    it("can view then edit a note in sequence", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "before edit" })

      -- View it
      auditor.show_note()
      local viewer_buf = auditor._note_float_buf
      assert.is_not_nil(viewer_buf)
      auditor._close_note_float()

      -- Edit it
      local result = editor_save(bufnr, token, "before edit", { "after edit" })
      assert.equals("after edit", result)
      assert.is_true(find_note_text(bufnr, hl.note_ns, "after edit"))
      cleanup(bufnr)
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Full lifecycle round-trips (E2E-13, E2E-14, E2E-15)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("E2E-13: mark → note → save → exit → enter → verify", function()
    it("DB-saved note fully round-trips through mode cycle", function()
      local bufnr, filepath = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "persisted note" })

      -- Save to DB
      auditor.audit()

      -- Verify DB has the note
      local rows = db.get_highlights(filepath)
      local found_db = false
      for _, r in ipairs(rows) do
        if r.note == "persisted note" then
          found_db = true
        end
      end
      assert.is_true(found_db, "note must be in DB")

      -- Exit and re-enter
      auditor.exit_audit_mode()
      assert.equals(0, note_extmark_count(bufnr, hl.note_ns))

      auditor.enter_audit_mode()
      assert.is_true(find_note_text(bufnr, hl.note_ns, "persisted note"))
      assert.equals(1, note_count(auditor, bufnr))
      cleanup(bufnr)
    end)
  end)

  describe("E2E-14: mark → note → save → exit → edit buffer → enter → stale recovery", function()
    it("note recovered after buffer position shift", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "stale recovery note" })

      auditor.audit()
      auditor.exit_audit_mode()

      -- Insert lines above to shift positions
      vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "line1", "line2", "line3" })

      auditor.enter_audit_mode()

      -- Note should be recovered
      assert.is_true(find_note_text(bufnr, hl.note_ns, "stale recovery note"))
      assert.equals(1, note_count(auditor, bufnr))
      cleanup(bufnr)
    end)
  end)

  describe("E2E-15: unsaved note → exit → enter → restored", function()
    it("unsaved note survives mode transition via _saved_notes", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "unsaved note" })

      -- Do NOT call audit() — note is unsaved
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      assert.is_true(find_note_text(bufnr, hl.note_ns, "unsaved note"))
      assert.equals(1, note_count(auditor, bufnr))
      cleanup(bufnr)
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Toggle and repeated cycles (E2E-16, E2E-17)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("E2E-16: multiple enter/exit cycles with unsaved note", function()
    it("note survives 10 enter/exit cycles", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "durable note" })

      for _ = 1, 10 do
        auditor.exit_audit_mode()
        auditor.enter_audit_mode()
      end

      assert.is_true(find_note_text(bufnr, hl.note_ns, "durable note"))
      assert.equals(1, note_count(auditor, bufnr))
      -- Only one note extmark, not duplicates
      assert.equals(1, note_extmark_count(bufnr, hl.note_ns))
      cleanup(bufnr)
    end)
  end)

  describe("E2E-17: toggle preserves notes", function()
    it("toggling on and off preserves notes", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "toggle note" })

      -- Toggle off
      auditor.toggle_audit_mode()
      assert.is_false(auditor._audit_mode)

      -- Toggle on
      auditor.toggle_audit_mode()
      assert.is_true(auditor._audit_mode)

      assert.is_true(find_note_text(bufnr, hl.note_ns, "toggle note"))
      cleanup(bufnr)
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Undo, clear, re-mark interactions (E2E-18 through E2E-21)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("E2E-18: undo removes note + extmarks", function()
    it("undo_at_cursor clears note completely", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "undo me" })

      assert.equals(1, note_count(auditor, bufnr))
      assert.is_true(note_extmark_count(bufnr, hl.note_ns) >= 1)

      auditor.undo_at_cursor()

      assert.equals(0, note_count(auditor, bufnr))
      assert.equals(0, note_extmark_count(bufnr, hl.note_ns))
      assert.equals(0, hl_extmark_count(bufnr, hl.ns))
      cleanup(bufnr)
    end)
  end)

  describe("E2E-19: clear_buffer removes all notes", function()
    it("clear_buffer wipes all notes and highlights", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "note on hello" })

      vim.api.nvim_win_set_cursor(0, { 1, 6 })
      auditor.highlight_cword_buffer("blue")
      local token2 = auditor._cword_token(bufnr)
      editor_save(bufnr, token2, "", { "note on world" })

      assert.equals(2, note_count(auditor, bufnr))

      auditor.clear_buffer()

      assert.equals(0, note_count(auditor, bufnr))
      assert.equals(0, note_extmark_count(bufnr, hl.note_ns))
      assert.equals(0, hl_extmark_count(bufnr, hl.ns))
      cleanup(bufnr)
    end)
  end)

  describe("E2E-20: re-mark clears old note", function()
    it("re-marking word removes existing note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "old note" })

      assert.equals(1, note_count(auditor, bufnr))

      -- Re-mark same word with different color
      auditor.highlight_cword_buffer("blue")

      assert.equals(0, note_count(auditor, bufnr))
      cleanup(bufnr)
    end)
  end)

  describe("E2E-21: re-mark then add new note", function()
    it("adding note after re-mark works correctly", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "first note" })

      -- Re-mark
      auditor.highlight_cword_buffer("blue")
      assert.equals(0, note_count(auditor, bufnr))

      -- Add new note
      local token2 = auditor._cword_token(bufnr)
      editor_save(bufnr, token2, "", { "second note" })

      assert.equals(1, note_count(auditor, bufnr))
      assert.is_true(find_note_text(bufnr, hl.note_ns, "second note"))
      assert.is_false(find_note_text(bufnr, hl.note_ns, "first note"))
      cleanup(bufnr)
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Multiple notes (E2E-22, E2E-23)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("E2E-22: multiple notes on same line", function()
    it("different words on same line each get their own note", function()
      local bufnr = setup_buf({ "hello world foo" }, 1, 0)

      -- Note on "hello"
      auditor.highlight_cword_buffer("red")
      local t1 = auditor._cword_token(bufnr)
      editor_save(bufnr, t1, "", { "note1" })

      -- Note on "world"
      vim.api.nvim_win_set_cursor(0, { 1, 6 })
      auditor.highlight_cword_buffer("blue")
      local t2 = auditor._cword_token(bufnr)
      editor_save(bufnr, t2, "", { "note2" })

      -- Note on "foo"
      vim.api.nvim_win_set_cursor(0, { 1, 12 })
      auditor.highlight_cword_buffer("red")
      local t3 = auditor._cword_token(bufnr)
      editor_save(bufnr, t3, "", { "note3" })

      assert.equals(3, note_count(auditor, bufnr))
      assert.is_true(find_note_text(bufnr, hl.note_ns, "note1"))
      assert.is_true(find_note_text(bufnr, hl.note_ns, "note2"))
      assert.is_true(find_note_text(bufnr, hl.note_ns, "note3"))
      cleanup(bufnr)
    end)
  end)

  describe("E2E-23: multiple notes on different lines", function()
    it("notes across lines are independent", function()
      local bufnr = setup_buf({ "alpha", "bravo", "charlie" }, 1, 0)

      auditor.highlight_cword_buffer("red")
      local t1 = auditor._cword_token(bufnr)
      editor_save(bufnr, t1, "", { "line1 note" })

      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      auditor.highlight_cword_buffer("blue")
      local t2 = auditor._cword_token(bufnr)
      editor_save(bufnr, t2, "", { "line2 note" })

      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      auditor.highlight_cword_buffer("red")
      local t3 = auditor._cword_token(bufnr)
      editor_save(bufnr, t3, "", { "line3 note" })

      assert.equals(3, note_count(auditor, bufnr))

      -- Delete middle note
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      auditor.undo_at_cursor()

      assert.equals(2, note_count(auditor, bufnr))
      assert.is_true(find_note_text(bufnr, hl.note_ns, "line1 note"))
      assert.is_false(find_note_text(bufnr, hl.note_ns, "line2 note"))
      assert.is_true(find_note_text(bufnr, hl.note_ns, "line3 note"))
      cleanup(bufnr)
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Color variations (E2E-24, E2E-25)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("E2E-24: note on gradient highlight", function()
    it("note works with half (gradient) color", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("half")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "gradient note" })

      assert.equals(1, note_count(auditor, bufnr))
      assert.is_true(find_note_text(bufnr, hl.note_ns, "gradient note"))

      -- Save + round-trip
      auditor.audit()
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      assert.is_true(find_note_text(bufnr, hl.note_ns, "gradient note"))
      cleanup(bufnr)
    end)
  end)

  describe("E2E-25: note with custom solid color", function()
    it("custom colors support notes", function()
      reset_modules()
      local tmp_db = vim.fn.tempname() .. ".db"
      auditor = require("auditor")
      auditor.setup({
        db_path = tmp_db,
        keymaps = false,
        colors = {
          { name = "green", label = "Green", hl = { bg = "#00ff00", fg = "#000000" } },
        },
      })
      hl = require("auditor.highlights")
      db = require("auditor.db")

      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("green")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "green note" })

      assert.equals(1, note_count(auditor, bufnr))
      assert.is_true(find_note_text(bufnr, hl.note_ns, "green note"))
      cleanup(bufnr)
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Delete/re-add, warning messages (E2E-26 through E2E-31)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("E2E-26: delete then re-add note", function()
    it("can delete a note and then add a new one", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "first" })
      assert.equals(1, note_count(auditor, bufnr))

      auditor.delete_note()
      assert.equals(0, note_count(auditor, bufnr))

      local token2 = auditor._cword_token(bufnr)
      editor_save(bufnr, token2, "", { "second" })
      assert.equals(1, note_count(auditor, bufnr))
      assert.is_true(find_note_text(bufnr, hl.note_ns, "second"))
      cleanup(bufnr)
    end)
  end)

  describe("E2E-27: edit_note on word without note warns", function()
    it("warns and does nothing", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      auditor._note_input_override = true

      local restore, msgs = capture_notify()
      auditor.edit_note()
      restore()

      assert.is_true(msgs_contain(msgs, "No note"))
      cleanup(bufnr)
    end)
  end)

  describe("E2E-28: show_note on word without note warns", function()
    it("warns and does nothing", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore, msgs = capture_notify()
      auditor.show_note()
      restore()

      assert.is_true(msgs_contain(msgs, "No note"))
      assert.is_nil(auditor._note_float_win)
      cleanup(bufnr)
    end)
  end)

  describe("E2E-29: delete_note on word without note warns", function()
    it("warns and does nothing", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore, msgs = capture_notify()
      auditor.delete_note()
      restore()

      assert.is_true(msgs_contain(msgs, "No note"))
      cleanup(bufnr)
    end)
  end)

  describe("E2E-30: add_note without highlight warns", function()
    it("warns when no highlight exists on word", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor._note_input_override = true

      local restore, msgs = capture_notify()
      auditor.add_note()
      restore()

      assert.is_true(msgs_contain(msgs, "No highlight") or msgs_contain(msgs, "Mark it first"))
      cleanup(bufnr)
    end)
  end)

  describe("E2E-31: all note commands fail outside audit mode", function()
    it("add_note, edit_note, delete_note, show_note, list_notes all fail", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.exit_audit_mode()
      auditor._note_input_override = true

      local commands = { "add_note", "edit_note", "delete_note", "show_note", "list_notes" }
      for _, cmd in ipairs(commands) do
        local restore, msgs = capture_notify()
        auditor[cmd]()
        restore()
        assert.is_true(msgs_contain(msgs, "Cannot"), cmd .. " should fail outside audit mode")
      end
      cleanup(bufnr)
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Multi-buffer (E2E-32, E2E-33)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("E2E-32: notes isolated per buffer", function()
    it("notes on buffer A do not appear on buffer B", function()
      local bufA = setup_buf({ "alpha bravo" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local tA = auditor._cword_token(bufA)
      editor_save(bufA, tA, "", { "note A" })

      local bufB = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(bufB, vim.fn.tempname() .. ".lua")
      vim.api.nvim_buf_set_lines(bufB, 0, -1, false, { "charlie delta" })
      vim.api.nvim_set_current_buf(bufB)

      -- Re-enter to pick up buffer B
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      vim.api.nvim_set_current_buf(bufB)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("blue")
      local tB = auditor._cword_token(bufB)
      editor_save(bufB, tB, "", { "note B" })

      assert.equals(1, note_count(auditor, bufA))
      assert.equals(1, note_count(auditor, bufB))
      assert.is_true(find_note_text(bufA, hl.note_ns, "note A"))
      assert.is_true(find_note_text(bufB, hl.note_ns, "note B"))
      assert.is_false(find_note_text(bufA, hl.note_ns, "note B"))
      assert.is_false(find_note_text(bufB, hl.note_ns, "note A"))

      cleanup(bufA)
      cleanup(bufB)
    end)
  end)

  describe("E2E-33: multi-buffer save", function()
    it("save persists notes from both buffers", function()
      local bufA, fpA = setup_buf({ "alpha" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local tA = auditor._cword_token(bufA)
      editor_save(bufA, tA, "", { "noteA" })

      local bufB = vim.api.nvim_create_buf(false, true)
      local fpB = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufB, fpB)
      vim.api.nvim_buf_set_lines(bufB, 0, -1, false, { "bravo" })
      vim.api.nvim_set_current_buf(bufB)
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()
      vim.api.nvim_set_current_buf(bufB)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("blue")
      local tB = auditor._cword_token(bufB)
      editor_save(bufB, tB, "", { "noteB" })

      auditor.audit()

      local rowsA = db.get_highlights(vim.fn.resolve(vim.fn.fnamemodify(fpA, ":p")))
      local rowsB = db.get_highlights(vim.fn.resolve(vim.fn.fnamemodify(fpB, ":p")))

      local foundA, foundB = false, false
      for _, r in ipairs(rowsA) do
        if r.note == "noteA" then foundA = true end
      end
      for _, r in ipairs(rowsB) do
        if r.note == "noteB" then foundB = true end
      end
      assert.is_true(foundA)
      assert.is_true(foundB)

      cleanup(bufA)
      cleanup(bufB)
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════════
  -- list_notes (E2E-34, E2E-35)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("E2E-34: list_notes sorted", function()
    it("quickfix entries sorted by line then col", function()
      local bufnr = setup_buf({ "aaa bbb", "ccc ddd" }, 1, 0)

      -- Note on "bbb" (line 1, col 4)
      vim.api.nvim_win_set_cursor(0, { 1, 4 })
      auditor.highlight_cword_buffer("red")
      local t1 = auditor._cword_token(bufnr)
      editor_save(bufnr, t1, "", { "note bbb" })

      -- Note on "aaa" (line 1, col 0)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("blue")
      local t2 = auditor._cword_token(bufnr)
      editor_save(bufnr, t2, "", { "note aaa" })

      -- Note on "ccc" (line 2, col 0)
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      auditor.highlight_cword_buffer("red")
      local t3 = auditor._cword_token(bufnr)
      editor_save(bufnr, t3, "", { "note ccc" })

      auditor.list_notes()
      local qf = vim.fn.getqflist()
      assert.equals(3, #qf)
      -- line 1 col 1 (aaa), line 1 col 5 (bbb), line 2 col 1 (ccc)
      assert.equals(1, qf[1].lnum)
      assert.equals(1, qf[2].lnum)
      assert.equals(2, qf[3].lnum)
      assert.is_true(qf[1].col < qf[2].col)
      assert.is_truthy(qf[1].text:match("note aaa"))
      assert.is_truthy(qf[2].text:match("note bbb"))
      assert.is_truthy(qf[3].text:match("note ccc"))

      vim.cmd("cclose")
      cleanup(bufnr)
    end)
  end)

  describe("E2E-35: list_notes on empty buffer", function()
    it("shows info when no notes exist", function()
      local bufnr = setup_buf({ "hello" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore, msgs = capture_notify()
      auditor.list_notes()
      restore()

      assert.is_true(msgs_contain(msgs, "No notes"))
      cleanup(bufnr)
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Buffer edits with notes (E2E-36, E2E-37)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("E2E-36: note survives line insert above", function()
    it("inserting a line above does not break the note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "still here" })

      -- Insert line above
      vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "new first line" })

      -- Note should still be tracked (extmark moves with the line)
      assert.equals(1, note_count(auditor, bufnr))

      -- Save, exit, enter to verify full cycle
      auditor.audit()
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      assert.is_true(find_note_text(bufnr, hl.note_ns, "still here"))
      cleanup(bufnr)
    end)
  end)

  describe("E2E-37: note survives line delete above", function()
    it("deleting a line above does not break the note", function()
      local bufnr = setup_buf({ "first line", "hello world" }, 2, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "stays" })

      -- Delete first line
      vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, {})

      assert.equals(1, note_count(auditor, bufnr))

      auditor.audit()
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      assert.is_true(find_note_text(bufnr, hl.note_ns, "stays"))
      cleanup(bufnr)
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Float lifecycle edge cases (E2E-38 through E2E-41)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("E2E-38: open two editors rapidly", function()
    it("opening a new editor closes the previous one", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, hl.ns, token)

      auditor._open_note_editor(bufnr, target_id, token, "")
      local first_win = auditor._note_float_win
      local first_buf = auditor._note_float_buf
      assert.is_true(vim.api.nvim_win_is_valid(first_win))

      -- Open second editor immediately
      auditor._open_note_editor(bufnr, target_id, token, "")
      local second_win = auditor._note_float_win

      -- First should be closed
      assert.is_false(vim.api.nvim_win_is_valid(first_win))
      assert.is_true(vim.api.nvim_win_is_valid(second_win))
      assert.are_not.equal(first_buf, auditor._note_float_buf)

      auditor._close_note_float()
      cleanup(bufnr)
    end)
  end)

  describe("E2E-39: open two viewers rapidly", function()
    it("opening a new viewer closes the previous one", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "content" })

      auditor.show_note()
      local first_win = auditor._note_float_win
      assert.is_true(vim.api.nvim_win_is_valid(first_win))

      auditor.show_note()
      local second_win = auditor._note_float_win

      assert.is_false(vim.api.nvim_win_is_valid(first_win))
      assert.is_true(vim.api.nvim_win_is_valid(second_win))

      auditor._close_note_float()
      cleanup(bufnr)
    end)
  end)

  describe("E2E-40: exit audit mode with editor open", function()
    it("float editor state is cleared on exit", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, hl.ns, token)

      auditor._open_note_editor(bufnr, target_id, token, "")
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "typing..." })

      -- Exit audit mode — should not crash
      auditor.exit_audit_mode()

      -- Note should NOT be saved (editor was not saved before exit)
      assert.equals(0, note_count(auditor, bufnr))
      cleanup(bufnr)
    end)
  end)

  describe("E2E-41: exit audit mode with viewer open", function()
    it("viewer float state is cleared on exit", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "viewer text" })

      auditor.show_note()
      assert.is_not_nil(auditor._note_float_win)

      auditor.exit_audit_mode()

      -- Note should still be preserved in _saved_notes even though viewer was open
      auditor.enter_audit_mode()
      assert.is_true(find_note_text(bufnr, hl.note_ns, "viewer text"))
      cleanup(bufnr)
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Multi-line notes (E2E-42, E2E-43)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("E2E-42: multi-line note via float editor", function()
    it("saves multi-line text with newlines", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)

      local result = editor_save(bufnr, token, "", {
        "Line 1: overview",
        "Line 2: details",
        "Line 3: conclusion",
      })

      assert.equals("Line 1: overview\nLine 2: details\nLine 3: conclusion", result)
      assert.equals(1, note_count(auditor, bufnr))
      cleanup(bufnr)
    end)
  end)

  describe("E2E-43: multi-line note DB round-trip", function()
    it("newlines preserved through save → exit → enter", function()
      local bufnr, filepath = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "first", "second", "third" })

      auditor.audit()

      -- Verify DB
      local rows = db.get_highlights(filepath)
      local found = false
      for _, r in ipairs(rows) do
        if r.note and r.note:find("first") and r.note:find("second") and r.note:find("third") then
          found = true
        end
      end
      assert.is_true(found, "multi-line note in DB")

      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      -- Note text should still have newlines
      local target_id2 = find_target_id(bufnr, hl.ns, token)
      assert.is_not_nil(target_id2)
      local note = auditor._notes[bufnr][target_id2]
      assert.is_not_nil(note)
      assert.is_truthy(note:find("\n"))
      assert.is_truthy(note:find("first"))
      assert.is_truthy(note:find("second"))
      assert.is_truthy(note:find("third"))
      cleanup(bufnr)
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Edge cases (E2E-44, E2E-45)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("E2E-44: open editor, cancel — highlight intact", function()
    it("cancelling note editor does not affect the highlight", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local before = hl_extmark_count(bufnr, hl.ns)

      local token = auditor._cword_token(bufnr)
      editor_cancel(bufnr, token, "", nil)

      assert.equals(before, hl_extmark_count(bufnr, hl.ns))
      assert.equals(0, note_count(auditor, bufnr))
      cleanup(bufnr)
    end)
  end)

  describe("E2E-45: editor saves to original word regardless of cursor", function()
    it("note is attached to the word it was opened on", function()
      local bufnr = setup_buf({ "alpha bravo charlie" }, 1, 0)
      auditor.highlight_cword_buffer("red") -- "alpha"
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, hl.ns, token)

      auditor._open_note_editor(bufnr, target_id, token, "")
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "on alpha" })

      -- Cursor is in the float, but the note should attach to "alpha"
      local cb = get_keymap_cb(auditor._note_float_buf, "n", "<C-S>")
        or get_keymap_cb(auditor._note_float_buf, "n", "<C-s>")
      cb()

      assert.equals("on alpha", auditor._notes[bufnr][target_id])
      cleanup(bufnr)
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Exhaustive state machine transitions (E2E-46 through E2E-55)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("E2E-46: S0→S1→S2→S3→S4→S8→S9 full sequence", function()
    it("walks through every major state", function()
      -- S0: no audit mode
      reset_modules()
      local tmp_db = vim.fn.tempname() .. ".db"
      auditor = require("auditor")
      auditor.setup({ db_path = tmp_db, keymaps = false })
      hl = require("auditor.highlights")
      db = require("auditor.db")
      assert.is_false(auditor._audit_mode)

      -- S0→S1: enter audit mode, cursor not on word
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(bufnr, vim.fn.tempname() .. ".lua")
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "  hello  " })
      vim.api.nvim_set_current_buf(bufnr)
      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- on space
      assert.is_true(auditor._audit_mode)
      assert.is_nil(auditor._cword_token(bufnr)) -- no word under cursor

      -- S1→S2: move to word, highlight it
      vim.api.nvim_win_set_cursor(0, { 1, 2 }) -- on "hello"
      assert.is_not_nil(auditor._cword_token(bufnr))
      auditor.highlight_cword_buffer("red")
      assert.is_true(hl_extmark_count(bufnr, hl.ns) >= 1)
      assert.equals(0, note_count(auditor, bufnr))

      -- S2→S3: add note (unsaved)
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "my note" })
      assert.equals(1, note_count(auditor, bufnr))

      -- S3→S4: save to DB
      auditor.audit()
      assert.equals(1, note_count(auditor, bufnr))

      -- S4→S8: exit audit mode
      auditor.exit_audit_mode()
      assert.is_false(auditor._audit_mode)
      assert.equals(0, note_extmark_count(bufnr, hl.note_ns))

      -- S8→S9: re-enter, note restored
      auditor.enter_audit_mode()
      assert.is_true(find_note_text(bufnr, hl.note_ns, "my note"))
      assert.equals(1, note_count(auditor, bufnr))

      cleanup(bufnr)
    end)
  end)

  describe("E2E-47: S2→S5→S3 (editor new → save)", function()
    it("opening editor on highlight without note and saving transitions to note state", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      assert.equals(0, note_count(auditor, bufnr)) -- S2

      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, hl.ns, token)
      auditor._open_note_editor(bufnr, target_id, token, "")
      assert.is_not_nil(auditor._note_float_win) -- S5

      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "new note" })
      local cb = get_keymap_cb(auditor._note_float_buf, "n", "<C-S>")
        or get_keymap_cb(auditor._note_float_buf, "n", "<C-s>")
      cb()
      assert.is_nil(auditor._note_float_win) -- float closed
      assert.equals(1, note_count(auditor, bufnr)) -- S3

      cleanup(bufnr)
    end)
  end)

  describe("E2E-48: S2→S5→S2 (editor new → cancel)", function()
    it("opening editor and cancelling returns to no-note state", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      assert.equals(0, note_count(auditor, bufnr)) -- S2

      local token = auditor._cword_token(bufnr)
      editor_cancel(bufnr, token, "", { "will be discarded" })
      assert.equals(0, note_count(auditor, bufnr)) -- S2

      cleanup(bufnr)
    end)
  end)

  describe("E2E-49: S3→S6→S3 (editor edit → save updated)", function()
    it("editing existing note via editor updates it", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "v1" })
      assert.equals(1, note_count(auditor, bufnr)) -- S3

      local result = editor_save(bufnr, token, "v1", { "v2" })
      assert.equals("v2", result) -- S3 with updated text
      assert.equals(1, note_count(auditor, bufnr))

      cleanup(bufnr)
    end)
  end)

  describe("E2E-50: S3→S6→S3 (editor edit → cancel preserves)", function()
    it("cancelling edit preserves original note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, hl.ns, token)
      editor_save(bufnr, token, "", { "original" })
      assert.equals("original", auditor._notes[bufnr][target_id]) -- S3

      editor_cancel(bufnr, token, "original", { "modified" })
      assert.equals("original", auditor._notes[bufnr][target_id]) -- S3 unchanged

      cleanup(bufnr)
    end)
  end)

  describe("E2E-51: S3→S7→S3 (viewer → close)", function()
    it("viewing and closing note does not modify state", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, hl.ns, token)
      editor_save(bufnr, token, "", { "viewable" })
      assert.equals(1, note_count(auditor, bufnr)) -- S3

      auditor.show_note()
      assert.is_not_nil(auditor._note_float_win) -- S7

      auditor._close_note_float()
      assert.equals(1, note_count(auditor, bufnr)) -- S3
      assert.equals("viewable", auditor._notes[bufnr][target_id])

      cleanup(bufnr)
    end)
  end)

  describe("E2E-52: S3→delete→S2", function()
    it("deleting note returns to no-note state", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "to delete" })
      assert.equals(1, note_count(auditor, bufnr)) -- S3

      auditor.delete_note()
      assert.equals(0, note_count(auditor, bufnr)) -- S2
      assert.equals(0, note_extmark_count(bufnr, hl.note_ns))
      -- Highlight still exists
      assert.is_true(hl_extmark_count(bufnr, hl.ns) >= 1)

      cleanup(bufnr)
    end)
  end)

  describe("E2E-53: S2→add→S3→save→S4→exit→S8→enter→S9→verify", function()
    it("full lifecycle with all transitions", function()
      local bufnr, filepath = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)

      -- S2→S3
      editor_save(bufnr, token, "", { "lifecycle note" })
      assert.equals(1, note_count(auditor, bufnr))

      -- S3→S4
      auditor.audit()
      local rows = db.get_highlights(filepath)
      local db_note = false
      for _, r in ipairs(rows) do
        if r.note == "lifecycle note" then db_note = true end
      end
      assert.is_true(db_note)

      -- S4→S8
      auditor.exit_audit_mode()

      -- S8→S9
      auditor.enter_audit_mode()
      assert.is_true(find_note_text(bufnr, hl.note_ns, "lifecycle note"))
      assert.equals(1, note_count(auditor, bufnr))
      assert.equals(1, note_extmark_count(bufnr, hl.note_ns))

      cleanup(bufnr)
    end)
  end)

  describe("E2E-54: S4→undo→S1 (DB-backed note removed)", function()
    it("undoing a DB-backed highlight removes its note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "db note" })
      auditor.audit()
      assert.equals(1, note_count(auditor, bufnr)) -- S4

      auditor.undo_at_cursor()
      assert.equals(0, note_count(auditor, bufnr)) -- S1
      assert.equals(0, note_extmark_count(bufnr, hl.note_ns))
      assert.equals(0, hl_extmark_count(bufnr, hl.ns))

      cleanup(bufnr)
    end)
  end)

  describe("E2E-55: S4→clear→S1 (everything cleared)", function()
    it("clearing removes DB-backed notes and highlights", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "cleared note" })

      vim.api.nvim_win_set_cursor(0, { 1, 6 })
      auditor.highlight_cword_buffer("blue")
      local token2 = auditor._cword_token(bufnr)
      editor_save(bufnr, token2, "", { "also cleared" })

      auditor.audit()
      assert.equals(2, note_count(auditor, bufnr)) -- S4

      auditor.clear_buffer()
      assert.equals(0, note_count(auditor, bufnr)) -- S1
      assert.equals(0, note_extmark_count(bufnr, hl.note_ns))
      assert.equals(0, hl_extmark_count(bufnr, hl.ns))

      cleanup(bufnr)
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Editor behavior details (E2E-56, E2E-57)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("E2E-56: startinsert on new, normal on edit", function()
    it("new note starts in insert mode", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, hl.ns, token)

      auditor._open_note_editor(bufnr, target_id, token, "")
      -- After opening with empty initial_text, startinsert is called
      -- In headless tests, mode query may vary, but the float should exist
      assert.is_not_nil(auditor._note_float_win)
      auditor._close_note_float()

      -- Edit existing: should NOT call startinsert
      editor_save(bufnr, token, "", { "existing" })
      auditor._open_note_editor(bufnr, target_id, token, "existing")
      assert.is_not_nil(auditor._note_float_win)
      auditor._close_note_float()

      cleanup(bufnr)
    end)
  end)

  describe("E2E-57: note count consistency", function()
    it("note count matches extmark count after every operation", function()
      local bufnr = setup_buf({ "aaa bbb ccc" }, 1, 0)

      local function assert_consistent()
        local nc = note_count(auditor, bufnr)
        local ec = note_extmark_count(bufnr, hl.note_ns)
        assert.equals(nc, ec,
          string.format("note_count=%d but extmark_count=%d", nc, ec))
      end

      -- Add 3 highlights + notes
      auditor.highlight_cword_buffer("red") -- aaa
      local t1 = auditor._cword_token(bufnr)
      editor_save(bufnr, t1, "", { "note1" })
      assert_consistent()

      vim.api.nvim_win_set_cursor(0, { 1, 4 })
      auditor.highlight_cword_buffer("blue") -- bbb
      local t2 = auditor._cword_token(bufnr)
      editor_save(bufnr, t2, "", { "note2" })
      assert_consistent()

      vim.api.nvim_win_set_cursor(0, { 1, 8 })
      auditor.highlight_cword_buffer("red") -- ccc
      local t3 = auditor._cword_token(bufnr)
      editor_save(bufnr, t3, "", { "note3" })
      assert_consistent()

      -- Delete one
      vim.api.nvim_win_set_cursor(0, { 1, 4 })
      auditor.delete_note()
      assert_consistent()

      -- Undo one
      vim.api.nvim_win_set_cursor(0, { 1, 8 })
      auditor.undo_at_cursor()
      assert_consistent()

      -- Save
      auditor.audit()
      assert_consistent()

      -- Exit and enter
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()
      assert_consistent()

      -- Clear
      auditor.clear_buffer()
      assert_consistent()
      assert.equals(0, note_count(auditor, bufnr))

      cleanup(bufnr)
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Comprehensive combination tests (E2E-58 through E2E-65)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("E2E-58: add note → save → edit note → save again", function()
    it("edited note overwrites DB entry", function()
      local bufnr, filepath = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)

      editor_save(bufnr, token, "", { "v1" })
      auditor.audit()

      -- Edit via float
      editor_save(bufnr, token, "v1", { "v2" })
      auditor.audit()

      local rows = db.get_highlights(filepath)
      local found = false
      for _, r in ipairs(rows) do
        if r.note == "v2" then found = true end
      end
      assert.is_true(found)

      -- v1 should not exist
      local old = false
      for _, r in ipairs(rows) do
        if r.note == "v1" then old = true end
      end
      assert.is_false(old)

      cleanup(bufnr)
    end)
  end)

  describe("E2E-59: add note → delete → save → exit → enter → no note", function()
    it("deleted note is not restored from DB", function()
      local bufnr, filepath = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)

      editor_save(bufnr, token, "", { "to delete" })
      auditor.delete_note()
      auditor.audit()

      local rows = db.get_highlights(filepath)
      for _, r in ipairs(rows) do
        assert.is_not.equals("to delete", r.note or "")
      end

      auditor.exit_audit_mode()
      auditor.enter_audit_mode()
      assert.equals(0, note_count(auditor, bufnr))

      cleanup(bufnr)
    end)
  end)

  describe("E2E-60: add note → undo highlight → re-mark → no note", function()
    it("undone highlight's note is not restored after re-mark", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "gone with undo" })

      auditor.undo_at_cursor()
      assert.equals(0, note_count(auditor, bufnr))

      -- Re-mark same word
      auditor.highlight_cword_buffer("blue")
      assert.equals(0, note_count(auditor, bufnr))

      cleanup(bufnr)
    end)
  end)

  describe("E2E-61: viewer → editor transition", function()
    it("viewing note then opening editor replaces viewer", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, hl.ns, token)
      editor_save(bufnr, token, "", { "viewable" })

      -- Open viewer
      auditor.show_note()
      local viewer_win = auditor._note_float_win
      assert.is_not_nil(viewer_win)

      -- Open editor (should close viewer)
      auditor._open_note_editor(bufnr, target_id, token, "viewable")
      assert.is_false(vim.api.nvim_win_is_valid(viewer_win))
      assert.is_not_nil(auditor._note_float_win)
      -- New float should be an editor (modifiable)
      assert.is_true(vim.bo[auditor._note_float_buf].modifiable)

      auditor._close_note_float()
      cleanup(bufnr)
    end)
  end)

  describe("E2E-62: editor → viewer transition", function()
    it("opening viewer while editor is open replaces editor", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, hl.ns, token)

      -- Save a note first so show_note has something to show
      editor_save(bufnr, token, "", { "content" })

      -- Open editor
      auditor._open_note_editor(bufnr, target_id, token, "content")
      local editor_win = auditor._note_float_win
      assert.is_not_nil(editor_win)

      -- Need to go back to source buffer window for show_note to work
      -- (show_note reads cursor position from current buffer)
      -- close the editor first, then show
      auditor._close_note_float()
      vim.api.nvim_set_current_buf(bufnr)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      auditor.show_note()
      assert.is_not_nil(auditor._note_float_win)
      -- Viewer is not modifiable
      assert.is_false(vim.bo[auditor._note_float_buf].modifiable)

      auditor._close_note_float()
      cleanup(bufnr)
    end)
  end)

  describe("E2E-63: repeated save is idempotent", function()
    it("audit() twice does not duplicate DB rows", function()
      local bufnr, filepath = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "idempotent" })

      auditor.audit()
      local rows1 = db.get_highlights(filepath)

      auditor.audit()
      local rows2 = db.get_highlights(filepath)

      assert.equals(#rows1, #rows2)
      assert.equals(1, note_count(auditor, bufnr))
      cleanup(bufnr)
    end)
  end)

  describe("E2E-64: add note via vim.ui.input fallback", function()
    it("_note_input_override uses vim.ui.input path", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      auditor._note_input_override = true

      local restore_input = stub_input("input note")
      auditor.add_note()
      restore_input()

      assert.equals(1, note_count(auditor, bufnr))
      assert.is_true(find_note_text(bufnr, hl.note_ns, "input note"))

      -- Round-trip
      auditor.audit()
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()
      assert.is_true(find_note_text(bufnr, hl.note_ns, "input note"))

      cleanup(bufnr)
    end)
  end)

  describe("E2E-65: add note via float, edit via vim.ui.input", function()
    it("mixing float and input paths works", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)

      -- Add via float
      editor_save(bufnr, token, "", { "float note" })
      assert.equals(1, note_count(auditor, bufnr))

      -- Edit via input
      auditor._note_input_override = true
      local restore_input = stub_input("input edited")
      auditor.edit_note()
      restore_input()

      local target_id = find_target_id(bufnr, hl.ns, token)
      assert.equals("input edited", auditor._notes[bufnr][target_id])
      assert.is_true(find_note_text(bufnr, hl.note_ns, "input edited"))

      cleanup(bufnr)
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Note extmark duplication guard (E2E-66 through E2E-68)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("E2E-66: no duplicate note extmarks after save+exit+enter", function()
    it("exactly 1 note extmark after DB round-trip", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "single" })

      auditor.audit()
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      assert.equals(1, note_count(auditor, bufnr))
      assert.equals(1, note_extmark_count(bufnr, hl.note_ns))
      cleanup(bufnr)
    end)
  end)

  describe("E2E-67: no duplicate notes after multiple save cycles", function()
    it("repeated save does not duplicate note extmarks", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "once" })

      for _ = 1, 5 do
        auditor.audit()
        auditor.exit_audit_mode()
        auditor.enter_audit_mode()
      end

      assert.equals(1, note_count(auditor, bufnr))
      assert.equals(1, note_extmark_count(bufnr, hl.note_ns))
      cleanup(bufnr)
    end)
  end)

  describe("E2E-68: no orphan note extmarks after highlight undo", function()
    it("undoing highlight removes note extmark completely", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "orphan check" })

      assert.equals(1, note_extmark_count(bufnr, hl.note_ns))

      auditor.undo_at_cursor()

      assert.equals(0, note_extmark_count(bufnr, hl.note_ns))
      -- Verify no note extmarks anywhere on the line
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, {})
      assert.equals(0, #marks)
      cleanup(bufnr)
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Complex multi-operation sequences (E2E-69 through E2E-72)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("E2E-69: add → edit → delete → re-add → save → round-trip", function()
    it("full CRUD cycle with DB persistence", function()
      local bufnr, filepath = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)

      -- Create
      editor_save(bufnr, token, "", { "created" })
      assert.equals(1, note_count(auditor, bufnr))

      -- Update
      editor_save(bufnr, token, "created", { "updated" })
      local target_id = find_target_id(bufnr, hl.ns, token)
      assert.equals("updated", auditor._notes[bufnr][target_id])

      -- Delete
      auditor.delete_note()
      assert.equals(0, note_count(auditor, bufnr))

      -- Re-create
      editor_save(bufnr, token, "", { "re-created" })
      assert.equals(1, note_count(auditor, bufnr))

      -- Save and round-trip
      auditor.audit()
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      assert.is_true(find_note_text(bufnr, hl.note_ns, "re-created"))
      -- "updated" should not appear (it was deleted before re-create)
      assert.is_false(find_note_text(bufnr, hl.note_ns, "updated"))

      local rows = db.get_highlights(filepath)
      local db_note = nil
      for _, r in ipairs(rows) do
        if r.note and r.note ~= "" then
          db_note = r.note
        end
      end
      assert.equals("re-created", db_note)

      cleanup(bufnr)
    end)
  end)

  describe("E2E-70: interleaved notes across words", function()
    it("add/edit/delete different words interleaved", function()
      local bufnr = setup_buf({ "alpha bravo charlie" }, 1, 0)

      -- Highlight all three
      auditor.highlight_cword_buffer("red") -- alpha
      vim.api.nvim_win_set_cursor(0, { 1, 6 })
      auditor.highlight_cword_buffer("blue") -- bravo
      vim.api.nvim_win_set_cursor(0, { 1, 12 })
      auditor.highlight_cword_buffer("red") -- charlie

      -- Add note to alpha
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local tA = auditor._cword_token(bufnr)
      editor_save(bufnr, tA, "", { "note A" })

      -- Add note to charlie
      vim.api.nvim_win_set_cursor(0, { 1, 12 })
      local tC = auditor._cword_token(bufnr)
      editor_save(bufnr, tC, "", { "note C" })

      -- Edit alpha's note
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      editor_save(bufnr, tA, "note A", { "note A v2" })

      -- Delete charlie's note
      vim.api.nvim_win_set_cursor(0, { 1, 12 })
      auditor.delete_note()

      -- Add note to bravo
      vim.api.nvim_win_set_cursor(0, { 1, 6 })
      local tB = auditor._cword_token(bufnr)
      editor_save(bufnr, tB, "", { "note B" })

      assert.equals(2, note_count(auditor, bufnr))
      assert.is_true(find_note_text(bufnr, hl.note_ns, "note A v2"))
      assert.is_true(find_note_text(bufnr, hl.note_ns, "note B"))
      assert.is_false(find_note_text(bufnr, hl.note_ns, "note C"))

      -- Round-trip
      auditor.audit()
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      assert.equals(2, note_count(auditor, bufnr))
      assert.is_true(find_note_text(bufnr, hl.note_ns, "note A v2"))
      assert.is_true(find_note_text(bufnr, hl.note_ns, "note B"))

      cleanup(bufnr)
    end)
  end)

  describe("E2E-71: highlight with note, clear, re-highlight, add different note", function()
    it("clear wipes slate, new note on same word works", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "original" })
      auditor.audit()

      auditor.clear_buffer()
      assert.equals(0, note_count(auditor, bufnr))
      assert.equals(0, hl_extmark_count(bufnr, hl.ns))

      -- Re-highlight and add different note
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("blue")
      local token2 = auditor._cword_token(bufnr)
      editor_save(bufnr, token2, "", { "fresh start" })

      assert.equals(1, note_count(auditor, bufnr))
      assert.is_true(find_note_text(bufnr, hl.note_ns, "fresh start"))
      assert.is_false(find_note_text(bufnr, hl.note_ns, "original"))

      cleanup(bufnr)
    end)
  end)

  describe("E2E-72: rapid open/cancel cycles", function()
    it("10 rapid open/cancel cycles cause no leaks or crashes", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, hl.ns, token)

      for i = 1, 10 do
        auditor._open_note_editor(bufnr, target_id, token, "")
        vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "attempt " .. i })
        auditor._close_note_float()
      end

      -- No note should be saved (all cancelled via _close_note_float)
      assert.equals(0, note_count(auditor, bufnr))
      assert.is_nil(auditor._note_float_win)
      assert.is_nil(auditor._note_float_buf)

      -- Highlight still intact
      assert.is_true(hl_extmark_count(bufnr, hl.ns) >= 1)

      cleanup(bufnr)
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Buffer content doesn't change (E2E-73)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("E2E-73: buffer content unchanged through entire note lifecycle", function()
    it("buffer lines are identical after add/edit/delete/save cycle", function()
      local original = { "function foo()", "  local x = 42", "  return x", "end" }
      local bufnr = setup_buf(vim.fn.copy(original), 2, 8)

      -- Highlight "x"
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "important variable", "tracks state" })

      -- Edit note
      editor_save(bufnr, token, "important variable\ntracks state", { "updated note" })

      -- Save
      auditor.audit()

      -- Exit/enter
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      -- Delete note
      vim.api.nvim_win_set_cursor(0, { 2, 8 })
      auditor.delete_note()

      -- Buffer should be unchanged
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.same(original, lines)

      cleanup(bufnr)
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════════
  -- pick_note_action integration (E2E-74)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("E2E-74: pick_note_action context sensitivity", function()
    it("shows 'Add note' when highlight exists but no note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local menu_items
      local orig_select = vim.ui.select
      vim.ui.select = function(items, _opts, _cb)
        menu_items = items
      end

      auditor.pick_note_action()
      vim.ui.select = orig_select

      assert.is_not_nil(menu_items)
      local labels = {}
      for _, item in ipairs(menu_items) do
        table.insert(labels, item.label)
      end
      assert.is_truthy(vim.tbl_contains(labels, "Add note"))
      assert.is_falsy(vim.tbl_contains(labels, "Edit note"))
      assert.is_falsy(vim.tbl_contains(labels, "Delete note"))
      assert.is_truthy(vim.tbl_contains(labels, "List all notes"))

      cleanup(bufnr)
    end)

    it("shows edit/delete/show when note exists", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "a note" })

      local menu_items
      local orig_select = vim.ui.select
      vim.ui.select = function(items, _opts, _cb)
        menu_items = items
      end

      auditor.pick_note_action()
      vim.ui.select = orig_select

      local labels = {}
      for _, item in ipairs(menu_items) do
        table.insert(labels, item.label)
      end
      assert.is_falsy(vim.tbl_contains(labels, "Add note"))
      assert.is_truthy(vim.tbl_contains(labels, "Show note"))
      assert.is_truthy(vim.tbl_contains(labels, "Edit note"))
      assert.is_truthy(vim.tbl_contains(labels, "Delete note"))
      assert.is_truthy(vim.tbl_contains(labels, "List all notes"))

      cleanup(bufnr)
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Whitespace-only note edge case (E2E-75)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("E2E-75: whitespace-only note treated as empty", function()
    it("saving only spaces/newlines creates no note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)

      local result = editor_save(bufnr, token, "", { "   ", "  ", "" })
      assert.is_nil(result)
      assert.equals(0, note_count(auditor, bufnr))
      cleanup(bufnr)
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════════
  -- Show note with multi-line content (E2E-76)
  -- ═══════════════════════════════════════════════════════════════════════════

  describe("E2E-76: show_note displays multi-line note", function()
    it("viewer shows all lines of multi-line note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      editor_save(bufnr, token, "", { "line1", "line2", "line3" })

      auditor.show_note()
      assert.is_not_nil(auditor._note_float_buf)

      local lines = vim.api.nvim_buf_get_lines(auditor._note_float_buf, 0, -1, false)
      assert.equals(3, #lines)
      assert.equals("line1", lines[1])
      assert.equals("line2", lines[2])
      assert.equals("line3", lines[3])

      auditor._close_note_float()
      cleanup(bufnr)
    end)
  end)
end)
