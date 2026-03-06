-- test/spec/canonical_and_warn_spec.lua
-- Tests for filepath canonicalization, VimLeavePre warning,
-- and multi-step undo scenarios.

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
-- Filepath canonicalization
-- ═══════════════════════════════════════════════════════════════════════════════

describe("filepath canonicalization", function()
  local auditor, db

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
  end)

  it("saves with absolute canonical path", function()
    -- Create a buffer with a relative-looking name that gets resolved
    local tmpdir = vim.fn.fnamemodify(vim.fn.tempname(), ":h")
    local filepath = tmpdir .. "/test_canon.lua"
    -- Write actual file so resolve works
    vim.fn.writefile({ "hello world" }, filepath)

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, filepath)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })
    vim.api.nvim_set_current_buf(bufnr)

    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    auditor.audit()

    -- The canonical path should be used for DB storage
    local canonical = vim.fn.resolve(vim.fn.fnamemodify(filepath, ":p"))
    local rows = db.get_highlights(canonical)
    assert.equals(1, #rows)

    vim.fn.delete(filepath)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("symlink resolves to same DB entry as target", function()
    local tmpdir = vim.fn.fnamemodify(vim.fn.tempname(), ":h")
    local target = tmpdir .. "/canon_target.lua"
    local link = tmpdir .. "/canon_link.lua"

    vim.fn.writefile({ "hello world" }, target)
    vim.fn.system({ "ln", "-sf", target, link })

    -- Mark via target
    local buf1 = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf1, target)
    vim.api.nvim_buf_set_lines(buf1, 0, -1, false, { "hello world" })
    vim.api.nvim_set_current_buf(buf1)
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    auditor.audit()

    -- Check that querying via resolved link path finds the same rows
    local canonical_target = vim.fn.resolve(vim.fn.fnamemodify(target, ":p"))
    local canonical_link = vim.fn.resolve(vim.fn.fnamemodify(link, ":p"))
    assert.equals(canonical_target, canonical_link)

    local rows = db.get_highlights(canonical_link)
    assert.equals(1, #rows)

    vim.fn.delete(target)
    vim.fn.delete(link)
    pcall(vim.api.nvim_buf_delete, buf1, { force = true })
  end)

  it("unnamed buffer is skipped (empty filepath)", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })
    vim.api.nvim_set_current_buf(bufnr)

    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")

    -- audit() should skip this buffer (no filepath)
    local restore, msgs = capture_notify()
    auditor.audit()
    restore()

    -- Should report nothing to save (no filepath → skipped)
    local found = false
    for _, m in ipairs(msgs) do
      if m.msg:match("Nothing new to save") then
        found = true
      end
    end
    assert.is_true(found)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- VimLeavePre warning
-- ═══════════════════════════════════════════════════════════════════════════════

