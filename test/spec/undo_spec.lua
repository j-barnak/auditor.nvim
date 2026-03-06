-- test/spec/undo_spec.lua
-- Exhaustive tests for undo_at_cursor() and db.remove_highlight().
--
-- Coverage:
--   DB unit tests    — remove_highlight: exact match, isolation, no-op
--   Unit tests       — undo_at_cursor: guards, edge cases, notification
--   Integration      — mark → undo, save → undo, multi-word, round-trips
--   Property-based   — random mark/undo sequences, extmark count invariants
--   Fuzz             — random interleaving of all ops never crashes

local function reset_modules()
  for _, m in ipairs({ "auditor", "auditor.init", "auditor.db", "auditor.highlights", "auditor.ts" }) do
    package.loaded[m] = nil
  end
end

-- Deterministic PRNG (LCG)
local function make_rng(seed)
  local s = math.abs(seed) + 1
  return function(lo, hi)
    s = (s * 1664525 + 1013904223) % (2 ^ 32)
    return lo + (math.floor(s * (hi - lo + 1) / (2 ^ 32)))
  end
end

local function property(desc, n, fn)
  for seed = 1, n do
    local rng = make_rng(seed)
    local ok, err = pcall(fn, rng, seed)
    if not ok then
      error(string.format("[undo] '%s' failed at seed=%d:\n%s", desc, seed, tostring(err)), 2)
    end
  end
end

local function extmark_count(bufnr, ns)
  return #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
end

local function get_extmarks(bufnr, ns)
  return vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
end

local function make_named_buf(text)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local filepath = vim.fn.tempname() .. ".lua"
  vim.api.nvim_buf_set_name(bufnr, filepath)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, type(text) == "table" and text or { text })
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr, filepath
end

-- ═══════════════════════════════════════════════════════════════════════════
-- DB: remove_highlight
-- ═══════════════════════════════════════════════════════════════════════════

