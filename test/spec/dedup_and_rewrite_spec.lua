-- test/spec/dedup_and_rewrite_spec.lua
-- Tests for: duplicate mark dedup, full DB rewrite on save, _db_extmarks
-- tracking for undo after edits, double setup() guard, and _db_extmarks
-- lifecycle cleanup.
--
-- Coverage:
--   D1  Re-marking same word replaces extmark (no visual stacking)
--   D2  Re-marking same word with different color updates to new color
--   D3  Dedup cleans old pending entry
--   D4  Dedup cleans _db_extmarks for replaced DB-backed highlight
--   D5  Full DB rewrite: save → edit → save → no duplicate rows
--   D6  Full DB rewrite: stale DB rows cleaned after word deleted
--   D7  Full DB rewrite: moved highlights get updated positions
--   D8  Full DB rewrite: multiple buffers processed
--   D9  _db_extmarks populated on load_for_buffer
--   D10 _db_extmarks used for undo DB removal after edit
--   D11 _db_extmarks cleaned on clear_buffer
--   D12 _db_extmarks cleaned on exit_audit_mode
--   D13 _db_extmarks rebuilt on enter_audit_mode
--   D14 _db_extmarks cleaned on BufDelete
--   D15 _db_extmarks rebuilt after audit() (full rewrite)
--   D16 Double setup() warns and returns
--   D17 audit() with no pending and no _db_extmarks is a no-op
--   D18 highlight_cword dedup with function-scope marking
--   D19 Property: mark+dedup+save cycles never produce duplicates
--   D20 Undo DB-backed highlight after buffer edit uses original position

local function reset_modules()
  for _, m in ipairs({ "auditor", "auditor.init", "auditor.db", "auditor.highlights", "auditor.ts" }) do
    package.loaded[m] = nil
  end
end

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

-- ═══════════════════════════════════════════════════════════════════════════════
-- D1: Re-marking same word replaces extmark (no visual stacking)
-- ═══════════════════════════════════════════════════════════════════════════════