describe("VimLeavePre warning", function()
  local auditor

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
  end)

  it("warns when there are unsaved pending highlights", function()
    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")

    -- Simulate VimLeavePre by finding and invoking the callback
    local restore, msgs = capture_notify()
    vim.api.nvim_exec_autocmds("VimLeavePre", {})
    restore()

    local found = false
    for _, m in ipairs(msgs) do
      if m.msg:match("unsaved highlight") and m.level == vim.log.levels.WARN then
        found = true
      end
    end
    assert.is_true(found)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("does not warn when no pending highlights", function()
    make_buf({ "hello world" })
    auditor.enter_audit_mode()

    local restore, msgs = capture_notify()
    vim.api.nvim_exec_autocmds("VimLeavePre", {})
    restore()

    for _, m in ipairs(msgs) do
      assert.is_nil(m.msg:match("unsaved highlight"))
    end
  end)

  it("does not warn after save", function()
    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    auditor.audit() -- save

    local restore, msgs = capture_notify()
    vim.api.nvim_exec_autocmds("VimLeavePre", {})
    restore()

    for _, m in ipairs(msgs) do
      assert.is_nil(m.msg:match("unsaved highlight"))
    end

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("reports correct count of unsaved highlights", function()
    local bufnr = make_buf({ "hello world foo" })
    auditor.enter_audit_mode()

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red") -- 1 word
    vim.api.nvim_win_set_cursor(0, { 1, 6 })
    auditor.highlight_cword_buffer("blue") -- 1 word

    local restore, msgs = capture_notify()
    vim.api.nvim_exec_autocmds("VimLeavePre", {})
    restore()

    local found_count = false
    for _, m in ipairs(msgs) do
      if m.msg:match("2 unsaved highlight") then
        found_count = true
      end
    end
    assert.is_true(found_count)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Multi-step undo: save → edit → exit → enter → edit → undo
-- ═══════════════════════════════════════════════════════════════════════════════

describe("multi-step undo", function()
  local auditor, db

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
  end)

  it("save → edit → save → exit → enter → edit → undo removes DB row", function()
    local bufnr, filepath = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    auditor.audit()
    assert.equals(1, #db.get_highlights(filepath))

    -- Edit: insert line above, then save to update DB positions
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "new line" })
    auditor.audit()

    -- Exit and re-enter
    auditor.exit_audit_mode()
    auditor.enter_audit_mode()

    -- Edit again: insert another line
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "another" })

    -- "hello" is now at line 2 (0-indexed), cursor must be on it
    vim.api.nvim_win_set_cursor(0, { 3, 0 }) -- 1-indexed line 3
    auditor.undo_at_cursor()

    -- DB row should be removed
    assert.equals(0, #db.get_highlights(filepath))

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("save → exit → enter → undo (no edits) removes DB row", function()
    local bufnr, filepath = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    auditor.audit()

    auditor.exit_audit_mode()
    auditor.enter_audit_mode()

    -- Undo at same position
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.undo_at_cursor()

    assert.equals(0, #db.get_highlights(filepath))
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("two marks → save → edit → save → exit → enter → undo one → correct row removed", function()
    local bufnr, filepath = make_buf({ "hello world" })
    auditor.enter_audit_mode()

    -- Mark both words
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red") -- "hello"
    vim.api.nvim_win_set_cursor(0, { 1, 6 })
    auditor.highlight_cword_buffer("blue") -- "world"
    auditor.audit()
    assert.equals(2, #db.get_highlights(filepath))

    -- Insert line above and save to update DB positions
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "inserted" })
    auditor.audit()

    -- Exit/enter cycle
    auditor.exit_audit_mode()
    auditor.enter_audit_mode()

    -- Undo "hello" (now at line 1, 0-indexed = row 2 in 1-indexed)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    auditor.undo_at_cursor()

    -- Only "world" should remain
    local rows = db.get_highlights(filepath)
    assert.equals(1, #rows)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("save → edit → save → edit → undo → consistent state", function()
    local bufnr, filepath = make_buf({ "hello world" })
    auditor.enter_audit_mode()

    -- Mark and save
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    auditor.audit()

    -- Edit: insert line
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "top" })

    -- Save again (rewrite with new positions)
    auditor.audit()
    local rows = db.get_highlights(filepath)
    assert.equals(1, #rows)
    assert.equals(1, rows[1].line) -- "hello" moved to line 1

    -- Edit again
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "top2" })

    -- Undo "hello" at its new position (line 2, 0-indexed)
    vim.api.nvim_win_set_cursor(0, { 3, 0 }) -- 1-indexed
    auditor.undo_at_cursor()

    assert.equals(0, #db.get_highlights(filepath))
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Setup guard
-- ═══════════════════════════════════════════════════════════════════════════════

describe("setup guard: functions before setup()", function()
  local auditor

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    -- Deliberately do NOT call setup()
  end)

  it("enter_audit_mode before setup() notifies error", function()
    local restore, msgs = capture_notify()
    auditor.enter_audit_mode()
    restore()

    local found = false
    for _, m in ipairs(msgs) do
      if m.msg:match("not initialised") and m.level == vim.log.levels.ERROR then
        found = true
      end
    end
    assert.is_true(found)
    assert.is_false(auditor._audit_mode)
  end)

  it("exit_audit_mode before setup() notifies error", function()
    local restore, msgs = capture_notify()
    auditor.exit_audit_mode()
    restore()

    local found = false
    for _, m in ipairs(msgs) do
      if m.msg:match("not initialised") then
        found = true
      end
    end
    assert.is_true(found)
  end)

  it("highlight_cword_buffer before setup() notifies error", function()
    -- Need to set _audit_mode manually to bypass audit mode check
    -- and hit the setup check
    local restore, msgs = capture_notify()
    auditor.highlight_cword_buffer("red")
    restore()

    local found = false
    for _, m in ipairs(msgs) do
      if m.msg:match("not initialised") or m.msg:match("outside audit mode") then
        found = true
      end
    end
    assert.is_true(found)
  end)
end)