describe("db.remove_highlight", function()
  local db, tmp_path

  before_each(function()
    package.loaded["auditor.db"] = nil
    db = require("auditor.db")
    tmp_path = vim.fn.tempname() .. ".db"
    db.setup(tmp_path)
  end)

  after_each(function()
    pcall(os.remove, tmp_path)
  end)

  it("removes a row by exact position", function()
    db.save_words("/f.lua", {
      { line = 0, col_start = 0, col_end = 5 },
      { line = 0, col_start = 6, col_end = 11 },
    }, "red")
    assert.equals(2, #db.get_highlights("/f.lua"))

    db.remove_highlight("/f.lua", 0, 0, 5)
    local rows = db.get_highlights("/f.lua")
    assert.equals(1, #rows)
    assert.equals(6, rows[1].col_start)
  end)

  it("does not affect other positions in the same file", function()
    db.save_words("/f.lua", {
      { line = 0, col_start = 0, col_end = 3 },
      { line = 1, col_start = 0, col_end = 3 },
      { line = 2, col_start = 0, col_end = 3 },
    }, "blue")

    db.remove_highlight("/f.lua", 1, 0, 3)
    local rows = db.get_highlights("/f.lua")
    assert.equals(2, #rows)
    local lines = {}
    for _, r in ipairs(rows) do
      lines[r.line] = true
    end
    assert.truthy(lines[0])
    assert.truthy(lines[2])
    assert.is_nil(lines[1])
  end)

  it("does not affect other files", function()
    db.save_words("/a.lua", { { line = 0, col_start = 0, col_end = 5 } }, "red")
    db.save_words("/b.lua", { { line = 0, col_start = 0, col_end = 5 } }, "blue")

    db.remove_highlight("/a.lua", 0, 0, 5)
    assert.same({}, db.get_highlights("/a.lua"))
    assert.equals(1, #db.get_highlights("/b.lua"))
  end)

  it("is a no-op when no matching row exists", function()
    db.save_words("/f.lua", { { line = 0, col_start = 0, col_end = 5 } }, "red")
    db.remove_highlight("/f.lua", 99, 0, 5) -- non-existent line
    assert.equals(1, #db.get_highlights("/f.lua"))
  end)

  it("does not error when called on empty DB", function()
    assert.has_no.errors(function()
      db.remove_highlight("/nonexistent.lua", 0, 0, 5)
    end)
  end)

  it("removes all duplicate rows at the same position", function()
    db.save_words("/dup.lua", { { line = 0, col_start = 0, col_end = 5 } }, "red")
    db.save_words("/dup.lua", { { line = 0, col_start = 0, col_end = 5 } }, "blue")
    assert.equals(2, #db.get_highlights("/dup.lua"))

    db.remove_highlight("/dup.lua", 0, 0, 5)
    assert.same({}, db.get_highlights("/dup.lua"))
  end)

  it("partial position mismatch does not remove", function()
    db.save_words("/f.lua", { { line = 0, col_start = 0, col_end = 5 } }, "red")
    -- Wrong col_end
    db.remove_highlight("/f.lua", 0, 0, 4)
    assert.equals(1, #db.get_highlights("/f.lua"))
    -- Wrong col_start
    db.remove_highlight("/f.lua", 0, 1, 5)
    assert.equals(1, #db.get_highlights("/f.lua"))
    -- Wrong line
    db.remove_highlight("/f.lua", 1, 0, 5)
    assert.equals(1, #db.get_highlights("/f.lua"))
  end)

  it("survives DB reopen", function()
    db.save_words("/f.lua", {
      { line = 0, col_start = 0, col_end = 5 },
      { line = 0, col_start = 6, col_end = 11 },
    }, "red")
    db.remove_highlight("/f.lua", 0, 0, 5)

    -- Reopen
    package.loaded["auditor.db"] = nil
    local db2 = require("auditor.db")
    db2.setup(tmp_path)
    local rows = db2.get_highlights("/f.lua")
    assert.equals(1, #rows)
    assert.equals(6, rows[1].col_start)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- UNIT TESTS: undo_at_cursor
-- ═══════════════════════════════════════════════════════════════════════════

describe("undo: unit", function()
  local auditor, hl, tmp_db

  before_each(function()
    reset_modules()
    tmp_db = vim.fn.tempname() .. ".db"
    auditor = require("auditor")
    auditor.setup({ db_path = tmp_db, keymaps = false })
    hl = require("auditor.highlights")
  end)

  after_each(function()
    pcall(os.remove, tmp_db)
  end)

  -- ── guards ──────────────────────────────────────────────────────────────

  describe("guards", function()
    it("is blocked outside audit mode", function()
      local b, p = make_named_buf("hello world")
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.undo_at_cursor()
      -- No crash, no change
      assert.equals(0, extmark_count(b, hl.ns))
      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)

    it("does nothing when cursor is on whitespace", function()
      local b, p = make_named_buf("hello world")
      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      assert.equals(1, extmark_count(b, hl.ns))

      vim.api.nvim_win_set_cursor(0, { 1, 5 }) -- space
      auditor.undo_at_cursor()
      assert.equals(1, extmark_count(b, hl.ns)) -- unchanged
      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)

    it("does nothing when word has no highlight", function()
      local b, p = make_named_buf("hello world")
      auditor.enter_audit_mode()
      -- No marks applied; try to undo on "hello"
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.undo_at_cursor()
      assert.equals(0, extmark_count(b, hl.ns))
      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)

  -- ── command registration ──────────────────────────────────────────────

  describe("command registration", function()
    it("registers :AuditUndo", function()
      assert.equals(2, vim.fn.exists(":AuditUndo"))
    end)

    it(":AuditUndo is blocked outside audit mode via vim.cmd", function()
      local b, p = make_named_buf("hello world")
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.cmd("AuditUndo") -- should not error
      assert.equals(0, extmark_count(b, hl.ns))
      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- INTEGRATION TESTS
-- ═══════════════════════════════════════════════════════════════════════════

describe("undo: integration", function()
  local auditor, db, hl, tmp_db

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

  -- ── unsaved mark → undo ───────────────────────────────────────────────

  describe("unsaved mark → undo", function()
    it("removes extmark", function()
      local b, p = make_named_buf("hello world")
      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      assert.equals(1, extmark_count(b, hl.ns))

      auditor.undo_at_cursor()
      assert.equals(0, extmark_count(b, hl.ns))
      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)

    it("clears pending queue", function()
      local b, p = make_named_buf("hello world")
      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      assert.equals(1, #auditor._pending[b])

      auditor.undo_at_cursor()
      -- Pending should be empty (entry removed since it had only 1 word)
      assert.equals(0, #auditor._pending[b])
      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)

    it("does not write to DB", function()
      local b, p = make_named_buf("hello world")
      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      auditor.undo_at_cursor()
      assert.same({}, db.get_highlights(p))
      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)

    it("save after undo saves nothing new", function()
      local b, p = make_named_buf("hello world")
      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      auditor.undo_at_cursor()
      auditor.audit()
      assert.same({}, db.get_highlights(p))
      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)

  -- ── saved mark → undo ─────────────────────────────────────────────────

  describe("saved mark → undo", function()
    it("removes extmark and DB row", function()
      local b, p = make_named_buf("hello world")
      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      auditor.audit()
      assert.equals(1, #db.get_highlights(p))

      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.undo_at_cursor()
      assert.equals(0, extmark_count(b, hl.ns))
      assert.same({}, db.get_highlights(p))
      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)

    it("DB removal survives module reload", function()
      local b, p = make_named_buf("hello world")
      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("blue")
      auditor.audit()
      assert.equals(1, #db.get_highlights(p))

      auditor.undo_at_cursor()
      assert.same({}, db.get_highlights(p))

      -- Simulate restart
      reset_modules()
      auditor = require("auditor")
      auditor.setup({ db_path = tmp_db, keymaps = false })
      db = require("auditor.db")
      hl = require("auditor.highlights")

      assert.same({}, db.get_highlights(p))
      auditor.enter_audit_mode()
      assert.equals(0, extmark_count(b, hl.ns))

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)

  -- ── multi-word undo ───────────────────────────────────────────────────

  describe("multi-word undo", function()
    it("undo one word leaves others intact", function()
      local b, p = make_named_buf("aaa bbb ccc")
      auditor.enter_audit_mode()

      -- Mark all three words
      vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- aaa
      auditor.highlight_cword_buffer("red")
      vim.api.nvim_win_set_cursor(0, { 1, 4 }) -- bbb
      auditor.highlight_cword_buffer("blue")
      vim.api.nvim_win_set_cursor(0, { 1, 8 }) -- ccc
      auditor.highlight_cword_buffer("half")
      -- "ccc" (3 chars) → 3 raw extmarks (primary + 2 overlays); + "aaa" + "bbb" = 5 total
      assert.equals(5, extmark_count(b, hl.ns))

      -- Undo only "bbb"
      vim.api.nvim_win_set_cursor(0, { 1, 4 })
      auditor.undo_at_cursor()
      -- "aaa" (1 extmark) + "ccc" half (3 extmarks) = 4
      assert.equals(4, extmark_count(b, hl.ns))

      -- Verify remaining extmarks are "aaa" and "ccc"
      local marks = get_extmarks(b, hl.ns)
      local positions = {}
      for _, m in ipairs(marks) do
        table.insert(positions, { col_start = m[3], col_end = m[4].end_col })
      end
      table.sort(positions, function(a, b2)
        return a.col_start < b2.col_start
      end)
      assert.equals(0, positions[1].col_start) -- aaa
      assert.equals(3, positions[1].col_end)
      assert.equals(8, positions[2].col_start) -- ccc
      assert.equals(11, positions[2].col_end)

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)

    it("undo one of many saved words removes only that DB row", function()
      local b, p = make_named_buf("aaa bbb ccc")
      auditor.enter_audit_mode()

      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      vim.api.nvim_win_set_cursor(0, { 1, 4 })
      auditor.highlight_cword_buffer("red")
      vim.api.nvim_win_set_cursor(0, { 1, 8 })
      auditor.highlight_cword_buffer("red")
      auditor.audit()
      assert.equals(3, #db.get_highlights(p))

      -- Undo "aaa"
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.undo_at_cursor()
      assert.equals(2, #db.get_highlights(p))

      -- Verify remaining rows
      local rows = db.get_highlights(p)
      local col_starts = {}
      for _, r in ipairs(rows) do
        col_starts[r.col_start] = true
      end
      assert.is_nil(col_starts[0]) -- aaa removed
      assert.truthy(col_starts[4]) -- bbb remains
      assert.truthy(col_starts[8]) -- ccc remains

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)

    it("undo all words one by one leaves clean state", function()
      local b, p = make_named_buf("aaa bbb")
      auditor.enter_audit_mode()

      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      vim.api.nvim_win_set_cursor(0, { 1, 4 })
      auditor.highlight_cword_buffer("blue")
      auditor.audit()
      assert.equals(2, #db.get_highlights(p))

      -- Undo both
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.undo_at_cursor()
      vim.api.nvim_win_set_cursor(0, { 1, 4 })
      auditor.undo_at_cursor()

      assert.equals(0, extmark_count(b, hl.ns))
      assert.same({}, db.get_highlights(p))

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)

  -- ── word_red (multi-occurrence) + undo ────────────────────────────────

  describe("word_red + undo", function()
    it("undo one occurrence of a multi-occurrence highlight", function()
      local b, p = make_named_buf("foo bar foo baz foo")
      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- first "foo"
      auditor.highlight_cword("red")
      -- 3 occurrences of "foo"
      assert.equals(3, extmark_count(b, hl.ns))

      -- Undo only the first occurrence (col 0)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.undo_at_cursor()
      assert.equals(2, extmark_count(b, hl.ns))

      -- The remaining extmarks should be at col 8 and col 16
      local marks = get_extmarks(b, hl.ns)
      local cols = {}
      for _, m in ipairs(marks) do
        table.insert(cols, m[3])
      end
      table.sort(cols)
      assert.equals(8, cols[1])
      assert.equals(16, cols[2])

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)

  -- ── undo across enter/exit cycles ─────────────────────────────────────

  describe("undo persistence across mode transitions", function()
    it("undo + exit + enter: highlight stays removed", function()
      local b, p = make_named_buf("hello world")
      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      auditor.audit()

      auditor.undo_at_cursor()
      assert.equals(0, extmark_count(b, hl.ns))
      assert.same({}, db.get_highlights(p))

      -- Cycle
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      -- Still gone
      assert.equals(0, extmark_count(b, hl.ns))
      assert.same({}, db.get_highlights(p))

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)

    it("unsaved undo + exit + enter: pending is cleaned", function()
      local b, p = make_named_buf("hello world")
      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      auditor.undo_at_cursor()

      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      assert.equals(0, extmark_count(b, hl.ns))
      assert.equals(0, #(auditor._pending[b] or {}))

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)

  -- ── undo via vim.cmd ──────────────────────────────────────────────────

  describe(":AuditUndo via vim.cmd", function()
    it("works in audit mode", function()
      local b, p = make_named_buf("hello world")
      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      assert.equals(1, extmark_count(b, hl.ns))

      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.cmd("AuditUndo")
      assert.equals(0, extmark_count(b, hl.ns))

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)

    it("full lifecycle via commands", function()
      local b, p = make_named_buf("hello world")
      vim.cmd("EnterAuditMode")
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.cmd("AuditRed")
      vim.cmd("AuditSave")
      assert.equals(1, #db.get_highlights(p))

      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.cmd("AuditUndo")
      assert.equals(0, extmark_count(b, hl.ns))
      assert.same({}, db.get_highlights(p))

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)

  -- ── multi-line ────────────────────────────────────────────────────────

  describe("multi-line", function()
    it("undo on line 2 does not affect line 1 highlights", function()
      local b, p = make_named_buf({ "hello world", "hello again" })
      auditor.enter_audit_mode()

      -- Mark "hello" on line 1
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      -- Mark "hello" on line 2
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      auditor.highlight_cword_buffer("blue")
      assert.equals(2, extmark_count(b, hl.ns))

      -- Undo only line 2
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      auditor.undo_at_cursor()
      assert.equals(1, extmark_count(b, hl.ns))

      -- Remaining extmark is on line 0
      local marks = get_extmarks(b, hl.ns)
      assert.equals(0, marks[1][2]) -- row 0
      assert.equals("AuditorRed", marks[1][4].hl_group)

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)

  -- ── undo idempotency ──────────────────────────────────────────────────

  describe("idempotency", function()
    it("second undo on same word is a no-op (no highlight found)", function()
      local b, p = make_named_buf("hello world")
      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      auditor.undo_at_cursor()
      assert.equals(0, extmark_count(b, hl.ns))

      -- Second undo — should do nothing, not error
      assert.has_no.errors(function()
        auditor.undo_at_cursor()
      end)
      assert.equals(0, extmark_count(b, hl.ns))

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)

  -- ── undo + re-mark ────────────────────────────────────────────────────

  describe("undo + re-mark", function()
    it("can re-mark after undoing", function()
      local b, p = make_named_buf("hello world")
      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      auditor.undo_at_cursor()
      assert.equals(0, extmark_count(b, hl.ns))

      -- Re-mark as blue
      auditor.highlight_cword_buffer("blue")
      assert.equals(1, extmark_count(b, hl.ns))
      local marks = get_extmarks(b, hl.ns)
      assert.equals("AuditorBlue", marks[1][4].hl_group)

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)

    it("re-marked highlight saves correctly after undo", function()
      local b, p = make_named_buf("hello world")
      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      auditor.audit()
      auditor.undo_at_cursor()
      assert.same({}, db.get_highlights(p))

      -- Re-mark and save
      auditor.highlight_cword_buffer("blue")
      auditor.audit()
      local rows = db.get_highlights(p)
      assert.equals(1, #rows)
      assert.equals("blue", rows[1].color)

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- PROPERTY-BASED
-- ═══════════════════════════════════════════════════════════════════════════

describe("undo: property-based", function()
  local auditor, db, hl, tmp_db

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

  it("P1: mark + undo always yields 0 extmarks", function()
    property("mark+undo=0", 200, function(rng)
      local b = vim.api.nvim_create_buf(false, true)
      local p = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(b, p)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(b)

      auditor.enter_audit_mode()
      local colors = { "red", "blue", "half" }
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer(colors[rng(1, 3)])
      assert(extmark_count(b, hl.ns) == 1)

      auditor.undo_at_cursor()
      assert(extmark_count(b, hl.ns) == 0, "extmarks remain after undo")

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)

  it("P2: mark + save + undo always yields 0 DB rows", function()
    property("mark+save+undo=0 DB", 200, function(rng)
      local b = vim.api.nvim_create_buf(false, true)
      local p = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(b, p)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(b)

      auditor.enter_audit_mode()
      local colors = { "red", "blue", "half" }
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer(colors[rng(1, 3)])
      auditor.audit()
      assert(#db.get_highlights(p) == 1)

      auditor.undo_at_cursor()
      assert(#db.get_highlights(p) == 0, "DB rows remain after undo")

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)

  it("P3: mark N words + undo 1 → N-1 extmarks", function()
    property("undo decrements count", 200, function(rng)
      local words = { "aaa", "bbb", "ccc", "ddd" }
      local n = rng(2, 4)
      local parts = {}
      for i = 1, n do
        parts[i] = words[i]
      end
      local line = table.concat(parts, " ")

      local b = vim.api.nvim_create_buf(false, true)
      local p = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(b, p)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { line })
      vim.api.nvim_set_current_buf(b)

      auditor.enter_audit_mode()
      local col = 0
      for i = 1, n do
        vim.api.nvim_win_set_cursor(0, { 1, col })
        auditor.highlight_cword_buffer("red")
        col = col + #words[i] + 1
      end
      assert(extmark_count(b, hl.ns) == n)

      -- Undo one random word
      local undo_idx = rng(1, n)
      local undo_col = 0
      for i = 1, undo_idx - 1 do
        undo_col = undo_col + #words[i] + 1
      end
      vim.api.nvim_win_set_cursor(0, { 1, undo_col })
      auditor.undo_at_cursor()

      assert(
        extmark_count(b, hl.ns) == n - 1,
        string.format("expected %d extmarks, got %d", n - 1, extmark_count(b, hl.ns))
      )

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)

  it("P4: undo on unhighlighted word is always a no-op", function()
    property("undo no-op", 200, function(rng)
      local b = vim.api.nvim_create_buf(false, true)
      local p = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(b, p)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "aaa bbb ccc" })
      vim.api.nvim_set_current_buf(b)

      auditor.enter_audit_mode()
      -- Only highlight "aaa"
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")

      -- Try undo on "bbb" or "ccc" (unhighlighted)
      local cols = { 4, 8 }
      vim.api.nvim_win_set_cursor(0, { 1, cols[rng(1, 2)] })
      auditor.undo_at_cursor()

      -- "aaa" highlight should still be there
      assert(extmark_count(b, hl.ns) == 1, "undo on unhighlighted word removed a mark")

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)

  it("P5: undo is blocked in OFF mode (never changes state)", function()
    property("undo blocked in OFF", 200, function(rng)
      local b = vim.api.nvim_create_buf(false, true)
      local p = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(b, p)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(b)

      -- Seed DB data
      db.save_words(p, { { line = 0, col_start = 0, col_end = 5 } }, "red")
      local db_count = #db.get_highlights(p)

      auditor.exit_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, rng(0, 10) })
      auditor.undo_at_cursor()

      assert(#db.get_highlights(p) == db_count, "DB changed by blocked undo")

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)

  it("P6: mark + undo + re-mark + save: DB has exactly 1 row", function()
    property("undo+remark round-trip", 200, function(rng)
      local b = vim.api.nvim_create_buf(false, true)
      local p = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(b, p)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(b)

      auditor.enter_audit_mode()
      local colors = { "red", "blue", "half" }
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer(colors[rng(1, 3)])
      auditor.undo_at_cursor()
      auditor.highlight_cword_buffer(colors[rng(1, 3)])
      auditor.audit()

      assert(
        #db.get_highlights(p) == 1,
        string.format("expected 1 DB row, got %d", #db.get_highlights(p))
      )

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- FUZZ: random ops never crash
-- ═══════════════════════════════════════════════════════════════════════════

describe("undo: fuzz", function()
  local auditor, hl, tmp_db

  before_each(function()
    reset_modules()
    tmp_db = vim.fn.tempname() .. ".db"
    auditor = require("auditor")
    auditor.setup({ db_path = tmp_db, keymaps = false })
    hl = require("auditor.highlights")
  end)

  after_each(function()
    pcall(os.remove, tmp_db)
  end)

  it("F1: random mix of enter/exit/toggle/mark/undo/save/clear never errors", function()
    property("no crashes", 300, function(rng)
      local b = vim.api.nvim_create_buf(false, true)
      local p = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(b, p)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "alpha beta gamma" })
      vim.api.nvim_set_current_buf(b)

      local colors = { "red", "blue", "half" }
      for _ = 1, rng(10, 40) do
        local op = rng(1, 9)
        if op == 1 then
          auditor.enter_audit_mode()
        elseif op == 2 then
          auditor.exit_audit_mode()
        elseif op == 3 then
          auditor.toggle_audit_mode()
        elseif op == 4 then
          vim.api.nvim_win_set_cursor(0, { 1, rng(0, 15) })
          auditor.highlight_cword_buffer(colors[rng(1, 3)])
        elseif op == 5 then
          vim.api.nvim_win_set_cursor(0, { 1, rng(0, 15) })
          auditor.highlight_cword(colors[rng(1, 3)])
        elseif op == 6 then
          auditor.audit()
        elseif op == 7 then
          auditor.clear_buffer()
        elseif op == 8 then
          vim.api.nvim_win_set_cursor(0, { 1, rng(0, 15) })
          auditor.undo_at_cursor()
        else
          -- no-op
          vim.api.nvim_win_set_cursor(0, { 1, rng(0, 15) })
        end
      end

      -- Invariant: extmark count is never negative
      assert(extmark_count(b, hl.ns) >= 0)

      -- Invariant: if OFF, no extmarks
      if not auditor._audit_mode then
        assert(extmark_count(b, hl.ns) == 0)
      end

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)

  it("F2: rapid mark/undo cycles never crash", function()
    property("rapid mark/undo", 200, function(rng)
      local b = vim.api.nvim_create_buf(false, true)
      local p = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(b, p)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(b)

      auditor.enter_audit_mode()
      local colors = { "red", "blue", "half" }
      local n_cycles = rng(5, 30)
      for _ = 1, n_cycles do
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        auditor.highlight_cword_buffer(colors[rng(1, 3)])
        auditor.undo_at_cursor()
      end

      assert(extmark_count(b, hl.ns) == 0, "extmarks remain after all mark/undo cycles")

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)

  it("F3: interleaved mark/save/undo: DB count never negative", function()
    property("DB non-negative", 200, function(rng)
      local b = vim.api.nvim_create_buf(false, true)
      local p = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(b, p)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(b)

      auditor.enter_audit_mode()
      local db = require("auditor.db")
      local colors = { "red", "blue", "half" }

      for _ = 1, rng(5, 20) do
        local op = rng(1, 3)
        if op == 1 then
          vim.api.nvim_win_set_cursor(0, { 1, rng(0, 1) == 0 and 0 or 6 })
          auditor.highlight_cword_buffer(colors[rng(1, 3)])
        elseif op == 2 then
          auditor.audit()
        else
          vim.api.nvim_win_set_cursor(0, { 1, rng(0, 1) == 0 and 0 or 6 })
          auditor.undo_at_cursor()
        end
      end

      assert(#db.get_highlights(p) >= 0, "negative DB count")
      assert(extmark_count(b, hl.ns) >= 0, "negative extmark count")

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- EDGE CASES
-- ═══════════════════════════════════════════════════════════════════════════

describe("undo: edge cases", function()
  local auditor, db, hl, tmp_db

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

  it("undo on scratch buffer (no name) does not error", function()
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello world" })
    vim.api.nvim_set_current_buf(b)

    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    assert.equals(1, extmark_count(b, hl.ns))

    assert.has_no.errors(function()
      auditor.undo_at_cursor()
    end)
    assert.equals(0, extmark_count(b, hl.ns))

    pcall(vim.api.nvim_buf_delete, b, { force = true })
  end)

  it("undo on empty buffer does not error", function()
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "" })
    vim.api.nvim_set_current_buf(b)
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    assert.has_no.errors(function()
      auditor.undo_at_cursor()
    end)
    pcall(vim.api.nvim_buf_delete, b, { force = true })
  end)

  it("undo on single-character word works", function()
    local b, p = make_named_buf("a b c")
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- "a"
    auditor.highlight_cword_buffer("red")
    assert.equals(1, extmark_count(b, hl.ns))

    auditor.undo_at_cursor()
    assert.equals(0, extmark_count(b, hl.ns))

    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)

  it("undo on underscore-containing word works", function()
    local b, p = make_named_buf("my_var = 42")
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- "my_var"
    auditor.highlight_cword_buffer("blue")

    local marks = get_extmarks(b, hl.ns)
    assert.equals(1, #marks)
    assert.equals(0, marks[1][3]) -- col_start
    assert.equals(6, marks[1][4].end_col) -- col_end

    auditor.undo_at_cursor()
    assert.equals(0, extmark_count(b, hl.ns))

    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)

  it("undo on word with digits works", function()
    local b, p = make_named_buf("var123 = 0")
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 3 }) -- inside "var123"
    auditor.highlight_cword_buffer("red")

    local marks = get_extmarks(b, hl.ns)
    assert.equals(0, marks[1][3])
    assert.equals(6, marks[1][4].end_col)

    auditor.undo_at_cursor()
    assert.equals(0, extmark_count(b, hl.ns))

    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)

  it("undo only removes one extmark when word appears multiple times", function()
    -- If the user marked each occurrence separately with highlight_cword_buffer,
    -- undo should only remove the one under the cursor
    local b, p = make_named_buf("foo bar foo")
    auditor.enter_audit_mode()

    -- Mark first "foo"
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    -- Mark second "foo"
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    auditor.highlight_cword_buffer("red")
    assert.equals(2, extmark_count(b, hl.ns))

    -- Undo first "foo" only
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.undo_at_cursor()
    assert.equals(1, extmark_count(b, hl.ns))

    -- Remaining mark is the second "foo"
    local marks = get_extmarks(b, hl.ns)
    assert.equals(8, marks[1][3])

    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)

  it("undo after clear is a no-op (no extmarks to remove)", function()
    local b, p = make_named_buf("hello world")
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    auditor.clear_buffer()

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    assert.has_no.errors(function()
      auditor.undo_at_cursor()
    end)
    assert.equals(0, extmark_count(b, hl.ns))

    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)

  it("undo on DB-loaded highlight (not from pending) works", function()
    local b, p = make_named_buf("hello world")

    -- Seed DB directly (simulate restart)
    db.save_words(p, { { line = 0, col_start = 0, col_end = 5 } }, "red")

    auditor.enter_audit_mode()
    assert.equals(1, extmark_count(b, hl.ns))

    -- Undo the DB-loaded highlight
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.undo_at_cursor()

    assert.equals(0, extmark_count(b, hl.ns))
    assert.same({}, db.get_highlights(p))

    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)
end)