describe("dedup: re-mark replaces extmark", function()
  local auditor, hl

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    hl = require("auditor.highlights")
  end)

  it("marking same word twice produces only one extmark", function()
    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    auditor.highlight_cword_buffer("red")

    local marks = get_marks(bufnr, hl.ns)
    assert.equals(1, #marks)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("marking same word three times still produces one logical extmark", function()
    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    auditor.highlight_cword_buffer("blue")
    auditor.highlight_cword_buffer("half")

    -- Last mark is "half" which creates 2 raw extmarks, but 1 logical
    local collected = hl.collect_extmarks(bufnr)
    assert.equals(1, #collected)
    assert.equals("half", collected[1].color)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- D2: Re-marking with different color updates to new color
-- ═══════════════════════════════════════════════════════════════════════════════

describe("dedup: re-mark with different color", function()
  local auditor, hl

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    hl = require("auditor.highlights")
  end)

  it("last color wins when re-marking", function()
    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    auditor.highlight_cword_buffer("blue")

    local marks = get_marks(bufnr, hl.ns)
    assert.equals(1, #marks)
    assert.equals("AuditorBlue", marks[1][4].hl_group)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("save after re-mark stores only the latest color", function()
    local bufnr, filepath = make_buf({ "hello world" })
    local db = require("auditor.db")
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    auditor.highlight_cword_buffer("blue")

    auditor.audit()
    local rows = db.get_highlights(filepath)
    assert.equals(1, #rows)
    assert.equals("blue", rows[1].color)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- D3: Dedup cleans old pending entry
-- ═══════════════════════════════════════════════════════════════════════════════

describe("dedup: old pending cleaned on re-mark", function()
  local auditor

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
  end)

  it("re-marking removes old pending entry's word", function()
    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    auditor.highlight_cword_buffer("blue")

    -- Count total pending words
    local total = 0
    for _, entry in ipairs(auditor._pending[bufnr]) do
      total = total + #entry.words
    end
    -- Old red entry should have 0 words, new blue entry should have 1
    assert.equals(1, total)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- D4: Dedup cleans _db_extmarks for replaced DB-backed highlight
-- ═══════════════════════════════════════════════════════════════════════════════

describe("dedup: _db_extmarks cleaned on re-mark over DB highlight", function()
  local auditor

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
  end)

  it("re-marking a DB-backed highlight removes its _db_extmarks entry", function()
    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    auditor.audit() -- save to DB

    -- Verify _db_extmarks is populated
    assert.is_true(next(auditor._db_extmarks[bufnr]) ~= nil)

    -- Re-mark same word with different color → should remove old _db_extmarks entry
    auditor.highlight_cword_buffer("blue")

    -- The old DB-backed extmark ID should be gone from _db_extmarks
    -- The new pending extmark won't be in _db_extmarks (it's pending, not DB-backed)
    local db_count = 0
    for _ in pairs(auditor._db_extmarks[bufnr] or {}) do
      db_count = db_count + 1
    end
    assert.equals(0, db_count)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- D5: Full DB rewrite: save → edit → save → no duplicates
-- ═══════════════════════════════════════════════════════════════════════════════

describe("full DB rewrite: no duplicates on repeated save", function()
  local auditor, db

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
  end)

  it("save → mark another word → save → no duplicate rows for first word", function()
    local bufnr, filepath = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red") -- mark "hello"
    auditor.audit()

    -- Mark another word
    vim.api.nvim_win_set_cursor(0, { 1, 6 })
    auditor.highlight_cword_buffer("blue") -- mark "world"
    auditor.audit()

    local rows = db.get_highlights(filepath)
    assert.equals(2, #rows) -- exactly 2, not 3+

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("save → re-mark same word → save → exactly 1 row", function()
    local bufnr, filepath = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    auditor.audit()

    -- Re-mark with different color
    auditor.highlight_cword_buffer("blue")
    auditor.audit()

    local rows = db.get_highlights(filepath)
    assert.equals(1, #rows)
    assert.equals("blue", rows[1].color)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("triple save with no new marks does not create duplicates", function()
    local bufnr, filepath = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    auditor.audit()
    auditor.audit() -- no-op (nothing new)
    auditor.audit() -- no-op again

    local rows = db.get_highlights(filepath)
    assert.equals(1, #rows)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- D6: Full DB rewrite: stale DB rows cleaned after word deleted
-- ═══════════════════════════════════════════════════════════════════════════════

describe("full DB rewrite: stale rows cleaned", function()
  local auditor, db

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
  end)

  it("save → delete marked word → save → stale row removed", function()
    local bufnr, filepath = make_buf({ "hello world", "keep me" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red") -- mark "hello"
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    auditor.highlight_cword_buffer("blue") -- mark "keep"
    auditor.audit()

    assert.equals(2, #db.get_highlights(filepath))

    -- Delete the line with "hello"
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, {})

    -- Save again — full rewrite should only write surviving "keep"
    auditor.audit()
    local rows = db.get_highlights(filepath)
    assert.equals(1, #rows)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("save → replace buffer entirely → save → all old rows cleaned", function()
    local bufnr, filepath = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    auditor.audit()
    assert.equals(1, #db.get_highlights(filepath))

    -- Replace entire buffer
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "completely new" })

    -- Save — extmark collapsed, no highlights to write
    auditor.audit()
    local rows = db.get_highlights(filepath)
    assert.equals(0, #rows)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- D7: Full DB rewrite: moved highlights get updated positions
-- ═══════════════════════════════════════════════════════════════════════════════

describe("full DB rewrite: positions updated after edit", function()
  local auditor, db

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
  end)

  it("save → insert lines → save → DB positions updated", function()
    local bufnr, filepath = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    auditor.audit()

    -- Verify initial position
    local rows = db.get_highlights(filepath)
    assert.equals(0, rows[1].line)

    -- Insert 3 lines above
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "a", "b", "c" })

    -- Save again — full rewrite picks up moved position
    auditor.audit()
    rows = db.get_highlights(filepath)
    assert.equals(1, #rows)
    assert.equals(3, rows[1].line)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- D8: Full DB rewrite: multiple buffers processed
-- ═══════════════════════════════════════════════════════════════════════════════

describe("full DB rewrite: multiple buffers", function()
  local auditor, db

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
  end)

  it("save processes pending from multiple buffers", function()
    auditor.enter_audit_mode()

    local buf1, fp1 = make_buf({ "hello" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")

    local buf2, fp2 = make_buf({ "world" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("blue")

    auditor.audit()

    assert.equals(1, #db.get_highlights(fp1))
    assert.equals(1, #db.get_highlights(fp2))

    pcall(vim.api.nvim_buf_delete, buf1, { force = true })
    pcall(vim.api.nvim_buf_delete, buf2, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- D9: _db_extmarks populated on load_for_buffer
-- ═══════════════════════════════════════════════════════════════════════════════

describe("_db_extmarks: populated on load", function()
  local auditor

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
  end)

  it("load_for_buffer populates _db_extmarks", function()
    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    auditor.audit()

    -- Exit and re-enter to trigger load_for_buffer
    auditor.exit_audit_mode()
    auditor.enter_audit_mode()

    assert.not_nil(auditor._db_extmarks[bufnr])
    local count = 0
    for _, pos in pairs(auditor._db_extmarks[bufnr]) do
      count = count + 1
      assert.equals(0, pos.line)
      assert.equals(0, pos.col_start)
      assert.equals(5, pos.col_end)
    end
    assert.equals(1, count)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- D10: _db_extmarks used for undo DB removal after edit
-- ═══════════════════════════════════════════════════════════════════════════════

describe("_db_extmarks: undo uses original DB position after edit", function()
  local auditor, db

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
  end)

  it("undo removes DB row using tracked original position", function()
    local bufnr, filepath = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    auditor.audit()

    -- Verify DB has the row
    assert.equals(1, #db.get_highlights(filepath))

    -- Insert line above → extmark moves to line 1
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "inserted" })

    -- Undo at new cursor position
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    auditor.undo_at_cursor()

    -- DB row should be removed (using original position from _db_extmarks)
    assert.equals(0, #db.get_highlights(filepath))

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("undo after column shift removes DB row correctly", function()
    local bufnr, filepath = make_buf({ "  hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 2 }) -- "hello" at col 2
    auditor.highlight_cword_buffer("red")
    auditor.audit()

    -- Delete leading spaces → "hello" shifts to col 0
    vim.api.nvim_buf_set_text(bufnr, 0, 0, 0, 2, { "" })

    -- Undo at new position
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.undo_at_cursor()

    -- DB row removed using original col 2 position
    assert.equals(0, #db.get_highlights(filepath))

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- D11: _db_extmarks cleaned on clear_buffer
-- ═══════════════════════════════════════════════════════════════════════════════

describe("_db_extmarks: cleaned on clear_buffer", function()
  local auditor

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
  end)

  it("clear_buffer resets _db_extmarks for the buffer", function()
    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    auditor.audit()

    assert.is_true(next(auditor._db_extmarks[bufnr]) ~= nil)

    auditor.clear_buffer()
    assert.same({}, auditor._db_extmarks[bufnr])

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- D12: _db_extmarks cleaned on exit_audit_mode
-- ═══════════════════════════════════════════════════════════════════════════════

describe("_db_extmarks: cleaned on exit", function()
  local auditor

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
  end)

  it("exit_audit_mode clears _db_extmarks", function()
    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    auditor.audit()

    assert.is_true(next(auditor._db_extmarks[bufnr]) ~= nil)

    auditor.exit_audit_mode()
    assert.same({}, auditor._db_extmarks[bufnr])

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- D13: _db_extmarks rebuilt on enter_audit_mode
-- ═══════════════════════════════════════════════════════════════════════════════

describe("_db_extmarks: rebuilt on enter", function()
  local auditor

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
  end)

  it("enter_audit_mode rebuilds _db_extmarks from DB", function()
    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    auditor.audit()
    auditor.exit_audit_mode()

    assert.same({}, auditor._db_extmarks[bufnr])

    auditor.enter_audit_mode()
    assert.is_true(next(auditor._db_extmarks[bufnr]) ~= nil)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- D14: _db_extmarks cleaned on BufDelete
-- ═══════════════════════════════════════════════════════════════════════════════

describe("_db_extmarks: cleaned on BufDelete", function()
  local auditor

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
  end)

  it("deleting buffer removes _db_extmarks entry", function()
    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    auditor.audit()

    assert.not_nil(auditor._db_extmarks[bufnr])
    vim.api.nvim_buf_delete(bufnr, { force = true })
    assert.is_nil(auditor._db_extmarks[bufnr])
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- D15: _db_extmarks rebuilt after audit() (full rewrite)
-- ═══════════════════════════════════════════════════════════════════════════════

describe("_db_extmarks: rebuilt after audit", function()
  local auditor

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
  end)

  it("audit() rebuilds _db_extmarks with current extmark positions", function()
    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    auditor.audit()

    -- Verify _db_extmarks has current position
    local count = 0
    for _, pos in pairs(auditor._db_extmarks[bufnr]) do
      count = count + 1
      assert.equals(0, pos.line)
      assert.equals(0, pos.col_start)
      assert.equals(5, pos.col_end)
    end
    assert.equals(1, count)

    -- Edit buffer, then save again
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "new" })
    -- Mark another word
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("blue") -- mark "new"
    auditor.audit()

    -- _db_extmarks should have updated positions
    count = 0
    for _, pos in pairs(auditor._db_extmarks[bufnr]) do
      count = count + 1
      -- Both "new" (line 0) and "hello" (line 1) should be tracked
      assert.is_true(pos.line == 0 or pos.line == 1)
    end
    assert.equals(2, count)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- D16: Double setup() warns and returns
-- ═══════════════════════════════════════════════════════════════════════════════

describe("double setup guard", function()
  local auditor

  before_each(function()
    reset_modules()
    auditor = require("auditor")
  end)

  it("second setup() call warns and returns", function()
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    assert.is_true(auditor._setup_done)

    local restore, msgs = capture_notify()
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    restore()

    local found = false
    for _, m in ipairs(msgs) do
      if m.msg:match("already called") then
        found = true
      end
    end
    assert.is_true(found)
  end)

  it("setup is only called once even with repeated attempts", function()
    local db_path = vim.fn.tempname() .. ".db"
    auditor.setup({ db_path = db_path, keymaps = false })

    local restore = capture_notify()
    for _ = 1, 5 do
      auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    end
    restore()

    -- Plugin should still work normally
    auditor.enter_audit_mode()
    assert.is_true(auditor._audit_mode)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- D17: audit() with no pending and no _db_extmarks is a no-op
-- ═══════════════════════════════════════════════════════════════════════════════

describe("audit: no-op when nothing to save", function()
  local auditor

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
  end)

  it("audit() with no pending is a no-op", function()
    make_buf({ "hello world" })
    auditor.enter_audit_mode()

    local restore, msgs = capture_notify()
    auditor.audit()
    restore()

    local found = false
    for _, m in ipairs(msgs) do
      if m.msg:match("Nothing new to save") then
        found = true
      end
    end
    assert.is_true(found)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- D18: highlight_cword dedup with function-scope marking
-- ═══════════════════════════════════════════════════════════════════════════════

describe("dedup: highlight_cword function scope", function()
  local auditor, hl

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    hl = require("auditor.highlights")
  end)

  it("re-marking all occurrences does not stack extmarks", function()
    local bufnr = make_buf({ "foo bar foo baz foo" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword("red") -- marks 3 "foo" occurrences
    auditor.highlight_cword("blue") -- re-marks all 3

    local marks = get_marks(bufnr, hl.ns)
    assert.equals(3, #marks) -- exactly 3, not 6

    -- All should be blue
    for _, m in ipairs(marks) do
      assert.equals("AuditorBlue", m[4].hl_group)
    end

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- D19: Property — mark+dedup+save cycles never produce duplicates
-- ═══════════════════════════════════════════════════════════════════════════════

describe("property: mark + save cycles never produce duplicates", function()
  local auditor, db

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
  end)

  it("100 mark+save cycles on same word produce exactly 1 DB row", function()
    local bufnr, filepath = make_buf({ "hello world" })
    auditor.enter_audit_mode()

    local colors = { "red", "blue", "half" }
    for i = 1, 100 do
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer(colors[(i % 3) + 1])
      auditor.audit()

      local rows = db.get_highlights(filepath)
      assert.equals(1, #rows, string.format("Duplicate at iteration %d", i))
    end

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("50 mark+edit+save cycles never produce duplicates", function()
    local bufnr, filepath = make_buf({ "hello world" })
    auditor.enter_audit_mode()

    for i = 1, 50 do
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")

      -- Insert/remove a line to shift positions
      if i % 2 == 0 then
        vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "line" .. i })
      else
        local lc = vim.api.nvim_buf_line_count(bufnr)
        if lc > 1 then
          vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, {})
        end
      end

      auditor.audit()

      -- Find the word "hello" in DB rows
      local rows = db.get_highlights(filepath)
      local hello_count = 0
      for _, r in ipairs(rows) do
        if r.col_start == 0 and r.col_end == 5 then
          hello_count = hello_count + 1
        end
      end
      -- Could be 0 if "hello" was deleted, but never > 1
      assert.is_true(hello_count <= 1, string.format("Duplicate at iteration %d", i))
    end

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- D20: Undo DB-backed highlight after buffer edit uses original position
-- ═══════════════════════════════════════════════════════════════════════════════

describe("undo DB-backed highlight after edit", function()
  local auditor, db

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
  end)

  it("undo after save+edit removes correct DB row", function()
    local bufnr, filepath = make_buf({ "aaa", "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    auditor.highlight_cword_buffer("red") -- "hello" at line 1
    auditor.audit()

    assert.equals(1, #db.get_highlights(filepath))

    -- Insert 2 lines above → "hello" moves to line 3
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "x", "y" })

    -- _db_extmarks still tracks original position (line 1)
    -- Undo at current cursor position (line 4 in 1-indexed = line 3 in 0-indexed)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    auditor.undo_at_cursor()

    -- DB should be empty — removed using original tracked position
    assert.equals(0, #db.get_highlights(filepath))

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("undo of one of multiple DB-backed highlights after edit", function()
    local bufnr, filepath = make_buf({ "hello world", "hello again" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red") -- "hello" line 0
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    auditor.highlight_cword_buffer("blue") -- "hello" line 1
    auditor.audit()

    assert.equals(2, #db.get_highlights(filepath))

    -- Insert line at top → both shift
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "inserted" })

    -- Undo only the first one (now at line 1, 1-indexed = line 2)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    auditor.undo_at_cursor()

    -- Only one should remain
    assert.equals(1, #db.get_highlights(filepath))

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("undo pending highlight after edit does not touch DB", function()
    local bufnr, filepath = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    -- Don't save — it's still pending

    -- Insert line above
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "new" })

    -- Undo
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    auditor.undo_at_cursor()

    -- DB should be empty (nothing was saved)
    assert.equals(0, #db.get_highlights(filepath))
    -- Pending should be cleaned
    local pending = auditor._pending[bufnr] or {}
    assert.equals(0, #pending)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)
