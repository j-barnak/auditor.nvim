-- test/spec/state_machine_spec.lua
-- Exhaustive tests for the Enter/Exit audit mode state machine.
--
-- Models the state machine as:
--   State: { mode: bool, extmarks_visible: bool, pending_preserved: bool, db_unchanged: bool }
--   Transitions: enter_audit_mode(), exit_audit_mode()
--
-- Verifies invariants hold for all possible transition sequences.

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
      error(
        string.format("[state_machine] '%s' failed at seed=%d:\n%s", desc, seed, tostring(err)),
        2
      )
    end
  end
end

local function extmark_count(bufnr, ns)
  return #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
end

-- ═══════════════════════════════════════════════════════════════════════════
-- BASIC STATE TRANSITIONS
-- ═══════════════════════════════════════════════════════════════════════════

describe("state machine: basic transitions", function()
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

  -- ── initial state ─────────────────────────────────────────────────────

  it("initial state: mode is OFF", function()
    assert.is_false(auditor._audit_mode)
  end)

  it("initial state: no extmarks on any buffer", function()
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello" })
    assert.equals(0, extmark_count(b, hl.ns))
    pcall(vim.api.nvim_buf_delete, b, { force = true })
  end)

  -- ── OFF → ON ──────────────────────────────────────────────────────────

  it("OFF → ON: mode becomes true", function()
    auditor.enter_audit_mode()
    assert.is_true(auditor._audit_mode)
  end)

  it("OFF → ON: saved highlights become visible", function()
    local b = vim.api.nvim_create_buf(false, true)
    local p = vim.fn.tempname() .. ".lua"
    vim.api.nvim_buf_set_name(b, p)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello world" })
    db.save_words(p, { { line = 0, col_start = 0, col_end = 5 } }, "red")

    assert.equals(0, extmark_count(b, hl.ns))
    auditor.enter_audit_mode()
    assert.equals(1, extmark_count(b, hl.ns))

    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)

  -- ── ON → OFF ──────────────────────────────────────────────────────────

  it("ON → OFF: mode becomes false", function()
    auditor.enter_audit_mode()
    auditor.exit_audit_mode()
    assert.is_false(auditor._audit_mode)
  end)

  it("ON → OFF: all extmarks are cleared", function()
    local b = vim.api.nvim_create_buf(false, true)
    local p = vim.fn.tempname() .. ".lua"
    vim.api.nvim_buf_set_name(b, p)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello world" })
    db.save_words(p, { { line = 0, col_start = 0, col_end = 5 } }, "red")

    auditor.enter_audit_mode()
    assert.equals(1, extmark_count(b, hl.ns))

    auditor.exit_audit_mode()
    assert.equals(0, extmark_count(b, hl.ns))

    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)

  it("ON → OFF: DB is not modified", function()
    local p = vim.fn.tempname() .. ".lua"
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(b, p)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello" })
    db.save_words(p, { { line = 0, col_start = 0, col_end = 5 } }, "red")
    local before = #db.get_highlights(p)

    auditor.enter_audit_mode()
    auditor.exit_audit_mode()

    assert.equals(before, #db.get_highlights(p))

    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)

  -- ── ON → ON (idempotent enter) ────────────────────────────────────────

  it("ON → ON: mode stays true", function()
    auditor.enter_audit_mode()
    auditor.enter_audit_mode()
    assert.is_true(auditor._audit_mode)
  end)

  it("ON → ON: no duplicate extmarks", function()
    local b = vim.api.nvim_create_buf(false, true)
    local p = vim.fn.tempname() .. ".lua"
    vim.api.nvim_buf_set_name(b, p)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello world" })
    db.save_words(p, {
      { line = 0, col_start = 0, col_end = 5 },
      { line = 0, col_start = 6, col_end = 11 },
    }, "red")

    auditor.enter_audit_mode()
    local count1 = extmark_count(b, hl.ns)
    auditor.enter_audit_mode()
    local count2 = extmark_count(b, hl.ns)

    assert.equals(count1, count2)
    assert.equals(2, count2)

    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)

  -- ── OFF → OFF (idempotent exit) ───────────────────────────────────────

  it("OFF → OFF: mode stays false", function()
    auditor.exit_audit_mode()
    assert.is_false(auditor._audit_mode)
    auditor.exit_audit_mode()
    assert.is_false(auditor._audit_mode)
  end)

  it("OFF → OFF: no error", function()
    assert.has_no.errors(function()
      auditor.exit_audit_mode()
      auditor.exit_audit_mode()
      auditor.exit_audit_mode()
    end)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- PENDING ACROSS STATE TRANSITIONS
-- ═══════════════════════════════════════════════════════════════════════════

describe("state machine: pending across transitions", function()
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

  it("pending survives ON → OFF", function()
    local b = vim.api.nvim_create_buf(false, true)
    local p = vim.fn.tempname() .. ".lua"
    vim.api.nvim_buf_set_name(b, p)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello world" })
    vim.api.nvim_set_current_buf(b)

    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    assert.equals(1, #auditor._pending[b])

    auditor.exit_audit_mode()
    assert.equals(1, #auditor._pending[b])

    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)

  it("pending survives ON → OFF → ON", function()
    local b = vim.api.nvim_create_buf(false, true)
    local p = vim.fn.tempname() .. ".lua"
    vim.api.nvim_buf_set_name(b, p)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello world" })
    vim.api.nvim_set_current_buf(b)

    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")

    auditor.exit_audit_mode()
    auditor.enter_audit_mode()

    -- Pending still there
    assert.equals(1, #auditor._pending[b])
    -- Extmarks re-applied
    assert.equals(1, extmark_count(b, hl.ns))
    -- DB still empty (not saved)
    assert.same({}, db.get_highlights(p))

    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)

  it("pending can be saved after ON → OFF → ON", function()
    local b = vim.api.nvim_create_buf(false, true)
    local p = vim.fn.tempname() .. ".lua"
    vim.api.nvim_buf_set_name(b, p)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello world" })
    vim.api.nvim_set_current_buf(b)

    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")

    auditor.exit_audit_mode()
    auditor.enter_audit_mode()
    auditor.audit()

    assert.equals(1, #db.get_highlights(p))
    assert.same({}, auditor._pending[b])

    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)

  it("pending is cleared by clear_buffer in ON state", function()
    local b = vim.api.nvim_create_buf(false, true)
    local p = vim.fn.tempname() .. ".lua"
    vim.api.nvim_buf_set_name(b, p)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello world" })
    vim.api.nvim_set_current_buf(b)

    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    auditor.audit()
    auditor.clear_buffer()

    assert.same({}, auditor._pending[b])
    assert.same({}, db.get_highlights(p))
    assert.equals(0, extmark_count(b, hl.ns))

    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- COMMAND GATING
-- ═══════════════════════════════════════════════════════════════════════════

describe("state machine: command gating", function()
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

  local function make_buf()
    local b = vim.api.nvim_create_buf(false, true)
    local p = vim.fn.tempname() .. ".lua"
    vim.api.nvim_buf_set_name(b, p)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello world" })
    vim.api.nvim_set_current_buf(b)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    return b, p
  end

  it("highlight_cword_buffer is blocked in OFF state", function()
    local b, p = make_buf()
    auditor.highlight_cword_buffer("red")
    assert.equals(0, extmark_count(b, hl.ns))
    assert.is_nil(auditor._pending[b])
    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)

  it("highlight_cword is blocked in OFF state", function()
    local b, p = make_buf()
    auditor.highlight_cword("red")
    assert.equals(0, extmark_count(b, hl.ns))
    assert.is_nil(auditor._pending[b])
    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)

  it("audit() is blocked in OFF state", function()
    local b, p = make_buf()
    auditor._pending[b] =
      { { words = { { line = 0, col_start = 0, col_end = 5 } }, color = "red" } }
    auditor.audit()
    assert.same({}, db.get_highlights(p))
    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)

  it("clear_buffer() is blocked in OFF state", function()
    local b, p = make_buf()
    db.save_words(p, { { line = 0, col_start = 0, col_end = 5 } }, "red")
    auditor.clear_buffer()
    assert.equals(1, #db.get_highlights(p))
    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)

  it("pick_color() is blocked in OFF state", function()
    local b, p = make_buf()
    -- pick_color uses vim.ui.select which we can't easily test interactively,
    -- but the guard should prevent any action
    auditor.pick_color()
    assert.equals(0, extmark_count(b, hl.ns))
    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)

  it("all commands work after entering ON state", function()
    local b, p = make_buf()
    auditor.enter_audit_mode()

    auditor.highlight_cword_buffer("red")
    assert.equals(1, extmark_count(b, hl.ns))
    assert.equals(1, #auditor._pending[b])

    auditor.audit()
    assert.equals(1, #db.get_highlights(p))

    auditor.clear_buffer()
    assert.same({}, db.get_highlights(p))
    assert.equals(0, extmark_count(b, hl.ns))

    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)

  it("commands blocked again after ON → OFF", function()
    local b, p = make_buf()
    auditor.enter_audit_mode()
    auditor.exit_audit_mode()

    auditor.highlight_cword_buffer("red")
    assert.equals(0, extmark_count(b, hl.ns))

    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)

  it("commands work again after ON → OFF → ON", function()
    local b, p = make_buf()
    auditor.enter_audit_mode()
    auditor.exit_audit_mode()
    auditor.enter_audit_mode()

    auditor.highlight_cword_buffer("blue")
    assert.equals(1, extmark_count(b, hl.ns))

    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- EXHAUSTIVE SEQUENCES (all length-N paths)
-- ═══════════════════════════════════════════════════════════════════════════

describe("state machine: exhaustive sequences", function()
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

  it("all 2^4 = 16 length-4 enter/exit sequences maintain invariants", function()
    for bits = 0, 15 do
      reset_modules()
      auditor = require("auditor")
      auditor.setup({ db_path = tmp_db, keymaps = false })
      hl = require("auditor.highlights")
      db = require("auditor.db")

      local b = vim.api.nvim_create_buf(false, true)
      local p = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(b, p)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello world" })
      db.save_words(p, { { line = 0, col_start = 0, col_end = 5 } }, "red")

      local last_was_enter = false
      local seq = {}
      for i = 0, 3 do
        local is_enter = bit.band(bits, bit.lshift(1, i)) ~= 0
        if is_enter then
          auditor.enter_audit_mode()
          last_was_enter = true
          table.insert(seq, "E")
        else
          auditor.exit_audit_mode()
          last_was_enter = false
          table.insert(seq, "X")
        end
      end

      local seq_str = table.concat(seq)

      -- Invariant 1: mode matches last op
      assert(
        auditor._audit_mode == last_was_enter,
        string.format(
          "seq %s: mode=%s, last_enter=%s",
          seq_str,
          tostring(auditor._audit_mode),
          tostring(last_was_enter)
        )
      )

      -- Invariant 2: if mode ON, extmarks visible; if OFF, extmarks cleared
      if auditor._audit_mode then
        assert(extmark_count(b, hl.ns) >= 1, string.format("seq %s: ON but no extmarks", seq_str))
      else
        assert(extmark_count(b, hl.ns) == 0, string.format("seq %s: OFF but has extmarks", seq_str))
      end

      -- Invariant 3: DB unchanged
      assert(#db.get_highlights(p) == 1, string.format("seq %s: DB changed", seq_str))

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end
  end)

  it("all 2^6 = 64 length-6 enter/exit sequences maintain invariants", function()
    for bits = 0, 63 do
      reset_modules()
      auditor = require("auditor")
      auditor.setup({ db_path = tmp_db, keymaps = false })
      hl = require("auditor.highlights")
      db = require("auditor.db")

      local b = vim.api.nvim_create_buf(false, true)
      local p = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(b, p)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "test data" })
      db.save_words(p, {
        { line = 0, col_start = 0, col_end = 4 },
        { line = 0, col_start = 5, col_end = 9 },
      }, "blue")

      local last_was_enter = false
      for i = 0, 5 do
        if bit.band(bits, bit.lshift(1, i)) ~= 0 then
          auditor.enter_audit_mode()
          last_was_enter = true
        else
          auditor.exit_audit_mode()
          last_was_enter = false
        end
      end

      assert(auditor._audit_mode == last_was_enter)

      if auditor._audit_mode then
        assert(extmark_count(b, hl.ns) == 2)
      else
        assert(extmark_count(b, hl.ns) == 0)
      end

      assert(#db.get_highlights(p) == 2)

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- PROPERTY-BASED: random sequences with marking
-- ═══════════════════════════════════════════════════════════════════════════

describe("state machine: property-based", function()
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

  it("P1: mode flag is always consistent with last enter/exit call", function()
    property("mode flag consistency", 500, function(rng)
      local n = rng(1, 30)
      local last_enter = false
      for _ = 1, n do
        if rng(0, 1) == 1 then
          auditor.enter_audit_mode()
          last_enter = true
        else
          auditor.exit_audit_mode()
          last_enter = false
        end
      end
      assert(auditor._audit_mode == last_enter)
    end)
  end)

  it("P2: exit always clears all extmarks across all buffers", function()
    property("exit clears extmarks", 200, function(rng)
      local bufs = {}
      local n_bufs = rng(1, 4)
      for i = 1, n_bufs do
        local b = vim.api.nvim_create_buf(false, true)
        local p = vim.fn.tempname() .. ".lua"
        vim.api.nvim_buf_set_name(b, p)
        vim.api.nvim_buf_set_lines(b, 0, -1, false, { "word" .. i })
        db.save_words(p, { { line = 0, col_start = 0, col_end = 5 } }, "red")
        bufs[i] = { bufnr = b, path = p }
      end

      -- Random transitions
      for _ = 1, rng(1, 10) do
        if rng(0, 1) == 1 then
          auditor.enter_audit_mode()
        else
          auditor.exit_audit_mode()
        end
      end
      -- Final exit
      auditor.exit_audit_mode()

      for _, buf in ipairs(bufs) do
        assert(extmark_count(buf.bufnr, hl.ns) == 0)
        pcall(vim.api.nvim_buf_delete, buf.bufnr, { force = true })
        pcall(os.remove, buf.path)
      end
    end)
  end)

  it("P3: enter always restores exact DB extmark count", function()
    property("enter restores DB highlights", 200, function(rng)
      local b = vim.api.nvim_create_buf(false, true)
      local p = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(b, p)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "aa bb cc dd ee" })
      local n_tokens = rng(1, 5)
      local words = {}
      for j = 1, n_tokens do
        table.insert(words, { line = 0, col_start = (j - 1) * 3, col_end = (j - 1) * 3 + 2 })
      end
      db.save_words(p, words, "red")

      -- Random transitions ending with enter
      for _ = 1, rng(0, 8) do
        if rng(0, 1) == 1 then
          auditor.enter_audit_mode()
        else
          auditor.exit_audit_mode()
        end
      end
      auditor.enter_audit_mode()

      assert(
        extmark_count(b, hl.ns) == n_tokens,
        string.format("expected %d extmarks, got %d", n_tokens, extmark_count(b, hl.ns))
      )

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)

  it("P4: DB is never modified by enter/exit", function()
    property("DB immutability", 300, function(rng)
      local p = vim.fn.tempname() .. ".lua"
      local b = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(b, p)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello" })
      local n_saved = rng(1, 5)
      local words = {}
      for _ = 1, n_saved do
        table.insert(words, { line = 0, col_start = 0, col_end = 5 })
      end
      db.save_words(p, words, "blue")
      local before = #db.get_highlights(p)

      for _ = 1, rng(2, 20) do
        if rng(0, 1) == 1 then
          auditor.enter_audit_mode()
        else
          auditor.exit_audit_mode()
        end
      end

      assert(#db.get_highlights(p) == before)

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)

  it("P5: blocked commands in OFF state never produce side effects", function()
    property("OFF state side-effect freedom", 200, function(rng)
      local b = vim.api.nvim_create_buf(false, true)
      local p = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(b, p)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(b)

      auditor.exit_audit_mode()
      local db_before = #db.get_highlights(p)
      local marks_before = extmark_count(b, hl.ns)

      for _ = 1, rng(3, 15) do
        local op = rng(1, 3)
        if op == 1 then
          vim.api.nvim_win_set_cursor(0, { 1, rng(0, 10) })
          auditor.highlight_cword_buffer("red")
        elseif op == 2 then
          vim.api.nvim_win_set_cursor(0, { 1, rng(0, 10) })
          auditor.highlight_cword("blue")
        elseif op == 3 then
          auditor.audit()
        end
      end

      assert(extmark_count(b, hl.ns) == marks_before)
      assert(#db.get_highlights(p) == db_before)

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)

  it("P6: marking in ON, then ON→OFF→ON, extmark count = saved + pending", function()
    property("pending re-applied on re-enter", 200, function(rng)
      local b = vim.api.nvim_create_buf(false, true)
      local p = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(b, p)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(b)

      -- Seed some saved data
      local n_saved = rng(0, 2)
      if n_saved > 0 then
        local words = {}
        if n_saved >= 1 then
          table.insert(words, { line = 0, col_start = 0, col_end = 5 })
        end
        if n_saved >= 2 then
          table.insert(words, { line = 0, col_start = 6, col_end = 11 })
        end
        db.save_words(p, words, "blue")
      end

      auditor.enter_audit_mode()

      -- Mark pending
      local n_pending = rng(0, 2)
      local cols = { { 0, "hello" }, { 6, "world" } }
      for i = 1, n_pending do
        vim.api.nvim_win_set_cursor(0, { 1, cols[i][1] })
        auditor.highlight_cword_buffer("red")
      end

      local total_expected = n_saved + n_pending
      assert(
        extmark_count(b, hl.ns) == total_expected,
        string.format("before exit: expected %d, got %d", total_expected, extmark_count(b, hl.ns))
      )

      -- Round-trip
      auditor.exit_audit_mode()
      assert(extmark_count(b, hl.ns) == 0)
      auditor.enter_audit_mode()

      assert(
        extmark_count(b, hl.ns) == total_expected,
        string.format(
          "after re-enter: expected %d, got %d",
          total_expected,
          extmark_count(b, hl.ns)
        )
      )

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- FUZZ: random ops never crash
-- ═══════════════════════════════════════════════════════════════════════════

describe("state machine: fuzz", function()
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

  it("F1: random mix of all operations never errors", function()
    property("no crashes", 300, function(rng)
      local b = vim.api.nvim_create_buf(false, true)
      local p = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(b, p)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "alpha beta gamma" })
      vim.api.nvim_set_current_buf(b)

      local colors = { "red", "blue", "half" }
      for _ = 1, rng(10, 40) do
        local op = rng(1, 7)
        if op == 1 then
          auditor.enter_audit_mode()
        elseif op == 2 then
          auditor.exit_audit_mode()
        elseif op == 3 then
          vim.api.nvim_win_set_cursor(0, { 1, rng(0, 15) })
          auditor.highlight_cword_buffer(colors[rng(1, 3)])
        elseif op == 4 then
          vim.api.nvim_win_set_cursor(0, { 1, rng(0, 15) })
          auditor.highlight_cword(colors[rng(1, 3)])
        elseif op == 5 then
          auditor.audit()
        elseif op == 6 then
          auditor.clear_buffer()
        elseif op == 7 then
          -- no-op: just move cursor
          vim.api.nvim_win_set_cursor(0, { 1, rng(0, 15) })
        end
      end

      -- Final invariant: mode matches expectation
      if auditor._audit_mode then
        -- No crash accessing extmarks
        local _ = extmark_count(b, hl.ns)
      else
        assert(extmark_count(b, hl.ns) == 0)
      end

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)
end)
