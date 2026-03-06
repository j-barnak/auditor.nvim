-- test/spec/edit_after_mark_spec.lua
-- Comprehensive tests for editing a buffer after marking/auditing words.
-- Verifies that extmark-tracked positions flow correctly through save, exit,
-- re-enter, and undo operations.
--
-- Coverage:
--   E1  Mark → insert line above → save → DB has shifted line
--   E2  Mark → delete line above → save → DB has shifted line
--   E3  Mark → insert chars before word on same line → save → DB has shifted col
--   E4  Mark → delete chars before word on same line → save → DB has shifted col
--   E5  Mark → delete line containing the word → save → nothing saved
--   E6  Mark → replace line with shorter text → save → handle gracefully
--   E7  Mark → edit → exit → enter → pending restored at updated positions
--   E8  Mark → edit → undo at cursor → extmark found, pending cleaned
--   E9  Mark → edit → save → exit → enter → DB correct → restored
--   E10 Mark multiple → edit → some survive → save → only survivors in DB
--   E11 Mark → edit → exit → edit more → enter → graceful stale handling
--   E12 Mark → insert within word → save → DB has expanded range
--   E13 Pending stores extmark_ids after marking
--   E14 sync_pending_from_extmarks updates positions
--   E15 undo_at_cursor cleans pending by extmark ID after edit
--   E16 highlight_cword (function scope) → edit → save → correct positions
--   E17 Property: random edits between mark and save → no crash

local function reset_modules()
  for _, m in ipairs({ "auditor", "auditor.init", "auditor.db", "auditor.highlights", "auditor.ts" }) do
    package.loaded[m] = nil
  end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- Helpers
-- ═══════════════════════════════════════════════════════════════════════════════

local function make_buf(lines, name)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local filepath = name or (vim.fn.tempname() .. ".lua")
  vim.api.nvim_buf_set_name(bufnr, filepath)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr, filepath
end

local function get_marks(bufnr, ns)
  return vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
end

local function mark_positions(marks)
  local out = {}
  for _, m in ipairs(marks) do
    table.insert(out, { line = m[2], col_start = m[3], col_end = m[4].end_col })
  end
  table.sort(out, function(a, b)
    if a.line ~= b.line then
      return a.line < b.line
    end
    return a.col_start < b.col_start
  end)
  return out
end

-- deterministic PRNG
local function make_rng(seed)
  local s = math.abs(seed) + 1
  return function(lo, hi)
    s = (s * 1664525 + 1013904223) % (2 ^ 32)
    return lo + math.floor(s * (hi - lo + 1) / (2 ^ 32))
  end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- E1: Mark → insert line above → save → DB has shifted line
-- ═══════════════════════════════════════════════════════════════════════════════

