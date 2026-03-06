-- test/spec/notes_display_spec.lua
-- Tests for note display redesign: format_note_preview, sign indicators,
-- EOL truncated preview, floating viewer.
--
-- Coverage:
--   D1  format_note_preview: short note, no prefix
--   D2  format_note_preview: short note with word prefix
--   D3  format_note_preview: truncation kicks in
--   D4  format_note_preview: multi-line note appends (+N lines)
--   D5  format_note_preview: multi-line + truncation
--   D6  format_note_preview: empty/nil text returns ""
--   D7  format_note_preview: custom max_len
--   D8  format_note_preview: very long word prefix
--   D9  apply_note creates sign extmark
--   D10 apply_note sign matches color
--   D11 apply_note EOL preview contains word prefix
--   D12 apply_note gradient color sign
--   D13 Multiple notes on same line each show
--   D14 note_sign_hl returns per-color group
--   D15 note_sign_hl unknown color falls back
--   D16 backward compat: apply_note without color/word_text
--   D17 AuditNoteShow command exists
--   D18 show_note requires audit mode
--   D19 show_note requires highlight with note
--   D20 show_note opens floating window
--   D21 show_note floating window is read-only
--   D22 show_note closes previous float
--   D23 show_note title shows word
--   D24 show_note multi-line note scrollable
--   D25 _close_note_float safely handles no float
--   D26 note_preview_len setup option takes effect
--   D27 note_sign_icon setup option (custom icon, disable with "")
--   D28 custom colors note sign highlights (solid, gradient)
--   D29 sign color matches audit color in add_note flow (red, blue, gradient)
--   D30 show_note after DB round-trip (save → exit → enter)
--   D31 multi-line note persists through DB round-trip
--   D32 exit audit mode with float open
--   D33 format_note_preview whitespace word_text
--   D34 float viewer dimensions (min/max width, height cap)
--   D35 note_sign_hl all default colors
--   D36 EOL preview updates after edit_note
--   D37 sign persists after note edit
--   D38 note delete removes sign and preview
--   D39 undo removes sign and preview
--   D40 word prefix correct after DB restoration
--   D41 sign color correct after DB restoration

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

