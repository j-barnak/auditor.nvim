-- test/spec/robustness_spec.lua
-- Robustness tests: buffer validity guards, setup gate, DB error resilience,
-- BufDelete pending cleanup, clear_buffer ordering, exit/toggle setup guards.
--
-- Coverage:
--   R1  Functions called before setup() — all guarded functions notify and bail
--   R2  load_for_buffer on invalid/unnamed buffer — no crash
--   R3  DB error during audit() — pending preserved for retry
--   R4  DB error during clear_buffer() — extmarks preserved, user notified
--   R5  DB error during undo_at_cursor() — user notified, no crash
--   R6  DB error during load_for_buffer() — user notified, no crash
--   R7  exit_audit_mode() before setup() — setup guard
--   R8  toggle_audit_mode() before setup() — setup guard (both directions)
--   R9  is_active() works before setup() — returns false, no crash
--   R10 BufDelete cleans up _pending — stale entries removed
--   R11 clear_buffer() DB-first ordering — extmarks preserved on DB failure
--   R12 clear_buffer() DB-first ordering — extmarks cleared on DB success

local function reset_modules()
  for _, m in ipairs({ "auditor", "auditor.init", "auditor.db", "auditor.highlights", "auditor.ts" }) do
    package.loaded[m] = nil
  end
end

local function extmark_count(bufnr, ns)
  return #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
end

-- Capture vim.notify calls; returns {restore, messages} where messages is a
-- list of {msg, level} tables and restore() puts the original back.
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

