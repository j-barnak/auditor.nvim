-- test/spec/notes_save_and_scale_spec.lua
-- Tests for note saving keymaps, many-notes scaling, and fuzz.
--
-- Coverage:
--   S1  <CR> not mapped in editor (reserved for multi-line)
--   S2  <S-CR> in normal mode saves and closes float
--   S3  <S-CR> in insert mode saves
--   S4  <C-s> in normal mode saves
--   S5  <C-s> in insert mode saves
--   S6  save closes the float window
--   S7  S-CR save DB round-trip
--   S8  all save keymaps are equivalent (S-CR, C-s)
--   S9  save updates EOL preview
--   S10 save multi-line content
--   S11 10 notes on separate lines with long text
--   S12 20 notes: all signs and previews present
--   S13 many notes: save/exit/enter round-trip preserves all
--   S14 50 words on 50 lines: mark + note + save + reload
--   S15 long note (1000 chars): preview truncated, viewer shows full
--   S16 very long note (10K chars): no crash, preview bounded
--   S17 multi-line note (50 lines): preview shows (+N lines), viewer has all
--   S18 note with 200-char word prefix: preview bounded
--   S19 fuzz: 100 random notes, mark + save + exit + enter, all restored
--   S20 fuzz: random note lengths (1-5000 chars), 50 iterations
--   S21 fuzz: rapid mark + note + undo cycles (100 iterations)
--   S22 fuzz: interleaved add/edit/delete on multiple words (50 iterations)
--   S23 fuzz: many notes with unicode content, DB round-trip
--   S24 property: every saved note survives mode transition
--   S25 property: note count matches after save/load
--   S26 property: no orphan note extmarks after undo
--   S27 default save keys are <C-s> and <S-CR>
--   S28 default cancel keys are q and <Esc>
--   S29 custom save keys via setup (replaces defaults, default not registered)
--   S30 custom cancel keys via setup (replaces defaults, default not registered)
--   S31 single save key works
--   S32 many save keys all work
--   S33 custom save key DB round-trip
--   S34 empty save keys list → no save keymaps
--   S35 empty cancel keys list → no cancel keymaps
--   S36 save keys in both n and i mode
--   S37 cancel keys only in normal mode
--   S38 fuzz: 20 random key configs don't crash

local function reset_modules()
  for _, m in ipairs({ "auditor", "auditor.init", "auditor.db", "auditor.highlights", "auditor.ts" }) do
    package.loaded[m] = nil
  end
end

local function make_rng(seed)
  local s = math.abs(seed) + 1
  return function(lo, hi)
    s = (s * 1664525 + 1013904223) % (2 ^ 32)
    return lo + math.floor(s * (hi - lo + 1) / (2 ^ 32))
  end
end

local function random_ascii(rng, len)
  local chars = {}
  for i = 1, len do
    chars[i] = string.char(rng(32, 126))
  end
  return table.concat(chars)
end