describe("edit after mark: insert line above", function()
  local auditor, db, hl

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
    hl = require("auditor.highlights")
  end)

  it("save records the shifted line position", function()
    local bufnr, filepath = make_buf({ "alpha", "hello world", "beta" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- "hello" on line 1 (0-idx)
    auditor.highlight_cword_buffer("red")

    -- Insert a line above → "hello" moves to line 2
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "new line" })

    auditor.audit()
    local rows = db.get_highlights(filepath)
    assert.equals(1, #rows)
    assert.equals(2, rows[1].line) -- shifted from 1 to 2
    assert.equals(0, rows[1].col_start)
    assert.equals(5, rows[1].col_end)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("extmark visually tracks the word after insertion", function()
    local bufnr, _ = make_buf({ "alpha", "hello world", "beta" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    auditor.highlight_cword_buffer("blue")

    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "new1", "new2" })

    local marks = get_marks(bufnr, hl.ns)
    assert.equals(1, #marks)
    assert.equals(3, marks[1][2]) -- line shifted by 2
    assert.equals(0, marks[1][3])
    assert.equals(5, marks[1][4].end_col)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E2: Mark → delete line above → save → DB has shifted line
-- ═══════════════════════════════════════════════════════════════════════════════

describe("edit after mark: delete line above", function()
  local auditor, db

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
  end)

  it("save records the shifted-up line position", function()
    local bufnr, filepath = make_buf({ "line0", "line1", "hello world", "line3" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 3, 0 }) -- "hello" on line 2 (0-idx)
    auditor.highlight_cword_buffer("red")

    -- Delete line 0 → "hello" moves to line 1
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, {})

    auditor.audit()
    local rows = db.get_highlights(filepath)
    assert.equals(1, #rows)
    assert.equals(1, rows[1].line) -- shifted from 2 to 1

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("deleting two lines above shifts word up by two", function()
    local bufnr, filepath = make_buf({ "a", "b", "c", "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 4, 0 }) -- "hello" on line 3
    auditor.highlight_cword_buffer("blue")

    vim.api.nvim_buf_set_lines(bufnr, 0, 2, false, {})

    auditor.audit()
    local rows = db.get_highlights(filepath)
    assert.equals(1, #rows)
    assert.equals(1, rows[1].line) -- shifted from 3 to 1

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E3: Mark → insert chars before word → save → DB has shifted col
-- ═══════════════════════════════════════════════════════════════════════════════

describe("edit after mark: insert chars before word", function()
  local auditor, db

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
  end)

  it("save records shifted column after prepending text", function()
    local bufnr, filepath = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 6 }) -- "world" at col 6-11
    auditor.highlight_cword_buffer("red")

    -- Prepend "XX " at the start of the line → "world" shifts right by 3
    vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 0, { "XX " })

    auditor.audit()
    local rows = db.get_highlights(filepath)
    assert.equals(1, #rows)
    assert.equals(9, rows[1].col_start) -- shifted from 6 to 9
    assert.equals(14, rows[1].col_end) -- shifted from 11 to 14

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E4: Mark → delete chars before word → save → DB has shifted col
-- ═══════════════════════════════════════════════════════════════════════════════

describe("edit after mark: delete chars before word", function()
  local auditor, db

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
  end)

  it("save records shifted-left column after deleting prefix", function()
    local bufnr, filepath = make_buf({ "   hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 3 }) -- "hello" at col 3-8
    auditor.highlight_cword_buffer("red")

    -- Delete the 3-char prefix → "hello" shifts to col 0
    vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 3, { "" })

    auditor.audit()
    local rows = db.get_highlights(filepath)
    assert.equals(1, #rows)
    assert.equals(0, rows[1].col_start)
    assert.equals(5, rows[1].col_end)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E5: Mark → delete line containing the word → save → nothing saved
-- ═══════════════════════════════════════════════════════════════════════════════

describe("edit after mark: delete line with word", function()
  local auditor, db

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
  end)

  it("save writes nothing when the marked line was deleted", function()
    local bufnr, filepath = make_buf({ "keep", "hello world", "also keep" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- "hello"
    auditor.highlight_cword_buffer("red")

    -- Delete the entire line containing "hello"
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, {})

    auditor.audit()
    local rows = db.get_highlights(filepath)
    -- The extmark collapsed to zero-width when its line was deleted,
    -- so sync_pending_from_extmarks filters it out.
    assert.equals(0, #rows)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("pending is cleaned after saving deleted word", function()
    local bufnr, _ = make_buf({ "aaa", "hello", "bbb" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    auditor.highlight_cword_buffer("red")

    vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, {})
    auditor.audit()

    -- Pending should be empty (or entry removed)
    local pending = auditor._pending[bufnr] or {}
    local total_words = 0
    for _, e in ipairs(pending) do
      total_words = total_words + #e.words
    end
    assert.equals(0, total_words)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E6: Mark → replace line with shorter text → save → graceful
-- ═══════════════════════════════════════════════════════════════════════════════

describe("edit after mark: replace line with shorter text", function()
  local auditor, db

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
  end)

  it("no crash and no stale data saved", function()
    local bufnr, filepath = make_buf({ "long_function_name = 42" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- "long_function_name" col 0-18
    auditor.highlight_cword_buffer("red")

    -- Replace the line with much shorter content
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "x" })

    local ok = pcall(auditor.audit)
    assert.is_true(ok)

    -- Extmark collapsed → nothing should be saved
    local rows = db.get_highlights(filepath)
    assert.equals(0, #rows)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E7: Mark → edit → exit → enter → pending at updated positions
-- ═══════════════════════════════════════════════════════════════════════════════

describe("edit after mark: exit → enter preserves updated positions", function()
  local auditor, hl

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    hl = require("auditor.highlights")
  end)

  it("pending positions are synced before exit, restored on enter", function()
    local bufnr, _ = make_buf({ "aaa", "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- "hello" on line 1
    auditor.highlight_cword_buffer("red")

    -- Insert line above → "hello" moves to line 2
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "inserted" })

    -- Exit syncs pending from extmarks (captures line 2)
    auditor.exit_audit_mode()

    -- Check pending was updated
    local pending = auditor._pending[bufnr]
    assert.not_nil(pending)
    assert.equals(1, #pending)
    assert.equals(2, pending[1].words[1].line) -- updated to line 2

    -- Re-enter → pending applied at line 2
    auditor.enter_audit_mode()
    local marks = mark_positions(get_marks(bufnr, hl.ns))
    assert.equals(1, #marks)
    assert.equals(2, marks[1].line)
    assert.equals(0, marks[1].col_start)
    assert.equals(5, marks[1].col_end)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("pending extmark_ids are refreshed on re-enter", function()
    local bufnr, _ = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("blue")

    local old_ids = auditor._pending[bufnr][1].extmark_ids
    assert.equals(1, #old_ids)

    auditor.exit_audit_mode()
    auditor.enter_audit_mode()

    -- New extmark IDs should be assigned
    local new_ids = auditor._pending[bufnr][1].extmark_ids
    assert.equals(1, #new_ids)
    -- IDs are new because extmarks were cleared and re-created
    -- (just verify they exist and are numbers)
    assert.is_number(new_ids[1])

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E8: Mark → edit → undo at cursor → finds extmark at new position
-- ═══════════════════════════════════════════════════════════════════════════════

describe("edit after mark: undo at cursor after edit", function()
  local auditor, hl

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    hl = require("auditor.highlights")
  end)

  it("undo finds the extmark at its new position after line insertion", function()
    local bufnr, _ = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- "hello" on line 0
    auditor.highlight_cword_buffer("red")

    -- Insert line above → "hello" now on line 1
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "inserted" })

    -- Move cursor to "hello" at its new position (line 2 in 1-indexed)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    auditor.undo_at_cursor()

    -- Extmark should be removed
    assert.equals(0, #get_marks(bufnr, hl.ns))

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("undo cleans pending by extmark ID (not stale position)", function()
    local bufnr, _ = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")

    -- Insert line above
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "new" })

    -- Undo at new cursor position
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    auditor.undo_at_cursor()

    -- Pending should be cleaned
    local pending = auditor._pending[bufnr] or {}
    assert.equals(0, #pending)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E9: Mark → edit → save → exit → enter → DB positions correct
-- ═══════════════════════════════════════════════════════════════════════════════

describe("edit after mark: full round-trip with edit", function()
  local auditor, db, hl

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
    hl = require("auditor.highlights")
  end)

  it("mark → insert line → save → exit → enter → highlights at correct position", function()
    local bufnr, filepath = make_buf({ "first", "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    auditor.highlight_cword_buffer("red")

    -- Insert 2 lines at top
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "new1", "new2" })

    auditor.audit()
    auditor.exit_audit_mode()

    -- Verify DB
    local rows = db.get_highlights(filepath)
    assert.equals(1, #rows)
    assert.equals(3, rows[1].line) -- original line 1 + 2 inserted = line 3

    -- Re-enter → highlight should appear at correct position
    auditor.enter_audit_mode()
    local marks = mark_positions(get_marks(bufnr, hl.ns))
    assert.equals(1, #marks)
    assert.equals(3, marks[1].line)
    assert.equals(0, marks[1].col_start)
    assert.equals(5, marks[1].col_end)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("mark → delete prefix → save → exit → enter → cols correct", function()
    local bufnr = make_buf({ "    hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 4 }) -- "hello" at col 4
    auditor.highlight_cword_buffer("blue")

    -- Remove the 4 leading spaces
    vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 4, { "" })

    auditor.audit()
    auditor.exit_audit_mode()
    auditor.enter_audit_mode()

    local marks = mark_positions(get_marks(bufnr, hl.ns))
    assert.equals(1, #marks)
    assert.equals(0, marks[1].col_start) -- shifted from 4 to 0
    assert.equals(5, marks[1].col_end)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E10: Mark multiple → edit → some survive → save → only survivors in DB
-- ═══════════════════════════════════════════════════════════════════════════════

describe("edit after mark: partial survival after edit", function()
  local auditor, db

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
  end)

  it("only surviving highlights are saved after line deletion", function()
    local bufnr, filepath = make_buf({ "aaa", "bbb", "ccc" })
    auditor.enter_audit_mode()

    -- Mark word on each line
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    auditor.highlight_cword_buffer("blue")
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    auditor.highlight_cword_buffer("red")

    -- Delete line 2 ("bbb") — its extmark collapses
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, {})

    auditor.audit()
    local rows = db.get_highlights(filepath)

    -- "bbb" was deleted, only "aaa" and "ccc" should be saved
    -- (extmark for "bbb" collapsed to zero width → filtered out)
    assert.equals(2, #rows)

    local lines_saved = {}
    for _, r in ipairs(rows) do
      table.insert(lines_saved, r.line)
    end
    table.sort(lines_saved)
    -- "aaa" stays at line 0, "ccc" shifts from line 2 to line 1
    assert.equals(0, lines_saved[1])
    assert.equals(1, lines_saved[2])

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E11: Mark → edit → exit → edit more → enter → graceful
-- ═══════════════════════════════════════════════════════════════════════════════

describe("edit after mark: doubly stale pending", function()
  local auditor

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
  end)

  it("no crash when pending positions become stale between exit and re-enter", function()
    local bufnr, _ = make_buf({ "hello world", "second line" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")

    -- Edit → exit syncs to updated position
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "new" })
    auditor.exit_audit_mode()

    -- Edit MORE after exit → pending becomes doubly stale
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "x" })

    -- Re-enter should not crash (stale positions silently skipped)
    local ok = pcall(auditor.enter_audit_mode)
    assert.is_true(ok)

    -- Stale pending entry should be filtered out
    local pending = auditor._pending[bufnr] or {}
    local total_words = 0
    for _, e in ipairs(pending) do
      total_words = total_words + #e.words
    end
    assert.equals(0, total_words)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E12: Mark → insert within word → save → DB has expanded range
-- ═══════════════════════════════════════════════════════════════════════════════

describe("edit after mark: insert within word", function()
  local auditor, db

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
  end)

  it("extmark expands when text is inserted inside the highlighted range", function()
    local bufnr, filepath = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 }) -- "hello" at col 0-5
    auditor.highlight_cword_buffer("red")

    -- Insert "XX" inside "hello" → "heXXllo" at col 0-7
    vim.api.nvim_buf_set_text(bufnr, 0, 2, 0, 2, { "XX" })

    auditor.audit()
    local rows = db.get_highlights(filepath)
    assert.equals(1, #rows)
    assert.equals(0, rows[1].col_start)
    assert.equals(7, rows[1].col_end) -- expanded from 5 to 7

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E13: Pending stores extmark_ids after marking
-- ═══════════════════════════════════════════════════════════════════════════════

describe("edit after mark: pending extmark_ids", function()
  local auditor, hl

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    hl = require("auditor.highlights")
  end)

  it("highlight_cword_buffer stores extmark_ids in pending", function()
    local bufnr, _ = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")

    local entry = auditor._pending[bufnr][1]
    assert.not_nil(entry.extmark_ids)
    assert.equals(1, #entry.extmark_ids)
    assert.is_number(entry.extmark_ids[1])

    -- Verify the extmark ID is valid
    local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, hl.ns, entry.extmark_ids[1], {})
    assert.equals(0, mark[1]) -- line 0
    assert.equals(0, mark[2]) -- col 0

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("highlight_cword stores extmark_ids in pending", function()
    local bufnr, _ = make_buf({ "foo bar foo" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword("red") -- marks both "foo" occurrences

    local entry = auditor._pending[bufnr][1]
    assert.not_nil(entry.extmark_ids)
    assert.equals(2, #entry.extmark_ids)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("extmark_ids and words arrays are aligned", function()
    local bufnr, _ = make_buf({ "x y x" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword("blue") -- marks both "x" occurrences

    local entry = auditor._pending[bufnr][1]
    assert.equals(#entry.words, #entry.extmark_ids)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E14: sync_pending_from_extmarks updates positions
-- ═══════════════════════════════════════════════════════════════════════════════

describe("edit after mark: sync_pending_from_extmarks", function()
  local auditor

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
  end)

  it("updates pending positions after line insertion", function()
    local bufnr, _ = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")

    -- Verify original position
    assert.equals(0, auditor._pending[bufnr][1].words[1].line)

    -- Insert line above
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "new" })

    -- Sync
    auditor._sync_pending_from_extmarks(bufnr)

    -- Position should be updated
    assert.equals(1, auditor._pending[bufnr][1].words[1].line)
    assert.equals(0, auditor._pending[bufnr][1].words[1].col_start)
    assert.equals(5, auditor._pending[bufnr][1].words[1].col_end)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("updates pending positions after col shift", function()
    local bufnr, _ = make_buf({ "  hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 2 }) -- "hello" at col 2
    auditor.highlight_cword_buffer("blue")

    assert.equals(2, auditor._pending[bufnr][1].words[1].col_start)

    -- Delete leading spaces
    vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 2, { "" })

    auditor._sync_pending_from_extmarks(bufnr)

    assert.equals(0, auditor._pending[bufnr][1].words[1].col_start)
    assert.equals(5, auditor._pending[bufnr][1].words[1].col_end)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("removes zero-width extmarks (deleted content) from pending", function()
    local bufnr, _ = make_buf({ "hello" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")

    assert.equals(1, #auditor._pending[bufnr][1].words)

    -- Replace the entire line content → extmark collapses to zero-width
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "" })

    auditor._sync_pending_from_extmarks(bufnr)

    -- Zero-width extmark should be filtered out
    assert.equals(0, #auditor._pending[bufnr][1].words)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("preserves valid extmarks while removing collapsed ones", function()
    local bufnr, _ = make_buf({ "aaa bbb" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red") -- mark "aaa"
    vim.api.nvim_win_set_cursor(0, { 1, 4 })
    auditor.highlight_cword_buffer("blue") -- mark "bbb"

    -- Delete "aaa" text but keep "bbb"
    vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 3, { "" })

    auditor._sync_pending_from_extmarks(bufnr)

    -- "aaa" extmark collapsed, "bbb" should survive
    local total_words = 0
    for _, entry in ipairs(auditor._pending[bufnr]) do
      total_words = total_words + #entry.words
    end
    assert.equals(1, total_words) -- only "bbb" survives

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E15: undo_at_cursor cleans pending by extmark ID after edit
-- ═══════════════════════════════════════════════════════════════════════════════

describe("edit after mark: undo cleans pending by extmark ID", function()
  local auditor

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
  end)

  it("pending cleaned when undo after col shift", function()
    local bufnr, _ = make_buf({ "  hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    auditor.highlight_cword_buffer("red") -- "hello" at col 2-7

    -- Delete leading spaces → "hello" shifts to col 0-5
    vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 2, { "" })

    -- Undo at new position
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.undo_at_cursor()

    local pending = auditor._pending[bufnr] or {}
    assert.equals(0, #pending)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("only the undone word is removed from a multi-word pending entry", function()
    local bufnr, _ = make_buf({ "foo bar foo" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword("red") -- marks both "foo" at col 0 and col 8

    -- Insert line above → both shift to line 1
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "new" })

    -- Undo the first "foo" (now at line 1, col 0)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    auditor.undo_at_cursor()

    -- One "foo" should remain in pending
    local pending = auditor._pending[bufnr]
    assert.not_nil(pending)
    assert.equals(1, #pending)
    assert.equals(1, #pending[1].words)
    assert.equals(1, #pending[1].extmark_ids)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E16: highlight_cword (function scope) → edit → save → correct
-- ═══════════════════════════════════════════════════════════════════════════════

describe("edit after mark: highlight_cword with edit", function()
  local auditor, db

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
  end)

  it("multi-occurrence mark → insert lines → save → all positions shifted", function()
    local bufnr, filepath = make_buf({ "foo bar foo baz foo" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword("red") -- marks 3 "foo" occurrences

    -- Insert 2 lines at top
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "a", "b" })

    auditor.audit()
    local rows = db.get_highlights(filepath)
    assert.equals(3, #rows)
    for _, r in ipairs(rows) do
      assert.equals(2, r.line) -- all shifted from 0 to 2
    end

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E17: Property — random edits between mark and save → no crash
-- ═══════════════════════════════════════════════════════════════════════════════

describe("edit after mark: property — random edits never crash", function()
  local auditor

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
  end)

  it("200 random edit sequences between mark and save", function()
    for seed = 1, 200 do
      local rng = make_rng(seed)

      -- Random buffer content
      local num_lines = rng(1, 5)
      local lines = {}
      for i = 1, num_lines do
        local chars = {}
        local len = rng(3, 20)
        for j = 1, len do
          local c = string.char(rng(97, 122)) -- a-z
          chars[j] = c
        end
        -- Insert spaces to create words
        if #chars > 5 then
          chars[rng(3, #chars - 2)] = " "
        end
        lines[i] = table.concat(chars)
      end

      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.api.nvim_set_current_buf(bufnr)

      auditor.enter_audit_mode()

      -- Place cursor on a word character
      local line_idx = rng(1, num_lines)
      local line_text = lines[line_idx]
      local word_cols = {}
      for c = 1, #line_text do
        if line_text:sub(c, c):match("[%w_]") then
          table.insert(word_cols, c - 1)
        end
      end

      if #word_cols > 0 then
        local col = word_cols[rng(1, #word_cols)]
        vim.api.nvim_win_set_cursor(0, { line_idx, col })

        local ok_mark = pcall(auditor.highlight_cword_buffer, "red")
        assert(ok_mark, string.format("seed=%d: mark failed", seed))

        -- Random edit
        local edit_type = rng(1, 4)
        local cur_lines = vim.api.nvim_buf_line_count(bufnr)

        if edit_type == 1 and cur_lines > 0 then
          -- Insert line
          local at = rng(0, cur_lines)
          pcall(vim.api.nvim_buf_set_lines, bufnr, at, at, false, { "inserted" })
        elseif edit_type == 2 and cur_lines > 1 then
          -- Delete line
          local del = rng(0, cur_lines - 1)
          pcall(vim.api.nvim_buf_set_lines, bufnr, del, del + 1, false, {})
        elseif edit_type == 3 and cur_lines > 0 then
          -- Replace line
          local rep = rng(0, cur_lines - 1)
          pcall(vim.api.nvim_buf_set_lines, bufnr, rep, rep + 1, false, { "replaced" })
        else
          -- Insert text on a line
          if cur_lines > 0 then
            local l = rng(0, cur_lines - 1)
            pcall(vim.api.nvim_buf_set_text, bufnr, l, 0, l, 0, { "XX" })
          end
        end

        -- Save should never crash
        local ok_save = pcall(auditor.audit)
        assert(ok_save, string.format("seed=%d: save failed", seed))
      end

      auditor.exit_audit_mode()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end)

  it("100 random edit sequences between mark, exit, and re-enter", function()
    for seed = 1, 100 do
      local rng = make_rng(seed)
      local lines = { "hello world", "foo bar baz" }

      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.api.nvim_set_current_buf(bufnr)

      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      pcall(auditor.highlight_cword_buffer, "blue")

      -- Random mutations
      for _ = 1, rng(1, 3) do
        local op = rng(1, 3)
        local cur_lines = vim.api.nvim_buf_line_count(bufnr)
        if op == 1 then
          pcall(vim.api.nvim_buf_set_lines, bufnr, 0, 0, false, { "ins" })
        elseif op == 2 and cur_lines > 1 then
          pcall(vim.api.nvim_buf_set_lines, bufnr, 0, 1, false, {})
        else
          pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, { "short" })
        end
      end

      -- Exit and re-enter should never crash
      local ok_exit = pcall(auditor.exit_audit_mode)
      assert(ok_exit, string.format("seed=%d: exit failed", seed))

      local ok_enter = pcall(auditor.enter_audit_mode)
      assert(ok_enter, string.format("seed=%d: re-enter failed", seed))

      auditor.exit_audit_mode()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end)
end)