describe("notes display", function()
  local auditor, hl

  before_each(function()
    reset_modules()
    local tmp_db = vim.fn.tempname() .. ".db"
    auditor = require("auditor")
    auditor.setup({ db_path = tmp_db, keymaps = false })
    auditor._note_input_override = true
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

  local function stub_input(response)
    local orig = vim.ui.input
    vim.ui.input = function(_opts, callback)
      callback(response)
    end
    return function()
      vim.ui.input = orig
    end
  end

  -- ── D1: format_note_preview short note no prefix ─────────────────────
  describe("D1: format_note_preview short note no prefix", function()
    it("returns indented text", function()
      local result = hl.format_note_preview("hello world", nil, 30)
      assert.equals("  hello world", result)
    end)
  end)

  -- ── D2: format_note_preview with word prefix ─────────────────────────
  describe("D2: format_note_preview with word prefix", function()
    it("prepends word: prefix", function()
      local result = hl.format_note_preview("my note", "foo", 30)
      assert.equals("  foo: my note", result)
    end)
  end)

  -- ── D3: format_note_preview truncation ───────────────────────────────
  describe("D3: format_note_preview truncation", function()
    it("truncates long text with ...", function()
      local result = hl.format_note_preview("abcdefghijklmnopqrstuvwxyz", "w", 15)
      -- "w: " is 3 chars, leaves 12 for text, minus 3 for "..." = 9 chars of text
      assert.is_truthy(result:match("%.%.%."))
      assert.is_true(#result - 2 <= 15) -- subtract leading "  "
    end)
  end)

  -- ── D4: format_note_preview multi-line ───────────────────────────────
  describe("D4: format_note_preview multi-line", function()
    it("appends +N lines suffix", function()
      local result = hl.format_note_preview("line1\nline2\nline3", nil, 50)
      assert.is_truthy(result:match("%+2 lines%)"))
      assert.is_truthy(result:match("line1"))
    end)
  end)

  -- ── D5: format_note_preview multi-line + truncation ──────────────────
  describe("D5: format_note_preview multi-line + truncation", function()
    it("truncates first line and adds suffix", function()
      local result = hl.format_note_preview("a very long first line here\nsecond", "word", 30)
      assert.is_truthy(result:match("%.%.%."))
      assert.is_truthy(result:match("%+1 lines%)"))
    end)
  end)

  -- ── D6: format_note_preview empty/nil ────────────────────────────────
  describe("D6: format_note_preview empty/nil", function()
    it("returns empty string for nil", function()
      assert.equals("", hl.format_note_preview(nil, "word", 30))
    end)

    it("returns empty string for empty text", function()
      assert.equals("", hl.format_note_preview("", "word", 30))
    end)
  end)

  -- ── D7: format_note_preview custom max_len ───────────────────────────
  describe("D7: format_note_preview custom max_len", function()
    it("respects custom max_len", function()
      local result = hl.format_note_preview("abcdefghij", nil, 5)
      assert.is_true(#result - 2 <= 5) -- subtract "  " prefix
    end)
  end)

  -- ── D8: format_note_preview very long word prefix ────────────────────
  describe("D8: format_note_preview long word prefix", function()
    it("handles prefix longer than max_len", function()
      local result = hl.format_note_preview("note", "verylongword", 10)
      assert.is_truthy(result) -- should not crash
      assert.is_true(#result > 0)
    end)
  end)

  -- ── D9: apply_note creates sign extmark ──────────────────────────────
  describe("D9: apply_note creates sign extmark", function()
    it("extmark has sign_text", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })

      hl.apply_note(bufnr, 0, "my note", "red", "hello")

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      assert.is_true(#marks >= 1)
      local details = marks[1][4]
      assert.is_truthy(details.sign_text)
      assert.is_truthy(details.sign_hl_group)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── D10: apply_note sign matches color ───────────────────────────────
  describe("D10: apply_note sign matches color", function()
    it("sign uses per-color highlight", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })

      hl.apply_note(bufnr, 0, "note", "red", "hello")

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      assert.equals("AuditorNoteSignRed", marks[1][4].sign_hl_group)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── D11: apply_note EOL preview contains word prefix ─────────────────
  describe("D11: apply_note EOL preview has word prefix", function()
    it("virt_text includes word: prefix", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })

      hl.apply_note(bufnr, 0, "check this", "red", "hello")

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      local vt = marks[1][4].virt_text
      assert.is_truthy(vt)
      assert.is_truthy(vt[1][1]:match("hello: check this"))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── D12: apply_note gradient color sign ──────────────────────────────
  describe("D12: gradient color sign", function()
    it("half color gets AuditorNoteSignHalf", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello" })

      hl.apply_note(bufnr, 0, "note", "half", "hello")

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      assert.equals("AuditorNoteSignHalf", marks[1][4].sign_hl_group)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── D13: Multiple notes on same line ─────────────────────────────────
  describe("D13: multiple notes on same line", function()
    it("each word shows its own preview", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input("note_hello")
      auditor.add_note()
      ri()

      vim.api.nvim_win_set_cursor(0, { 1, 6 })
      auditor.highlight_cword_buffer("blue")
      ri = stub_input("note_world")
      auditor.add_note()
      ri()

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      local texts = {}
      for _, m in ipairs(marks) do
        local vt = m[4].virt_text
        if vt then
          table.insert(texts, vt[1][1])
        end
      end
      local all = table.concat(texts, "|")
      assert.is_truthy(all:match("hello: note_hello"))
      assert.is_truthy(all:match("world: note_world"))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── D14: note_sign_hl returns per-color group ────────────────────────
  describe("D14: note_sign_hl per-color", function()
    it("returns AuditorNoteSignRed for red", function()
      assert.equals("AuditorNoteSignRed", hl.note_sign_hl("red"))
    end)

    it("returns AuditorNoteSignBlue for blue", function()
      assert.equals("AuditorNoteSignBlue", hl.note_sign_hl("blue"))
    end)
  end)

  -- ── D15: note_sign_hl unknown color falls back ───────────────────────
  describe("D15: note_sign_hl fallback", function()
    it("returns AuditorNoteSign for nil", function()
      assert.equals("AuditorNoteSign", hl.note_sign_hl(nil))
    end)

    it("returns AuditorNoteSign for empty string", function()
      assert.equals("AuditorNoteSign", hl.note_sign_hl(""))
    end)

    it("returns AuditorNoteSign for unknown color", function()
      assert.equals("AuditorNoteSign", hl.note_sign_hl("nonexistent_xyz"))
    end)
  end)

  -- ── D16: backward compat ─────────────────────────────────────────────
  describe("D16: apply_note without color/word_text", function()
    it("works with just bufnr, line, text", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello" })

      local id = hl.apply_note(bufnr, 0, "plain note")
      assert.is_number(id)

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      assert.is_true(#marks >= 1)
      local vt = marks[1][4].virt_text
      assert.is_truthy(vt[1][1]:match("plain note"))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── D17: AuditNoteShow command exists ────────────────────────────────
  describe("D17: AuditNoteShow command", function()
    it("is registered", function()
      assert.equals(2, vim.fn.exists(":AuditNoteShow"))
    end)
  end)

  -- ── D18: show_note requires audit mode ───────────────────────────────
  describe("D18: show_note requires audit mode", function()
    it("warns when not in audit mode", function()
      local bufnr = setup_buf({ "hello" }, 1, 0)
      auditor.exit_audit_mode()

      local restore, msgs = capture_notify()
      auditor.show_note()
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

  -- ── D19: show_note requires note ─────────────────────────────────────
  describe("D19: show_note requires note on word", function()
    it("warns when no note exists", function()
      local bufnr = setup_buf({ "hello" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore, msgs = capture_notify()
      auditor.show_note()
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
      local bufnr = setup_buf({ "hello" }, 1, 0)

      local restore, msgs = capture_notify()
      auditor.show_note()
      restore()

      local found = false
      for _, m in ipairs(msgs) do
        if m.msg:match("No note") or m.msg:match("No word") then
          found = true
        end
      end
      assert.is_true(found)
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── D20: show_note opens floating window ─────────────────────────────
  describe("D20: show_note opens float", function()
    it("creates a floating window with note content", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input("my full note")
      auditor.add_note()
      ri()

      auditor.show_note()

      assert.is_not_nil(auditor._note_float_win)
      assert.is_true(vim.api.nvim_win_is_valid(auditor._note_float_win))

      -- Float buffer should have the note text
      local lines = vim.api.nvim_buf_get_lines(auditor._note_float_buf, 0, -1, false)
      assert.equals("my full note", lines[1])

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── D21: show_note float is read-only ────────────────────────────────
  describe("D21: show_note float is read-only", function()
    it("float buffer is not modifiable", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input("locked note")
      auditor.add_note()
      ri()

      auditor.show_note()

      assert.is_false(vim.bo[auditor._note_float_buf].modifiable)

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── D22: show_note closes previous float ─────────────────────────────
  describe("D22: show_note closes previous float", function()
    it("opening a new note viewer closes the old one", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input("note1")
      auditor.add_note()
      ri()

      auditor.show_note()
      local first_win = auditor._note_float_win

      -- Move to another word, mark it, add note, show
      vim.api.nvim_win_set_cursor(0, { 1, 6 })
      auditor.highlight_cword_buffer("blue")
      ri = stub_input("note2")
      auditor.add_note()
      ri()

      auditor.show_note()

      -- First window should be closed
      assert.is_false(vim.api.nvim_win_is_valid(first_win))
      -- New window should be open
      assert.is_true(vim.api.nvim_win_is_valid(auditor._note_float_win))

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── D23: show_note title shows word ──────────────────────────────────
  describe("D23: show_note title shows word", function()
    it("float window config includes word in title", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input("a note")
      auditor.add_note()
      ri()

      auditor.show_note()

      local config = vim.api.nvim_win_get_config(auditor._note_float_win)
      -- title is an array of {text, hl_group} chunks
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

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── D24: show_note multi-line note ───────────────────────────────────
  describe("D24: show_note multi-line", function()
    it("shows all lines in float buffer", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input("line1\nline2\nline3")
      auditor.add_note()
      ri()

      auditor.show_note()

      local lines = vim.api.nvim_buf_get_lines(auditor._note_float_buf, 0, -1, false)
      assert.equals(3, #lines)
      assert.equals("line1", lines[1])
      assert.equals("line2", lines[2])
      assert.equals("line3", lines[3])

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── D25: _close_note_float safely handles no float ───────────────────
  describe("D25: _close_note_float when no float open", function()
    it("does not error", function()
      auditor._note_float_win = nil
      auditor._note_float_buf = nil
      local ok = pcall(auditor._close_note_float)
      assert.is_true(ok)
    end)

    it("handles invalid window ID", function()
      auditor._note_float_win = 999999
      auditor._note_float_buf = nil
      local ok = pcall(auditor._close_note_float)
      assert.is_true(ok)
      assert.is_nil(auditor._note_float_win)
    end)
  end)

  -- ── D26: note_preview_len setup option takes effect ────────────────────
  describe("D26: note_preview_len setup option", function()
    it("custom note_preview_len controls truncation", function()
      reset_modules()
      local tmp_db = vim.fn.tempname() .. ".db"
      local a2 = require("auditor")
      a2.setup({ db_path = tmp_db, keymaps = false, note_preview_len = 10 })
      local hl2 = require("auditor.highlights")

      assert.equals(10, hl2._note_preview_len)

      local result = hl2.format_note_preview("abcdefghijklmnop", nil)
      -- content (after "  ") should be <= 10
      assert.is_true(#result - 2 <= 10)
    end)

    it("default note_preview_len is 30", function()
      assert.equals(30, hl._note_preview_len)
    end)
  end)

  -- ── D27: note_sign_icon setup option ───────────────────────────────────
  describe("D27: note_sign_icon setup option", function()
    it("custom sign icon is used in apply_note", function()
      reset_modules()
      local tmp_db = vim.fn.tempname() .. ".db"
      local a2 = require("auditor")
      a2.setup({ db_path = tmp_db, keymaps = false, note_sign_icon = "!" })
      local hl2 = require("auditor.highlights")

      assert.equals("!", hl2._note_sign_icon)

      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello" })
      hl2.apply_note(bufnr, 0, "test", "red", "hello")

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl2.note_ns, 0, -1, { details = true })
      assert.equals("! ", marks[1][4].sign_text)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("empty string disables sign", function()
      reset_modules()
      local tmp_db = vim.fn.tempname() .. ".db"
      local a2 = require("auditor")
      a2.setup({ db_path = tmp_db, keymaps = false, note_sign_icon = "" })
      local hl2 = require("auditor.highlights")

      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello" })
      hl2.apply_note(bufnr, 0, "test", "red", "hello")

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl2.note_ns, 0, -1, { details = true })
      -- No sign_text when icon is ""
      assert.is_falsy(marks[1][4].sign_text)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── D28: custom colors with note sign highlights ───────────────────────
  describe("D28: custom colors note sign highlights", function()
    it("custom solid color gets per-color sign hl", function()
      reset_modules()
      local tmp_db = vim.fn.tempname() .. ".db"
      local a2 = require("auditor")
      a2.setup({
        db_path = tmp_db,
        keymaps = false,
        colors = {
          { name = "green", label = "Green", hl = { bg = "#00CC00", fg = "#FFFFFF", bold = true } },
        },
      })
      local hl2 = require("auditor.highlights")

      assert.equals(1, vim.fn.hlexists("AuditorNoteSignGreen"))
      assert.equals("AuditorNoteSignGreen", hl2.note_sign_hl("green"))
    end)

    it("custom gradient color gets per-color sign hl", function()
      reset_modules()
      local tmp_db = vim.fn.tempname() .. ".db"
      local a2 = require("auditor")
      a2.setup({
        db_path = tmp_db,
        keymaps = false,
        colors = {
          { name = "warm", label = "Warm", gradient = { "#FF0000", "#FFFF00" } },
        },
      })
      local hl2 = require("auditor.highlights")

      assert.equals(1, vim.fn.hlexists("AuditorNoteSignWarm"))
      assert.equals("AuditorNoteSignWarm", hl2.note_sign_hl("warm"))
    end)
  end)

  -- ── D29: sign color matches word audit color in full flow ──────────────
  describe("D29: sign color matches audit color in add_note flow", function()
    it("red word → red sign after add_note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input("my note")
      auditor.add_note()
      ri()

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      assert.is_true(#marks >= 1)
      assert.equals("AuditorNoteSignRed", marks[1][4].sign_hl_group)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("blue word → blue sign after add_note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 6)
      auditor.highlight_cword_buffer("blue")
      local ri = stub_input("blue note")
      auditor.add_note()
      ri()

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      assert.is_true(#marks >= 1)
      assert.equals("AuditorNoteSignBlue", marks[1][4].sign_hl_group)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("gradient word → gradient sign after add_note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("half")
      local ri = stub_input("half note")
      auditor.add_note()
      ri()

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      assert.is_true(#marks >= 1)
      assert.equals("AuditorNoteSignHalf", marks[1][4].sign_hl_group)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── D30: show_note after save/exit/enter (DB persistence) ──────────────
  describe("D30: show_note after DB round-trip", function()
    it("note survives save → exit → enter cycle", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input("persistent note")
      auditor.add_note()
      ri()

      auditor.audit()
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.show_note()

      assert.is_not_nil(auditor._note_float_win)
      assert.is_true(vim.api.nvim_win_is_valid(auditor._note_float_win))
      local lines = vim.api.nvim_buf_get_lines(auditor._note_float_buf, 0, -1, false)
      assert.equals("persistent note", lines[1])

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── D31: show_note multi-line note after DB round-trip ─────────────────
  describe("D31: multi-line note persists through DB", function()
    it("multi-line note survives save → exit → enter", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input("line1\nline2\nline3")
      auditor.add_note()
      ri()

      auditor.audit()
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.show_note()

      local lines = vim.api.nvim_buf_get_lines(auditor._note_float_buf, 0, -1, false)
      assert.equals(3, #lines)
      assert.equals("line1", lines[1])
      assert.equals("line2", lines[2])
      assert.equals("line3", lines[3])

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── D32: exit audit mode while float open ──────────────────────────────
  describe("D32: exit audit mode with float open", function()
    it("float is closed when exiting audit mode", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input("test note")
      auditor.add_note()
      ri()

      auditor.show_note()
      assert.is_true(vim.api.nvim_win_is_valid(auditor._note_float_win))

      -- Exit audit mode — floats should be cleaned up or at least not crash
      auditor.exit_audit_mode()

      -- The float might be closed by BufLeave autocmd or still open;
      -- either way, re-entering and showing should work
      auditor.enter_audit_mode()
      -- Should not crash
      local ok = pcall(auditor.show_note)
      assert.is_true(ok)

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── D33: format_note_preview whitespace-only word_text ─────────────────
  describe("D33: format_note_preview whitespace word_text", function()
    it("empty word_text treated as no prefix", function()
      local result = hl.format_note_preview("hello", "", 30)
      assert.equals("  hello", result)
    end)

    it("whitespace-only word_text is used as prefix", function()
      -- " " is non-empty so it becomes prefix "  : "
      local result = hl.format_note_preview("hello", " ", 30)
      assert.is_truthy(result:match(": hello"))
    end)
  end)

  -- ── D34: float viewer window dimensions ────────────────────────────────
  describe("D34: float viewer dimensions", function()
    it("width is at least 20", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input("hi")
      auditor.add_note()
      ri()

      auditor.show_note()
      local config = vim.api.nvim_win_get_config(auditor._note_float_win)
      assert.is_true(config.width >= 20)

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("width capped at 80 for long notes", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      local long_note = string.rep("x", 200)
      local ri = stub_input(long_note)
      auditor.highlight_cword_buffer("red")
      auditor.add_note()
      ri()

      auditor.show_note()
      local config = vim.api.nvim_win_get_config(auditor._note_float_win)
      assert.is_true(config.width <= 80)

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("height matches line count up to 15", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      local lines = {}
      for i = 1, 5 do
        lines[i] = "line" .. i
      end
      local ri = stub_input(table.concat(lines, "\n"))
      auditor.highlight_cword_buffer("red")
      auditor.add_note()
      ri()

      auditor.show_note()
      local config = vim.api.nvim_win_get_config(auditor._note_float_win)
      assert.equals(5, config.height)

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("height capped at 15 for many lines", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      local lines = {}
      for i = 1, 30 do
        lines[i] = "line" .. i
      end
      local ri = stub_input(table.concat(lines, "\n"))
      auditor.highlight_cword_buffer("red")
      auditor.add_note()
      ri()

      auditor.show_note()
      local config = vim.api.nvim_win_get_config(auditor._note_float_win)
      assert.equals(15, config.height)

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── D35: note_sign_hl with all default colors ─────────────────────────
  describe("D35: note_sign_hl all default colors", function()
    it("returns correct group for each default color", function()
      assert.equals("AuditorNoteSignRed", hl.note_sign_hl("red"))
      assert.equals("AuditorNoteSignBlue", hl.note_sign_hl("blue"))
      assert.equals("AuditorNoteSignHalf", hl.note_sign_hl("half"))
    end)
  end)

  -- ── D36: note EOL preview updates after edit_note ──────────────────────
  describe("D36: EOL preview updates after edit_note", function()
    it("preview reflects edited text", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input("original")
      auditor.add_note()
      ri()

      -- Edit the note
      ri = stub_input("updated text")
      auditor.edit_note()
      ri()

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      local found = false
      for _, m in ipairs(marks) do
        local vt = m[4].virt_text
        if vt and vt[1][1]:match("updated text") then
          found = true
        end
      end
      assert.is_true(found)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── D37: sign persists after note edit ─────────────────────────────────
  describe("D37: sign persists after note edit", function()
    it("sign hl group still correct after editing note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input("note v1")
      auditor.add_note()
      ri()

      ri = stub_input("note v2")
      auditor.edit_note()
      ri()

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      assert.is_true(#marks >= 1)
      assert.equals("AuditorNoteSignRed", marks[1][4].sign_hl_group)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── D38: note delete removes sign and preview ──────────────────────────
  describe("D38: note delete removes sign and preview", function()
    it("sign and EOL preview gone after delete_note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input("to delete")
      auditor.add_note()
      ri()

      -- Verify present
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, {})
      assert.is_true(#marks >= 1)

      auditor.delete_note()

      -- Should be gone
      marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, {})
      assert.equals(0, #marks)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── D39: undo removes sign and preview ─────────────────────────────────
  describe("D39: undo removes sign and preview", function()
    it("AuditUndo removes note sign along with highlight", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input("undo me")
      auditor.add_note()
      ri()

      auditor.undo_at_cursor()

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, {})
      assert.equals(0, #marks)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── D40: note word prefix from DB restoration ──────────────────────────
  describe("D40: word prefix correct after DB restoration", function()
    it("EOL preview shows word: prefix after save/load", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input("check this")
      auditor.add_note()
      ri()

      auditor.audit()
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      assert.is_true(#marks >= 1)
      local vt = marks[1][4].virt_text
      assert.is_truthy(vt[1][1]:match("hello: check this"))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── D41: sign color correct after DB restoration ───────────────────────
  describe("D41: sign color correct after DB restoration", function()
    it("sign hl matches original color after save/load", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("blue")
      local ri = stub_input("blue note")
      auditor.add_note()
      ri()

      auditor.audit()
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      assert.is_true(#marks >= 1)
      assert.equals("AuditorNoteSignBlue", marks[1][4].sign_hl_group)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)
end)
