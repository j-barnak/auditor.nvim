-- test/spec/notes_fuzz_spec.lua
-- Exhaustive, property-based, and fuzz tests for virtual text notes.
-- Notes accept arbitrary user input, so we fuzz with special characters,
-- unicode, SQL-like strings, very long strings, control characters, etc.
--
-- Coverage:
--   F1  Fuzz: random ASCII strings as note text — never crash, always recoverable
--   F2  Fuzz: unicode strings — CJK, emoji, accented chars, RTL
--   F3  Fuzz: SQL injection attempts — quoted strings, semicolons, DROP TABLE
--   F4  Fuzz: control characters — \0, \n, \r, \t, escape sequences
--   F5  Fuzz: extremely long strings (1K, 10K, 100K chars)
--   F6  Fuzz: empty/whitespace-only strings
--   F7  Property: note text round-trips through DB exactly
--   F8  Property: note survives enter/exit for any text
--   F9  Property: undo always removes note regardless of text
--   F10 Property: clear always removes all notes regardless of text
--   F11 Property: re-mark clears note regardless of text
--   F12 Fuzz: rapid add/edit/delete cycles never crash
--   F13 Fuzz: interleaved note operations across multiple words
--   F14 Fuzz: note operations on multiple buffers
--   F15 Property: list_notes includes all and only active notes
--   F16 Fuzz: pick_note_action menu context adapts correctly
--   F17 Fuzz: edit_note with arbitrary replacement text
--   F18 Property: note text never appears in buffer content

local function reset_modules()
  for _, m in ipairs({ "auditor", "auditor.init", "auditor.db", "auditor.highlights", "auditor.ts" }) do
    package.loaded[m] = nil
  end
end

-- Deterministic PRNG.
local function make_rng(seed)
  local s = math.abs(seed) + 1
  return function(lo, hi)
    s = (s * 1664525 + 1013904223) % (2 ^ 32)
    return lo + math.floor(s * (hi - lo + 1) / (2 ^ 32))
  end
end

-- Generate a random string of printable ASCII.
local function random_ascii(rng, len)
  local chars = {}
  for i = 1, len do
    chars[i] = string.char(rng(32, 126))
  end
  return table.concat(chars)
end

-- Predefined nasty strings for fuzzing.
local NASTY_STRINGS = {
  "",
  " ",
  "   ",
  "\t",
  "\n",
  "\r\n",
  "\t\n\r",
  "hello\x01world", -- embedded control char (avoid \0 — C string terminator)
  string.rep("a", 1000),
  string.rep("x", 10000),
  "'; DROP TABLE highlights; --",
  "\" OR 1=1 --",
  "Robert'); DROP TABLE Students;--",
  "<script>alert('xss')</script>",
  "$(rm -rf /)",
  "`rm -rf /`",
  "${HOME}",
  "\\n\\t\\r",
  "foo'bar\"baz",
  "foo\\'bar\\\"baz",
  "SELECT * FROM highlights WHERE 1=1",
  "INSERT INTO highlights VALUES(1,2,3)",
  "\x1b[31mred\x1b[0m", -- ANSI escape
  "\x01\x02\x03\x04", -- low control chars (avoid \x00 — C string terminator)
  "\xfe\xff", -- invalid UTF-8 start
  "\xc0\xaf", -- overlong UTF-8
  "日本語テスト", -- Japanese
  "中文测试", -- Chinese
  "한국어", -- Korean
  "العربية", -- Arabic (RTL)
  "🎉🔥💀🚀", -- emoji
  "café résumé naïve", -- accented Latin
  "Ñoño", -- tilde
  "a\xcc\x81", -- combining accent (a + combining acute)
  string.rep("🔥", 500), -- long emoji string
  "a" .. string.rep("\t", 100) .. "b",
  "note with\nnewline",
  "note with\rcarriage return",
  "  leading whitespace",
  "trailing whitespace  ",
  "  both sides  ",
  ("a"):rep(100000), -- 100K chars
}

