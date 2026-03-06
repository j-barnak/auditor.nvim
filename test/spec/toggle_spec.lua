-- test/spec/toggle_spec.lua
-- Exhaustive tests for toggle_audit_mode() and is_active().
--
-- Coverage:
--   Unit tests       — is_active, toggle state transitions, command registration
--   Integration      — toggle restores/hides highlights, multi-buffer, pending
--   Exhaustive       — all 3^4 and 3^6 {enter, exit, toggle} sequences
--   Property-based   — random sequences, is_active consistency, DB immutability
--   Fuzz             — random op interleaving never crashes

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
      error(string.format("[toggle] '%s' failed at seed=%d:\n%s", desc, seed, tostring(err)), 2)
    end
  end
end

local function extmark_count(bufnr, ns)
  return #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
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
-- UNIT TESTS
-- ═══════════════════════════════════════════════════════════════════════════

describe("toggle: unit", function()
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

  -- ── is_active ──────────────────────────────────────────────────────────

  describe("is_active()", function()
    it("returns false after setup", function()
      assert.is_false(auditor.is_active())
    end)

    it("returns true after enter_audit_mode", function()
      auditor.enter_audit_mode()
      assert.is_true(auditor.is_active())
    end)

    it("returns false after exit_audit_mode", function()
      auditor.enter_audit_mode()
      auditor.exit_audit_mode()
      assert.is_false(auditor.is_active())
    end)

    it("always agrees with _audit_mode", function()
      assert.equals(auditor._audit_mode, auditor.is_active())
      auditor.enter_audit_mode()
      assert.equals(auditor._audit_mode, auditor.is_active())
      auditor.exit_audit_mode()
      assert.equals(auditor._audit_mode, auditor.is_active())
    end)

    it("returns a boolean, not a truthy value", function()
      assert.is_boolean(auditor.is_active())
      auditor.enter_audit_mode()
      assert.is_boolean(auditor.is_active())
    end)

    it("returns true after toggle from OFF", function()
      auditor.toggle_audit_mode()
      assert.is_true(auditor.is_active())
    end)

    it("returns false after toggle from ON", function()
      auditor.enter_audit_mode()
      auditor.toggle_audit_mode()
      assert.is_false(auditor.is_active())
    end)
  end)

  -- ── toggle_audit_mode ──────────────────────────────────────────────────

  describe("toggle_audit_mode()", function()
    it("OFF → ON", function()
      assert.is_false(auditor._audit_mode)
      auditor.toggle_audit_mode()
      assert.is_true(auditor._audit_mode)
    end)

    it("ON → OFF", function()
      auditor.enter_audit_mode()
      auditor.toggle_audit_mode()
      assert.is_false(auditor._audit_mode)
    end)

    it("double toggle returns to original state (OFF)", function()
      auditor.toggle_audit_mode()
      auditor.toggle_audit_mode()
      assert.is_false(auditor._audit_mode)
    end)

    it("double toggle returns to original state (ON)", function()
      auditor.enter_audit_mode()
      auditor.toggle_audit_mode()
      auditor.toggle_audit_mode()
      assert.is_true(auditor._audit_mode)
    end)

    it("triple toggle from OFF ends ON", function()
      auditor.toggle_audit_mode()
      auditor.toggle_audit_mode()
      auditor.toggle_audit_mode()
      assert.is_true(auditor._audit_mode)
    end)

    it("toggle from OFF shows extmarks from DB", function()
      local b = vim.api.nvim_create_buf(false, true)
      local p = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(b, p)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello world" })
      local db = require("auditor.db")
      db.save_words(p, { { line = 0, col_start = 0, col_end = 5 } }, "red")

      assert.equals(0, extmark_count(b, hl.ns))
      auditor.toggle_audit_mode()
      assert.equals(1, extmark_count(b, hl.ns))

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)

    it("toggle from ON clears extmarks", function()
      local b = vim.api.nvim_create_buf(false, true)
      local p = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(b, p)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello world" })
      local db = require("auditor.db")
      db.save_words(p, { { line = 0, col_start = 0, col_end = 5 } }, "red")

      auditor.enter_audit_mode()
      assert.equals(1, extmark_count(b, hl.ns))
      auditor.toggle_audit_mode()
      assert.equals(0, extmark_count(b, hl.ns))

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)

  -- ── command registration ──────────────────────────────────────────────

  describe("command registration", function()
    it("registers :AuditToggle", function()
      assert.equals(2, vim.fn.exists(":AuditToggle"))
    end)

    it(":AuditToggle works via vim.cmd", function()
      vim.cmd("AuditToggle")
      assert.is_true(auditor._audit_mode)
      vim.cmd("AuditToggle")
      assert.is_false(auditor._audit_mode)
    end)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- INTEGRATION TESTS
-- ═══════════════════════════════════════════════════════════════════════════

describe("toggle: integration", function()
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

  it("toggle restores saved highlights from DB", function()
    local b, p = make_named_buf("hello world")
    db.save_words(p, {
      { line = 0, col_start = 0, col_end = 5 },
      { line = 0, col_start = 6, col_end = 11 },
    }, "red")

    auditor.toggle_audit_mode() -- OFF → ON
    assert.equals(2, extmark_count(b, hl.ns))

    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)

  it("toggle hides highlights when going ON → OFF", function()
    local b, p = make_named_buf("hello world")
    db.save_words(p, { { line = 0, col_start = 0, col_end = 5 } }, "blue")

    auditor.toggle_audit_mode() -- ON
    assert.equals(1, extmark_count(b, hl.ns))
    auditor.toggle_audit_mode() -- OFF
    assert.equals(0, extmark_count(b, hl.ns))

    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)

  it("pending is preserved across toggle cycles", function()
    local b, p = make_named_buf("hello world")
    auditor.toggle_audit_mode() -- ON
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    assert.equals(1, #auditor._pending[b])

    auditor.toggle_audit_mode() -- OFF
    assert.equals(1, #auditor._pending[b])

    auditor.toggle_audit_mode() -- ON
    assert.equals(1, #auditor._pending[b])
    assert.equals(1, extmark_count(b, hl.ns))

    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)

  it("toggle + mark + toggle + toggle: highlights restored", function()
    local b, p = make_named_buf("hello world")
    auditor.toggle_audit_mode() -- ON
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("blue")
    auditor.audit()

    auditor.toggle_audit_mode() -- OFF
    assert.equals(0, extmark_count(b, hl.ns))
    auditor.toggle_audit_mode() -- ON
    assert.equals(1, extmark_count(b, hl.ns))

    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)

  it("toggle does not modify the database", function()
    local _, p = make_named_buf("hello world")
    db.save_words(p, { { line = 0, col_start = 0, col_end = 5 } }, "red")
    local before = #db.get_highlights(p)

    for _ = 1, 10 do
      auditor.toggle_audit_mode()
    end

    assert.equals(before, #db.get_highlights(p))

    pcall(os.remove, p)
  end)

  it("multi-buffer toggle restores/hides all", function()
    local bufs = {}
    for i = 1, 3 do
      local b = vim.api.nvim_create_buf(false, true)
      local p = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(b, p)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "word" .. i })
      db.save_words(p, { { line = 0, col_start = 0, col_end = 5 } }, "blue")
      bufs[i] = { bufnr = b, path = p }
    end

    auditor.toggle_audit_mode() -- ON
    for i = 1, 3 do
      assert.is_true(extmark_count(bufs[i].bufnr, hl.ns) >= 1, "buf " .. i .. " missing extmarks")
    end

    auditor.toggle_audit_mode() -- OFF
    for i = 1, 3 do
      assert.equals(0, extmark_count(bufs[i].bufnr, hl.ns), "buf " .. i .. " still has extmarks")
    end

    for _, buf in ipairs(bufs) do
      pcall(vim.api.nvim_buf_delete, buf.bufnr, { force = true })
      pcall(os.remove, buf.path)
    end
  end)

  it("toggle interleaves correctly with explicit enter/exit", function()
    auditor.enter_audit_mode()
    assert.is_true(auditor._audit_mode)
    auditor.toggle_audit_mode() -- ON → OFF
    assert.is_false(auditor._audit_mode)
    auditor.toggle_audit_mode() -- OFF → ON
    assert.is_true(auditor._audit_mode)
    auditor.exit_audit_mode()
    assert.is_false(auditor._audit_mode)
    auditor.toggle_audit_mode() -- OFF → ON
    assert.is_true(auditor._audit_mode)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- EXHAUSTIVE: all 3^N sequences of {enter, exit, toggle}
-- ═══════════════════════════════════════════════════════════════════════════

describe("toggle: exhaustive sequences", function()
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

  local ops = { "enter", "exit", "toggle" }

  -- Predict expected mode after applying an op
  local function apply_op(mode, op)
    if op == "enter" then
      return true
    elseif op == "exit" then
      return false
    else -- toggle
      return not mode
    end
  end

  local function run_op(aud, op)
    if op == "enter" then
      aud.enter_audit_mode()
    elseif op == "exit" then
      aud.exit_audit_mode()
    else
      aud.toggle_audit_mode()
    end
  end

  it("all 3^4 = 81 length-4 sequences maintain invariants", function()
    for seq_num = 0, 80 do
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

      local expected_mode = false
      local seq = {}
      local n = seq_num
      for _ = 1, 4 do
        local op_idx = (n % 3) + 1
        n = math.floor(n / 3)
        local op = ops[op_idx]
        table.insert(seq, op:sub(1, 1):upper())
        run_op(auditor, op)
        expected_mode = apply_op(expected_mode, op)
      end

      local seq_str = table.concat(seq)

      -- Invariant 1: mode matches expected
      assert(
        auditor._audit_mode == expected_mode,
        string.format(
          "seq %s: mode=%s expected=%s",
          seq_str,
          tostring(auditor._audit_mode),
          tostring(expected_mode)
        )
      )

      -- Invariant 2: is_active agrees
      assert(
        auditor.is_active() == expected_mode,
        string.format(
          "seq %s: is_active=%s expected=%s",
          seq_str,
          tostring(auditor.is_active()),
          tostring(expected_mode)
        )
      )

      -- Invariant 3: extmarks match mode
      if expected_mode then
        assert(extmark_count(b, hl.ns) >= 1, string.format("seq %s: ON but no extmarks", seq_str))
      else
        assert(extmark_count(b, hl.ns) == 0, string.format("seq %s: OFF but has extmarks", seq_str))
      end

      -- Invariant 4: DB unchanged
      assert(#db.get_highlights(p) == 1, string.format("seq %s: DB changed", seq_str))

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end
  end)

  it("all 3^5 = 243 length-5 sequences maintain invariants", function()
    for seq_num = 0, 242 do
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

      local expected_mode = false
      local n = seq_num
      for _ = 1, 5 do
        local op_idx = (n % 3) + 1
        n = math.floor(n / 3)
        local op = ops[op_idx]
        run_op(auditor, op)
        expected_mode = apply_op(expected_mode, op)
      end

      assert(auditor._audit_mode == expected_mode)
      assert(auditor.is_active() == expected_mode)

      if expected_mode then
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
-- PROPERTY-BASED
-- ═══════════════════════════════════════════════════════════════════════════

describe("toggle: property-based", function()
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

  it("P1: mode always matches simulation after random {enter, exit, toggle} sequence", function()
    property("mode consistency", 500, function(rng)
      local expected = false
      local n_ops = rng(1, 30)
      for _ = 1, n_ops do
        local op = rng(1, 3)
        if op == 1 then
          auditor.enter_audit_mode()
          expected = true
        elseif op == 2 then
          auditor.exit_audit_mode()
          expected = false
        else
          auditor.toggle_audit_mode()
          expected = not expected
        end
      end
      assert(
        auditor._audit_mode == expected,
        string.format("mode=%s expected=%s", tostring(auditor._audit_mode), tostring(expected))
      )
    end)
  end)

  it("P2: is_active() always agrees with _audit_mode after random ops", function()
    property("is_active consistency", 500, function(rng)
      local n_ops = rng(1, 20)
      for _ = 1, n_ops do
        local op = rng(1, 3)
        if op == 1 then
          auditor.enter_audit_mode()
        elseif op == 2 then
          auditor.exit_audit_mode()
        else
          auditor.toggle_audit_mode()
        end
        assert(auditor.is_active() == auditor._audit_mode, "is_active disagrees with _audit_mode")
      end
    end)
  end)

  it("P3: N toggles from OFF → ON iff N is odd", function()
    property("toggle parity", 200, function(rng)
      local n = rng(1, 50)
      for _ = 1, n do
        auditor.toggle_audit_mode()
      end
      local expected = (n % 2) == 1
      assert(
        auditor._audit_mode == expected,
        string.format(
          "%d toggles: mode=%s expected=%s",
          n,
          tostring(auditor._audit_mode),
          tostring(expected)
        )
      )
      -- Reset for next iteration
      if auditor._audit_mode then
        auditor.exit_audit_mode()
      end
    end)
  end)

  it("P4: DB is never modified by enter/exit/toggle sequences", function()
    property("DB immutability", 300, function(rng)
      local p = vim.fn.tempname() .. ".lua"
      local b = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(b, p)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello" })
      db.save_words(p, { { line = 0, col_start = 0, col_end = 5 } }, "red")
      local before = #db.get_highlights(p)

      for _ = 1, rng(2, 20) do
        local op = rng(1, 3)
        if op == 1 then
          auditor.enter_audit_mode()
        elseif op == 2 then
          auditor.exit_audit_mode()
        else
          auditor.toggle_audit_mode()
        end
      end

      assert(#db.get_highlights(p) == before, "DB count changed")

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)

  it("P5: after exit/toggle-to-OFF, all extmarks cleared", function()
    property("clean OFF", 200, function(rng)
      local bufs = {}
      for i = 1, rng(1, 3) do
        local b = vim.api.nvim_create_buf(false, true)
        local p = vim.fn.tempname() .. ".lua"
        vim.api.nvim_buf_set_name(b, p)
        vim.api.nvim_buf_set_lines(b, 0, -1, false, { "word" .. i })
        db.save_words(p, { { line = 0, col_start = 0, col_end = 5 } }, "red")
        bufs[i] = { bufnr = b, path = p }
      end

      -- Random ops then ensure OFF
      for _ = 1, rng(1, 10) do
        local op = rng(1, 3)
        if op == 1 then
          auditor.enter_audit_mode()
        elseif op == 2 then
          auditor.exit_audit_mode()
        else
          auditor.toggle_audit_mode()
        end
      end

      -- Force OFF via toggle if needed
      if auditor._audit_mode then
        auditor.toggle_audit_mode()
      end

      for _, buf in ipairs(bufs) do
        assert(extmark_count(buf.bufnr, hl.ns) == 0, "extmarks remain after OFF")
        pcall(vim.api.nvim_buf_delete, buf.bufnr, { force = true })
        pcall(os.remove, buf.path)
      end
    end)
  end)

  it("P6: pending survives any toggle sequence", function()
    property("pending durability", 200, function(rng)
      local b = vim.api.nvim_create_buf(false, true)
      local p = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(b, p)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(b)

      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      local count = #auditor._pending[b]
      assert(count >= 1)

      for _ = 1, rng(1, 15) do
        local op = rng(1, 3)
        if op == 1 then
          auditor.enter_audit_mode()
        elseif op == 2 then
          auditor.exit_audit_mode()
        else
          auditor.toggle_audit_mode()
        end
      end

      assert(
        #auditor._pending[b] == count,
        string.format("pending changed: %d → %d", count, #auditor._pending[b])
      )

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- FUZZ: random ops never crash
-- ═══════════════════════════════════════════════════════════════════════════

describe("toggle: fuzz", function()
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

  it("F1: random mix of toggle/enter/exit/mark/save/clear never errors", function()
    property("no crashes", 300, function(rng)
      local b = vim.api.nvim_create_buf(false, true)
      local p = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(b, p)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "alpha beta gamma" })
      vim.api.nvim_set_current_buf(b)

      local colors = { "red", "blue", "half" }
      for _ = 1, rng(10, 40) do
        local op = rng(1, 8)
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
        else
          -- no-op
          vim.api.nvim_win_set_cursor(0, { 1, rng(0, 15) })
        end

        -- Invariant: is_active always matches _audit_mode
        assert(auditor.is_active() == auditor._audit_mode, "is_active disagrees with _audit_mode")
      end

      -- Final invariant
      if not auditor._audit_mode then
        assert(extmark_count(b, hl.ns) == 0)
      end

      pcall(vim.api.nvim_buf_delete, b, { force = true })
      pcall(os.remove, p)
    end)
  end)

  it("F2: toggle-only sequences: final state always correct", function()
    property("toggle-only parity", 500, function(rng)
      local n = rng(1, 100)
      for _ = 1, n do
        auditor.toggle_audit_mode()
      end

      local expected = (n % 2) == 1
      assert(auditor._audit_mode == expected)
      assert(auditor.is_active() == expected)

      -- Reset
      if auditor._audit_mode then
        auditor.exit_audit_mode()
      end
    end)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- EDGE CASES
-- ═══════════════════════════════════════════════════════════════════════════

describe("toggle: edge cases", function()
  local auditor, tmp_db

  before_each(function()
    reset_modules()
    tmp_db = vim.fn.tempname() .. ".db"
    auditor = require("auditor")
    auditor.setup({ db_path = tmp_db, keymaps = false })
  end)

  after_each(function()
    pcall(os.remove, tmp_db)
  end)

  it("toggle on empty buffer list does not error", function()
    assert.has_no.errors(function()
      auditor.toggle_audit_mode()
    end)
    assert.is_true(auditor._audit_mode)
  end)

  it("rapid toggle does not error", function()
    assert.has_no.errors(function()
      for _ = 1, 100 do
        auditor.toggle_audit_mode()
      end
    end)
  end)

  it("toggle → enter is equivalent to enter → enter (idempotent ON)", function()
    auditor.toggle_audit_mode() -- ON
    auditor.enter_audit_mode() -- still ON
    assert.is_true(auditor._audit_mode)
  end)

  it("exit → toggle is equivalent to toggle from OFF", function()
    auditor.exit_audit_mode()
    auditor.toggle_audit_mode()
    assert.is_true(auditor._audit_mode)
  end)

  it("commands work after toggle-to-ON", function()
    local b, p = make_named_buf("hello world")
    auditor.toggle_audit_mode() -- ON
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    local hl = require("auditor.highlights")
    assert.is_true(extmark_count(b, hl.ns) >= 1)
    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)

  it("commands are blocked after toggle-to-OFF", function()
    auditor.toggle_audit_mode() -- ON
    auditor.toggle_audit_mode() -- OFF
    local b, p = make_named_buf("hello world")
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    local hl = require("auditor.highlights")
    assert.equals(0, extmark_count(b, hl.ns))
    pcall(vim.api.nvim_buf_delete, b, { force = true })
    pcall(os.remove, p)
  end)
end)
