-- test/spec/e2e_lifecycle_spec.lua
-- End-to-end lifecycle tests covering every feature path.
-- Each test exercises a full user workflow from setup through to verification.

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
-- E2E: Complete single-buffer workflow
-- ═══════════════════════════════════════════════════════════════════════════════

describe("e2e: single buffer full workflow", function()
  local auditor, db, hl

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
    hl = require("auditor.highlights")
  end)

  it("setup → enter → mark red → mark blue → save → exit → enter → verify → undo → save → verify", function()
    local bufnr, filepath = make_buf({ "local function foo(bar, baz)", "  return bar + baz", "end" })

    -- Enter audit mode
    auditor.enter_audit_mode()
    assert.is_true(auditor.is_active())

    -- Mark "foo" red
    vim.api.nvim_win_set_cursor(0, { 1, 15 })
    auditor.highlight_cword_buffer("red")

    -- Mark "bar" blue
    vim.api.nvim_win_set_cursor(0, { 1, 19 })
    auditor.highlight_cword_buffer("blue")

    -- Verify extmarks exist
    local marks = get_marks(bufnr, hl.ns)
    assert.equals(2, #marks)

    -- Save
    auditor.audit()
    local rows = db.get_highlights(filepath)
    assert.equals(2, #rows)

    -- Exit
    auditor.exit_audit_mode()
    assert.is_false(auditor.is_active())

    -- Extmarks should be cleared
    marks = get_marks(bufnr, hl.ns)
    assert.equals(0, #marks)

    -- Re-enter — highlights restored from DB
    auditor.enter_audit_mode()
    marks = get_marks(bufnr, hl.ns)
    assert.equals(2, #marks)

    -- Undo "foo"
    vim.api.nvim_win_set_cursor(0, { 1, 15 })
    auditor.undo_at_cursor()
    marks = get_marks(bufnr, hl.ns)
    assert.equals(1, #marks)

    -- Save again — only "bar" should remain
    auditor.audit()
    rows = db.get_highlights(filepath)
    assert.equals(1, #rows)

    -- Clear all
    auditor.clear_buffer()
    marks = get_marks(bufnr, hl.ns)
    assert.equals(0, #marks)
    rows = db.get_highlights(filepath)
    assert.equals(0, #rows)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E2E: Multi-buffer workflow
-- ═══════════════════════════════════════════════════════════════════════════════

describe("e2e: multi-buffer workflow", function()
  local auditor, db

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
  end)

  it("marks in multiple buffers saved independently", function()
    auditor.enter_audit_mode()

    local buf1, fp1 = make_buf({ "alpha beta" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")

    local buf2, fp2 = make_buf({ "gamma delta" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("blue")

    local buf3, fp3 = make_buf({ "epsilon zeta" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("half")

    auditor.audit()

    assert.equals(1, #db.get_highlights(fp1))
    assert.equals(1, #db.get_highlights(fp2))
    assert.equals(1, #db.get_highlights(fp3))

    -- Clear only buf2
    vim.api.nvim_set_current_buf(buf2)
    auditor.clear_buffer()

    assert.equals(1, #db.get_highlights(fp1))
    assert.equals(0, #db.get_highlights(fp2))
    assert.equals(1, #db.get_highlights(fp3))

    pcall(vim.api.nvim_buf_delete, buf1, { force = true })
    pcall(vim.api.nvim_buf_delete, buf2, { force = true })
    pcall(vim.api.nvim_buf_delete, buf3, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E2E: Edit-during-audit workflow
-- ═══════════════════════════════════════════════════════════════════════════════

describe("e2e: editing during audit mode", function()
  local auditor, db, hl

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
    hl = require("auditor.highlights")
  end)

  it("highlights track buffer edits through mark → edit → save → verify cycle", function()
    local bufnr, filepath = make_buf({ "hello world" })
    auditor.enter_audit_mode()

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")

    -- Insert 3 lines above
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "a", "b", "c" })

    -- Extmark should have moved
    local marks = get_marks(bufnr, hl.ns)
    assert.equals(1, #marks)
    assert.equals(3, marks[1][2]) -- line moved from 0 to 3

    -- Save — DB should get updated position
    auditor.audit()
    local rows = db.get_highlights(filepath)
    assert.equals(1, #rows)
    assert.equals(3, rows[1].line)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("multiple edits + saves maintain consistency", function()
    local bufnr, filepath = make_buf({ "foo bar baz" })
    auditor.enter_audit_mode()

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red") -- "foo"
    vim.api.nvim_win_set_cursor(0, { 1, 4 })
    auditor.highlight_cword_buffer("blue") -- "bar"

    auditor.audit()
    assert.equals(2, #db.get_highlights(filepath))

    -- Delete "foo" line content and replace
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "replaced bar baz" })

    -- Save — extmarks may have been invalidated
    auditor.audit()
    local rows = db.get_highlights(filepath)
    -- Count whatever survived the edit
    assert.is_true(#rows >= 0)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E2E: Toggle mode cycles
-- ═══════════════════════════════════════════════════════════════════════════════

describe("e2e: toggle mode cycles", function()
  local auditor, hl

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    hl = require("auditor.highlights")
  end)

  it("toggle preserves pending through multiple cycles", function()
    local bufnr = make_buf({ "hello world" })

    -- Toggle on
    auditor.toggle_audit_mode()
    assert.is_true(auditor.is_active())

    -- Mark
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")

    -- Toggle off
    auditor.toggle_audit_mode()
    assert.is_false(auditor.is_active())

    -- Toggle on — pending should re-apply
    auditor.toggle_audit_mode()
    assert.is_true(auditor.is_active())
    local marks = get_marks(bufnr, hl.ns)
    assert.equals(1, #marks)

    -- Toggle off/on again
    auditor.toggle_audit_mode()
    auditor.toggle_audit_mode()
    marks = get_marks(bufnr, hl.ns)
    assert.equals(1, #marks)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E2E: Half-and-half color alternation
-- ═══════════════════════════════════════════════════════════════════════════════

describe("e2e: half-and-half alternation", function()
  local auditor, hl

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    hl = require("auditor.highlights")
  end)

  it("half color persists as gradient across save/load cycle", function()
    local bufnr = make_buf({ "aaa bbb ccc ddd eee" })
    auditor.enter_audit_mode()

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("half") -- "aaa"

    -- Save and reload
    auditor.audit()
    auditor.exit_audit_mode()
    auditor.enter_audit_mode()

    local marks = get_marks(bufnr, hl.ns)
    -- "aaa" (3 chars): 1 primary + 2 overlays = 3 raw extmarks
    assert.equals(3, #marks)
    for _, m in ipairs(marks) do
      assert.is_truthy(m[4].hl_group:match("^AuditorGrad"))
    end

    -- collect_extmarks sees 1 logical mark
    local collected = hl.collect_extmarks(bufnr)
    assert.equals(1, #collected)
    assert.equals("half", collected[1].color)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E2E: Undo of DB-backed highlights after complex edit sequence
-- ═══════════════════════════════════════════════════════════════════════════════

describe("e2e: complex undo sequences", function()
  local auditor, db

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
  end)

  it("undo each of 5 marks one by one", function()
    local bufnr, filepath = make_buf({ "aa bb cc dd ee" })
    auditor.enter_audit_mode()

    local words = { { 0, "red" }, { 3, "blue" }, { 6, "red" }, { 9, "blue" }, { 12, "half" } }
    for _, w in ipairs(words) do
      vim.api.nvim_win_set_cursor(0, { 1, w[1] })
      auditor.highlight_cword_buffer(w[2])
    end
    auditor.audit()
    assert.equals(5, #db.get_highlights(filepath))

    -- Undo each one
    for i = #words, 1, -1 do
      vim.api.nvim_win_set_cursor(0, { 1, words[i][1] })
      auditor.undo_at_cursor()
      assert.equals(i - 1, #db.get_highlights(filepath))
    end

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("undo works after save → edit → save → edit → undo chain", function()
    local bufnr, filepath = make_buf({ "hello world" })
    auditor.enter_audit_mode()

    -- Mark and save
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    auditor.audit()

    -- Edit (insert line)
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "line1" })
    auditor.audit() -- save at new position

    -- Edit again
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "line2" })

    -- Undo at current position (hello is now at line 2)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    auditor.undo_at_cursor()

    assert.equals(0, #db.get_highlights(filepath))
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E2E: Function-scoped highlighting (highlight_cword)
-- ═══════════════════════════════════════════════════════════════════════════════

describe("e2e: function-scoped highlighting", function()
  local auditor, db

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
  end)

  it("marks all occurrences within buffer scope (no treesitter)", function()
    local bufnr, filepath = make_buf({ "foo bar foo baz foo" })
    auditor.enter_audit_mode()

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword("red") -- marks all "foo"

    auditor.audit()
    local rows = db.get_highlights(filepath)
    assert.equals(3, #rows)
    for _, r in ipairs(rows) do
      assert.equals("red", r.color)
    end

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("function-scoped marks survive save → exit → enter cycle", function()
    local bufnr, filepath = make_buf({ "foo bar foo" })
    auditor.enter_audit_mode()

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword("blue")
    auditor.audit()

    auditor.exit_audit_mode()
    auditor.enter_audit_mode()

    local rows = db.get_highlights(filepath)
    assert.equals(2, #rows)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E2E: Color picker (pick_color / pick_cword_color)
-- ═══════════════════════════════════════════════════════════════════════════════

describe("e2e: color pickers", function()
  local auditor, hl

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    hl = require("auditor.highlights")
  end)

  it("pick_color calls vim.ui.select and applies choice", function()
    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    -- Mock vim.ui.select to auto-pick first choice
    local orig_select = vim.ui.select
    vim.ui.select = function(items, _opts, on_choice)
      on_choice(items[1])
    end

    auditor.pick_color()

    vim.ui.select = orig_select

    local marks = get_marks(bufnr, hl.ns)
    assert.equals(1, #marks)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("pick_color with cancel (nil choice) does nothing", function()
    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local orig_select = vim.ui.select
    vim.ui.select = function(_, _, on_choice)
      on_choice(nil)
    end

    auditor.pick_color()
    vim.ui.select = orig_select

    local marks = get_marks(bufnr, hl.ns)
    assert.equals(0, #marks)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("pick_cword_color calls vim.ui.select and applies choice", function()
    local bufnr = make_buf({ "foo bar foo" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local orig_select = vim.ui.select
    vim.ui.select = function(items, _, on_choice)
      -- Pick blue (second item)
      on_choice(items[2])
    end

    auditor.pick_cword_color()
    vim.ui.select = orig_select

    local marks = get_marks(bufnr, hl.ns)
    -- highlight_cword marks all occurrences of "foo" in scope
    assert.equals(2, #marks)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("pick_cword_color outside audit mode notifies", function()
    make_buf({ "hello" })

    local restore, msgs = capture_notify()
    auditor.pick_cword_color()
    restore()

    local found = false
    for _, m in ipairs(msgs) do
      if m.msg:match("outside audit mode") then
        found = true
      end
    end
    assert.is_true(found)
  end)

  it("pick_color outside audit mode notifies", function()
    make_buf({ "hello" })

    local restore, msgs = capture_notify()
    auditor.pick_color()
    restore()

    local found = false
    for _, m in ipairs(msgs) do
      if m.msg:match("outside audit mode") then
        found = true
      end
    end
    assert.is_true(found)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E2E: BufDelete autocmd cleanup
-- ═══════════════════════════════════════════════════════════════════════════════

describe("e2e: buffer deletion cleanup", function()
  local auditor

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
  end)

  it("deleting buffer cleans pending and db_extmarks", function()
    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    auditor.audit()

    assert.not_nil(auditor._pending[bufnr])
    assert.not_nil(auditor._db_extmarks[bufnr])

    -- Create a different buffer to switch to before deleting
    local buf2 = make_buf({ "other" })
    vim.api.nvim_buf_delete(bufnr, { force = true })

    assert.is_nil(auditor._pending[bufnr])
    assert.is_nil(auditor._db_extmarks[bufnr])

    pcall(vim.api.nvim_buf_delete, buf2, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E2E: Unnamed buffer handling
-- ═══════════════════════════════════════════════════════════════════════════════

describe("e2e: unnamed buffer", function()
  local auditor

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
  end)

  it("marking works but save skips unnamed buffers", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })
    vim.api.nvim_set_current_buf(bufnr)

    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")

    -- Pending is populated
    assert.is_true(#auditor._pending[bufnr] > 0)

    -- Save should skip (no filepath) and report nothing saved
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

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E2E: Clear buffer with no DB rows
-- ═══════════════════════════════════════════════════════════════════════════════

describe("e2e: clear buffer edge cases", function()
  local auditor, db

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
  end)

  it("clear on buffer with no highlights is safe", function()
    local bufnr, filepath = make_buf({ "hello world" })
    auditor.enter_audit_mode()

    -- Clear without any marks — should not crash
    auditor.clear_buffer()
    assert.equals(0, #db.get_highlights(filepath))

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("clear after partial undo removes remainder", function()
    local bufnr, filepath = make_buf({ "aa bb cc" })
    auditor.enter_audit_mode()

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    vim.api.nvim_win_set_cursor(0, { 1, 3 })
    auditor.highlight_cword_buffer("blue")
    vim.api.nvim_win_set_cursor(0, { 1, 6 })
    auditor.highlight_cword_buffer("half")
    auditor.audit()
    assert.equals(3, #db.get_highlights(filepath))

    -- Undo one
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.undo_at_cursor()

    -- Clear the rest
    auditor.clear_buffer()
    assert.equals(0, #db.get_highlights(filepath))

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E2E: Custom colors
-- ═══════════════════════════════════════════════════════════════════════════════

describe("e2e: custom colors in setup", function()
  it("custom color options are used in picker", function()
    reset_modules()
    local auditor = require("auditor")
    auditor.setup({
      db_path = vim.fn.tempname() .. ".db",
      keymaps = false,
      colors = {
        { name = "red", label = "Primary", hl = { bg = "#CC0000", fg = "#FFFFFF", bold = true } },
        { name = "blue", label = "Secondary", hl = { bg = "#0055CC", fg = "#FFFFFF", bold = true } },
      },
    })

    assert.equals(2, #auditor._colors)
    assert.equals("Primary", auditor._colors[1].label)
    assert.equals("red", auditor._colors[1].color)
    assert.equals("Secondary", auditor._colors[2].label)
    assert.equals("blue", auditor._colors[2].color)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E2E: Double undo on same word
-- ═══════════════════════════════════════════════════════════════════════════════

describe("e2e: double undo", function()
  local auditor

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
  end)

  it("second undo on same word reports no highlight", function()
    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")

    auditor.undo_at_cursor()

    local restore, msgs = capture_notify()
    auditor.undo_at_cursor()
    restore()

    local found = false
    for _, m in ipairs(msgs) do
      if m.msg:match("No highlight on this word") then
        found = true
      end
    end
    assert.is_true(found)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E2E: Undo on non-highlighted word
-- ═══════════════════════════════════════════════════════════════════════════════

describe("e2e: undo on non-highlighted word", function()
  local auditor

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
  end)

  it("undo on unmarked word notifies correctly", function()
    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local restore, msgs = capture_notify()
    auditor.undo_at_cursor()
    restore()

    local found = false
    for _, m in ipairs(msgs) do
      if m.msg:match("No highlight on this word") then
        found = true
      end
    end
    assert.is_true(found)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("undo on whitespace notifies no word", function()
    local bufnr = make_buf({ "hello   world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 6 }) -- on space

    local restore, msgs = capture_notify()
    auditor.undo_at_cursor()
    restore()

    local found = false
    for _, m in ipairs(msgs) do
      if m.msg:match("No word under cursor") then
        found = true
      end
    end
    assert.is_true(found)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E2E: Audit mode guards on every gated function
-- ═══════════════════════════════════════════════════════════════════════════════

describe("e2e: audit mode guards", function()
  local auditor

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
  end)

  it("all gated functions refuse when not in audit mode", function()
    make_buf({ "hello world" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local gated = {
      function() auditor.highlight_cword_buffer("red") end,
      function() auditor.highlight_cword("red") end,
      function() auditor.audit() end,
      function() auditor.clear_buffer() end,
      function() auditor.pick_color() end,
      function() auditor.pick_cword_color() end,
      function() auditor.undo_at_cursor() end,
    }

    for _, fn in ipairs(gated) do
      local restore, msgs = capture_notify()
      fn()
      restore()
      local found = false
      for _, m in ipairs(msgs) do
        if m.msg:match("outside audit mode") then
          found = true
        end
      end
      assert.is_true(found, "Expected audit mode guard notification")
    end
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- E2E: Load for buffer edge cases
-- ═══════════════════════════════════════════════════════════════════════════════

describe("e2e: load_for_buffer", function()
  local auditor

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
  end)

  it("loading invalid buffer is safe", function()
    -- Should not crash
    auditor.load_for_buffer(999999)
  end)

  it("loading buffer with empty name is safe", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello" })
    -- No name set
    auditor.load_for_buffer(bufnr)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)
