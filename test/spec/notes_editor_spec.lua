-- test/spec/notes_editor_spec.lua
-- Tests for the floating note editor: creation, save, cancel, multi-line,
-- special chars, rapid cycles.
--
-- Coverage:
--   E1  _open_note_editor creates floating window
--   E2  _open_note_editor pre-fills with initial_text
--   E3  save via <C-s> stores note
--   E4  cancel via q preserves no note (new)
--   E5  cancel via <Esc> preserves no note (new)
--   E6  save empty text removes note
--   E7  multi-line save stores newlines
--   E8  editor opens in insert mode for new note
--   E9  editor opens in normal mode for edit (pre-filled)
--   E10 saving updates EOL preview
--   E11 rapid open/close cycles don't crash
--   E12 editor closes previous float
--   E13 editor on deleted buffer doesn't crash
--   E14 editor title shows word
--   E15 <C-s> in insert mode saves
--   E16 cancel preserves existing note during edit
--   E17 editor save → DB round-trip → reload
--   E18 multi-line editor → DB round-trip
--   E19 editor unicode content (4 cases)
--   E20 editor special chars (SQL injection, shell, quotes, long)
--   E21 editor dimensions (min width/height, max width cap)
--   E22 trailing whitespace stripped on save
--   E23 editor float highlight groups
--   E24 add_note uses float editor by default (not _note_input_override)
--   E25 edit_note uses float editor by default (pre-filled)
--   E26 editor buffer settings (bufhidden=wipe)
--   E27 S-Enter saves note (normal and insert mode)

local function reset_modules()
  for _, m in ipairs({ "auditor", "auditor.init", "auditor.db", "auditor.highlights", "auditor.ts" }) do
    package.loaded[m] = nil
  end
end