describe("robustness", function()
  -- ── R1: functions before setup() ──────────────────────────────────────────

  describe("R1: functions called before setup()", function()
    local auditor

    before_each(function()
      reset_modules()
      auditor = require("auditor")
      -- Do NOT call setup()
    end)

    it("enter_audit_mode() notifies and returns without crashing", function()
      local restore, msgs = capture_notify()
      auditor.enter_audit_mode()
      restore()
      local found = false
      for _, m in ipairs(msgs) do
        if m.msg:match("not initialised") then
          found = true
        end
      end
      assert.is_true(found)
      assert.is_false(auditor._audit_mode)
    end)

    it("highlight_cword_buffer() notifies about missing setup", function()
      local restore, msgs = capture_notify()
      auditor.highlight_cword_buffer("red")
      restore()
      local found = false
      for _, m in ipairs(msgs) do
        if m.msg:match("not initialised") then
          found = true
        end
      end
      assert.is_true(found)
    end)

    it("highlight_cword() notifies about missing setup", function()
      local restore, msgs = capture_notify()
      auditor.highlight_cword("blue")
      restore()
      local found = false
      for _, m in ipairs(msgs) do
        if m.msg:match("not initialised") then
          found = true
        end
      end
      assert.is_true(found)
    end)

    it("audit() notifies about missing setup", function()
      local restore, msgs = capture_notify()
      auditor.audit()
      restore()
      local found = false
      for _, m in ipairs(msgs) do
        if m.msg:match("not initialised") then
          found = true
        end
      end
      assert.is_true(found)
    end)

    it("clear_buffer() notifies about missing setup", function()
      local restore, msgs = capture_notify()
      auditor.clear_buffer()
      restore()
      local found = false
      for _, m in ipairs(msgs) do
        if m.msg:match("not initialised") then
          found = true
        end
      end
      assert.is_true(found)
    end)

    it("undo_at_cursor() notifies about missing setup", function()
      local restore, msgs = capture_notify()
      auditor.undo_at_cursor()
      restore()
      local found = false
      for _, m in ipairs(msgs) do
        if m.msg:match("not initialised") then
          found = true
        end
      end
      assert.is_true(found)
    end)

    it("pick_color() notifies about missing setup", function()
      local restore, msgs = capture_notify()
      auditor.pick_color()
      restore()
      local found = false
      for _, m in ipairs(msgs) do
        if m.msg:match("not initialised") then
          found = true
        end
      end
      assert.is_true(found)
    end)

    it("pick_cword_color() notifies about missing setup", function()
      local restore, msgs = capture_notify()
      auditor.pick_cword_color()
      restore()
      local found = false
      for _, m in ipairs(msgs) do
        if m.msg:match("not initialised") then
          found = true
        end
      end
      assert.is_true(found)
    end)

    it("_setup_done is false before setup", function()
      assert.is_false(auditor._setup_done)
    end)

    it("_setup_done is true after setup", function()
      local tmp_db = vim.fn.tempname() .. ".db"
      auditor.setup({ db_path = tmp_db, keymaps = false })
      assert.is_true(auditor._setup_done)
      pcall(os.remove, tmp_db)
    end)

    it("_audit_mode stays false for all blocked calls", function()
      local restore = capture_notify()
      auditor.enter_audit_mode()
      auditor.highlight_cword_buffer("red")
      auditor.highlight_cword("blue")
      auditor.audit()
      auditor.clear_buffer()
      auditor.undo_at_cursor()
      restore()
      assert.is_false(auditor._audit_mode)
    end)

    it("_pending stays empty for all blocked calls", function()
      local restore = capture_notify()
      auditor.highlight_cword_buffer("red")
      auditor.highlight_cword("blue")
      restore()
      assert.same({}, auditor._pending)
    end)
  end)

  -- ── R2: load_for_buffer on invalid buffer ─────────────────────────────────

  describe("R2: load_for_buffer on invalid buffer", function()
    local auditor

    before_each(function()
      reset_modules()
      auditor = require("auditor")
      local tmp_db = vim.fn.tempname() .. ".db"
      auditor.setup({ db_path = tmp_db, keymaps = false })
    end)

    it("does not crash when buffer is invalid", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_delete(bufnr, { force = true })

      local ok = pcall(auditor.load_for_buffer, bufnr)
      assert.is_true(ok)
    end)

    it("does not crash when buffer has no name", function()
      local bufnr = vim.api.nvim_create_buf(false, true)

      local ok = pcall(auditor.load_for_buffer, bufnr)
      assert.is_true(ok)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("does not apply any extmarks for invalid buffer", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_delete(bufnr, { force = true })

      -- Just verifying it returns silently — can't check extmarks on invalid buf
      local ok = pcall(auditor.load_for_buffer, bufnr)
      assert.is_true(ok)
    end)
  end)

  -- ── R3: DB error during audit() preserves pending ─────────────────────────

  describe("R3: DB error during audit() preserves pending", function()
    local auditor, db

    before_each(function()
      reset_modules()
      auditor = require("auditor")
      local tmp_db = vim.fn.tempname() .. ".db"
      auditor.setup({ db_path = tmp_db, keymaps = false })
      db = require("auditor.db")
    end)

    it("pending is preserved when db.save_words errors", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(bufnr)
      auditor.enter_audit_mode()

      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")

      assert.is_true(#auditor._pending[bufnr] > 0)

      local orig_rewrite = db.rewrite_highlights
      db.rewrite_highlights = function()
        error("simulated DB failure")
      end

      local restore = capture_notify()
      auditor.audit()
      restore()
      db.rewrite_highlights = orig_rewrite

      -- Pending must still be populated so user can retry.
      assert.is_true(#auditor._pending[bufnr] > 0)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("error notification includes DB error message", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello" })
      vim.api.nvim_set_current_buf(bufnr)
      auditor.enter_audit_mode()

      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")

      local orig_rewrite = db.rewrite_highlights
      db.rewrite_highlights = function()
        error("simulated DB failure")
      end

      local restore, msgs = capture_notify()
      auditor.audit()
      restore()
      db.rewrite_highlights = orig_rewrite

      local found_error = false
      for _, m in ipairs(msgs) do
        if m.level == vim.log.levels.ERROR and m.msg:match("DB save failed") then
          found_error = true
        end
      end
      assert.is_true(found_error)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("successful retry after transient failure works", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello" })
      vim.api.nvim_set_current_buf(bufnr)
      auditor.enter_audit_mode()

      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")

      -- First attempt fails
      local orig_rewrite = db.rewrite_highlights
      db.rewrite_highlights = function()
        error("simulated DB failure")
      end

      local restore = capture_notify()
      auditor.audit()
      restore()

      -- Restore original and retry
      db.rewrite_highlights = orig_rewrite
      auditor.audit()

      -- Pending should now be cleared and DB should have the data
      assert.same({}, auditor._pending[bufnr])
      assert.is_true(#db.get_highlights(filepath) >= 1)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── R4: DB error during clear_buffer() ────────────────────────────────────

  describe("R4: DB error during clear_buffer()", function()
    local auditor, db

    before_each(function()
      reset_modules()
      auditor = require("auditor")
      local tmp_db = vim.fn.tempname() .. ".db"
      auditor.setup({ db_path = tmp_db, keymaps = false })
      db = require("auditor.db")
    end)

    it("does not crash and notifies user", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello" })
      vim.api.nvim_set_current_buf(bufnr)
      auditor.enter_audit_mode()

      local orig_clear = db.clear_highlights
      db.clear_highlights = function()
        error("simulated DB failure")
      end

      local restore, msgs = capture_notify()
      auditor.clear_buffer()
      restore()
      db.clear_highlights = orig_clear

      local found = false
      for _, m in ipairs(msgs) do
        if m.level == vim.log.levels.ERROR and m.msg:match("DB clear failed") then
          found = true
        end
      end
      assert.is_true(found)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── R5: DB error during undo_at_cursor() ──────────────────────────────────

  describe("R5: DB error during undo_at_cursor()", function()
    local auditor, db

    before_each(function()
      reset_modules()
      auditor = require("auditor")
      local tmp_db = vim.fn.tempname() .. ".db"
      auditor.setup({ db_path = tmp_db, keymaps = false })
      db = require("auditor.db")
    end)

    it("does not crash and notifies user", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(bufnr)
      auditor.enter_audit_mode()

      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")

      local orig_remove = db.remove_highlight
      db.remove_highlight = function()
        error("simulated DB failure")
      end

      local restore, msgs = capture_notify()
      auditor.undo_at_cursor()
      restore()
      db.remove_highlight = orig_remove

      local found = false
      for _, m in ipairs(msgs) do
        if m.level == vim.log.levels.ERROR and m.msg:match("DB remove failed") then
          found = true
        end
      end
      assert.is_true(found)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── R6: DB error during load_for_buffer() ─────────────────────────────────

  describe("R6: DB error during load_for_buffer()", function()
    local auditor, db

    before_each(function()
      reset_modules()
      auditor = require("auditor")
      local tmp_db = vim.fn.tempname() .. ".db"
      auditor.setup({ db_path = tmp_db, keymaps = false })
      db = require("auditor.db")
    end)

    it("does not crash and notifies user", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)

      local orig_get = db.get_highlights
      db.get_highlights = function()
        error("simulated DB failure")
      end

      local restore, msgs = capture_notify()
      local ok = pcall(auditor.load_for_buffer, bufnr)
      restore()
      db.get_highlights = orig_get

      assert.is_true(ok)
      local found = false
      for _, m in ipairs(msgs) do
        if m.level == vim.log.levels.ERROR and m.msg:match("Failed to load") then
          found = true
        end
      end
      assert.is_true(found)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("does not apply any extmarks when DB errors", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })
      local hl = require("auditor.highlights")

      local orig_get = db.get_highlights
      db.get_highlights = function()
        error("simulated DB failure")
      end

      local restore = capture_notify()
      pcall(auditor.load_for_buffer, bufnr)
      restore()
      db.get_highlights = orig_get

      assert.equals(0, extmark_count(bufnr, hl.ns))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── R7: exit_audit_mode() before setup() ──────────────────────────────────

  describe("R7: exit_audit_mode() before setup()", function()
    local auditor

    before_each(function()
      reset_modules()
      auditor = require("auditor")
      -- Do NOT call setup()
    end)

    it("notifies about missing setup and returns", function()
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

    it("does not crash", function()
      local restore = capture_notify()
      local ok = pcall(auditor.exit_audit_mode)
      restore()
      assert.is_true(ok)
    end)

    it("_audit_mode stays false", function()
      local restore = capture_notify()
      auditor.exit_audit_mode()
      restore()
      assert.is_false(auditor._audit_mode)
    end)

    it("calling exit multiple times before setup does not crash", function()
      local restore = capture_notify()
      for _ = 1, 5 do
        local ok = pcall(auditor.exit_audit_mode)
        assert.is_true(ok)
      end
      restore()
    end)

    it("exit works normally after setup", function()
      local tmp_db = vim.fn.tempname() .. ".db"
      auditor.setup({ db_path = tmp_db, keymaps = false })
      auditor.enter_audit_mode()
      assert.is_true(auditor._audit_mode)

      auditor.exit_audit_mode()
      assert.is_false(auditor._audit_mode)
      pcall(os.remove, tmp_db)
    end)
  end)

  -- ── R8: toggle_audit_mode() before setup() ────────────────────────────────

  describe("R8: toggle_audit_mode() before setup()", function()
    local auditor

    before_each(function()
      reset_modules()
      auditor = require("auditor")
      -- Do NOT call setup()
    end)

    it("notifies about missing setup", function()
      local restore, msgs = capture_notify()
      auditor.toggle_audit_mode()
      restore()
      local found = false
      for _, m in ipairs(msgs) do
        if m.msg:match("not initialised") then
          found = true
        end
      end
      assert.is_true(found)
    end)

    it("does not crash", function()
      local restore = capture_notify()
      local ok = pcall(auditor.toggle_audit_mode)
      restore()
      assert.is_true(ok)
    end)

    it("_audit_mode stays false (toggle from off tries enter, which is guarded)", function()
      local restore = capture_notify()
      auditor.toggle_audit_mode()
      restore()
      assert.is_false(auditor._audit_mode)
    end)

    it("rapid toggle calls before setup do not crash", function()
      local restore = capture_notify()
      for _ = 1, 10 do
        local ok = pcall(auditor.toggle_audit_mode)
        assert.is_true(ok)
      end
      restore()
      assert.is_false(auditor._audit_mode)
    end)

    it("toggle works normally after setup", function()
      local tmp_db = vim.fn.tempname() .. ".db"
      auditor.setup({ db_path = tmp_db, keymaps = false })

      auditor.toggle_audit_mode()
      assert.is_true(auditor._audit_mode)

      auditor.toggle_audit_mode()
      assert.is_false(auditor._audit_mode)
      pcall(os.remove, tmp_db)
    end)

    it("toggle from active → exit is guarded before setup (hypothetical)", function()
      -- Force _audit_mode to true without setup to test the exit path guard
      auditor._audit_mode = true
      local restore, msgs = capture_notify()
      auditor.toggle_audit_mode()
      restore()
      -- toggle sees _audit_mode=true, calls exit_audit_mode which checks _setup_done
      local found = false
      for _, m in ipairs(msgs) do
        if m.msg:match("not initialised") then
          found = true
        end
      end
      assert.is_true(found)
      -- _audit_mode should still be true since exit was blocked
      assert.is_true(auditor._audit_mode)
    end)
  end)

  -- ── R9: is_active() works before setup() ──────────────────────────────────

  describe("R9: is_active() works before setup()", function()
    local auditor

    before_each(function()
      reset_modules()
      auditor = require("auditor")
      -- Do NOT call setup()
    end)

    it("returns false before setup", function()
      assert.is_false(auditor.is_active())
    end)

    it("does not crash", function()
      local ok, result = pcall(auditor.is_active)
      assert.is_true(ok)
      assert.is_false(result)
    end)

    it("returns boolean type", function()
      assert.equals("boolean", type(auditor.is_active()))
    end)

    it("returns true after setup + enter", function()
      local tmp_db = vim.fn.tempname() .. ".db"
      auditor.setup({ db_path = tmp_db, keymaps = false })
      auditor.enter_audit_mode()
      assert.is_true(auditor.is_active())
      pcall(os.remove, tmp_db)
    end)

    it("returns false after setup + enter + exit", function()
      local tmp_db = vim.fn.tempname() .. ".db"
      auditor.setup({ db_path = tmp_db, keymaps = false })
      auditor.enter_audit_mode()
      auditor.exit_audit_mode()
      assert.is_false(auditor.is_active())
      pcall(os.remove, tmp_db)
    end)
  end)

  -- ── R10: BufDelete cleans up _pending ─────────────────────────────────────

  describe("R10: BufDelete cleans up _pending", function()
    local auditor

    before_each(function()
      reset_modules()
      auditor = require("auditor")
      local tmp_db = vim.fn.tempname() .. ".db"
      auditor.setup({ db_path = tmp_db, keymaps = false })
    end)

    it("deleting a buffer removes its pending entries", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(bufnr)
      auditor.enter_audit_mode()

      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      assert.is_true(#auditor._pending[bufnr] > 0)

      -- Delete the buffer — BufDelete autocmd should clean up pending
      vim.api.nvim_buf_delete(bufnr, { force = true })
      assert.is_nil(auditor._pending[bufnr])
    end)

    it("deleting one buffer does not affect pending of another", function()
      auditor.enter_audit_mode()

      local buf1 = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf1, vim.fn.tempname() .. ".lua")
      vim.api.nvim_buf_set_lines(buf1, 0, -1, false, { "hello" })
      vim.api.nvim_set_current_buf(buf1)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")

      local buf2 = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf2, vim.fn.tempname() .. ".lua")
      vim.api.nvim_buf_set_lines(buf2, 0, -1, false, { "world" })
      vim.api.nvim_set_current_buf(buf2)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("blue")

      assert.is_true(#auditor._pending[buf1] > 0)
      assert.is_true(#auditor._pending[buf2] > 0)

      vim.api.nvim_buf_delete(buf1, { force = true })

      assert.is_nil(auditor._pending[buf1])
      assert.is_true(#auditor._pending[buf2] > 0)

      pcall(vim.api.nvim_buf_delete, buf2, { force = true })
    end)

    it("deleting buffer with no pending does not error", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      assert.is_nil(auditor._pending[bufnr])

      local ok = pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      assert.is_true(ok)
    end)

    it("pending does not accumulate stale entries after multiple buffer create/delete", function()
      auditor.enter_audit_mode()

      for _ = 1, 10 do
        local b = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_name(b, vim.fn.tempname() .. ".lua")
        vim.api.nvim_buf_set_lines(b, 0, -1, false, { "word" })
        vim.api.nvim_set_current_buf(b)
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        auditor.highlight_cword_buffer("red")
        vim.api.nvim_buf_delete(b, { force = true })
      end

      -- All stale entries should be cleaned up
      local count = 0
      for _ in pairs(auditor._pending) do
        count = count + 1
      end
      assert.equals(0, count)
    end)

    it("audit() on deleted buffer skips stale pending (double safety)", function()
      auditor.enter_audit_mode()

      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello" })
      vim.api.nvim_set_current_buf(bufnr)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")

      -- Delete the buffer — autocmd cleans up pending
      vim.api.nvim_buf_delete(bufnr, { force = true })

      -- audit() should not crash even though buffer is gone
      local ok = pcall(auditor.audit)
      assert.is_true(ok)
    end)
  end)

  -- ── R11: clear_buffer() DB-first ordering — extmarks preserved on failure ─

  describe("R11: clear_buffer() preserves extmarks when DB fails", function()
    local auditor, db, hl

    before_each(function()
      reset_modules()
      auditor = require("auditor")
      local tmp_db = vim.fn.tempname() .. ".db"
      auditor.setup({ db_path = tmp_db, keymaps = false })
      db = require("auditor.db")
      hl = require("auditor.highlights")
    end)

    it("extmarks are NOT cleared when DB clear fails", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(bufnr)
      auditor.enter_audit_mode()

      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      local marks_before = extmark_count(bufnr, hl.ns)
      assert.is_true(marks_before >= 1)

      local orig_clear = db.clear_highlights
      db.clear_highlights = function()
        error("simulated DB failure")
      end

      local restore = capture_notify()
      auditor.clear_buffer()
      restore()
      db.clear_highlights = orig_clear

      -- Extmarks should still be visible
      assert.equals(marks_before, extmark_count(bufnr, hl.ns))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("pending is NOT cleared when DB clear fails", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(bufnr)
      auditor.enter_audit_mode()

      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      assert.is_true(#auditor._pending[bufnr] > 0)

      local orig_clear = db.clear_highlights
      db.clear_highlights = function()
        error("simulated DB failure")
      end

      local restore = capture_notify()
      auditor.clear_buffer()
      restore()
      db.clear_highlights = orig_clear

      -- Pending should still be populated
      assert.is_true(#auditor._pending[bufnr] > 0)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("re-entering audit mode after DB failure still shows highlights", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(bufnr)
      auditor.enter_audit_mode()

      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      auditor.audit() -- save to DB

      local orig_clear = db.clear_highlights
      db.clear_highlights = function()
        error("simulated DB failure")
      end

      local restore = capture_notify()
      auditor.clear_buffer() -- fails, extmarks preserved
      restore()
      db.clear_highlights = orig_clear

      -- Exit and re-enter — DB rows still exist, so they should be restored
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      assert.is_true(extmark_count(bufnr, hl.ns) >= 1)

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── R12: clear_buffer() DB-first ordering — extmarks cleared on success ───

  describe("R12: clear_buffer() clears extmarks on DB success", function()
    local auditor, db, hl

    before_each(function()
      reset_modules()
      auditor = require("auditor")
      local tmp_db = vim.fn.tempname() .. ".db"
      auditor.setup({ db_path = tmp_db, keymaps = false })
      db = require("auditor.db")
      hl = require("auditor.highlights")
    end)

    it("extmarks are cleared when DB clear succeeds", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(bufnr)
      auditor.enter_audit_mode()

      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      auditor.audit()

      assert.is_true(extmark_count(bufnr, hl.ns) >= 1)
      assert.is_true(#db.get_highlights(filepath) >= 1)

      auditor.clear_buffer()

      assert.equals(0, extmark_count(bufnr, hl.ns))
      assert.same({}, db.get_highlights(filepath))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("pending is cleared when DB clear succeeds", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello" })
      vim.api.nvim_set_current_buf(bufnr)
      auditor.enter_audit_mode()

      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      assert.is_true(#auditor._pending[bufnr] > 0)

      auditor.clear_buffer()
      assert.same({}, auditor._pending[bufnr])

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("re-entering after successful clear shows no highlights", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello" })
      vim.api.nvim_set_current_buf(bufnr)
      auditor.enter_audit_mode()

      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      auditor.audit()
      auditor.clear_buffer()

      auditor.exit_audit_mode()
      auditor.enter_audit_mode()

      assert.equals(0, extmark_count(bufnr, hl.ns))
      assert.same({}, db.get_highlights(filepath))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)
end)
