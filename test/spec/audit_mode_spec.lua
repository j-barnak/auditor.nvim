-- test/spec/audit_mode_spec.lua
-- Exhaustive tests for audit mode: EnterAuditMode / ExitAuditMode
--
-- Coverage:
--   Unit tests       — state flag, command registration, guards
--   Integration      — highlight visibility across enter/exit cycles
--   Multi-buffer     — highlights across multiple buffers
--   Pending          — unsaved highlights preserved across mode transitions
--   Property-based   — random enter/exit sequences
--   Fuzz             — random mark/save/enter/exit interleaving

local function reset_modules()
  for _, m in ipairs({ "auditor", "auditor.init", "auditor.db", "auditor.highlights", "auditor.ts" }) do
    package.loaded[m] = nil
  end
end

-- ── deterministic PRNG (same LCG as fuzz_spec) ─────────────────────────────

---@param seed integer
---@return fun(lo: integer, hi: integer): integer
local function make_rng(seed)
  local s = math.abs(seed) + 1
  return function(lo, hi)
    s = (s * 1664525 + 1013904223) % (2 ^ 32)
    return lo + (math.floor(s * (hi - lo + 1) / (2 ^ 32)))
  end
end

-- Run a property over `n` seeds; error message includes the seed.
local function property(desc, n, fn)
  for seed = 1, n do
    local rng = make_rng(seed)
    local ok, err = pcall(fn, rng, seed)
    if not ok then
      error(
        string.format(
          "[audit_mode] Property '%s' failed at seed=%d:\n%s",
          desc,
          seed,
          tostring(err)
        ),
        2
      )
    end
  end
end

-- ── helpers ─────────────────────────────────────────────────────────────────

local function make_named_buf(_auditor, text)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local filepath = vim.fn.tempname() .. ".lua"
  vim.api.nvim_buf_set_name(bufnr, filepath)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, type(text) == "table" and text or { text })
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr, filepath
end

-- Place cursor on the first word character of the buffer.
local function cursor_on_first_word()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
end

local function extmark_count(bufnr, ns)
  return #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
end

-- ═══════════════════════════════════════════════════════════════════════════
-- UNIT TESTS
-- ═══════════════════════════════════════════════════════════════════════════

