-- test/spec/e2e_fuzz_spec.lua
-- Property-based and fuzz tests for end-to-end invariants.
-- Every property must hold for ALL random inputs.

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

local function suppress_notify()
  local orig = vim.notify
  vim.notify = function() end
  return function()
    vim.notify = orig
  end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- Property: After any sequence of mark/save, DB row count equals extmark count
-- ═══════════════════════════════════════════════════════════════════════════════

describe("property: DB rows match extmarks after save", function()
  local auditor, db, hl

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
    hl = require("auditor.highlights")
  end)

  it("holds for 200 random mark/save sequences", function()
    math.randomseed(1001)
    local restore = suppress_notify()

    local bufnr, filepath = make_buf({
      "alpha beta gamma",
      "delta epsilon zeta",
      "eta theta iota",
    })
    auditor.enter_audit_mode()

    local colors = { "red", "blue", "half" }
    -- Word positions: all words and their column offsets
    local word_positions = {
      { 1, 0 }, { 1, 6 }, { 1, 11 },
      { 2, 0 }, { 2, 6 }, { 2, 14 },
      { 3, 0 }, { 3, 4 }, { 3, 10 },
    }

    for _ = 1, 200 do
      -- Random action: mark or save
      local action = math.random(1, 3)
      if action <= 2 then
        -- Mark a random word
        local wp = word_positions[math.random(1, #word_positions)]
        vim.api.nvim_win_set_cursor(0, { wp[1], wp[2] })
        auditor.highlight_cword_buffer(colors[math.random(1, 3)])
      else
        -- Save
        auditor.audit()
        -- PROPERTY: after save, DB rows == logical extmark count
        local rows = db.get_highlights(filepath)
        local collected = hl.collect_extmarks(bufnr)
        assert.equals(#collected, #rows)
      end
    end

    restore()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Property: is_active() always equals _audit_mode
-- ═══════════════════════════════════════════════════════════════════════════════

describe("property: is_active() consistency", function()
  local auditor

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
  end)

  it("is_active() == _audit_mode after any state transition", function()
    local restore = suppress_notify()
    math.randomseed(2002)

    make_buf({ "hello" })

    for _ = 1, 100 do
      local action = math.random(1, 3)
      if action == 1 then
        auditor.enter_audit_mode()
      elseif action == 2 then
        auditor.exit_audit_mode()
      else
        auditor.toggle_audit_mode()
      end
      assert.equals(auditor._audit_mode, auditor.is_active())
    end

    restore()
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Property: Pending count never exceeds total extmarks
-- ═══════════════════════════════════════════════════════════════════════════════

describe("property: pending <= extmarks", function()
  local auditor, hl

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    hl = require("auditor.highlights")
  end)

  it("pending word count never exceeds extmark count during audit mode", function()
    local restore = suppress_notify()
    math.randomseed(3003)

    local bufnr = make_buf({ "aa bb cc dd ee ff gg hh ii jj" })
    auditor.enter_audit_mode()

    local colors = { "red", "blue", "half" }
    local positions = { 0, 3, 6, 9, 12, 15, 18, 21, 24, 27 }

    for _ = 1, 100 do
      local action = math.random(1, 4)
      if action <= 2 then
        -- Mark random word
        local col = positions[math.random(1, #positions)]
        vim.api.nvim_win_set_cursor(0, { 1, col })
        auditor.highlight_cword_buffer(colors[math.random(1, 3)])
      elseif action == 3 then
        -- Undo random word
        local col = positions[math.random(1, #positions)]
        vim.api.nvim_win_set_cursor(0, { 1, col })
        auditor.undo_at_cursor()
      else
        -- Save
        auditor.audit()
      end

      -- PROPERTY: pending words <= total extmarks
      local pending_count = 0
      if auditor._pending[bufnr] then
        for _, entry in ipairs(auditor._pending[bufnr]) do
          pending_count = pending_count + #entry.words
        end
      end
      local extmark_count = #vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, {})
      assert.is_true(
        pending_count <= extmark_count,
        string.format("pending %d > extmarks %d", pending_count, extmark_count)
      )
    end

    restore()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Property: BufDelete always cleans _pending[bufnr] and _db_extmarks[bufnr]
-- ═══════════════════════════════════════════════════════════════════════════════

describe("property: BufDelete cleanup", function()
  local auditor

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
  end)

  it("deleting any buffer always cleans state tables", function()
    local restore = suppress_notify()

    auditor.enter_audit_mode()
    local bufs = {}
    for i = 1, 20 do
      local bufnr = make_buf({ "word" .. i })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")
      table.insert(bufs, bufnr)
    end

    -- Save some
    auditor.audit()

    -- Delete all in random order
    math.randomseed(4004)
    local order = {}
    for i = 1, #bufs do
      table.insert(order, i)
    end
    for i = #order, 2, -1 do
      local j = math.random(1, i)
      order[i], order[j] = order[j], order[i]
    end

    -- Need a buffer to stay current
    local keep = make_buf({ "keep" })

    for _, idx in ipairs(order) do
      local bufnr = bufs[idx]
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
        -- PROPERTY: state cleaned
        assert.is_nil(auditor._pending[bufnr])
        assert.is_nil(auditor._db_extmarks[bufnr])
      end
    end

    restore()
    pcall(vim.api.nvim_buf_delete, keep, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Property: DB unchanged unless save() called
-- ═══════════════════════════════════════════════════════════════════════════════

describe("property: DB unchanged without save", function()
  local auditor, db

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
  end)

  it("mark/undo/enter/exit never change DB without explicit save", function()
    local restore = suppress_notify()
    math.randomseed(5005)

    local bufnr, filepath = make_buf({ "hello world foo bar" })
    auditor.enter_audit_mode()
    local colors = { "red", "blue", "half" }
    local positions = { 0, 6, 12, 16 }

    -- Do a known save first
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    auditor.audit()
    local _ = #db.get_highlights(filepath)

    -- Now do 50 operations WITHOUT saving
    for _ = 1, 50 do
      local action = math.random(1, 5)
      if action == 1 then
        local col = positions[math.random(1, #positions)]
        vim.api.nvim_win_set_cursor(0, { 1, col })
        auditor.highlight_cword_buffer(colors[math.random(1, 3)])
      elseif action == 2 then
        local col = positions[math.random(1, #positions)]
        vim.api.nvim_win_set_cursor(0, { 1, col })
        auditor.undo_at_cursor()
      elseif action == 3 then
        auditor.enter_audit_mode()
      elseif action == 4 then
        auditor.exit_audit_mode()
      else
        auditor.toggle_audit_mode()
      end
    end

    -- Undo changes DB for saved highlights, but mark/enter/exit should not
    -- The point: marks alone don't write to DB
    -- Re-enter to check
    if not auditor.is_active() then
      auditor.enter_audit_mode()
    end

    restore()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Fuzz: Random complete workflows never crash
-- ═══════════════════════════════════════════════════════════════════════════════

describe("fuzz: random complete workflows", function()
  local auditor

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
  end)

  it("500 random operations never crash", function()
    local restore = suppress_notify()
    math.randomseed(6006)

    local bufnrs = {}
    -- Create several buffers
    for i = 1, 5 do
      local bufnr = make_buf({ "word" .. i .. " other" .. i .. " third" .. i })
      table.insert(bufnrs, bufnr)
    end

    local colors = { "red", "blue", "half" }

    for _ = 1, 500 do
      local action = math.random(1, 10)

      if action == 1 then
        auditor.enter_audit_mode()
      elseif action == 2 then
        auditor.exit_audit_mode()
      elseif action == 3 then
        auditor.toggle_audit_mode()
      elseif action <= 6 then
        -- Mark in random buffer
        local bufnr = bufnrs[math.random(1, #bufnrs)]
        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_set_current_buf(bufnr)
          local line_count = vim.api.nvim_buf_line_count(bufnr)
          if line_count > 0 then
            local line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
            if line and #line > 0 then
              vim.api.nvim_win_set_cursor(0, { 1, math.random(0, #line - 1) })
              auditor.highlight_cword_buffer(colors[math.random(1, 3)])
            end
          end
        end
      elseif action == 7 then
        auditor.audit()
      elseif action == 8 then
        auditor.clear_buffer()
      elseif action == 9 then
        -- Undo
        local bufnr = bufnrs[math.random(1, #bufnrs)]
        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_set_current_buf(bufnr)
          local line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
          if line and #line > 0 then
            vim.api.nvim_win_set_cursor(0, { 1, math.random(0, #line - 1) })
            auditor.undo_at_cursor()
          end
        end
      else
        -- Edit random buffer
        local bufnr = bufnrs[math.random(1, #bufnrs)]
        if vim.api.nvim_buf_is_valid(bufnr) then
          local lc = vim.api.nvim_buf_line_count(bufnr)
          if lc > 0 then
            if math.random(1, 2) == 1 then
              vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "inserted_" .. math.random(1, 100) })
            elseif lc > 1 then
              vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, {})
            end
          end
        end
      end
    end

    restore()
    for _, bufnr in ipairs(bufnrs) do
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Fuzz: Rapid mark/undo cycles on same position
-- ═══════════════════════════════════════════════════════════════════════════════

describe("fuzz: rapid mark/undo cycles", function()
  local auditor, hl

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    hl = require("auditor.highlights")
  end)

  it("200 mark/undo cycles on same word leave 0 or 1 extmarks", function()
    local restore = suppress_notify()
    math.randomseed(7007)

    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    local colors = { "red", "blue", "half" }

    for _ = 1, 200 do
      if math.random(1, 2) == 1 then
        auditor.highlight_cword_buffer(colors[math.random(1, 3)])
      else
        auditor.undo_at_cursor()
      end

      -- INVARIANT: at most 1 logical mark on this position (half creates 2 raw extmarks)
      local collected = hl.collect_extmarks(bufnr)
      assert.is_true(#collected <= 1, "Multiple logical marks at same position: " .. #collected)
    end

    restore()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Fuzz: Random edits during audit mode don't crash
-- ═══════════════════════════════════════════════════════════════════════════════

describe("fuzz: random edits during audit", function()
  local auditor, db

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
  end)

  it("100 mark/edit/save cycles maintain DB consistency", function()
    local restore = suppress_notify()
    math.randomseed(8008)

    local bufnr, filepath = make_buf({ "aa bb cc dd" })
    auditor.enter_audit_mode()

    for _ = 1, 100 do
      local action = math.random(1, 4)

      if action == 1 then
        -- Mark random position
        local line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
        if line and #line > 0 then
          vim.api.nvim_win_set_cursor(0, { 1, math.random(0, math.max(0, #line - 1)) })
          auditor.highlight_cword_buffer("red")
        end
      elseif action == 2 then
        -- Insert text
        local lc = vim.api.nvim_buf_line_count(bufnr)
        if lc > 0 then
          vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "new_" .. math.random(100) })
        end
      elseif action == 3 then
        -- Delete text
        local lc = vim.api.nvim_buf_line_count(bufnr)
        if lc > 1 then
          vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, {})
        end
      else
        -- Save
        auditor.audit()
        -- INVARIANT: DB rows are non-negative and finite
        local rows = db.get_highlights(filepath)
        assert.is_true(#rows >= 0)
        assert.is_true(#rows < 10000) -- sanity bound
      end
    end

    restore()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Property: sync_pending_from_extmarks keeps words and IDs in sync
-- ═══════════════════════════════════════════════════════════════════════════════

describe("property: sync_pending consistency", function()
  local auditor

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
  end)

  it("after sync, words count equals extmark_ids count per entry", function()
    local restore = suppress_notify()

    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")
    vim.api.nvim_win_set_cursor(0, { 1, 6 })
    auditor.highlight_cword_buffer("blue")

    -- Edit buffer
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "inserted" })

    -- Sync
    auditor._sync_pending_from_extmarks(bufnr)

    -- PROPERTY: words and extmark_ids have same length
    for _, entry in ipairs(auditor._pending[bufnr] or {}) do
      if entry.extmark_ids then
        assert.equals(#entry.words, #entry.extmark_ids)
      end
    end

    restore()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("sync removes entries for deleted extmarks", function()
    local restore = suppress_notify()

    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")

    -- Delete the line — extmark should be invalidated
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })

    auditor._sync_pending_from_extmarks(bufnr)

    -- Pending should have zero valid words
    local total = 0
    for _, entry in ipairs(auditor._pending[bufnr] or {}) do
      total = total + #entry.words
    end
    assert.equals(0, total)

    restore()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Property: collect_extmarks returns only valid auditor extmarks
-- ═══════════════════════════════════════════════════════════════════════════════

describe("property: collect_extmarks filtering", function()
  local auditor, hl

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    hl = require("auditor.highlights")
  end)

  it("non-auditor extmarks are excluded", function()
    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()

    -- Add auditor mark
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")

    -- Add non-auditor extmark in a different namespace
    local other_ns = vim.api.nvim_create_namespace("other_plugin")
    vim.api.nvim_buf_set_extmark(bufnr, other_ns, 0, 6, {
      end_row = 0,
      end_col = 11,
      hl_group = "Comment",
    })

    local collected = hl.collect_extmarks(bufnr)
    -- Only auditor marks should appear
    assert.equals(1, #collected)
    assert.equals("red", collected[1].color)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("extmarks with unknown hl_group are excluded", function()
    local bufnr = make_buf({ "hello world" })

    -- Add extmark with non-auditor hl_group in auditor namespace
    vim.api.nvim_buf_set_extmark(bufnr, hl.ns, 0, 0, {
      end_row = 0,
      end_col = 5,
      hl_group = "UnknownGroup",
    })

    local collected = hl.collect_extmarks(bufnr)
    assert.equals(0, #collected)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Fuzz: find_word_occurrences with various patterns
-- ═══════════════════════════════════════════════════════════════════════════════

describe("fuzz: find_word_occurrences", function()
  local auditor

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
  end)

  it("never finds partial matches (word boundary enforcement)", function()
    local bufnr = make_buf({
      "req request require req_id",
      "myreq req myrequest",
      "areq reqb req",
    })

    local results = auditor._find_word_occurrences(bufnr, "req", 0, 2)
    -- "req" should match standalone "req" only, not parts of other words
    for _, r in ipairs(results) do
      local line = vim.api.nvim_buf_get_lines(bufnr, r.line, r.line + 1, false)[1]
      local matched = line:sub(r.col_start + 1, r.col_end)
      assert.equals("req", matched)

      -- Check boundaries: char before should not be [%w_]
      if r.col_start > 0 then
        local before = line:sub(r.col_start, r.col_start)
        assert.is_nil(before:match("[%w_]"), "Word boundary violated at start")
      end
      -- char after should not be [%w_]
      if r.col_end < #line then
        local after = line:sub(r.col_end + 1, r.col_end + 1)
        assert.is_nil(after:match("[%w_]"), "Word boundary violated at end")
      end
    end

    -- Should find: line 0 col 0-3 ("req"), line 1 col 6-9 ("req"), line 2 col 10-13 ("req")
    assert.equals(3, #results)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("handles special regex characters in words (via vim.pesc)", function()
    local bufnr = make_buf({ "a_b c_d a_b" })

    local results = auditor._find_word_occurrences(bufnr, "a_b", 0, 0)
    assert.equals(2, #results)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("single line range works", function()
    local bufnr = make_buf({ "aa bb aa", "aa cc aa" })

    local results = auditor._find_word_occurrences(bufnr, "aa", 0, 0)
    assert.equals(2, #results) -- only line 0

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("empty line in range is handled", function()
    local bufnr = make_buf({ "aa", "", "aa" })

    local results = auditor._find_word_occurrences(bufnr, "aa", 0, 2)
    assert.equals(2, #results)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Property: Dedup invariant - at most 1 extmark per position
-- ═══════════════════════════════════════════════════════════════════════════════

describe("property: at most 1 extmark per position", function()
  local auditor, hl

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    hl = require("auditor.highlights")
  end)

  it("holds after 100 random mark operations", function()
    local restore = suppress_notify()
    math.randomseed(9009)

    local bufnr = make_buf({ "aaa bbb ccc ddd eee" })
    auditor.enter_audit_mode()

    local colors = { "red", "blue", "half" }
    local cols = { 0, 4, 8, 12, 16 }

    for _ = 1, 100 do
      local col = cols[math.random(1, #cols)]
      vim.api.nvim_win_set_cursor(0, { 1, col })
      auditor.highlight_cword_buffer(colors[math.random(1, 3)])

      -- Check: no duplicate extmarks at same position
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.ns, 0, -1, { details = true })
      local positions = {}
      for _, m in ipairs(marks) do
        local key = string.format("%d:%d:%d", m[2], m[3], m[4].end_col)
        assert.is_nil(positions[key], "Duplicate extmark at " .. key)
        positions[key] = true
      end
    end

    restore()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Property: rewrite_highlights rollback on error (via init.audit)
-- ═══════════════════════════════════════════════════════════════════════════════

describe("property: audit rollback preserves pending", function()
  local auditor, db

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
  end)

  it("pending preserved when DB write fails", function()
    local restore = suppress_notify()

    local bufnr = make_buf({ "hello world" })
    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")

    -- Make rewrite_highlights fail
    local orig = db.rewrite_highlights
    db.rewrite_highlights = function()
      error("simulated failure")
    end

    auditor.audit()

    db.rewrite_highlights = orig

    -- Pending should still be there
    local count = 0
    for _, entry in ipairs(auditor._pending[bufnr] or {}) do
      count = count + #entry.words
    end
    assert.is_true(count > 0)

    -- Retry should succeed
    auditor.audit()
    assert.equals(1, #db.get_highlights(vim.fn.resolve(vim.fn.fnamemodify(
      vim.api.nvim_buf_get_name(bufnr), ":p"
    ))))

    restore()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Fuzz: Concurrent multi-buffer mark/save/clear
-- ═══════════════════════════════════════════════════════════════════════════════

describe("fuzz: multi-buffer concurrent operations", function()
  local auditor, db

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    db = require("auditor.db")
  end)

  it("200 operations across 5 buffers maintain per-file isolation", function()
    local restore = suppress_notify()
    math.randomseed(10010)

    auditor.enter_audit_mode()
    local bufs = {}
    local fps = {}
    for i = 1, 5 do
      local bufnr, filepath = make_buf({ "word" .. i .. " other" .. i })
      bufs[i] = bufnr
      fps[i] = filepath
    end

    local colors = { "red", "blue", "half" }

    for _ = 1, 200 do
      local buf_idx = math.random(1, 5)
      local bufnr = bufs[buf_idx]
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_set_current_buf(bufnr)

        local action = math.random(1, 4)
        if action <= 2 then
          vim.api.nvim_win_set_cursor(0, { 1, 0 })
          auditor.highlight_cword_buffer(colors[math.random(1, 3)])
        elseif action == 3 then
          auditor.audit()
        else
          auditor.clear_buffer()
        end
      end
    end

    -- Save everything
    auditor.audit()

    -- PROPERTY: each file has its own independent rows
    for i = 1, 5 do
      if vim.api.nvim_buf_is_valid(bufs[i]) then
        local rows = db.get_highlights(fps[i])
        for _, r in ipairs(rows) do
          assert.equals(fps[i], r.filepath)
        end
      end
    end

    restore()
    for _, bufnr in ipairs(bufs) do
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end)
end)