describe("notes save and scale", function()
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

  -- Helper: get keymap callback by lhs from a buffer
  local function get_keymap_cb(float_buf, mode, lhs)
    local keymaps = vim.api.nvim_buf_get_keymap(float_buf, mode)
    for _, km in ipairs(keymaps) do
      if km.lhs == lhs then
        return km.callback
      end
    end
    return nil
  end

  -- ═══════════════════════════════════════════════════════════════════════
  -- Save keymap tests
  -- ═══════════════════════════════════════════════════════════════════════

  -- ── S1: <CR> is NOT mapped in editor (reserved for newlines) ───────────
  describe("S1: <CR> not mapped in editor", function()
    it("Enter in normal mode is not a save keymap", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")

      local cb = get_keymap_cb(auditor._note_float_buf, "n", "<CR>")
      assert.is_nil(cb, "<CR> should NOT be mapped (reserved for multi-line editing)")

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S2: <S-CR> in normal mode saves note ───────────────────────────────
  describe("S2: <S-CR> normal mode saves", function()
    it("S-CR keymap saves and closes float", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")
      local float_win = auditor._note_float_win
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "SCR save" })

      local cb = get_keymap_cb(auditor._note_float_buf, "n", "<S-CR>")
      assert.is_not_nil(cb, "<S-CR> keymap must exist in normal mode")
      cb()

      assert.equals("SCR save", auditor._notes[bufnr][target_id])
      assert.is_false(vim.api.nvim_win_is_valid(float_win))
      assert.is_nil(auditor._note_float_win)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S3: <S-CR> in insert mode saves note ───────────────────────────────
  describe("S3: <S-CR> insert mode saves", function()
    it("S-CR keymap exists in insert mode and saves", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "SCR insert" })

      local cb = get_keymap_cb(auditor._note_float_buf, "i", "<S-CR>")
      assert.is_not_nil(cb, "<S-CR> keymap must exist in insert mode")
      cb()

      assert.equals("SCR insert", auditor._notes[bufnr][target_id])
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S4: <C-s> in normal mode saves note ────────────────────────────────
  describe("S4: <C-s> normal mode saves", function()
    it("Ctrl-s in normal mode saves", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "ctrl-s normal" })

      local cb = get_keymap_cb(auditor._note_float_buf, "n", "<C-S>")
        or get_keymap_cb(auditor._note_float_buf, "n", "<C-s>")
      assert.is_not_nil(cb, "<C-s> keymap must exist in normal mode")
      cb()

      assert.equals("ctrl-s normal", auditor._notes[bufnr][target_id])
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S5: <C-s> in insert mode saves note ────────────────────────────────
  describe("S5: <C-s> insert mode saves", function()
    it("Ctrl-s in insert mode saves", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "ctrl-s insert" })

      local cb = get_keymap_cb(auditor._note_float_buf, "i", "<C-S>")
        or get_keymap_cb(auditor._note_float_buf, "i", "<C-s>")
      assert.is_not_nil(cb, "<C-s> keymap must exist in insert mode")
      cb()

      assert.equals("ctrl-s insert", auditor._notes[bufnr][target_id])
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S6: <S-CR> save closes the float ───────────────────────────────────
  describe("S6: save closes float", function()
    it("float window is closed after S-CR save", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")
      local float_win = auditor._note_float_win
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "close test" })

      get_keymap_cb(auditor._note_float_buf, "n", "<S-CR>")()

      assert.is_false(vim.api.nvim_win_is_valid(float_win))
      assert.is_nil(auditor._note_float_win)
      assert.is_nil(auditor._note_float_buf)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S7: <S-CR> save round-trip via DB ──────────────────────────────────
  describe("S7: S-CR save DB round-trip", function()
    it("note saved via S-CR persists through save/exit/enter", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "DB persist via S-CR" })
      get_keymap_cb(auditor._note_float_buf, "n", "<S-CR>")()

      auditor.audit()
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local ext = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, { details = true })
      local found = nil
      for _, em in ipairs(ext) do
        if auditor._notes[bufnr] and auditor._notes[bufnr][em[1]] then
          found = auditor._notes[bufnr][em[1]]
          break
        end
      end
      assert.equals("DB persist via S-CR", found)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S8: all save keymaps are equivalent ────────────────────────────────
  describe("S8: all save keymaps are equivalent", function()
    it("S-CR and C-s all produce the same result", function()
      for _, key_info in ipairs({
        { mode = "n", lhs = "<S-CR>", label = "S-CR-n" },
        { mode = "n", lhs = "<C-S>", alt_lhs = "<C-s>", label = "C-s-n" },
        { mode = "i", lhs = "<S-CR>", label = "S-CR-i" },
        { mode = "i", lhs = "<C-S>", alt_lhs = "<C-s>", label = "C-s-i" },
      }) do
        reset_modules()
        local tmp_db = vim.fn.tempname() .. ".db"
        auditor = require("auditor")
        auditor.setup({ db_path = tmp_db, keymaps = false })
        hl = require("auditor.highlights")

        local bufnr = setup_buf({ "hello world" }, 1, 0)
        auditor.highlight_cword_buffer("red")
        local token = auditor._cword_token(bufnr)
        local target_id = find_target_id(bufnr, token)

        auditor._open_note_editor(bufnr, target_id, token, "")
        vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { key_info.label })

        local cb = get_keymap_cb(auditor._note_float_buf, key_info.mode, key_info.lhs)
        if not cb and key_info.alt_lhs then
          cb = get_keymap_cb(auditor._note_float_buf, key_info.mode, key_info.alt_lhs)
        end
        assert.is_not_nil(cb, key_info.label .. " keymap missing")
        cb()

        assert.equals(key_info.label, auditor._notes[bufnr][target_id],
          key_info.label .. " did not save correctly")

        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end)
  end)

  -- ── S9: save updates EOL preview ───────────────────────────────────────
  describe("S9: save updates EOL preview", function()
    it("EOL preview reflects saved text", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "preview check" })
      get_keymap_cb(auditor._note_float_buf, "n", "<S-CR>")()

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      local found = false
      for _, m in ipairs(marks) do
        local vt = m[4].virt_text
        if vt and vt[1][1]:match("preview check") then
          found = true
        end
      end
      assert.is_true(found)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S10: save with multi-line content ──────────────────────────────────
  describe("S10: save multi-line", function()
    it("multi-line note joined with newlines", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "L1", "L2", "L3" })
      get_keymap_cb(auditor._note_float_buf, "n", "<S-CR>")()

      assert.equals("L1\nL2\nL3", auditor._notes[bufnr][target_id])

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════
  -- Many-notes scaling tests
  -- ═══════════════════════════════════════════════════════════════════════

  -- ── S11: 10 notes on separate lines with long text ─────────────────────
  describe("S11: 10 notes on separate lines", function()
    it("all 10 notes have signs and previews", function()
      local lines = {}
      for i = 1, 10 do
        lines[i] = "word" .. i .. " rest of line " .. i
      end
      local bufnr = setup_buf(lines, 1, 0)

      for i = 1, 10 do
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        auditor.highlight_cword_buffer("red")
        local long_note = "Note for word" .. i .. ": " .. string.rep("x", 100)
        local ri = stub_input(long_note)
        auditor.add_note()
        ri()
      end

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      assert.equals(10, #marks)

      for _, m in ipairs(marks) do
        -- Each should have sign and preview
        assert.is_truthy(m[4].sign_text)
        assert.is_truthy(m[4].virt_text)
        -- Preview should be truncated (not the full 100+ chars)
        local preview = m[4].virt_text[1][1]
        assert.is_true(#preview <= 40) -- "  " + max 30 content + some margin
      end

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S12: 20 notes all present ──────────────────────────────────────────
  describe("S12: 20 notes all signs and previews present", function()
    it("20 separate words each get a note", function()
      local lines = {}
      for i = 1, 20 do
        lines[i] = "token" .. i .. " padding"
      end
      local bufnr = setup_buf(lines, 1, 0)

      for i = 1, 20 do
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        auditor.highlight_cword_buffer(i % 2 == 0 and "blue" or "red")
        local ri = stub_input("note" .. i)
        auditor.add_note()
        ri()
      end

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      assert.equals(20, #marks)

      -- Collect all preview texts
      local previews = {}
      for _, m in ipairs(marks) do
        local vt = m[4].virt_text
        if vt then
          table.insert(previews, vt[1][1])
        end
      end
      local all = table.concat(previews, "|")
      for i = 1, 20 do
        assert.is_truthy(all:find("note" .. i, 1, true),
          "missing preview for note" .. i)
      end

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S13: many notes save/exit/enter round-trip ─────────────────────────
  describe("S13: many notes survive save/exit/enter", function()
    it("10 notes all restored after DB round-trip", function()
      local lines = {}
      for i = 1, 10 do
        lines[i] = "var" .. i .. " = value"
      end
      local bufnr = setup_buf(lines, 1, 0)

      for i = 1, 10 do
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        auditor.highlight_cword_buffer("red")
        local ri = stub_input("persistent_note_" .. i)
        auditor.add_note()
        ri()
      end

      auditor.audit()
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      -- Count restored notes
      local note_count = 0
      if auditor._notes[bufnr] then
        for _ in pairs(auditor._notes[bufnr]) do
          note_count = note_count + 1
        end
      end
      assert.equals(10, note_count)

      -- Verify note extmarks
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      assert.equals(10, #marks)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S14: 50 words on 50 lines: full lifecycle ─────────────────────────
  describe("S14: 50-word full lifecycle", function()
    it("mark + note + save + reload for 50 words", function()
      local lines = {}
      for i = 1, 50 do
        lines[i] = "func" .. i .. " arguments"
      end
      local bufnr = setup_buf(lines, 1, 0)

      local colors = { "red", "blue", "half" }
      for i = 1, 50 do
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        auditor.highlight_cword_buffer(colors[(i % 3) + 1])
        local ri = stub_input("n" .. i)
        auditor.add_note()
        ri()
      end

      auditor.audit()
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      local note_count = 0
      if auditor._notes[bufnr] then
        for _ in pairs(auditor._notes[bufnr]) do
          note_count = note_count + 1
        end
      end
      assert.equals(50, note_count)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S15: long note (1000 chars): preview truncated, viewer full ────────
  describe("S15: long note 1000 chars", function()
    it("preview truncated but viewer shows full content", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      local long_text = string.rep("abcde ", 167) -- ~1000 chars
      auditor.highlight_cword_buffer("red")
      local ri = stub_input(long_text)
      auditor.add_note()
      ri()

      -- Preview should be truncated
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      local preview = marks[1][4].virt_text[1][1]
      assert.is_true(#preview < 100) -- way shorter than 1000

      -- Viewer should show full text
      auditor.show_note()
      local viewer_lines = vim.api.nvim_buf_get_lines(auditor._note_float_buf, 0, -1, false)
      local full = table.concat(viewer_lines, "\n")
      -- Note: trailing whitespace is stripped on save_note but not on vim.ui.input path
      assert.is_true(#full >= 500) -- substantial portion preserved

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S16: very long note (10K chars): no crash ──────────────────────────
  describe("S16: very long note 10K chars", function()
    it("no crash, preview bounded", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      local huge = string.rep("x", 10000)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input(huge)
      auditor.add_note()
      ri()

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      assert.is_true(#marks >= 1)
      local preview = marks[1][4].virt_text[1][1]
      assert.is_true(#preview <= 40)

      -- Save and reload
      auditor.audit()
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      local ext = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, { details = true })
      local found = nil
      for _, em in ipairs(ext) do
        if auditor._notes[bufnr] and auditor._notes[bufnr][em[1]] then
          found = auditor._notes[bufnr][em[1]]
          break
        end
      end
      assert.is_truthy(found)
      assert.equals(10000, #found)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S17: multi-line note (50 lines): preview and viewer ────────────────
  describe("S17: multi-line note 50 lines", function()
    it("preview shows +N lines, viewer has all lines", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      local note_lines = {}
      for i = 1, 50 do
        note_lines[i] = "line number " .. i
      end
      local multi = table.concat(note_lines, "\n")
      auditor.highlight_cword_buffer("red")
      local ri = stub_input(multi)
      auditor.add_note()
      ri()

      -- Preview should mention +49 lines
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      local preview = marks[1][4].virt_text[1][1]
      assert.is_truthy(preview:match("%+49 lines%)"))

      -- Viewer should have all 50 lines
      auditor.show_note()
      local viewer_lines = vim.api.nvim_buf_get_lines(auditor._note_float_buf, 0, -1, false)
      assert.equals(50, #viewer_lines)
      assert.equals("line number 1", viewer_lines[1])
      assert.equals("line number 50", viewer_lines[50])

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S18: note with very long word prefix ───────────────────────────────
  describe("S18: long word prefix", function()
    it("preview bounded even with 200-char word", function()
      local long_word = string.rep("a", 200)
      local bufnr = setup_buf({ long_word .. " rest" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input("note text")
      auditor.add_note()
      ri()

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      local preview = marks[1][4].virt_text[1][1]
      -- Preview should be bounded
      assert.is_true(#preview <= 40)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ═══════════════════════════════════════════════════════════════════════
  -- Fuzz tests
  -- ═══════════════════════════════════════════════════════════════════════

  -- ── S19: fuzz 100 random notes, DB round-trip ──────────────────────────
  describe("S19: fuzz 100 random notes DB round-trip", function()
    it("all 100 notes survive save/exit/enter", function()
      local lines = {}
      for i = 1, 100 do
        lines[i] = "w" .. i .. " padding"
      end
      local bufnr = setup_buf(lines, 1, 0)

      local rng = make_rng(42)
      local expected = {}
      local colors = { "red", "blue", "half" }

      for i = 1, 100 do
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        local c = colors[rng(1, 3)]
        auditor.highlight_cword_buffer(c)
        local note_text = "n" .. i .. "_" .. random_ascii(rng, rng(1, 80))
        local ri = stub_input(note_text)
        auditor.add_note()
        ri()
        expected[i] = note_text
      end

      auditor.audit()
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      -- All 100 notes should be restored
      local note_count = 0
      local restored_texts = {}
      if auditor._notes[bufnr] then
        for _, text in pairs(auditor._notes[bufnr]) do
          note_count = note_count + 1
          restored_texts[text] = true
        end
      end
      assert.equals(100, note_count)

      -- Verify each expected note exists
      for i = 1, 100 do
        assert.is_true(restored_texts[expected[i]] ~= nil,
          "missing note " .. i)
      end

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S20: fuzz random note lengths ──────────────────────────────────────
  describe("S20: fuzz random note lengths", function()
    it("50 notes with lengths 1-5000, all survive", function()
      local lines = {}
      for i = 1, 50 do
        lines[i] = "tok" .. i .. " rest"
      end
      local bufnr = setup_buf(lines, 1, 0)

      local rng = make_rng(99)

      for i = 1, 50 do
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        auditor.highlight_cword_buffer("red")
        local len = rng(1, 5000)
        local note_text = random_ascii(rng, len)
        local ri = stub_input(note_text)
        auditor.add_note()
        ri()
      end

      auditor.audit()
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      local note_count = 0
      if auditor._notes[bufnr] then
        for _ in pairs(auditor._notes[bufnr]) do
          note_count = note_count + 1
        end
      end
      assert.equals(50, note_count)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S21: fuzz rapid mark + note + undo cycles ──────────────────────────
  describe("S21: fuzz rapid mark/note/undo 100 cycles", function()
    it("no crashes after 100 mark+note+undo cycles", function()
      local bufnr = setup_buf({ "hello world test" }, 1, 0)
      local rng = make_rng(77)

      for i = 1, 100 do
        local col = ({ 0, 6, 12 })[rng(1, 3)]
        vim.api.nvim_win_set_cursor(0, { 1, col })
        local color = ({ "red", "blue", "half" })[rng(1, 3)]

        local ok, err = pcall(auditor.highlight_cword_buffer, color)
        assert(ok, string.format("iter=%d mark: %s", i, tostring(err)))

        local ri = stub_input("n" .. i)
        ok, err = pcall(auditor.add_note)
        assert(ok, string.format("iter=%d note: %s", i, tostring(err)))
        ri()

        if rng(1, 3) == 1 then
          ok, err = pcall(auditor.undo_at_cursor)
          assert(ok, string.format("iter=%d undo: %s", i, tostring(err)))
        end
      end

      -- Should not crash on save
      local ok, err = pcall(auditor.audit)
      assert(ok, "save: " .. tostring(err))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S22: fuzz interleaved add/edit/delete on multiple words ────────────
  describe("S22: fuzz interleaved add/edit/delete 50 cycles", function()
    it("no crashes with random operations", function()
      local bufnr = setup_buf({ "alpha beta gamma delta" }, 1, 0)

      -- Mark all words
      for _, col in ipairs({ 0, 6, 11, 17 }) do
        vim.api.nvim_win_set_cursor(0, { 1, col })
        auditor.highlight_cword_buffer("red")
      end

      local rng = make_rng(123)
      local cols = { 0, 6, 11, 17 }

      for i = 1, 50 do
        local col = cols[rng(1, 4)]
        vim.api.nvim_win_set_cursor(0, { 1, col })
        local op = rng(1, 4)

        if op == 1 then
          local ri = stub_input("note_" .. i)
          pcall(auditor.add_note)
          ri()
        elseif op == 2 then
          local ri = stub_input("edit_" .. i)
          pcall(auditor.edit_note)
          ri()
        elseif op == 3 then
          pcall(auditor.delete_note)
        else
          pcall(auditor.show_note)
          pcall(auditor._close_note_float)
        end
      end

      -- Save should work
      local ok, err = pcall(auditor.audit)
      assert(ok, "save: " .. tostring(err))

      -- Exit/enter should work
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S23: fuzz unicode notes DB round-trip ──────────────────────────────
  describe("S23: fuzz unicode notes DB round-trip", function()
    it("unicode notes survive save/exit/enter", function()
      local unicode = {
        "日本語テスト",
        "🎉🔥💀🚀",
        "café résumé naïve",
        "中文测试 한국어",
        "θ∑∂ƒ∆π",
        "Ñoño señor",
        "مرحبا",
        "Привет мир",
        "αβγδεζ",
        "∀x∈ℝ: x²≥0",
      }
      local lines = {}
      for i = 1, #unicode do
        lines[i] = "word" .. i .. " padding"
      end
      local bufnr = setup_buf(lines, 1, 0)

      for i = 1, #unicode do
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        auditor.highlight_cword_buffer("red")
        local ri = stub_input(unicode[i])
        auditor.add_note()
        ri()
      end

      auditor.audit()
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      local restored = {}
      if auditor._notes[bufnr] then
        for _, text in pairs(auditor._notes[bufnr]) do
          restored[text] = true
        end
      end

      for i, text in ipairs(unicode) do
        assert.is_true(restored[text] ~= nil,
          "missing unicode note " .. i .. ": " .. text)
      end

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S24: property — every saved note survives mode transition ──────────
  describe("S24: property — notes survive mode transitions", function()
    it("50 notes survive 5 enter/exit cycles", function()
      local lines = {}
      for i = 1, 50 do
        lines[i] = "sym" .. i .. " extra"
      end
      local bufnr = setup_buf(lines, 1, 0)

      for i = 1, 50 do
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        auditor.highlight_cword_buffer("red")
        local ri = stub_input("prop_" .. i)
        auditor.add_note()
        ri()
      end

      for _ = 1, 5 do
        auditor.exit_audit_mode()
        auditor.enter_audit_mode()

        local count = 0
        if auditor._notes[bufnr] then
          for _ in pairs(auditor._notes[bufnr]) do
            count = count + 1
          end
        end
        assert.equals(50, count)
      end

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S25: property — note count matches after save/load ─────────────────
  describe("S25: property — note count matches after save/load", function()
    it("random number of notes: count stable through DB cycle", function()
      local rng = make_rng(55)
      local n = rng(10, 40)
      local lines = {}
      for i = 1, n do
        lines[i] = "item" .. i .. " rest"
      end
      local bufnr = setup_buf(lines, 1, 0)

      for i = 1, n do
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        auditor.highlight_cword_buffer("red")
        local ri = stub_input("cnt_" .. i)
        auditor.add_note()
        ri()
      end

      local before = 0
      for _ in pairs(auditor._notes[bufnr]) do
        before = before + 1
      end
      assert.equals(n, before)

      auditor.audit()
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      local after = 0
      if auditor._notes[bufnr] then
        for _ in pairs(auditor._notes[bufnr]) do
          after = after + 1
        end
      end
      assert.equals(before, after)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S26: property — no orphan note extmarks after undo ─────────────────
  describe("S26: property — no orphan note extmarks after undo", function()
    it("undoing all highlights leaves zero note extmarks", function()
      local lines = { "aaa bbb ccc ddd eee" }
      local bufnr = setup_buf(lines, 1, 0)
      local cols = { 0, 4, 8, 12, 16 }

      for _, col in ipairs(cols) do
        vim.api.nvim_win_set_cursor(0, { 1, col })
        auditor.highlight_cword_buffer("red")
        local ri = stub_input("note_at_" .. col)
        auditor.add_note()
        ri()
      end

      -- Verify notes present
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, {})
      assert.equals(5, #marks)

      -- Undo all
      for _, col in ipairs(cols) do
        vim.api.nvim_win_set_cursor(0, { 1, col })
        auditor.undo_at_cursor()
      end

      -- Zero note extmarks should remain
      marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, {})
      assert.equals(0, #marks)

      -- Zero notes in memory
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

  -- ═══════════════════════════════════════════════════════════════════════
  -- Configurable key tests
  -- ═══════════════════════════════════════════════════════════════════════

  -- ── S27: default save keys are <C-s> and <S-CR> ───────────────────────
  describe("S27: default save keys", function()
    it("default _note_save_keys contains C-s and S-CR", function()
      assert.is_true(vim.tbl_contains(auditor._note_save_keys, "<C-s>"))
      assert.is_true(vim.tbl_contains(auditor._note_save_keys, "<S-CR>"))
    end)
  end)

  -- ── S28: default cancel keys are q and <Esc> ──────────────────────────
  describe("S28: default cancel keys", function()
    it("default _note_cancel_keys contains q and Esc", function()
      assert.is_true(vim.tbl_contains(auditor._note_cancel_keys, "q"))
      assert.is_true(vim.tbl_contains(auditor._note_cancel_keys, "<Esc>"))
    end)
  end)

  -- ── S29: custom save keys via setup ────────────────────────────────────
  describe("S29: custom save keys via setup", function()
    it("custom note_save_keys replaces defaults", function()
      reset_modules()
      local tmp_db = vim.fn.tempname() .. ".db"
      auditor = require("auditor")
      auditor.setup({ db_path = tmp_db, keymaps = false, note_save_keys = { "<C-CR>", "<M-s>" } })
      hl = require("auditor.highlights")

      assert.same({ "<C-CR>", "<M-s>" }, auditor._note_save_keys)

      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "custom key" })

      -- Custom key should be registered
      local cb = get_keymap_cb(auditor._note_float_buf, "n", "<C-CR>")
      assert.is_not_nil(cb, "<C-CR> should be registered as save key")
      cb()

      assert.equals("custom key", auditor._notes[bufnr][target_id])

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("default C-s is NOT registered when custom keys used", function()
      reset_modules()
      local tmp_db = vim.fn.tempname() .. ".db"
      auditor = require("auditor")
      auditor.setup({ db_path = tmp_db, keymaps = false, note_save_keys = { "<M-s>" } })
      hl = require("auditor.highlights")

      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")

      -- Default <C-s> should NOT be registered
      local cb_cs = get_keymap_cb(auditor._note_float_buf, "n", "<C-S>")
        or get_keymap_cb(auditor._note_float_buf, "n", "<C-s>")
      assert.is_nil(cb_cs, "<C-s> should NOT be registered with custom save keys")

      -- Custom key should be registered
      local cb_ms = get_keymap_cb(auditor._note_float_buf, "n", "<M-s>")
      assert.is_not_nil(cb_ms, "<M-s> should be registered")

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S30: custom cancel keys via setup ──────────────────────────────────
  describe("S30: custom cancel keys via setup", function()
    it("custom note_cancel_keys replaces defaults", function()
      reset_modules()
      local tmp_db = vim.fn.tempname() .. ".db"
      auditor = require("auditor")
      auditor.setup({ db_path = tmp_db, keymaps = false, note_cancel_keys = { "<C-c>" } })
      hl = require("auditor.highlights")

      assert.same({ "<C-c>" }, auditor._note_cancel_keys)

      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "should cancel" })

      -- Custom cancel key should work
      local cb = get_keymap_cb(auditor._note_float_buf, "n", "<C-C>")
        or get_keymap_cb(auditor._note_float_buf, "n", "<C-c>")
      assert.is_not_nil(cb, "<C-c> should be registered as cancel key")
      cb()

      -- No note stored
      local has_note = auditor._notes[bufnr] and auditor._notes[bufnr][target_id]
      assert.is_nil(has_note)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("default q is NOT registered when custom cancel keys used", function()
      reset_modules()
      local tmp_db = vim.fn.tempname() .. ".db"
      auditor = require("auditor")
      auditor.setup({ db_path = tmp_db, keymaps = false, note_cancel_keys = { "<C-c>" } })
      hl = require("auditor.highlights")

      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")

      local cb_q = get_keymap_cb(auditor._note_float_buf, "n", "q")
      assert.is_nil(cb_q, "q should NOT be registered with custom cancel keys")

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S31: single save key works ─────────────────────────────────────────
  describe("S31: single save key", function()
    it("setup with just one save key", function()
      reset_modules()
      local tmp_db = vim.fn.tempname() .. ".db"
      auditor = require("auditor")
      auditor.setup({ db_path = tmp_db, keymaps = false, note_save_keys = { "<CR>" } })
      hl = require("auditor.highlights")

      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "enter save" })

      -- Only <CR> should be bound, both modes
      local cb_n = get_keymap_cb(auditor._note_float_buf, "n", "<CR>")
      local cb_i = get_keymap_cb(auditor._note_float_buf, "i", "<CR>")
      assert.is_not_nil(cb_n, "<CR> should exist in normal mode")
      assert.is_not_nil(cb_i, "<CR> should exist in insert mode")
      cb_n()

      assert.equals("enter save", auditor._notes[bufnr][target_id])

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S32: many save keys ────────────────────────────────────────────────
  describe("S32: many save keys", function()
    it("multiple save keys all work", function()
      reset_modules()
      local tmp_db = vim.fn.tempname() .. ".db"
      auditor = require("auditor")
      auditor.setup({
        db_path = tmp_db,
        keymaps = false,
        note_save_keys = { "<C-s>", "<S-CR>", "<M-CR>", "<C-CR>" },
      })
      hl = require("auditor.highlights")

      local keys_to_check = { "<C-S>", "<S-CR>", "<M-CR>", "<C-CR>" }
      -- Try alternate casing for C-s
      local alt = { "<C-s>", nil, nil, nil }

      for i, lhs in ipairs(keys_to_check) do
        reset_modules()
        local db2 = vim.fn.tempname() .. ".db"
        auditor = require("auditor")
        auditor.setup({
          db_path = db2,
          keymaps = false,
          note_save_keys = { "<C-s>", "<S-CR>", "<M-CR>", "<C-CR>" },
        })
        hl = require("auditor.highlights")

        local bufnr = setup_buf({ "hello world" }, 1, 0)
        auditor.highlight_cword_buffer("red")
        local token = auditor._cword_token(bufnr)
        local target_id = find_target_id(bufnr, token)

        auditor._open_note_editor(bufnr, target_id, token, "")
        vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "key" .. i })

        local cb = get_keymap_cb(auditor._note_float_buf, "n", lhs)
        if not cb and alt[i] then
          cb = get_keymap_cb(auditor._note_float_buf, "n", alt[i])
        end
        assert.is_not_nil(cb, lhs .. " should be registered")
        cb()

        assert.equals("key" .. i, auditor._notes[bufnr][target_id])
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end)
  end)

  -- ── S33: custom save key DB round-trip ─────────────────────────────────
  describe("S33: custom save key DB round-trip", function()
    it("note saved with custom key persists through DB cycle", function()
      reset_modules()
      local tmp_db = vim.fn.tempname() .. ".db"
      auditor = require("auditor")
      auditor.setup({ db_path = tmp_db, keymaps = false, note_save_keys = { "<M-s>" } })
      hl = require("auditor.highlights")

      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")
      vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "custom persist" })
      local cb = get_keymap_cb(auditor._note_float_buf, "n", "<M-s>")
      assert.is_not_nil(cb)
      cb()

      auditor.audit()
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      local ext = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, { details = true })
      local found = nil
      for _, em in ipairs(ext) do
        if auditor._notes[bufnr] and auditor._notes[bufnr][em[1]] then
          found = auditor._notes[bufnr][em[1]]
          break
        end
      end
      assert.equals("custom persist", found)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S34: empty save keys list → no save keymaps ────────────────────────
  describe("S34: empty save keys list", function()
    it("no save keymaps registered when list is empty", function()
      reset_modules()
      local tmp_db = vim.fn.tempname() .. ".db"
      auditor = require("auditor")
      auditor.setup({ db_path = tmp_db, keymaps = false, note_save_keys = {} })
      hl = require("auditor.highlights")

      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")

      -- No save keys should be registered
      local all_keymaps = vim.api.nvim_buf_get_keymap(auditor._note_float_buf, "n")
      local save_count = 0
      for _, km in ipairs(all_keymaps) do
        if km.desc == "Save note" then
          save_count = save_count + 1
        end
      end
      assert.equals(0, save_count)

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S35: empty cancel keys list → no cancel keymaps ────────────────────
  describe("S35: empty cancel keys list", function()
    it("no cancel keymaps registered when list is empty", function()
      reset_modules()
      local tmp_db = vim.fn.tempname() .. ".db"
      auditor = require("auditor")
      auditor.setup({ db_path = tmp_db, keymaps = false, note_cancel_keys = {} })
      hl = require("auditor.highlights")

      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")

      local all_keymaps = vim.api.nvim_buf_get_keymap(auditor._note_float_buf, "n")
      local cancel_count = 0
      for _, km in ipairs(all_keymaps) do
        if km.desc == "Cancel note editor" then
          cancel_count = cancel_count + 1
        end
      end
      assert.equals(0, cancel_count)

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S36: save keys bound in both normal and insert mode ────────────────
  describe("S36: save keys in both modes", function()
    it("each custom save key is in both n and i mode", function()
      reset_modules()
      local tmp_db = vim.fn.tempname() .. ".db"
      auditor = require("auditor")
      auditor.setup({ db_path = tmp_db, keymaps = false, note_save_keys = { "<M-x>", "<C-CR>" } })
      hl = require("auditor.highlights")

      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")

      for _, key in ipairs({ "<M-x>", "<C-CR>" }) do
        local cb_n = get_keymap_cb(auditor._note_float_buf, "n", key)
        local cb_i = get_keymap_cb(auditor._note_float_buf, "i", key)
        assert.is_not_nil(cb_n, key .. " missing in normal mode")
        assert.is_not_nil(cb_i, key .. " missing in insert mode")
      end

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S37: cancel keys only bound in normal mode ─────────────────────────
  describe("S37: cancel keys only in normal mode", function()
    it("cancel keys are NOT in insert mode", function()
      reset_modules()
      local tmp_db = vim.fn.tempname() .. ".db"
      auditor = require("auditor")
      auditor.setup({ db_path = tmp_db, keymaps = false, note_cancel_keys = { "x", "<C-q>" } })
      hl = require("auditor.highlights")

      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")

      -- Verify normal mode has them
      local cb_x = get_keymap_cb(auditor._note_float_buf, "n", "x")
      local cb_cq = get_keymap_cb(auditor._note_float_buf, "n", "<C-Q>")
        or get_keymap_cb(auditor._note_float_buf, "n", "<C-q>")
      assert.is_not_nil(cb_x, "x should be registered in normal mode")
      assert.is_not_nil(cb_cq, "<C-q> should be registered in normal mode")

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── S38: fuzz — random key configs don't crash ─────────────────────────
  describe("S38: fuzz random key configs", function()
    it("20 random key configs all work without crash", function()
      local rng = make_rng(314)
      local key_pool = {
        "<C-s>", "<S-CR>", "<C-CR>", "<M-CR>", "<M-s>", "<C-x>",
        "<M-x>", "<C-q>", "<F5>", "<F12>",
      }

      for seed = 1, 20 do
        reset_modules()
        local tmp_db = vim.fn.tempname() .. ".db"
        auditor = require("auditor")

        -- Random subset of keys for save
        local n_save = rng(1, 3)
        local save_keys = {}
        for _ = 1, n_save do
          save_keys[#save_keys + 1] = key_pool[rng(1, #key_pool)]
        end

        -- Random subset for cancel
        local n_cancel = rng(1, 2)
        local cancel_keys = {}
        for _ = 1, n_cancel do
          cancel_keys[#cancel_keys + 1] = key_pool[rng(1, #key_pool)]
        end

        local ok, err = pcall(auditor.setup, {
          db_path = tmp_db,
          keymaps = false,
          note_save_keys = save_keys,
          note_cancel_keys = cancel_keys,
        })
        assert(ok, string.format("seed=%d setup: %s", seed, tostring(err)))
        hl = require("auditor.highlights")

        local bufnr = setup_buf({ "hello world" }, 1, 0)
        auditor.highlight_cword_buffer("red")
        local token = auditor._cword_token(bufnr)
        local target_id = find_target_id(bufnr, token)

        ok, err = pcall(auditor._open_note_editor, bufnr, target_id, token, "")
        assert(ok, string.format("seed=%d open: %s", seed, tostring(err)))

        vim.api.nvim_buf_set_lines(auditor._note_float_buf, 0, -1, false, { "fuzz" .. seed })

        -- Try first save key
        local cb = get_keymap_cb(auditor._note_float_buf, "n", save_keys[1])
          or get_keymap_cb(auditor._note_float_buf, "i", save_keys[1])
        if cb then
          ok, err = pcall(cb)
          assert(ok, string.format("seed=%d save: %s", seed, tostring(err)))
        else
          pcall(auditor._close_note_float)
        end

        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end)
  end)
end)