describe("audit mode: unit", function()
  local auditor, hl
  local tmp_db

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

  -- ── state flag ──────────────────────────────────────────────────────────

  describe("state flag", function()
    it("defaults to false after setup", function()
      assert.is_false(auditor._audit_mode)
    end)

    it("is true after enter_audit_mode", function()
      auditor.enter_audit_mode()
      assert.is_true(auditor._audit_mode)
    end)

    it("is false after exit_audit_mode", function()
      auditor.enter_audit_mode()
      auditor.exit_audit_mode()
      assert.is_false(auditor._audit_mode)
    end)

    it("enter is idempotent (calling twice still true)", function()
      auditor.enter_audit_mode()
      auditor.enter_audit_mode()
      assert.is_true(auditor._audit_mode)
    end)

    it("exit is idempotent (calling twice still false)", function()
      auditor.exit_audit_mode()
      auditor.exit_audit_mode()
      assert.is_false(auditor._audit_mode)
    end)
  end)

  -- ── command registration ────────────────────────────────────────────────

  describe("command registration", function()
    it("registers EnterAuditMode", function()
      assert.equals(2, vim.fn.exists(":EnterAuditMode"))
    end)

    it("registers ExitAuditMode", function()
      assert.equals(2, vim.fn.exists(":ExitAuditMode"))
    end)
  end)

  -- ── command guards ──────────────────────────────────────────────────────

  describe("command guards (outside audit mode)", function()
    local bufnr, filepath

    before_each(function()
      bufnr, filepath = make_named_buf(auditor, "hello world")
    end)

    after_each(function()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      pcall(os.remove, filepath)
    end)

    it("highlight_cword_buffer is blocked", function()
      cursor_on_first_word()
      auditor.highlight_cword_buffer("red")
      assert.equals(0, extmark_count(bufnr, hl.ns))
    end)

    it("highlight_cword is blocked", function()
      cursor_on_first_word()
      auditor.highlight_cword("red")
      assert.equals(0, extmark_count(bufnr, hl.ns))
    end)

    it("audit() is blocked", function()
      -- Force something into pending to verify it's not saved
      auditor._pending[bufnr] =
        { { words = { { line = 0, col_start = 0, col_end = 5 } }, color = "red" } }
      auditor.audit()
      local db = require("auditor.db")
      assert.same({}, db.get_highlights(filepath))
    end)

    it("clear_buffer() is blocked", function()
      -- Manually insert a DB row, then verify clear_buffer doesn't remove it
      local db = require("auditor.db")
      db.save_words(filepath, { { line = 0, col_start = 0, col_end = 5 } }, "red")
      auditor.clear_buffer()
      assert.equals(1, #db.get_highlights(filepath))
    end)

    it("no pending entries created when highlight_cword_buffer is blocked", function()
      cursor_on_first_word()
      auditor.highlight_cword_buffer("red")
      assert.is_nil(auditor._pending[bufnr])
    end)

    it("no pending entries created when highlight_cword is blocked", function()
      cursor_on_first_word()
      auditor.highlight_cword("red")
      assert.is_nil(auditor._pending[bufnr])
    end)
  end)

  -- ── commands work IN audit mode ─────────────────────────────────────────

  describe("commands work inside audit mode", function()
    local bufnr, filepath

    before_each(function()
      bufnr, filepath = make_named_buf(auditor, "hello world")
      auditor.enter_audit_mode()
    end)

    after_each(function()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      pcall(os.remove, filepath)
    end)

    it("highlight_cword_buffer applies extmarks", function()
      cursor_on_first_word()
      auditor.highlight_cword_buffer("red")
      assert.is_true(extmark_count(bufnr, hl.ns) >= 1)
    end)

    it("highlight_cword applies extmarks", function()
      cursor_on_first_word()
      auditor.highlight_cword("blue")
      assert.is_true(extmark_count(bufnr, hl.ns) >= 1)
    end)

    it("audit() saves to DB", function()
      cursor_on_first_word()
      auditor.highlight_cword_buffer("red")
      auditor.audit()
      local db = require("auditor.db")
      assert.is_true(#db.get_highlights(filepath) >= 1)
    end)

    it("clear_buffer() removes extmarks and DB rows", function()
      cursor_on_first_word()
      auditor.highlight_cword_buffer("red")
      auditor.audit()
      auditor.clear_buffer()
      assert.equals(0, extmark_count(bufnr, hl.ns))
      local db = require("auditor.db")
      assert.same({}, db.get_highlights(filepath))
    end)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- INTEGRATION TESTS
-- ═══════════════════════════════════════════════════════════════════════════

describe("audit mode: integration", function()
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

  -- ── highlight visibility ────────────────────────────────────────────────

  describe("highlight visibility", function()
    local bufnr, filepath

    before_each(function()
      bufnr, filepath = make_named_buf(auditor, "hello world")
    end)

    after_each(function()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      pcall(os.remove, filepath)
    end)

    it("entering mode restores saved highlights from DB", function()
      -- Seed DB directly
      db.save_words(filepath, {
        { line = 0, col_start = 0, col_end = 5 },
        { line = 0, col_start = 6, col_end = 11 },
      }, "red")
      assert.equals(0, extmark_count(bufnr, hl.ns))

      auditor.enter_audit_mode()
      assert.equals(2, extmark_count(bufnr, hl.ns))
    end)

    it("exiting mode clears all extmarks", function()
      auditor.enter_audit_mode()
      cursor_on_first_word()
      auditor.highlight_cword_buffer("red")
      assert.is_true(extmark_count(bufnr, hl.ns) >= 1)

      auditor.exit_audit_mode()
      assert.equals(0, extmark_count(bufnr, hl.ns))
    end)

    it("exiting mode does NOT clear the database", function()
      auditor.enter_audit_mode()
      cursor_on_first_word()
      auditor.highlight_cword_buffer("red")
      auditor.audit()
      local count_before = #db.get_highlights(filepath)
      assert.is_true(count_before >= 1)

      auditor.exit_audit_mode()
      assert.equals(count_before, #db.get_highlights(filepath))
    end)

    it("re-entering mode restores highlights from DB", function()
      auditor.enter_audit_mode()
      cursor_on_first_word()
      auditor.highlight_cword_buffer("blue")
      auditor.audit()
      auditor.exit_audit_mode()
      assert.equals(0, extmark_count(bufnr, hl.ns))

      auditor.enter_audit_mode()
      assert.is_true(extmark_count(bufnr, hl.ns) >= 1)
    end)

    it("enter does not duplicate extmarks on repeated calls", function()
      db.save_words(filepath, {
        { line = 0, col_start = 0, col_end = 5 },
      }, "red")

      auditor.enter_audit_mode()
      local count1 = extmark_count(bufnr, hl.ns)

      auditor.enter_audit_mode()
      local count2 = extmark_count(bufnr, hl.ns)

      assert.equals(count1, count2)
    end)
  end)

  -- ── pending preservation ────────────────────────────────────────────────

  describe("pending preservation across mode transitions", function()
    local bufnr, filepath

    before_each(function()
      bufnr, filepath = make_named_buf(auditor, "hello world")
    end)

    after_each(function()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      pcall(os.remove, filepath)
    end)

    it("pending is preserved after exit", function()
      auditor.enter_audit_mode()
      cursor_on_first_word()
      auditor.highlight_cword_buffer("red")
      assert.is_true(#auditor._pending[bufnr] >= 1)

      auditor.exit_audit_mode()
      assert.is_true(#auditor._pending[bufnr] >= 1)
    end)

    it("pending extmarks are re-applied on enter", function()
      auditor.enter_audit_mode()
      cursor_on_first_word()
      auditor.highlight_cword_buffer("red")
      local count_before = extmark_count(bufnr, hl.ns)

      auditor.exit_audit_mode()
      assert.equals(0, extmark_count(bufnr, hl.ns))

      auditor.enter_audit_mode()
      assert.equals(count_before, extmark_count(bufnr, hl.ns))
    end)

    it("can save pending after re-entering mode", function()
      auditor.enter_audit_mode()
      cursor_on_first_word()
      auditor.highlight_cword_buffer("red")
      auditor.exit_audit_mode()

      auditor.enter_audit_mode()
      auditor.audit()
      assert.is_true(#db.get_highlights(filepath) >= 1)
    end)

    it("pending is cleared after successful audit", function()
      auditor.enter_audit_mode()
      cursor_on_first_word()
      auditor.highlight_cword_buffer("red")
      auditor.audit()
      assert.same({}, auditor._pending[bufnr])
    end)
  end)

  -- ── unsaved highlights: in-memory only ───────────────────────────────────

  describe("unsaved highlights are in-memory only", function()
    local bufnr, filepath

    before_each(function()
      bufnr, filepath = make_named_buf(auditor, "hello world")
      auditor.enter_audit_mode()
    end)

    after_each(function()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      pcall(os.remove, filepath)
    end)

    it("marking tokens creates extmarks but zero DB rows", function()
      cursor_on_first_word()
      auditor.highlight_cword_buffer("red")
      assert.is_true(extmark_count(bufnr, hl.ns) >= 1)
      assert.same({}, db.get_highlights(filepath))
    end)

    it("multiple mark calls accumulate extmarks but zero DB rows", function()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      vim.api.nvim_win_set_cursor(0, { 1, 6 })
      auditor.highlight_cword_buffer("blue")
      assert.is_true(extmark_count(bufnr, hl.ns) >= 2)
      assert.same({}, db.get_highlights(filepath))
    end)

    it("cword marking creates extmarks but zero DB rows", function()
      cursor_on_first_word()
      auditor.highlight_cword("red")
      assert.is_true(extmark_count(bufnr, hl.ns) >= 1)
      assert.same({}, db.get_highlights(filepath))
    end)

    it("unsaved marks survive one enter/exit cycle with zero DB rows", function()
      cursor_on_first_word()
      auditor.highlight_cword_buffer("red")
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()
      assert.is_true(extmark_count(bufnr, hl.ns) >= 1)
      assert.same({}, db.get_highlights(filepath))
    end)

    it("unsaved marks survive multiple enter/exit cycles with zero DB rows", function()
      cursor_on_first_word()
      auditor.highlight_cword_buffer("blue")
      for _ = 1, 5 do
        auditor.exit_audit_mode()
        auditor.enter_audit_mode()
      end
      assert.is_true(extmark_count(bufnr, hl.ns) >= 1)
      assert.same({}, db.get_highlights(filepath))
    end)

    it("simulated restart loses unsaved marks (module reload = pending gone)", function()
      cursor_on_first_word()
      auditor.highlight_cword_buffer("red")
      assert.is_true(extmark_count(bufnr, hl.ns) >= 1)
      assert.same({}, db.get_highlights(filepath))

      -- Simulate Neovim restart: reload all modules from scratch
      reset_modules()
      auditor = require("auditor")
      auditor.setup({ db_path = tmp_db, keymaps = false })
      db = require("auditor.db")
      hl = require("auditor.highlights")

      -- Pending is gone, DB is empty, extmarks were cleared by namespace reset
      assert.same({}, auditor._pending)
      assert.same({}, db.get_highlights(filepath))
    end)

    it("simulated restart preserves saved marks", function()
      cursor_on_first_word()
      auditor.highlight_cword_buffer("red")
      auditor.audit()
      local saved_count = #db.get_highlights(filepath)
      assert.is_true(saved_count >= 1)

      -- Simulate Neovim restart
      reset_modules()
      auditor = require("auditor")
      auditor.setup({ db_path = tmp_db, keymaps = false })
      db = require("auditor.db")
      hl = require("auditor.highlights")

      -- Pending is gone but DB rows survive
      assert.same({}, auditor._pending)
      assert.equals(saved_count, #db.get_highlights(filepath))

      -- Enter audit mode restores them as extmarks
      auditor.enter_audit_mode()
      assert.equals(saved_count, extmark_count(bufnr, hl.ns))
    end)

    it("mix of saved and unsaved: only saved survive restart", function()
      -- Save first batch
      cursor_on_first_word()
      auditor.highlight_cword_buffer("red")
      auditor.audit()
      local saved_count = #db.get_highlights(filepath)

      -- Mark more without saving
      vim.api.nvim_win_set_cursor(0, { 1, 6 })
      auditor.highlight_cword_buffer("blue")
      local total_extmarks = extmark_count(bufnr, hl.ns)
      assert.is_true(total_extmarks > saved_count)

      -- Simulate restart
      reset_modules()
      auditor = require("auditor")
      auditor.setup({ db_path = tmp_db, keymaps = false })
      db = require("auditor.db")
      hl = require("auditor.highlights")

      -- Only the saved batch persists
      assert.equals(saved_count, #db.get_highlights(filepath))
      auditor.enter_audit_mode()
      assert.equals(saved_count, extmark_count(bufnr, hl.ns))
    end)
  end)

  -- ── multi-buffer ────────────────────────────────────────────────────────

  describe("multi-buffer", function()
    local bufs = {}
    local paths = {}

    before_each(function()
      for i = 1, 3 do
        local b = vim.api.nvim_create_buf(false, true)
        local p = vim.fn.tempname() .. ".lua"
        vim.api.nvim_buf_set_name(b, p)
        vim.api.nvim_buf_set_lines(b, 0, -1, false, { "token" .. i .. " data" })
        bufs[i] = b
        paths[i] = p
        db.save_words(p, { { line = 0, col_start = 0, col_end = 6 } }, "red")
      end
    end)

    after_each(function()
      for i = 1, 3 do
        pcall(vim.api.nvim_buf_delete, bufs[i], { force = true })
        pcall(os.remove, paths[i])
      end
      bufs = {}
      paths = {}
    end)

    it("enter restores highlights across all loaded buffers", function()
      auditor.enter_audit_mode()
      for i = 1, 3 do
        assert.is_true(
          extmark_count(bufs[i], hl.ns) >= 1,
          "buffer " .. i .. " missing extmarks after enter"
        )
      end
    end)

    it("exit clears highlights across all loaded buffers", function()
      auditor.enter_audit_mode()
      auditor.exit_audit_mode()
      for i = 1, 3 do
        assert.equals(
          0,
          extmark_count(bufs[i], hl.ns),
          "buffer " .. i .. " still has extmarks after exit"
        )
      end
    end)

    it("clear_buffer only affects current buffer", function()
      auditor.enter_audit_mode()
      vim.api.nvim_set_current_buf(bufs[1])
      auditor.clear_buffer()

      assert.equals(0, extmark_count(bufs[1], hl.ns))
      assert.same({}, db.get_highlights(paths[1]))

      -- Other buffers untouched
      assert.is_true(extmark_count(bufs[2], hl.ns) >= 1)
      assert.is_true(#db.get_highlights(paths[2]) >= 1)
    end)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- PROPERTY-BASED TESTS
-- ═══════════════════════════════════════════════════════════════════════════

describe("audit mode: property-based", function()
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

  it("P1: after any enter/exit sequence, _audit_mode matches the last operation", function()
    property("P1 mode flag consistency", 500, function(rng)
      local n_ops = rng(1, 20)
      local last_enter = false
      for _ = 1, n_ops do
        if rng(0, 1) == 1 then
          auditor.enter_audit_mode()
          last_enter = true
        else
          auditor.exit_audit_mode()
          last_enter = false
        end
      end
      assert(
        auditor._audit_mode == last_enter,
        string.format(
          "mode is %s but last op was %s",
          tostring(auditor._audit_mode),
          last_enter and "enter" or "exit"
        )
      )
    end)
  end)

  it("P2: after exit, no buffer has extmarks in the auditor namespace", function()
    property("P2 clean exit", 200, function(rng)
      -- Create 1-3 buffers with DB data
      local bufs = {}
      local n_bufs = rng(1, 3)
      for i = 1, n_bufs do
        local b = vim.api.nvim_create_buf(false, true)
        local p = vim.fn.tempname() .. ".lua"
        vim.api.nvim_buf_set_name(b, p)
        vim.api.nvim_buf_set_lines(b, 0, -1, false, { "word" .. i })
        db.save_words(p, { { line = 0, col_start = 0, col_end = 5 } }, "red")
        bufs[i] = { bufnr = b, filepath = p }
      end

      -- Random enter/exit sequence
      local n_ops = rng(1, 8)
      for _ = 1, n_ops do
        if rng(0, 1) == 1 then
          auditor.enter_audit_mode()
        else
          auditor.exit_audit_mode()
        end
      end
      auditor.exit_audit_mode()

      for _, buf in ipairs(bufs) do
        assert(
          extmark_count(buf.bufnr, hl.ns) == 0,
          string.format("buf %d has extmarks after exit", buf.bufnr)
        )
        pcall(vim.api.nvim_buf_delete, buf.bufnr, { force = true })
        pcall(os.remove, buf.filepath)
      end
    end)
  end)

  it("P3: after enter, all DB highlights are visible as extmarks", function()
    property("P3 enter restores all", 200, function(rng)
      local n_bufs = rng(1, 3)
      local bufs = {}
      for i = 1, n_bufs do
        local b = vim.api.nvim_create_buf(false, true)
        local p = vim.fn.tempname() .. ".lua"
        vim.api.nvim_buf_set_name(b, p)
        vim.api.nvim_buf_set_lines(b, 0, -1, false, { "aaaa bbbb cccc" })
        local n_tokens = rng(1, 3)
        local words = {}
        for j = 1, n_tokens do
          table.insert(words, { line = 0, col_start = (j - 1) * 5, col_end = (j - 1) * 5 + 4 })
        end
        db.save_words(p, words, "red")
        bufs[i] = { bufnr = b, filepath = p, expected = n_tokens }
      end

      auditor.enter_audit_mode()

      for _, buf in ipairs(bufs) do
        local count = extmark_count(buf.bufnr, hl.ns)
        assert(
          count == buf.expected,
          string.format("buf %d: expected %d extmarks, got %d", buf.bufnr, buf.expected, count)
        )
        pcall(vim.api.nvim_buf_delete, buf.bufnr, { force = true })
        pcall(os.remove, buf.filepath)
      end
    end)
  end)

  it("P4: enter/exit cycles never alter the database", function()
    property("P4 DB invariant", 300, function(rng)
      local b = vim.api.nvim_create_buf(false, true)
      local p = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(b, p)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello world" })

      db.save_words(p, {
        { line = 0, col_start = 0, col_end = 5 },
        { line = 0, col_start = 6, col_end = 11 },
      }, "blue")
      local db_before = db.get_highlights(p)

      local n_ops = rng(2, 15)
      for _ = 1, n_ops do
        if rng(0, 1) == 1 then
          auditor.enter_audit_mode()
        else
          auditor.exit_audit_mode()
        end
      end

      local db_after = db.get_highlights(p)
      assert(
        #db_before == #db_after,
        string.format(
          "DB count changed: %d -> %d after %d enter/exit ops",
          #db_before,
          #db_after,
          n_ops
        )
      )

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)

  it("P5: pending survives any enter/exit sequence", function()
    property("P5 pending durability", 200, function(rng)
      local b = vim.api.nvim_create_buf(false, true)
      local p = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(b, p)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(b)

      -- Enter, mark, then random transitions
      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      local pending_count = #auditor._pending[b]
      assert(pending_count >= 1)

      local n_ops = rng(1, 10)
      for _ = 1, n_ops do
        if rng(0, 1) == 1 then
          auditor.enter_audit_mode()
        else
          auditor.exit_audit_mode()
        end
      end

      assert(
        #auditor._pending[b] == pending_count,
        string.format("pending changed: %d -> %d", pending_count, #auditor._pending[b])
      )

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- FUZZ TESTS
-- ═══════════════════════════════════════════════════════════════════════════

describe("audit mode: fuzz", function()
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

  it("F1: random interleaving of enter/exit/mark/save/clear never errors", function()
    property("F1 no errors on random ops", 200, function(rng)
      local b = vim.api.nvim_create_buf(false, true)
      local p = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(b, p)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "alpha beta gamma" })
      vim.api.nvim_set_current_buf(b)

      local n_ops = rng(5, 30)
      for _ = 1, n_ops do
        local op = rng(1, 6)
        if op == 1 then
          auditor.enter_audit_mode()
        elseif op == 2 then
          auditor.exit_audit_mode()
        elseif op == 3 then
          vim.api.nvim_win_set_cursor(0, { 1, rng(0, 15) })
          local colors = { "red", "blue", "half" }
          auditor.highlight_cword_buffer(colors[rng(1, 3)])
        elseif op == 4 then
          vim.api.nvim_win_set_cursor(0, { 1, rng(0, 15) })
          local colors = { "red", "blue", "half" }
          auditor.highlight_cword(colors[rng(1, 3)])
        elseif op == 5 then
          auditor.audit()
        elseif op == 6 then
          auditor.clear_buffer()
        end
      end

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)

  it("F2: mark → save → exit → enter preserves correct extmark count", function()
    property("F2 round-trip extmark count", 200, function(rng)
      local b = vim.api.nvim_create_buf(false, true)
      local p = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(b, p)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(b)

      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local colors = { "red", "blue", "half" }
      auditor.highlight_cword_buffer(colors[rng(1, 3)])
      auditor.audit()

      local saved_count = #db.get_highlights(p)
      assert(saved_count >= 1)

      -- Random number of exit/enter cycles
      local n_cycles = rng(1, 5)
      for _ = 1, n_cycles do
        auditor.exit_audit_mode()
        assert(extmark_count(b, hl.ns) == 0)
        auditor.enter_audit_mode()
      end

      assert(
        extmark_count(b, hl.ns) == saved_count,
        string.format(
          "expected %d extmarks after %d cycles, got %d",
          saved_count,
          n_cycles,
          extmark_count(b, hl.ns)
        )
      )

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)

  it("F3: guard consistency — blocked ops never change extmark or DB state", function()
    property("F3 guard side-effect freedom", 300, function(rng)
      local b = vim.api.nvim_create_buf(false, true)
      local p = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(b, p)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(b)

      -- Seed some DB rows
      db.save_words(p, { { line = 0, col_start = 0, col_end = 5 } }, "red")
      local db_count = #db.get_highlights(p)

      -- Ensure we're NOT in audit mode
      auditor.exit_audit_mode()
      local marks_before = extmark_count(b, hl.ns)

      -- Random blocked operations
      local n_ops = rng(3, 15)
      for _ = 1, n_ops do
        local op = rng(1, 4)
        if op == 1 then
          vim.api.nvim_win_set_cursor(0, { 1, 0 })
          auditor.highlight_cword_buffer("red")
        elseif op == 2 then
          vim.api.nvim_win_set_cursor(0, { 1, 0 })
          auditor.highlight_cword("blue")
        elseif op == 3 then
          auditor.audit()
        elseif op == 4 then
          auditor.clear_buffer()
        end
      end

      assert(extmark_count(b, hl.ns) == marks_before, "extmarks changed by blocked operation")
      assert(#db.get_highlights(p) == db_count, "DB changed by blocked operation")

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- LOGICAL / EDGE CASE TESTS
-- ═══════════════════════════════════════════════════════════════════════════

describe("audit mode: edge cases", function()
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

  it("exit before any enter does not error", function()
    assert.has_no.errors(function()
      auditor.exit_audit_mode()
    end)
    assert.is_false(auditor._audit_mode)
  end)

  it("enter on empty buffer list does not error", function()
    assert.has_no.errors(function()
      auditor.enter_audit_mode()
    end)
    assert.is_true(auditor._audit_mode)
  end)

  it("scratch buffers (no name) are skipped on enter", function()
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "scratch content" })

    assert.has_no.errors(function()
      auditor.enter_audit_mode()
    end)
    assert.equals(0, extmark_count(scratch, hl.ns))

    pcall(vim.api.nvim_buf_delete, scratch, { force = true })
  end)

  it("deleted buffer in pending does not error on enter", function()
    auditor.enter_audit_mode()
    local b = vim.api.nvim_create_buf(false, true)
    local p = vim.fn.tempname() .. ".lua"
    vim.api.nvim_buf_set_name(b, p)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello" })
    vim.api.nvim_set_current_buf(b)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")

    -- Delete the buffer, then re-enter
    vim.api.nvim_buf_delete(b, { force = true })

    assert.has_no.errors(function()
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()
    end)

    pcall(os.remove, p)
  end)

  it("full lifecycle: enter → mark → save → exit → enter → clear → exit", function()
    local b, p = make_named_buf(auditor, "foo bar baz")
    cursor_on_first_word()

    auditor.enter_audit_mode()
    auditor.highlight_cword_buffer("half")
    auditor.audit()
    assert.is_true(#db.get_highlights(p) >= 1)

    auditor.exit_audit_mode()
    assert.equals(0, extmark_count(b, hl.ns))
    assert.is_true(#db.get_highlights(p) >= 1) -- DB still has data

    auditor.enter_audit_mode()
    assert.is_true(extmark_count(b, hl.ns) >= 1) -- restored

    auditor.clear_buffer()
    assert.equals(0, extmark_count(b, hl.ns))
    assert.same({}, db.get_highlights(p))

    auditor.exit_audit_mode()
    assert.is_false(auditor._audit_mode)

    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)

  it("mixed colors survive enter/exit round-trip", function()
    local b, p = make_named_buf(auditor, "aaa bbb ccc")

    auditor.enter_audit_mode()
    vim.api.nvim_set_current_buf(b)

    -- Mark first word red
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")

    -- Mark second word blue
    vim.api.nvim_win_set_cursor(0, { 1, 4 })
    auditor.highlight_cword_buffer("blue")

    auditor.audit()
    local rows = db.get_highlights(p)
    local colors = {}
    for _, r in ipairs(rows) do
      colors[r.color] = (colors[r.color] or 0) + 1
    end
    assert.is_true((colors["red"] or 0) >= 1)
    assert.is_true((colors["blue"] or 0) >= 1)

    -- Round-trip
    auditor.exit_audit_mode()
    auditor.enter_audit_mode()

    local marks = vim.api.nvim_buf_get_extmarks(b, hl.ns, 0, -1, { details = true })
    local restored_groups = {}
    for _, m in ipairs(marks) do
      restored_groups[m[4].hl_group] = true
    end
    assert.truthy(restored_groups["AuditorRed"])
    assert.truthy(restored_groups["AuditorBlue"])

    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)

  it("commands work via vim.cmd (not just Lua API)", function()
    local b, p = make_named_buf(auditor, "hello world")

    vim.cmd("EnterAuditMode")
    assert.is_true(auditor._audit_mode)

    vim.api.nvim_set_current_buf(b)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("AuditRed")
    assert.is_true(extmark_count(b, hl.ns) >= 1)

    vim.cmd("AuditSave")
    assert.is_true(#db.get_highlights(p) >= 1)

    vim.cmd("AuditClear")
    assert.equals(0, extmark_count(b, hl.ns))
    assert.same({}, db.get_highlights(p))

    vim.cmd("ExitAuditMode")
    assert.is_false(auditor._audit_mode)

    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)

  it("AuditWordRed works via vim.cmd in audit mode", function()
    local b, p = make_named_buf(auditor, "hello world")
    auditor.enter_audit_mode()
    vim.api.nvim_set_current_buf(b)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    vim.cmd("AuditWordRed")
    assert.is_true(extmark_count(b, hl.ns) >= 1)

    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)

  it("vim.cmd commands are blocked outside audit mode", function()
    local b, p = make_named_buf(auditor, "hello world")
    vim.api.nvim_set_current_buf(b)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    vim.cmd("AuditRed")
    assert.equals(0, extmark_count(b, hl.ns))

    vim.cmd("AuditSave")
    assert.same({}, db.get_highlights(p))

    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- HIGHLIGHT GROUP TESTS
-- ═══════════════════════════════════════════════════════════════════════════

describe("audit mode: highlight groups", function()
  local auditor, hl
  local tmp_db

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

  it("AuditorRed has high-contrast colors and bold", function()
    local group = vim.api.nvim_get_hl(0, { name = "AuditorRed" })
    assert.is_true(group.bold == true)
    assert.is_number(group.fg)
    assert.is_number(group.bg)
  end)

  it("AuditorBlue has high-contrast colors and bold", function()
    local group = vim.api.nvim_get_hl(0, { name = "AuditorBlue" })
    assert.is_true(group.bold == true)
    assert.is_number(group.fg)
    assert.is_number(group.bg)
  end)

  it("gradient groups are defined and bold", function()
    local g00 = vim.api.nvim_get_hl(0, { name = "AuditorGrad00" })
    local g15 = vim.api.nvim_get_hl(0, { name = "AuditorGrad15" })
    assert.is_true(g00.bold == true)
    assert.is_true(g15.bold == true)
    assert.is_number(g00.bg)
    assert.is_number(g15.bg)
  end)

  it("all four groups have distinct bg colors for red vs blue", function()
    local red_bg = vim.api.nvim_get_hl(0, { name = "AuditorRed" }).bg
    local blue_bg = vim.api.nvim_get_hl(0, { name = "AuditorBlue" }).bg
    assert.is_not.equal(red_bg, blue_bg)
  end)

  it("extmarks use correct highlight groups for each color", function()
    auditor.enter_audit_mode()
    local bufnr = vim.api.nvim_create_buf(false, true)
    local filepath = vim.fn.tempname() .. ".lua"
    vim.api.nvim_buf_set_name(bufnr, filepath)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "aaa bbb ccc" })
    vim.api.nvim_set_current_buf(bufnr)

    -- Red
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")

    local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, { details = true })
    local groups = {}
    for _, m in ipairs(marks) do
      groups[m[4].hl_group] = true
    end
    assert.truthy(groups["AuditorRed"])

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    pcall(os.remove, filepath)
  end)
end)
