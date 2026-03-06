-- tests for note sign color: single color, configurable, default gray
--
-- SC1: default sign color is #6B7280
-- SC2: all audit colors produce the same sign hl group
-- SC3: note_sign_color setup option overrides the default
-- SC4: sign color survives DB round-trip
-- SC5: sign color survives mode transitions
-- SC6: note_sign_hl returns AuditorNoteSign for any input
-- SC7: note_sign_hl returns AuditorNoteSign for nil/empty
-- SC8: sign color correct after edit_note
-- SC9: sign color correct after delete + re-add
-- SC10: custom colors still get single sign hl
-- SC11: multiple notes same line all have same sign hl
-- SC12: gradient color note gets same sign hl as solid
-- SC13: sign hl persists after undo + re-mark + re-note
-- SC14: :wq saves note and closes float (not Neovim)
-- SC15: :w saves note and keeps float open

describe("notes sign color", function()
  local auditor, hl, db

  local function reset_modules()
    for k in pairs(package.loaded) do
      if k:match("^auditor") then
        package.loaded[k] = nil
      end
    end
  end

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    hl = require("auditor.highlights")
    db = require("auditor.db")
  end)

  after_each(function()
    -- Clean up float if left open
    if auditor._note_float_buf and vim.api.nvim_buf_is_valid(auditor._note_float_buf) then
      vim.bo[auditor._note_float_buf].modified = false
    end
    auditor._close_note_float()
    if auditor._audit_mode then
      pcall(auditor.exit_audit_mode)
    end
  end)

  local function setup_default()
    local tmp = vim.fn.tempname() .. ".db"
    auditor.setup({ db_path = tmp, keymaps = false })
    auditor._note_input_override = true
    return tmp
  end

  local function setup_custom_sign_color(color)
    local tmp = vim.fn.tempname() .. ".db"
    auditor.setup({ db_path = tmp, keymaps = false, note_sign_color = color })
    auditor._note_input_override = true
    return tmp
  end

  local function setup_buf(lines, row, col)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, vim.fn.tempname() .. ".lua")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_set_current_buf(bufnr)
    auditor.enter_audit_mode()
    if row then
      vim.api.nvim_win_set_cursor(0, { row, col or 0 })
    end
    return bufnr
  end

  local function stub_input(text)
    local orig = vim.ui.input
    vim.ui.input = function(_, cb)
      cb(text)
    end
    return function()
      vim.ui.input = orig
    end
  end

  local function note_extmarks(bufnr)
    return vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
  end

  local function cleanup(bufnr)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end

  -- ── SC1: default sign color ──────────────────────────────────────────
  describe("SC1: default sign color", function()
    it("AuditorNoteSign uses #6B7280 by default", function()
      setup_default()
      local info = vim.api.nvim_get_hl(0, { name = "AuditorNoteSign" })
      -- fg is stored as integer; #6B7280 = 0x6B7280 = 7041664
      assert.equals(0x6B7280, info.fg)
    end)
  end)

  -- ── SC2: all audit colors produce same sign hl ───────────────────────
  describe("SC2: all audit colors produce same sign hl", function()
    it("red, blue, half all get AuditorNoteSign", function()
      setup_default()
      local bufnr = setup_buf({ "hello world foo" }, 1, 0)

      auditor.highlight_cword_buffer("red")
      local ri = stub_input("note1")
      auditor.add_note()
      ri()

      vim.api.nvim_win_set_cursor(0, { 1, 6 })
      auditor.highlight_cword_buffer("blue")
      ri = stub_input("note2")
      auditor.add_note()
      ri()

      local marks = note_extmarks(bufnr)
      assert.is_true(#marks >= 2)
      for _, m in ipairs(marks) do
        assert.equals("AuditorNoteSign", m[4].sign_hl_group)
      end

      cleanup(bufnr)
    end)
  end)

  -- ── SC3: custom sign color ───────────────────────────────────────────
  describe("SC3: note_sign_color overrides default", function()
    it("custom color applied to AuditorNoteSign", function()
      setup_custom_sign_color("#FF00FF")
      local info = vim.api.nvim_get_hl(0, { name = "AuditorNoteSign" })
      assert.equals(0xFF00FF, info.fg)
    end)

    it("sign extmark uses the custom color group", function()
      setup_custom_sign_color("#AABBCC")
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input("custom color note")
      auditor.add_note()
      ri()

      local marks = note_extmarks(bufnr)
      assert.equals("AuditorNoteSign", marks[1][4].sign_hl_group)
      local info = vim.api.nvim_get_hl(0, { name = "AuditorNoteSign" })
      assert.equals(0xAABBCC, info.fg)

      cleanup(bufnr)
    end)
  end)

  -- ── SC4: sign color survives DB round-trip ───────────────────────────
  describe("SC4: sign color survives DB round-trip", function()
    it("sign hl is AuditorNoteSign after save/exit/enter", function()
      setup_default()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input("persist me")
      auditor.add_note()
      ri()

      auditor.audit()
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      local marks = note_extmarks(bufnr)
      assert.is_true(#marks >= 1)
      assert.equals("AuditorNoteSign", marks[1][4].sign_hl_group)

      cleanup(bufnr)
    end)
  end)

  -- ── SC5: sign color survives mode transitions ───────────────────────
  describe("SC5: sign color survives mode transitions", function()
    it("exit/enter cycle preserves sign hl", function()
      setup_default()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input("durable")
      auditor.add_note()
      ri()

      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      local marks = note_extmarks(bufnr)
      assert.is_true(#marks >= 1)
      assert.equals("AuditorNoteSign", marks[1][4].sign_hl_group)

      cleanup(bufnr)
    end)

    it("toggle twice preserves sign hl", function()
      setup_default()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input("toggle note")
      auditor.add_note()
      ri()

      auditor.toggle_audit_mode()
      auditor.toggle_audit_mode()

      local marks = note_extmarks(bufnr)
      assert.is_true(#marks >= 1)
      assert.equals("AuditorNoteSign", marks[1][4].sign_hl_group)

      cleanup(bufnr)
    end)
  end)

  -- ── SC6: note_sign_hl returns AuditorNoteSign for any input ─────────
  describe("SC6: note_sign_hl returns AuditorNoteSign for any input", function()
    it("always returns AuditorNoteSign", function()
      setup_default()
      assert.equals("AuditorNoteSign", hl.note_sign_hl())
      assert.equals("AuditorNoteSign", hl.note_sign_hl("red"))
      assert.equals("AuditorNoteSign", hl.note_sign_hl("blue"))
      assert.equals("AuditorNoteSign", hl.note_sign_hl("half"))
      assert.equals("AuditorNoteSign", hl.note_sign_hl("nonexistent"))
      assert.equals("AuditorNoteSign", hl.note_sign_hl(""))
    end)
  end)

  -- ── SC7: note_sign_hl returns AuditorNoteSign for nil/empty ─────────
  describe("SC7: note_sign_hl edge cases", function()
    it("nil argument", function()
      setup_default()
      assert.equals("AuditorNoteSign", hl.note_sign_hl(nil))
    end)
  end)

  -- ── SC8: sign correct after edit_note ────────────────────────────────
  describe("SC8: sign correct after edit_note", function()
    it("editing note preserves AuditorNoteSign", function()
      setup_default()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input("v1")
      auditor.add_note()
      ri()

      ri = stub_input("v2")
      auditor.edit_note()
      ri()

      local marks = note_extmarks(bufnr)
      assert.is_true(#marks >= 1)
      assert.equals("AuditorNoteSign", marks[1][4].sign_hl_group)

      cleanup(bufnr)
    end)
  end)

  -- ── SC9: sign after delete + re-add ──────────────────────────────────
  describe("SC9: sign after delete + re-add", function()
    it("re-added note gets AuditorNoteSign", function()
      setup_default()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local ri = stub_input("first")
      auditor.add_note()
      ri()

      auditor.delete_note()
      local marks = note_extmarks(bufnr)
      assert.equals(0, #marks)

      ri = stub_input("second")
      auditor.add_note()
      ri()

      marks = note_extmarks(bufnr)
      assert.is_true(#marks >= 1)
      assert.equals("AuditorNoteSign", marks[1][4].sign_hl_group)

      cleanup(bufnr)
    end)
  end)

  -- ── SC10: custom colors still get single sign hl ─────────────────────
  describe("SC10: custom colors with single sign", function()
    it("custom solid and gradient colors use AuditorNoteSign", function()
      reset_modules()
      local tmp = vim.fn.tempname() .. ".db"
      auditor = require("auditor")
      auditor.setup({
        db_path = tmp,
        keymaps = false,
        colors = {
          { name = "green", label = "Green", hl = { bg = "#00CC00", fg = "#FFFFFF" } },
          { name = "warm", label = "Warm", gradient = { "#FF0000", "#FFFF00" } },
        },
      })
      auditor._note_input_override = true
      hl = require("auditor.highlights")

      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("green")
      local ri = stub_input("green note")
      auditor.add_note()
      ri()

      local marks = note_extmarks(bufnr)
      assert.equals("AuditorNoteSign", marks[1][4].sign_hl_group)

      cleanup(bufnr)
    end)
  end)

  -- ── SC11: multiple notes same line all have same sign hl ─────────────
  describe("SC11: multiple notes same line same sign", function()
    it("three notes on one line all get AuditorNoteSign", function()
      setup_default()
      local bufnr = setup_buf({ "alpha bravo charlie" }, 1, 0)

      auditor.highlight_cword_buffer("red")
      local ri = stub_input("n1")
      auditor.add_note()
      ri()

      vim.api.nvim_win_set_cursor(0, { 1, 6 })
      auditor.highlight_cword_buffer("blue")
      ri = stub_input("n2")
      auditor.add_note()
      ri()

      vim.api.nvim_win_set_cursor(0, { 1, 12 })
      auditor.highlight_cword_buffer("red")
      ri = stub_input("n3")
      auditor.add_note()
      ri()

      local marks = note_extmarks(bufnr)
      assert.equals(3, #marks)
      for _, m in ipairs(marks) do
        assert.equals("AuditorNoteSign", m[4].sign_hl_group)
      end

      cleanup(bufnr)
    end)
  end)

  -- ── SC12: gradient note sign same as solid ───────────────────────────
  describe("SC12: gradient note sign same as solid", function()
    it("half-color note gets AuditorNoteSign", function()
      setup_default()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("half")
      local ri = stub_input("gradient note")
      auditor.add_note()
      ri()

      local marks = note_extmarks(bufnr)
      assert.equals("AuditorNoteSign", marks[1][4].sign_hl_group)

      cleanup(bufnr)
    end)
  end)

  -- ── SC13: sign after undo + re-mark + re-note ───────────────────────
  describe("SC13: sign after undo + re-mark + re-note", function()
    it("full cycle preserves AuditorNoteSign", function()
      setup_default()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input("original")
      auditor.add_note()
      ri()

      auditor.undo_at_cursor()

      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("blue")
      ri = stub_input("new note")
      auditor.add_note()
      ri()

      local marks = note_extmarks(bufnr)
      assert.is_true(#marks >= 1)
      assert.equals("AuditorNoteSign", marks[1][4].sign_hl_group)

      cleanup(bufnr)
    end)
  end)

  -- ── SC14: :wq saves note and closes float ───────────────────────────
  describe("SC14: :wq saves note and closes float", function()
    it(":wq does not quit Neovim", function()
      setup_default()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local token = auditor._cword_token(bufnr)
      local extmarks = vim.api.nvim_buf_get_extmarks(
        bufnr, hl.ns, { token.line, token.col_start }, { token.line, token.col_end }, { details = true }
      )
      local target_id
      for _, m in ipairs(extmarks) do
        if m[2] == token.line and m[3] == token.col_start and m[4].end_col == token.col_end then
          target_id = m[1]
          break
        end
      end

      auditor._open_note_editor(bufnr, target_id, token, "")
      assert.is_not_nil(auditor._note_float_win)
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "wq note" })
      vim.api.nvim_set_current_win(auditor._note_float_win)

      local ok = pcall(vim.cmd, "wq")
      assert.is_true(ok)
      assert.equals("wq note", auditor._notes[bufnr][target_id])
      -- Float should be closed but Neovim still running
      assert.is_true(auditor._note_float_win == nil or not vim.api.nvim_win_is_valid(auditor._note_float_win))

      cleanup(bufnr)
    end)
  end)

  -- ── SC15: :w saves but keeps float open ─────────────────────────────
  describe("SC15: :w saves but keeps float open", function()
    it(":w persists note without closing editor", function()
      setup_default()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local token = auditor._cword_token(bufnr)
      local extmarks = vim.api.nvim_buf_get_extmarks(
        bufnr, hl.ns, { token.line, token.col_start }, { token.line, token.col_end }, { details = true }
      )
      local target_id
      for _, m in ipairs(extmarks) do
        if m[2] == token.line and m[3] == token.col_start and m[4].end_col == token.col_end then
          target_id = m[1]
          break
        end
      end

      auditor._open_note_editor(bufnr, target_id, token, "")
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "just :w" })
      vim.api.nvim_set_current_win(auditor._note_float_win)

      local ok = pcall(vim.cmd, "write")
      assert.is_true(ok)
      assert.equals("just :w", auditor._notes[bufnr][target_id])
      -- Float should still be open
      assert.is_not_nil(auditor._note_float_win)
      assert.is_true(vim.api.nvim_win_is_valid(auditor._note_float_win))

      -- Can do :w again (not once-only)
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "updated via :w" })
      ok = pcall(vim.cmd, "write")
      assert.is_true(ok)
      assert.equals("updated via :w", auditor._notes[bufnr][target_id])

      auditor._close_note_float()
      cleanup(bufnr)
    end)
  end)

  -- ── SC16: sign_text is configurable icon ────────────────────────────
  describe("SC16: sign_text uses configured icon", function()
    it("default icon is diamond", function()
      setup_default()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input("icon test")
      auditor.add_note()
      ri()

      local marks = note_extmarks(bufnr)
      -- Neovim pads sign_text to 2 cells
      assert.is_true(marks[1][4].sign_text:find("\xe2\x97\x86") ~= nil)

      cleanup(bufnr)
    end)

    it("custom icon is used", function()
      reset_modules()
      local tmp = vim.fn.tempname() .. ".db"
      auditor = require("auditor")
      auditor.setup({ db_path = tmp, keymaps = false, note_sign_icon = "N" })
      auditor._note_input_override = true
      hl = require("auditor.highlights")

      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input("custom icon")
      auditor.add_note()
      ri()

      local marks = note_extmarks(bufnr)
      assert.equals("N ", marks[1][4].sign_text)

      cleanup(bufnr)
    end)

    it("empty string disables sign", function()
      reset_modules()
      local tmp = vim.fn.tempname() .. ".db"
      auditor = require("auditor")
      auditor.setup({ db_path = tmp, keymaps = false, note_sign_icon = "" })
      auditor._note_input_override = true
      hl = require("auditor.highlights")

      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input("no icon")
      auditor.add_note()
      ri()

      local marks = note_extmarks(bufnr)
      assert.is_nil(marks[1][4].sign_text)

      cleanup(bufnr)
    end)
  end)

  -- ── SC17: sign color with various hex values ────────────────────────
  describe("SC17: sign color accepts various hex values", function()
    local test_colors = {
      { hex = "#000000", int = 0x000000 },
      { hex = "#FFFFFF", int = 0xFFFFFF },
      { hex = "#123456", int = 0x123456 },
      { hex = "#ABCDEF", int = 0xABCDEF },
    }

    for _, tc in ipairs(test_colors) do
      it("accepts " .. tc.hex, function()
        setup_custom_sign_color(tc.hex)
        local info = vim.api.nvim_get_hl(0, { name = "AuditorNoteSign" })
        assert.equals(tc.int, info.fg)
      end)
    end
  end)
end)