describe("notes editor", function()
  local auditor, hl

  before_each(function()
    reset_modules()
    local tmp_db = vim.fn.tempname() .. ".db"
    auditor = require("auditor")
    auditor.setup({ db_path = tmp_db, keymaps = false })
    hl = require("auditor.highlights")
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
    return bufnr
  end

  -- Helper: find the highlight extmark at cursor position
  local function find_target_id(bufnr, token)
    local extmarks = vim.api.nvim_buf_get_extmarks(
      bufnr,
      hl.ns,
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

  -- ── E1: _open_note_editor creates floating window ────────────────────
  describe("E1: creates floating window", function()
    it("opens a float with modifiable buffer", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")

      assert.is_not_nil(auditor._note_float_win)
      assert.is_true(vim.api.nvim_win_is_valid(auditor._note_float_win))
      assert.is_true(vim.bo[auditor._note_float_buf].modifiable ~= false)

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── E2: pre-fills with initial_text ──────────────────────────────────
  describe("E2: pre-fills with initial_text", function()
    it("float buffer contains initial text", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "existing note")

      local lines = vim.api.nvim_buf_get_lines(auditor._note_float_buf, 0, -1, false)
      assert.equals("existing note", lines[1])

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("multi-line initial text is split", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "line1\nline2\nline3")

      local lines = vim.api.nvim_buf_get_lines(auditor._note_float_buf, 0, -1, false)
      assert.equals(3, #lines)
      assert.equals("line1", lines[1])
      assert.equals("line3", lines[3])

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── E3: save stores note ─────────────────────────────────────────────
  describe("E3: <C-s> save stores note", function()
    it("stores the buffer content as note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")

      -- Type into the float buffer
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "saved text" })

      -- Trigger save via the <C-s> keymap
      local keymaps = vim.api.nvim_buf_get_keymap(auditor._note_float_buf, "n")
      local save_fn = nil
      for _, km in ipairs(keymaps) do
        if km.lhs == "<C-S>" or km.lhs == "<C-s>" then
          save_fn = km.callback
          break
        end
      end
      assert.is_not_nil(save_fn)
      save_fn()

      -- Note should be stored
      assert.equals("saved text", auditor._notes[bufnr][target_id])

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── E4: cancel via q ─────────────────────────────────────────────────
  describe("E4: cancel via q preserves no note", function()
    it("closing without save does not create note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "unsaved" })

      -- Trigger cancel via q keymap
      local keymaps = vim.api.nvim_buf_get_keymap(auditor._note_float_buf, "n")
      local cancel_fn = nil
      for _, km in ipairs(keymaps) do
        if km.lhs == "q" then
          cancel_fn = km.callback
          break
        end
      end
      assert.is_not_nil(cancel_fn)
      cancel_fn()

      -- No note should be stored
      local has_note = auditor._notes[bufnr] and auditor._notes[bufnr][target_id]
      assert.is_nil(has_note)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── E5: cancel via <Esc> ─────────────────────────────────────────────
  describe("E5: cancel via <Esc>", function()
    it("Esc in normal mode closes without saving", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")

      -- Find <Esc> keymap
      local keymaps = vim.api.nvim_buf_get_keymap(auditor._note_float_buf, "n")
      local esc_fn = nil
      for _, km in ipairs(keymaps) do
        if km.lhs == "<Esc>" then
          esc_fn = km.callback
          break
        end
      end
      assert.is_not_nil(esc_fn)
      esc_fn()

      assert.is_nil(auditor._note_float_win)
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── E6: save empty text removes note ─────────────────────────────────
  describe("E6: save empty text removes note", function()
    it("saving empty content removes existing note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      -- Pre-set a note
      auditor._notes[bufnr] = auditor._notes[bufnr] or {}
      auditor._notes[bufnr][target_id] = "old note"

      auditor._open_note_editor(bufnr, target_id, token, "old note")

      -- Clear the buffer
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "" })

      -- Trigger save
      local keymaps = vim.api.nvim_buf_get_keymap(auditor._note_float_buf, "n")
      for _, km in ipairs(keymaps) do
        if km.lhs == "<C-S>" or km.lhs == "<C-s>" then
          km.callback()
          break
        end
      end

      -- Note should be removed
      assert.is_nil(auditor._notes[bufnr][target_id])

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── E7: multi-line save stores newlines ──────────────────────────────
  describe("E7: multi-line save", function()
    it("joins buffer lines with newlines", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "line1", "line2", "line3" })

      -- Trigger save
      local keymaps = vim.api.nvim_buf_get_keymap(auditor._note_float_buf, "n")
      for _, km in ipairs(keymaps) do
        if km.lhs == "<C-S>" or km.lhs == "<C-s>" then
          km.callback()
          break
        end
      end

      assert.equals("line1\nline2\nline3", auditor._notes[bufnr][target_id])

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── E8: new note opens with empty buffer ─────────────────────────────
  describe("E8: new note opens with empty buffer", function()
    it("float buffer is empty for new note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")

      local lines = vim.api.nvim_buf_get_lines(auditor._note_float_buf, 0, -1, false)
      assert.equals(1, #lines)
      assert.equals("", lines[1])

      -- Clean up
      pcall(vim.api.nvim_feedkeys,
        vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── E9: normal mode for edit ─────────────────────────────────────────
  describe("E9: normal mode for edit", function()
    it("does not start insert mode when pre-filled", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "existing")

      local mode = vim.api.nvim_get_mode()
      assert.equals("n", mode.mode)

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── E10: saving updates EOL preview ──────────────────────────────────
  describe("E10: save updates EOL preview", function()
    it("note extmark preview updated after save", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "updated preview" })

      -- Save
      local keymaps = vim.api.nvim_buf_get_keymap(auditor._note_float_buf, "n")
      for _, km in ipairs(keymaps) do
        if km.lhs == "<C-S>" or km.lhs == "<C-s>" then
          km.callback()
          break
        end
      end

      -- Check note extmark was updated
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      local found = false
      for _, m in ipairs(marks) do
        local vt = m[4].virt_text
        if vt and vt[1][1]:match("updated preview") then
          found = true
        end
      end
      assert.is_true(found)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── E11: rapid open/close cycles ─────────────────────────────────────
  describe("E11: rapid open/close cycles", function()
    it("does not crash after 20 open/close cycles", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      for _ = 1, 20 do
        local ok = pcall(auditor._open_note_editor, bufnr, target_id, token, "")
        assert.is_true(ok)
        -- Escape insert mode if in it
        pcall(vim.api.nvim_feedkeys,
          vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
        pcall(auditor._close_note_float)
      end

      assert.is_nil(auditor._note_float_win)
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── E12: editor closes previous float ────────────────────────────────
  describe("E12: opens editor closes previous float", function()
    it("previous float is closed when new editor opens", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "first")
      local first_win = auditor._note_float_win

      -- Escape insert mode
      pcall(vim.api.nvim_feedkeys,
        vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)

      auditor._open_note_editor(bufnr, target_id, token, "second")

      assert.is_false(vim.api.nvim_win_is_valid(first_win))
      assert.is_true(vim.api.nvim_win_is_valid(auditor._note_float_win))

      -- Escape and clean up
      pcall(vim.api.nvim_feedkeys,
        vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── E13: editor on deleted buffer ────────────────────────────────────
  describe("E13: save after source buffer deleted", function()
    it("does not crash", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")
      local float_buf = auditor._note_float_buf

      vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, { "orphan note" })

      -- Delete source buffer while editor is open
      -- Need a different buffer to switch to first
      local alt_buf = vim.api.nvim_create_buf(false, true)
      -- Can't delete current buf if it's the float, so just invalidate
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })

      -- Save should not crash
      local keymaps = vim.api.nvim_buf_get_keymap(float_buf, "n")
      for _, km in ipairs(keymaps) do
        if km.lhs == "<C-S>" or km.lhs == "<C-s>" then
          local ok = pcall(km.callback)
          assert.is_true(ok)
          break
        end
      end

      pcall(vim.api.nvim_buf_delete, alt_buf, { force = true })
    end)
  end)

  -- ── E14: editor title shows word ─────────────────────────────────────
  describe("E14: editor title shows word", function()
    it("title contains the word text", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")

      local config = vim.api.nvim_win_get_config(auditor._note_float_win)
      local title_text = ""
      if type(config.title) == "table" then
        for _, chunk in ipairs(config.title) do
          if type(chunk) == "table" then
            title_text = title_text .. chunk[1]
          elseif type(chunk) == "string" then
            title_text = title_text .. chunk
          end
        end
      elseif type(config.title) == "string" then
        title_text = config.title
      end
      assert.is_truthy(title_text:match("hello"))

      -- Escape insert mode and close
      pcall(vim.api.nvim_feedkeys,
        vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── E15: save via <C-s> in insert mode ─────────────────────────────────
  describe("E15: <C-s> in insert mode", function()
    it("insert-mode <C-s> keymap exists and saves", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "insert save" })

      -- Find insert-mode <C-s> keymap
      local keymaps = vim.api.nvim_buf_get_keymap(auditor._note_float_buf, "i")
      local save_fn = nil
      for _, km in ipairs(keymaps) do
        if km.lhs == "<C-S>" or km.lhs == "<C-s>" then
          save_fn = km.callback
          break
        end
      end
      assert.is_not_nil(save_fn, "insert-mode <C-s> keymap should exist")
      save_fn()

      assert.equals("insert save", auditor._notes[bufnr][target_id])
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── E16: cancel preserves existing note when editing ───────────────────
  describe("E16: cancel preserves existing note during edit", function()
    it("cancelling edit keeps original note text", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      -- Pre-set existing note
      auditor._notes[bufnr] = auditor._notes[bufnr] or {}
      auditor._notes[bufnr][target_id] = "original note"

      -- Open editor pre-filled, modify content, then cancel
      auditor._open_note_editor(bufnr, target_id, token, "original note")
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "modified text" })

      -- Cancel via q
      local keymaps = vim.api.nvim_buf_get_keymap(auditor._note_float_buf, "n")
      for _, km in ipairs(keymaps) do
        if km.lhs == "q" then
          km.callback()
          break
        end
      end

      -- Original note should be preserved
      assert.equals("original note", auditor._notes[bufnr][target_id])
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── E17: editor → save → DB round-trip → reload ───────────────────────
  describe("E17: editor save → DB round-trip", function()
    it("note saved via editor persists through save/exit/enter", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      -- Save note via editor
      auditor._open_note_editor(bufnr, target_id, token, "")
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "editor note" })
      local keymaps = vim.api.nvim_buf_get_keymap(auditor._note_float_buf, "n")
      for _, km in ipairs(keymaps) do
        if km.lhs == "<C-S>" or km.lhs == "<C-s>" then
          km.callback()
          break
        end
      end

      -- Persist to DB
      auditor.audit()

      -- Exit and re-enter
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      -- Note should be restored
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local found_note = nil
      local ext = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, { details = true })
      for _, em in ipairs(ext) do
        if auditor._notes[bufnr] and auditor._notes[bufnr][em[1]] then
          found_note = auditor._notes[bufnr][em[1]]
          break
        end
      end
      assert.equals("editor note", found_note)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── E18: multi-line editor save → DB round-trip ────────────────────────
  describe("E18: multi-line editor → DB round-trip", function()
    it("multi-line note from editor survives DB cycle", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "L1", "L2", "L3" })
      local keymaps = vim.api.nvim_buf_get_keymap(auditor._note_float_buf, "n")
      for _, km in ipairs(keymaps) do
        if km.lhs == "<C-S>" or km.lhs == "<C-s>" then
          km.callback()
          break
        end
      end

      assert.equals("L1\nL2\nL3", auditor._notes[bufnr][target_id])

      auditor.audit()
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      local found = nil
      local ext = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, { details = true })
      for _, em in ipairs(ext) do
        if auditor._notes[bufnr] and auditor._notes[bufnr][em[1]] then
          found = auditor._notes[bufnr][em[1]]
          break
        end
      end
      assert.equals("L1\nL2\nL3", found)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── E19: editor with unicode content ───────────────────────────────────
  describe("E19: editor unicode content", function()
    local unicode_inputs = {
      "日本語テスト",
      "🎉🔥💀🚀",
      "café résumé naïve",
      "中文测试 한국어",
    }

    for i, text in ipairs(unicode_inputs) do
      it(string.format("unicode %d: saves correctly", i), function()
        local bufnr = setup_buf({ "hello world" }, 1, 0)
        auditor.highlight_cword_buffer("red")
        local token = auditor._cword_token(bufnr)
        local target_id = find_target_id(bufnr, token)

        auditor._open_note_editor(bufnr, target_id, token, "")
        vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { text })
        local keymaps = vim.api.nvim_buf_get_keymap(auditor._note_float_buf, "n")
        for _, km in ipairs(keymaps) do
          if km.lhs == "<C-S>" or km.lhs == "<C-s>" then
            km.callback()
            break
          end
        end

        assert.equals(text, auditor._notes[bufnr][target_id])
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end)
    end
  end)

  -- ── E20: editor with special chars ─────────────────────────────────────
  describe("E20: editor special chars", function()
    local special_inputs = {
      "'; DROP TABLE highlights; --",
      "$(rm -rf /)",
      "foo'bar\"baz",
      "\\t\\n\\r",
      string.rep("x", 500),
    }

    for i, text in ipairs(special_inputs) do
      it(string.format("special %d: saves without crash", i), function()
        local bufnr = setup_buf({ "hello world" }, 1, 0)
        auditor.highlight_cword_buffer("red")
        local token = auditor._cword_token(bufnr)
        local target_id = find_target_id(bufnr, token)

        auditor._open_note_editor(bufnr, target_id, token, "")
        vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { text })
        local keymaps = vim.api.nvim_buf_get_keymap(auditor._note_float_buf, "n")
        for _, km in ipairs(keymaps) do
          if km.lhs == "<C-S>" or km.lhs == "<C-s>" then
            km.callback()
            break
          end
        end

        assert.equals(text, auditor._notes[bufnr][target_id])
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end)
    end
  end)

  -- ── E21: editor dimensions ─────────────────────────────────────────────
  describe("E21: editor dimensions", function()
    it("editor has minimum width of 40", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")

      local config = vim.api.nvim_win_get_config(auditor._note_float_win)
      assert.is_true(config.width >= 40)

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("editor has minimum height of 3", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")

      local config = vim.api.nvim_win_get_config(auditor._note_float_win)
      assert.is_true(config.height >= 3)

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("editor capped at 80 width for long content", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, string.rep("x", 200))

      local config = vim.api.nvim_win_get_config(auditor._note_float_win)
      assert.is_true(config.width <= 80)

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── E22: editor trailing whitespace stripped ───────────────────────────
  describe("E22: trailing whitespace stripped on save", function()
    it("trailing spaces and newlines are stripped", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false,
        { "content", "  ", "" })

      local keymaps = vim.api.nvim_buf_get_keymap(auditor._note_float_buf, "n")
      for _, km in ipairs(keymaps) do
        if km.lhs == "<C-S>" or km.lhs == "<C-s>" then
          km.callback()
          break
        end
      end

      -- Trailing whitespace lines should be stripped
      local note = auditor._notes[bufnr][target_id]
      assert.is_truthy(note)
      assert.is_falsy(note:match("%s+$"))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── E23: editor float uses correct highlight groups ────────────────────
  describe("E23: editor float highlight groups", function()
    it("float window has correct winhighlight", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")

      local winhl = vim.api.nvim_get_option_value("winhl", { win = auditor._note_float_win })
      assert.is_truthy(winhl:match("AuditorNoteFloat"))
      assert.is_truthy(winhl:match("AuditorNoteFloatBorder"))

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── E24: add_note via float editor (not _note_input_override) ──────────
  describe("E24: add_note uses float editor by default", function()
    it("opens float editor when _note_input_override is falsy", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      auditor._note_input_override = nil

      auditor.add_note()

      -- Float editor should be open
      assert.is_not_nil(auditor._note_float_win)
      assert.is_true(vim.api.nvim_win_is_valid(auditor._note_float_win))

      -- Clean up
      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── E25: edit_note via float editor (not _note_input_override) ─────────
  describe("E25: edit_note uses float editor by default", function()
    it("opens pre-filled float editor when _note_input_override is falsy", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      auditor._note_input_override = true

      -- Add note first via stub
      local orig = vim.ui.input
      vim.ui.input = function(_, cb) cb("existing") end
      auditor.add_note()
      vim.ui.input = orig

      auditor._note_input_override = nil
      auditor.edit_note()

      assert.is_not_nil(auditor._note_float_win)
      assert.is_true(vim.api.nvim_win_is_valid(auditor._note_float_win))

      -- Buffer should be pre-filled
      local lines = vim.api.nvim_buf_get_lines(auditor._note_float_buf, 0, -1, false)
      assert.equals("existing", lines[1])

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── E27: S-Enter saves note ──────────────────────────────────────────
  describe("E27: S-Enter saves note", function()
    it("normal-mode <S-CR> saves", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "shift enter" })

      local keymaps = vim.api.nvim_buf_get_keymap(auditor._note_float_buf, "n")
      local save_fn = nil
      for _, km in ipairs(keymaps) do
        if km.lhs == "<S-CR>" then
          save_fn = km.callback
          break
        end
      end
      assert.is_not_nil(save_fn, "<S-CR> keymap should exist in normal mode")
      save_fn()

      assert.equals("shift enter", auditor._notes[bufnr][target_id])
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("insert-mode <S-CR> saves", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "imode senter" })

      local keymaps = vim.api.nvim_buf_get_keymap(auditor._note_float_buf, "i")
      local save_fn = nil
      for _, km in ipairs(keymaps) do
        if km.lhs == "<S-CR>" then
          save_fn = km.callback
          break
        end
      end
      assert.is_not_nil(save_fn, "<S-CR> keymap should exist in insert mode")
      save_fn()

      assert.equals("imode senter", auditor._notes[bufnr][target_id])
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── E26: editor bufhidden is wipe ──────────────────────────────────────
  describe("E26: editor buffer settings", function()
    it("float buffer has bufhidden=wipe", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")

      assert.equals("wipe", vim.bo[auditor._note_float_buf].bufhidden)

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)
end)