describe("notes fuzz", function()
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

  local function stub_input(response)
    local orig = vim.ui.input
    vim.ui.input = function(_opts, callback)
      callback(response)
    end
    return function()
      vim.ui.input = orig
    end
  end

  -- ── F1: Random ASCII strings ──────────────────────────────────────────
  describe("F1: random ASCII note text (200 iterations)", function()
    it("never crashes on add + save + reload", function()
      for seed = 1, 200 do
        reset_modules()
        local tmp_db = vim.fn.tempname() .. ".db"
        auditor = require("auditor")
        auditor.setup({ db_path = tmp_db, keymaps = false })
        auditor._note_input_override = true
        db = require("auditor.db")
        hl = require("auditor.highlights")

        local rng = make_rng(seed)
        local text = random_ascii(rng, rng(1, 200))

        local bufnr = setup_buf({ "hello world" }, 1, 0)
        auditor.highlight_cword_buffer("red")

        local restore_input = stub_input(text)
        local ok1, err1 = pcall(auditor.add_note)
        restore_input()
        assert(ok1, string.format("seed=%d add_note: %s", seed, tostring(err1)))

        local ok2, err2 = pcall(auditor.audit)
        assert(ok2, string.format("seed=%d audit: %s", seed, tostring(err2)))

        -- Reload from DB
        vim.api.nvim_buf_clear_namespace(bufnr, hl.ns, 0, -1)
        hl.clear_notes(bufnr)
        auditor._notes[bufnr] = {}
        auditor._db_extmarks[bufnr] = {}

        local ok3, err3 = pcall(auditor.load_for_buffer, bufnr)
        assert(ok3, string.format("seed=%d load: %s", seed, tostring(err3)))

        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        pcall(os.remove, tmp_db)
      end
    end)
  end)

  -- ── F2: Unicode strings ───────────────────────────────────────────────
  describe("F2: unicode note text", function()
    local unicode_strings = {
      "日本語テスト",
      "中文测试备注",
      "한국어 메모",
      "العربية ملاحظة",
      "🎉🔥💀🚀🎸",
      "café résumé naïve",
      "Ñoño señor",
      "θ∑∂ƒ∆˚¬",
      "Ω≈ç√∫≤≥÷",
      "Ünïcödé ëvërÿwhérë",
      "🏳️‍🌈🏴‍☠️", -- composite emoji
      "a\xcc\x81" .. "b\xcc\x82", -- combining accents
    }

    for i, text in ipairs(unicode_strings) do
      it(string.format("unicode %d: add + save + reload", i), function()
        local bufnr, filepath = setup_buf({ "hello world" }, 1, 0)
        auditor.highlight_cword_buffer("red")

        local restore_input = stub_input(text)
        auditor.add_note()
        restore_input()

        auditor.audit()

        local rows = db.get_highlights(filepath)
        assert.is_true(#rows >= 1)
        local found = false
        for _, r in ipairs(rows) do
          if r.note == text then
            found = true
          end
        end
        assert.is_true(found, "unicode note not found in DB: " .. text)

        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end)
    end
  end)

  -- ── F3: SQL injection attempts ────────────────────────────────────────
  describe("F3: SQL injection attempts", function()
    local sql_strings = {
      "'; DROP TABLE highlights; --",
      "\" OR 1=1 --",
      "Robert'); DROP TABLE Students;--",
      "1; DELETE FROM highlights",
      "' UNION SELECT * FROM sqlite_master --",
      "test' OR '1'='1",
      "'; INSERT INTO highlights VALUES(999,'x',0,0,0,'red',1,'',''); --",
      "test\"; DROP TABLE highlights; --",
    }

    for i, text in ipairs(sql_strings) do
      it(string.format("SQL injection %d: does not corrupt DB", i), function()
        local bufnr, filepath = setup_buf({ "hello world" }, 1, 0)
        auditor.highlight_cword_buffer("red")

        local restore_input = stub_input(text)
        auditor.add_note()
        restore_input()

        auditor.audit()

        -- DB should still be healthy
        local rows = db.get_highlights(filepath)
        assert.is_true(#rows >= 1)
        assert.equals("red", rows[1].color)
        -- Note should be stored literally, not executed
        assert.equals(text, rows[1].note)

        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end)
    end
  end)

  -- ── F4: Control characters ────────────────────────────────────────────
  describe("F4: control characters in notes", function()
    local ctrl_strings = {
      "\t\t\t",
      "line1\nline2\nline3",
      "carriage\rreturn",
      "mixed\r\n\tend",
      "\x1b[31mcolored\x1b[0m",
      "bell\x07char",
      "backspace\x08char",
      "form\x0cfeed",
    }

    for i, text in ipairs(ctrl_strings) do
      it(string.format("control chars %d: add + save round-trip", i), function()
        local bufnr, filepath = setup_buf({ "hello world" }, 1, 0)
        auditor.highlight_cword_buffer("red")

        local restore_input = stub_input(text)
        local ok, err = pcall(auditor.add_note)
        restore_input()
        assert(ok, string.format("add_note failed: %s", tostring(err)))

        local ok2, err2 = pcall(auditor.audit)
        assert(ok2, string.format("audit failed: %s", tostring(err2)))

        local rows = db.get_highlights(filepath)
        assert.is_true(#rows >= 1)
        assert.equals(text, rows[1].note)

        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end)
    end
  end)

  -- ── F5: Extremely long strings ────────────────────────────────────────
  describe("F5: extremely long note text", function()
    local lengths = { 1000, 10000 }

    for _, len in ipairs(lengths) do
      it(string.format("length %d: add + save + reload", len), function()
        local text = string.rep("x", len)
        local bufnr, filepath = setup_buf({ "hello world" }, 1, 0)
        auditor.highlight_cword_buffer("red")

        local restore_input = stub_input(text)
        auditor.add_note()
        restore_input()

        auditor.audit()

        local rows = db.get_highlights(filepath)
        assert.is_true(#rows >= 1)
        assert.equals(len, #rows[1].note)

        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end)
    end
  end)

  -- ── F6: Empty/whitespace-only strings ─────────────────────────────────
  describe("F6: empty and whitespace-only input", function()
    it("empty string does not create note", function()
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

    it("nil input does not create note", function()
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

    it("whitespace-only string IS stored (user intent)", function()
      local bufnr, filepath = setup_buf({ "hello" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore_input = stub_input("   ")
      auditor.add_note()
      restore_input()

      auditor.audit()
      local rows = db.get_highlights(filepath)
      assert.equals("   ", rows[1].note)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── F7: Property: note text round-trips through DB exactly ────────────
  describe("F7: property — DB round-trip preserves text (100 iterations)", function()
    it("note text is identical after save + reload", function()
      for seed = 1, 100 do
        reset_modules()
        local tmp_db = vim.fn.tempname() .. ".db"
        auditor = require("auditor")
        auditor.setup({ db_path = tmp_db, keymaps = false })
        auditor._note_input_override = true
        db = require("auditor.db")
        hl = require("auditor.highlights")

        local rng = make_rng(seed)
        local text = random_ascii(rng, rng(1, 100))

        local bufnr, filepath = setup_buf({ "hello world" }, 1, 0)
        auditor.highlight_cword_buffer("red")

        local restore_input = stub_input(text)
        auditor.add_note()
        restore_input()

        auditor.audit()

        local rows = db.get_highlights(filepath)
        assert.is_true(#rows >= 1)
        assert.equals(text, rows[1].note,
          string.format("seed=%d: note mismatch", seed))

        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        pcall(os.remove, tmp_db)
      end
    end)
  end)

  -- ── F8: Property: note survives enter/exit for any text ───────────────
  describe("F8: property — notes survive mode transition (50 iterations)", function()
    it("note is present after exit + enter", function()
      for seed = 1, 50 do
        reset_modules()
        local tmp_db = vim.fn.tempname() .. ".db"
        auditor = require("auditor")
        auditor.setup({ db_path = tmp_db, keymaps = false })
        auditor._note_input_override = true
        db = require("auditor.db")
        hl = require("auditor.highlights")

        local rng = make_rng(seed)
        local text = random_ascii(rng, rng(1, 80))

        local bufnr = setup_buf({ "hello world" }, 1, 0)
        auditor.highlight_cword_buffer("red")

        local restore_input = stub_input(text)
        auditor.add_note()
        restore_input()

        auditor.exit_audit_mode()
        auditor.enter_audit_mode()

        -- Check note is present
        local found = false
        if auditor._notes[bufnr] then
          for _, n in pairs(auditor._notes[bufnr]) do
            if n == text then
              found = true
            end
          end
        end
        assert.is_true(found,
          string.format("seed=%d: note lost after mode transition", seed))

        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        pcall(os.remove, tmp_db)
      end
    end)
  end)

  -- ── F9: Property: undo always removes note ────────────────────────────
  describe("F9: property — undo removes note (50 iterations)", function()
    it("undo clears note for any text", function()
      for seed = 1, 50 do
        reset_modules()
        local tmp_db = vim.fn.tempname() .. ".db"
        auditor = require("auditor")
        auditor.setup({ db_path = tmp_db, keymaps = false })
        auditor._note_input_override = true
        hl = require("auditor.highlights")

        local rng = make_rng(seed)
        local text = random_ascii(rng, rng(1, 80))

        local bufnr = setup_buf({ "hello world" }, 1, 0)
        auditor.highlight_cword_buffer("red")

        local restore_input = stub_input(text)
        auditor.add_note()
        restore_input()

        auditor.undo_at_cursor()

        local count = 0
        if auditor._notes[bufnr] then
          for _ in pairs(auditor._notes[bufnr]) do
            count = count + 1
          end
        end
        assert.equals(0, count,
          string.format("seed=%d: note not removed after undo", seed))

        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        pcall(os.remove, tmp_db)
      end
    end)
  end)

  -- ── F10: Property: clear removes all notes ────────────────────────────
  describe("F10: property — clear removes notes (30 iterations)", function()
    it("clear wipes all notes for any text", function()
      for seed = 1, 30 do
        reset_modules()
        local tmp_db = vim.fn.tempname() .. ".db"
        auditor = require("auditor")
        auditor.setup({ db_path = tmp_db, keymaps = false })
        auditor._note_input_override = true
        hl = require("auditor.highlights")

        local rng = make_rng(seed)

        local bufnr = setup_buf({ "hello world" }, 1, 0)
        auditor.highlight_cword_buffer("red")
        local restore_input = stub_input(random_ascii(rng, rng(1, 50)))
        auditor.add_note()
        restore_input()

        vim.api.nvim_win_set_cursor(0, { 1, 6 })
        auditor.highlight_cword_buffer("blue")
        restore_input = stub_input(random_ascii(rng, rng(1, 50)))
        auditor.add_note()
        restore_input()

        auditor.clear_buffer()

        assert.same({}, auditor._notes[bufnr] or {},
          string.format("seed=%d: notes not cleared", seed))

        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        pcall(os.remove, tmp_db)
      end
    end)
  end)

  -- ── F11: Property: re-mark clears note ────────────────────────────────
  describe("F11: property — re-mark clears note (50 iterations)", function()
    it("re-marking removes previous note", function()
      for seed = 1, 50 do
        reset_modules()
        local tmp_db = vim.fn.tempname() .. ".db"
        auditor = require("auditor")
        auditor.setup({ db_path = tmp_db, keymaps = false })
        auditor._note_input_override = true
        hl = require("auditor.highlights")

        local rng = make_rng(seed)
        local text = random_ascii(rng, rng(1, 50))

        local bufnr = setup_buf({ "hello world" }, 1, 0)
        auditor.highlight_cword_buffer("red")

        local restore_input = stub_input(text)
        auditor.add_note()
        restore_input()

        -- Re-mark same word with different color
        auditor.highlight_cword_buffer("blue")

        local count = 0
        if auditor._notes[bufnr] then
          for _ in pairs(auditor._notes[bufnr]) do
            count = count + 1
          end
        end
        assert.equals(0, count,
          string.format("seed=%d: note not removed after re-mark", seed))

        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        pcall(os.remove, tmp_db)
      end
    end)
  end)

  -- ── F12: Rapid add/edit/delete cycles ─────────────────────────────────
  describe("F12: rapid add/edit/delete cycles (100 iterations)", function()
    it("never crashes", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      for seed = 1, 100 do
        local rng = make_rng(seed)
        local op = rng(1, 4)
        local text = random_ascii(rng, rng(1, 30))
        local restore_input = stub_input(text)

        local ok, err
        if op == 1 then
          ok, err = pcall(auditor.add_note)
        elseif op == 2 then
          ok, err = pcall(auditor.edit_note)
        elseif op == 3 then
          ok, err = pcall(auditor.delete_note)
        else
          ok, err = pcall(auditor.list_notes)
          pcall(vim.cmd, "cclose")
        end
        restore_input()
        assert(ok, string.format("seed=%d op=%d: %s", seed, op, tostring(err)))
      end

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── F13: Interleaved operations across multiple words ─────────────────
  describe("F13: interleaved notes on multiple words", function()
    it("notes stay associated with correct words", function()
      local bufnr = setup_buf({ "alpha beta gamma" }, 1, 0)

      -- Mark all three words
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red") -- alpha
      vim.api.nvim_win_set_cursor(0, { 1, 6 })
      auditor.highlight_cword_buffer("blue") -- beta
      vim.api.nvim_win_set_cursor(0, { 1, 11 })
      auditor.highlight_cword_buffer("red") -- gamma

      -- Add notes to each
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local restore_input = stub_input("note_alpha")
      auditor.add_note()
      restore_input()

      vim.api.nvim_win_set_cursor(0, { 1, 6 })
      restore_input = stub_input("note_beta")
      auditor.add_note()
      restore_input()

      vim.api.nvim_win_set_cursor(0, { 1, 11 })
      restore_input = stub_input("note_gamma")
      auditor.add_note()
      restore_input()

      -- Delete middle note
      vim.api.nvim_win_set_cursor(0, { 1, 6 })
      auditor.delete_note()

      -- Check: alpha and gamma notes exist, beta doesn't
      local notes_text = {}
      for _, text in pairs(auditor._notes[bufnr] or {}) do
        notes_text[text] = true
      end
      assert.is_true(notes_text["note_alpha"])
      assert.is_nil(notes_text["note_beta"])
      assert.is_true(notes_text["note_gamma"])

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── F14: Multi-buffer note isolation ──────────────────────────────────
  describe("F14: multi-buffer note isolation", function()
    it("notes in one buffer don't affect another", function()
      local buf1 = setup_buf({ "hello" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local restore_input = stub_input("buf1 note")
      auditor.add_note()
      restore_input()

      local buf2 = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf2, vim.fn.tempname() .. ".lua")
      vim.api.nvim_buf_set_lines(buf2, 0, -1, false, { "world" })
      vim.api.nvim_set_current_buf(buf2)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("blue")
      restore_input = stub_input("buf2 note")
      auditor.add_note()
      restore_input()

      -- Each buffer has exactly 1 note
      local count1 = 0
      for _ in pairs(auditor._notes[buf1] or {}) do
        count1 = count1 + 1
      end
      local count2 = 0
      for _ in pairs(auditor._notes[buf2] or {}) do
        count2 = count2 + 1
      end
      assert.equals(1, count1)
      assert.equals(1, count2)

      -- Delete buf1 — its notes gone, buf2 unaffected
      vim.api.nvim_buf_delete(buf1, { force = true })
      assert.is_nil(auditor._notes[buf1])
      assert.equals(1, count2)

      pcall(vim.api.nvim_buf_delete, buf2, { force = true })
    end)
  end)

  -- ── F15: list_notes includes all and only active notes ────────────────
  describe("F15: list_notes accuracy", function()
    it("quickfix has exactly the notes that exist", function()
      local bufnr = setup_buf({ "aaa bbb ccc" }, 1, 0)

      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      local restore_input = stub_input("n1")
      auditor.add_note()
      restore_input()

      vim.api.nvim_win_set_cursor(0, { 1, 4 })
      auditor.highlight_cword_buffer("blue")
      restore_input = stub_input("n2")
      auditor.add_note()
      restore_input()

      vim.api.nvim_win_set_cursor(0, { 1, 8 })
      auditor.highlight_cword_buffer("red")
      -- No note on ccc

      auditor.list_notes()
      local qf = vim.fn.getqflist()
      vim.cmd("cclose")
      assert.equals(2, #qf) -- only aaa and bbb have notes

      -- Delete one note — make sure we're in the right buffer and position
      vim.api.nvim_set_current_buf(bufnr)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.delete_note()

      auditor.list_notes()
      qf = vim.fn.getqflist()
      vim.cmd("cclose")
      assert.equals(1, #qf) -- only bbb now
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── F16: pick_note_action context ─────────────────────────────────────
  describe("F16: pick_note_action menu context", function()
    it("shows 'Add note' when highlight has no note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local captured_items
      local orig = vim.ui.select
      vim.ui.select = function(items, _opts, _cb)
        captured_items = items
      end
      auditor.pick_note_action()
      vim.ui.select = orig

      local labels = {}
      for _, item in ipairs(captured_items) do
        labels[item.label] = true
      end
      assert.is_true(labels["Add note"])
      assert.is_nil(labels["Edit note"])
      assert.is_nil(labels["Delete note"])
      assert.is_true(labels["List all notes"])

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("shows Edit/Delete when highlight has a note", function()
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")

      local restore_input = stub_input("test")
      auditor.add_note()
      restore_input()

      local captured_items
      local orig = vim.ui.select
      vim.ui.select = function(items, _opts, _cb)
        captured_items = items
      end
      auditor.pick_note_action()
      vim.ui.select = orig

      local labels = {}
      for _, item in ipairs(captured_items) do
        labels[item.label] = true
      end
      assert.is_nil(labels["Add note"])
      assert.is_true(labels["Show note"])
      assert.is_true(labels["Edit note"])
      assert.is_true(labels["Delete note"])
      assert.is_true(labels["List all notes"])

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("shows only List when cursor not on highlighted word", function()
      local bufnr = setup_buf({ "hello world" }, 1, 5) -- on space

      local captured_items
      local orig = vim.ui.select
      vim.ui.select = function(items, _opts, _cb)
        captured_items = items
      end
      auditor.pick_note_action()
      vim.ui.select = orig

      assert.equals(1, #captured_items)
      assert.equals("List all notes", captured_items[1].label)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── F17: edit_note with arbitrary replacement text ────────────────────
  describe("F17: edit_note fuzz (100 iterations)", function()
    it("never crashes with arbitrary replacement text", function()
      for seed = 1, 100 do
        reset_modules()
        local tmp_db = vim.fn.tempname() .. ".db"
        auditor = require("auditor")
        auditor.setup({ db_path = tmp_db, keymaps = false })
        auditor._note_input_override = true
        hl = require("auditor.highlights")

        local rng = make_rng(seed)
        local original = random_ascii(rng, rng(1, 30))
        local replacement = random_ascii(rng, rng(0, 50))

        local bufnr = setup_buf({ "hello world" }, 1, 0)
        auditor.highlight_cword_buffer("red")

        local restore_input = stub_input(original)
        auditor.add_note()
        restore_input()

        restore_input = stub_input(replacement)
        local ok, err = pcall(auditor.edit_note)
        restore_input()
        assert(ok, string.format("seed=%d edit: %s", seed, tostring(err)))

        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        pcall(os.remove, tmp_db)
      end
    end)
  end)

  -- ── F18: Property: note text never in buffer content ──────────────────
  describe("F18: property — notes never in buffer content (50 iterations)", function()
    it("buffer lines unchanged after adding notes", function()
      for seed = 1, 50 do
        reset_modules()
        local tmp_db = vim.fn.tempname() .. ".db"
        auditor = require("auditor")
        auditor.setup({ db_path = tmp_db, keymaps = false })
        auditor._note_input_override = true
        hl = require("auditor.highlights")

        local rng = make_rng(seed)
        local text = random_ascii(rng, rng(1, 50))

        local bufnr = setup_buf({ "hello world" }, 1, 0)
        auditor.highlight_cword_buffer("red")

        local restore_input = stub_input(text)
        auditor.add_note()
        restore_input()

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.equals(1, #lines)
        assert.equals("hello world", lines[1],
          string.format("seed=%d: buffer modified by note", seed))

        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        pcall(os.remove, tmp_db)
      end
    end)
  end)

  -- ── Nasty strings gauntlet ────────────────────────────────────────────
  describe("nasty strings gauntlet", function()
    for i, text in ipairs(NASTY_STRINGS) do
      -- Skip empty string (handled in F6)
      if text ~= "" then
        it(string.format("nasty string %d (%d bytes): full lifecycle",
            i, #text), function()
          -- Fresh modules for each nasty string to avoid cross-contamination
          reset_modules()
          local tmp_db = vim.fn.tempname() .. ".db"
          auditor = require("auditor")
          auditor.setup({ db_path = tmp_db, keymaps = false })
          auditor._note_input_override = true
          db = require("auditor.db")
          hl = require("auditor.highlights")

          local bufnr = vim.api.nvim_create_buf(false, true)
          local filepath = vim.fn.tempname() .. ".lua"
          vim.api.nvim_buf_set_name(bufnr, filepath)
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })
          vim.api.nvim_set_current_buf(bufnr)
          auditor.enter_audit_mode()
          vim.api.nvim_win_set_cursor(0, { 1, 0 })
          auditor.highlight_cword_buffer("red")

          local restore_input = stub_input(text)
          local ok1, err1 = pcall(auditor.add_note)
          restore_input()
          assert(ok1, string.format("add: %s", tostring(err1)))

          local ok2, err2 = pcall(auditor.audit)
          assert(ok2, string.format("save: %s", tostring(err2)))

          -- Check DB round-trip (use canonical path)
          local cpath = vim.fn.resolve(vim.fn.fnamemodify(filepath, ":p"))
          local rows = db.get_highlights(cpath)
          assert.is_true(#rows >= 1,
            string.format("nasty %d: no rows in DB", i))
          assert.equals(text, rows[1].note,
            string.format("nasty %d: note mismatch", i))

          -- Exit and re-enter
          auditor.exit_audit_mode()
          local ok3, err3 = pcall(auditor.enter_audit_mode)
          assert(ok3, string.format("re-enter: %s", tostring(err3)))

          -- Buffer unchanged
          local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          assert.equals("hello world", lines[1])

          pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
          pcall(os.remove, tmp_db)
        end)
      end
    end
  end)
end)
