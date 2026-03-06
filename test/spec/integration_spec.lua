-- test/spec/integration_spec.lua
-- End-to-end tests for the full auditor.nvim plugin lifecycle:
--   setup → enter_audit_mode → highlight_cword_buffer / highlight_cword → audit → load_for_buffer → clear_buffer

local function reset_modules()
  for _, m in ipairs({ "auditor", "auditor.init", "auditor.db", "auditor.highlights", "auditor.ts" }) do
    package.loaded[m] = nil
  end
end

describe("auditor (integration)", function()
  local auditor, db, hl
  local tmp_db

  before_each(function()
    reset_modules()
    tmp_db = vim.fn.tempname() .. ".db"
    auditor = require("auditor")
    auditor.setup({ db_path = tmp_db, keymaps = false })
    db = require("auditor.db")
    hl = require("auditor.highlights")
  end)

  after_each(function()
    pcall(os.remove, tmp_db)
  end)

  -- ── commands ────────────────────────────────────────────────────────────────

  describe("setup()", function()
    it("registers all user commands", function()
      assert.equals(2, vim.fn.exists(":EnterAuditMode"))
      assert.equals(2, vim.fn.exists(":ExitAuditMode"))
      assert.equals(2, vim.fn.exists(":AuditToggle"))
      assert.equals(2, vim.fn.exists(":AuditUndo"))
      assert.equals(2, vim.fn.exists(":AuditSave"))
      assert.equals(2, vim.fn.exists(":AuditClear"))
      assert.equals(2, vim.fn.exists(":AuditRed"))
      assert.equals(2, vim.fn.exists(":AuditBlue"))
      assert.equals(2, vim.fn.exists(":AuditHalf"))
      assert.equals(2, vim.fn.exists(":AuditMark"))
      assert.equals(2, vim.fn.exists(":AuditWordRed"))
      assert.equals(2, vim.fn.exists(":AuditWordBlue"))
      assert.equals(2, vim.fn.exists(":AuditWordHalf"))
      assert.equals(2, vim.fn.exists(":AuditWordMark"))
    end)
  end)

  -- ── per-buffer lifecycle ─────────────────────────────────────────────────────

  describe("highlight_cword_buffer → audit → load_for_buffer", function()
    local bufnr, filepath

    before_each(function()
      bufnr = vim.api.nvim_create_buf(false, true)
      filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(bufnr)
      auditor.enter_audit_mode()
    end)

    after_each(function()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      pcall(os.remove, filepath)
    end)

    it("does NOT write to DB until :AuditSave is called", function()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      assert.same({}, db.get_highlights(filepath))
    end)

    it("applies extmarks to the buffer immediately", function()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, {})
      assert.is_true(#marks >= 1)
    end)

    it("persists highlights to SQLite after :AuditSave", function()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      auditor.audit()

      local rows = db.get_highlights(filepath)
      assert.is_true(#rows >= 1)
      assert.equals("red", rows[1].color)
    end)

    it(":AuditSave clears the pending queue (second :AuditSave saves nothing new)", function()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      auditor.audit()
      local count_after_first = #db.get_highlights(filepath)

      auditor.audit() -- nothing pending
      assert.equals(count_after_first, #db.get_highlights(filepath))
    end)

    it("reloads saved highlights from DB via load_for_buffer", function()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("blue")
      auditor.audit()

      -- Wipe all extmarks, then reload
      vim.api.nvim_buf_clear_namespace(bufnr, hl.ns, 0, -1)
      assert.same({}, vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, {}))

      auditor.load_for_buffer(bufnr)
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, {})
      assert.is_true(#marks >= 1)
    end)

    it("half color creates per-character gradient", function()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("half")
      auditor.audit()

      local rows = db.get_highlights(filepath)
      assert.equals("half", rows[1].color)
      -- "hello" (5 chars): 1 primary + 4 overlays = 5 raw extmarks
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, { details = true })
      assert.equals(5, #marks)
      -- All should be AuditorGrad* groups
      for _, m in ipairs(marks) do
        assert.is_truthy(m[4].hl_group:match("^AuditorGrad"))
      end
      -- 1 logical mark
      assert.equals(1, #hl.collect_extmarks(bufnr))
    end)
  end)

  -- ── clear_buffer ─────────────────────────────────────────────────────────────

  describe("clear_buffer()", function()
    local bufnr, filepath

    before_each(function()
      bufnr = vim.api.nvim_create_buf(false, true)
      filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "foo bar" })
      vim.api.nvim_set_current_buf(bufnr)
      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- "foo"
      auditor.highlight_cword_buffer("red")
      auditor.audit()
    end)

    after_each(function()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      pcall(os.remove, filepath)
    end)

    it("removes all extmarks from the buffer", function()
      auditor.clear_buffer()
      assert.same({}, vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, {}))
    end)

    it("removes all DB rows for the buffer's filepath", function()
      auditor.clear_buffer()
      assert.same({}, db.get_highlights(filepath))
    end)

    it("does not affect highlights in other buffers", function()
      -- Save a second file's highlights directly
      db.save_words("/other.lua", { { line = 0, col_start = 0, col_end = 3 } }, "blue")

      auditor.clear_buffer()

      assert.equals(1, #db.get_highlights("/other.lua"))
    end)
  end)

  -- ── highlight_cword ───────────────────────────────────────────────────────────

  describe("highlight_cword()", function()
    local bufnr, filepath

    before_each(function()
      bufnr = vim.api.nvim_create_buf(false, true)
      filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(bufnr)
      auditor.enter_audit_mode()
    end)

    after_each(function()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      pcall(os.remove, filepath)
    end)

    local function set_cursor(row, col)
      vim.api.nvim_win_set_cursor(0, { row, col })
    end

    it("applies an extmark for the word under cursor", function()
      set_cursor(1, 2) -- col 2 = inside "hello"
      auditor.highlight_cword("red")

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, {})
      assert.is_true(#marks >= 1)
    end)

    it("highlights exactly the word boundaries", function()
      set_cursor(1, 0) -- start of "hello"
      auditor.highlight_cword("red")

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, { details = true })
      assert.equals(1, #marks) -- "hello" appears once in "hello world"
      local m = marks[1]
      assert.equals(0, m[2]) -- row 0
      assert.equals(0, m[3]) -- col_start 0
      assert.equals(5, m[4].end_col) -- col_end 5 ("hello")
    end)

    it("highlights the correct word when cursor is mid-word", function()
      set_cursor(1, 8) -- col 8 = inside "world"
      auditor.highlight_cword("blue")

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, { details = true })
      assert.equals(1, #marks) -- "world" appears once
      assert.equals(6, marks[1][3]) -- col_start
      assert.equals(11, marks[1][4].end_col) -- col_end
    end)

    it("adds one pending batch for the occurrence set", function()
      set_cursor(1, 0)
      auditor.highlight_cword("red")

      assert.not_nil(auditor._pending[bufnr])
      assert.equals(1, #auditor._pending[bufnr])
      assert.equals("red", auditor._pending[bufnr][1].color)
    end)

    it("persists to DB after :AuditSave", function()
      set_cursor(1, 0) -- "hello"
      auditor.highlight_cword("red")
      auditor.audit()

      local rows = db.get_highlights(filepath)
      assert.equals(1, #rows) -- "hello" appears once
      assert.equals(0, rows[1].col_start)
      assert.equals(5, rows[1].col_end)
      assert.equals("red", rows[1].color)
    end)

    it("does nothing when cursor is on whitespace", function()
      set_cursor(1, 5) -- the space between "hello" and "world"
      auditor.highlight_cword("red")

      assert.same({}, vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, {}))
    end)

    it("works on the last character of a word", function()
      set_cursor(1, 4) -- the 'o' at the end of "hello"
      auditor.highlight_cword("blue")

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, { details = true })
      assert.equals(1, #marks)
      assert.equals(0, marks[1][3]) -- col_start
      assert.equals(5, marks[1][4].end_col) -- col_end
    end)

    it("registers AuditWordRed / AuditWordBlue / AuditWordHalf / AuditWordMark commands", function()
      assert.equals(2, vim.fn.exists(":AuditWordRed"))
      assert.equals(2, vim.fn.exists(":AuditWordBlue"))
      assert.equals(2, vim.fn.exists(":AuditWordHalf"))
      assert.equals(2, vim.fn.exists(":AuditWordMark"))
    end)
  end)

  -- ── highlight_cword — all occurrences in scope ────────────────────────────

  describe("highlight_cword() — all occurrences in scope", function()
    local bufnr, filepath

    after_each(function()
      if bufnr then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        bufnr = nil
      end
      if filepath then
        pcall(os.remove, filepath)
        filepath = nil
      end
    end)

    local function setup_buf(lines)
      bufnr = vim.api.nvim_create_buf(false, true)
      filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.api.nvim_set_current_buf(bufnr)
      auditor.enter_audit_mode()
    end

    it("highlights all occurrences of a repeated word in a single-line buffer", function()
      setup_buf({ "req + req + req" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- on first "req"
      auditor.highlight_cword("red")

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, { details = true })
      assert.equals(3, #marks)
      assert.equals(0, marks[1][3])
      assert.equals(3, marks[1][4].end_col)
      assert.equals(6, marks[2][3])
      assert.equals(9, marks[2][4].end_col)
      assert.equals(12, marks[3][3])
      assert.equals(15, marks[3][4].end_col)
    end)

    it("does not match partial-word occurrences (req != request)", function()
      setup_buf({ "req request req" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- on "req"
      auditor.highlight_cword("blue")

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, { details = true })
      -- "req" appears at col 0 and col 12; "request" at col 4 must NOT be matched
      assert.equals(2, #marks)
      assert.equals(0, marks[1][3])
      assert.equals(12, marks[2][3])
    end)

    it("finds occurrences across multiple lines in buffer scope", function()
      setup_buf({
        "local req = {}",
        "req.method = 'GET'",
        "return req",
      })
      vim.api.nvim_win_set_cursor(0, { 1, 6 }) -- on "req" in line 1
      auditor.highlight_cword("red")

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, {})
      -- "req" appears on line 0 (col 6), line 1 (col 0), line 2 (col 7)
      assert.equals(3, #marks)
    end)

    it("persists all occurrences to DB after :AuditSave", function()
      setup_buf({ "x = foo + foo + foo" })
      vim.api.nvim_win_set_cursor(0, { 1, 4 }) -- on "foo"
      auditor.highlight_cword("red")
      auditor.audit()

      local rows = db.get_highlights(filepath)
      assert.equals(3, #rows)
      local colors = {}
      for _, r in ipairs(rows) do
        colors[r.color] = (colors[r.color] or 0) + 1
      end
      assert.equals(3, colors["red"])
    end)

    it("word_index is sequential across all occurrences in a batch", function()
      setup_buf({ "a a a" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword("half")
      auditor.audit()

      local rows = db.get_highlights(filepath)
      assert.equals(3, #rows)
      table.sort(rows, function(ra, rb)
        return ra.col_start < rb.col_start
      end)
      assert.equals(1, rows[1].word_index)
      assert.equals(2, rows[2].word_index)
      assert.equals(3, rows[3].word_index)
    end)
  end)
end)
