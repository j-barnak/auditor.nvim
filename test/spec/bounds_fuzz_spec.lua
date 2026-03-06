-- test/spec/bounds_fuzz_spec.lua
-- Fuzz and property-based tests ensuring no out-of-range or invalid-col errors
-- ever reach Neovim APIs. Exercises every path that maps DB/pending positions
-- to extmarks: apply_word, apply_words, load_for_buffer, enter_audit_mode,
-- highlight_cword_buffer, highlight_cword, undo_at_cursor.
--
-- Properties:
--   B1  apply_word never errors for any (line, col_start, col_end) on any buffer
--   B2  apply_words never errors for any random token list on any buffer
--   B3  load_for_buffer never errors with random stale DB rows
--   B4  enter_audit_mode never errors after random DB seeding + buffer mutation
--   B5  full lifecycle fuzz: mark → mutate buffer → save → exit → enter
--   B6  highlight_cword_buffer never errors on random cursor positions
--   B7  highlight_cword never errors on random cursor positions
--   B8  undo_at_cursor never errors on random cursor positions
--   B9  apply_word boundary: valid-id count matches expected for random tokens
--   B10 mixed pending + DB stale data: enter_audit_mode never errors
--   B11 rapid buffer mutations between operations never error
--   B12 empty / single-char / whitespace-only buffers never error

local function reset_modules()
  for _, m in ipairs({
    "auditor", "auditor.init", "auditor.db", "auditor.highlights", "auditor.ts",
  }) do
    package.loaded[m] = nil
  end
end

-- ── deterministic PRNG ────────────────────────────────────────────────────────

local function make_rng(seed)
  local s = math.abs(seed) + 1
  return function(lo, hi)
    s = (s * 1664525 + 1013904223) % (2 ^ 32)
    return lo + math.floor(s * (hi - lo + 1) / (2 ^ 32))
  end
end

-- ── generators ────────────────────────────────────────────────────────────────

local WORD_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789_"
local ALL_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789_ +-*/=<>()[];:,.!@#$%&|"

local function gen_random_lines(rng, min_lines, max_lines)
  local n = rng(min_lines, max_lines)
  local lines = {}
  for _ = 1, n do
    local len = rng(0, 40)
    local parts = {}
    for _ = 1, len do
      local idx = rng(1, #ALL_CHARS)
      parts[#parts + 1] = ALL_CHARS:sub(idx, idx)
    end
    lines[#lines + 1] = table.concat(parts)
  end
  return lines
end

local function gen_random_word(rng)
  local len = rng(1, 8)
  local parts = {}
  for _ = 1, len do
    local idx = rng(1, #WORD_CHARS)
    parts[#parts + 1] = WORD_CHARS:sub(idx, idx)
  end
  return table.concat(parts)
end

local function gen_random_tokens(rng, n)
  local tokens = {}
  for _ = 1, n do
    tokens[#tokens + 1] = {
      line = rng(0, 20),
      col_start = rng(0, 80),
      col_end = rng(0, 120),
    }
  end
  return tokens
end

-- Run a property; error message includes the seed.
local function property(desc, n, fn)
  for seed = 1, n do
    local rng = make_rng(seed)
    local ok, err = pcall(fn, rng, seed)
    if not ok then
      error(
        string.format(
          "[bounds_fuzz] '%s' failed at seed=%d:\n%s", desc, seed, tostring(err)
        ),
        2
      )
    end
  end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- B1-B2: highlights.apply_word / apply_words with arbitrary positions
-- ═══════════════════════════════════════════════════════════════════════════════

describe("bounds fuzz: apply_word / apply_words", function()
  local hl

  before_each(function()
    reset_modules()
    hl = require("auditor.highlights")
    hl.setup()
  end)

  it("B1: apply_word never errors for 1000 random positions on varied buffers", function()
    property("B1", 1000, function(rng)
      local lines = gen_random_lines(rng, 1, 8)
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

      local line = rng(0, 25)
      local col_start = rng(0, 100)
      local col_end = rng(0, 150)
      local colors = { "red", "blue", "half" }
      local color = colors[rng(1, 3)]
      local word_index = rng(1, 20)

      local ok, err = pcall(hl.apply_word, bufnr, line, col_start, col_end, color, word_index)
      assert(ok, string.format("apply_word errored: %s", tostring(err)))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  it("B2: apply_words never errors for 500 random token batches", function()
    property("B2", 500, function(rng)
      local lines = gen_random_lines(rng, 1, 6)
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

      local n_tokens = rng(1, 15)
      local tokens = gen_random_tokens(rng, n_tokens)
      local colors = { "red", "blue", "half" }

      local ok, err = pcall(hl.apply_words, bufnr, tokens, colors[rng(1, 3)])
      assert(ok, string.format("apply_words errored: %s", tostring(err)))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  it("B9: valid-id count matches logical extmarks — only in-range tokens produce extmarks", function()
    property("B9", 500, function(rng)
      local lines = gen_random_lines(rng, 1, 5)
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

      -- Clear stale half-pair tracking (buffer numbers may be reused)
      hl.clear_half_pairs(bufnr)

      local n_tokens = rng(1, 10)
      local tokens = gen_random_tokens(rng, n_tokens)
      local colors = { "red", "blue", "half" }

      local ids = hl.apply_words(bufnr, tokens, colors[rng(1, 3)])
      -- collect_extmarks returns logical marks (skips half-pair secondaries)
      local collected = hl.collect_extmarks(bufnr)
      assert(
        #ids == #collected,
        string.format("id count %d != logical extmark count %d", #ids, #collected)
      )

      -- Verify each id is actually a valid extmark
      for _, id in ipairs(ids) do
        local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, hl.ns, id, {})
        assert(#mark >= 2, string.format("extmark id %d not found", id))
      end

      hl.clear_half_pairs(bufnr)
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- B3: load_for_buffer with random stale DB rows
-- ═══════════════════════════════════════════════════════════════════════════════

describe("bounds fuzz: load_for_buffer with stale DB", function()
  local auditor, db, hl

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    local tmp_db = vim.fn.tempname() .. ".db"
    auditor.setup({ db_path = tmp_db, keymaps = false })
    db = require("auditor.db")
    hl = require("auditor.highlights")
  end)

  it("B3: load_for_buffer never errors with 500 random stale DB rows", function()
    property("B3", 500, function(rng)
      local lines = gen_random_lines(rng, 1, 5)
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

      -- Seed DB with random positions (some valid, most stale)
      local n_rows = rng(1, 8)
      local words = {}
      for _ = 1, n_rows do
        words[#words + 1] = {
          line = rng(0, 20),
          col_start = rng(0, 80),
          col_end = rng(0, 120),
        }
      end
      local colors = { "red", "blue", "half" }
      db.save_words(filepath, words, colors[rng(1, 3)])

      -- Clear stale half-pair tracking (buffer numbers may be reused)
      hl.clear_half_pairs(bufnr)

      local ok, err = pcall(auditor.load_for_buffer, bufnr)
      assert(ok, string.format("load_for_buffer errored: %s", tostring(err)))

      -- Count logical extmarks — must be <= n_rows (only valid ones applied)
      local collected = hl.collect_extmarks(bufnr)
      assert(#collected <= n_rows)

      db.clear_highlights(filepath)
      hl.clear_half_pairs(bufnr)
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- B4: enter_audit_mode with random DB data + mutated buffers
-- ═══════════════════════════════════════════════════════════════════════════════

describe("bounds fuzz: enter_audit_mode with stale state", function()
  local auditor, db

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    local tmp_db = vim.fn.tempname() .. ".db"
    auditor.setup({ db_path = tmp_db, keymaps = false })
    db = require("auditor.db")
  end)

  it("B4: enter after DB seed + buffer mutation (300 iterations)", function()
    property("B4", 300, function(rng)
      -- Create buffer with initial content
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      local initial_lines = gen_random_lines(rng, 2, 8)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, initial_lines)

      -- Seed DB with positions based on initial content
      local n_rows = rng(1, 6)
      local words = {}
      for _ = 1, n_rows do
        local l = rng(0, #initial_lines - 1)
        local line_len = #initial_lines[l + 1]
        if line_len > 0 then
          local cs = rng(0, line_len - 1)
          local ce = rng(cs + 1, line_len)
          words[#words + 1] = { line = l, col_start = cs, col_end = ce }
        end
      end
      if #words > 0 then
        local colors = { "red", "blue", "half" }
        db.save_words(filepath, words, colors[rng(1, 3)])
      end

      -- Mutate buffer: replace with different (possibly shorter) content
      local new_lines = gen_random_lines(rng, 1, 4)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)

      -- enter_audit_mode must not crash
      local ok, err = pcall(auditor.enter_audit_mode)
      assert(ok, string.format("enter_audit_mode errored: %s", tostring(err)))

      auditor.exit_audit_mode()
      db.clear_highlights(filepath)
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- B5: full lifecycle fuzz — mark → mutate → save → exit → enter
-- ═══════════════════════════════════════════════════════════════════════════════

describe("bounds fuzz: full lifecycle", function()
  local auditor, db

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    local tmp_db = vim.fn.tempname() .. ".db"
    auditor.setup({ db_path = tmp_db, keymaps = false })
    db = require("auditor.db")
  end)

  it("B5: mark → mutate → save → exit → enter (200 iterations)", function()
    property("B5", 200, function(rng)
      local lines = gen_random_lines(rng, 2, 6)
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.api.nvim_set_current_buf(bufnr)

      auditor.enter_audit_mode()

      -- Try to mark a word (might be on whitespace, that's fine)
      local line_count = vim.api.nvim_buf_line_count(bufnr)
      local row = rng(1, line_count)
      local line_text = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
      local col = 0
      if #line_text > 0 then
        col = rng(0, #line_text - 1)
      end
      vim.api.nvim_win_set_cursor(0, { row, col })

      local colors = { "red", "blue", "half" }
      local ok1 = pcall(auditor.highlight_cword_buffer, colors[rng(1, 3)])
      assert(ok1, "highlight_cword_buffer errored")

      -- Save
      local ok2 = pcall(auditor.audit)
      assert(ok2, "audit errored")

      -- Mutate buffer
      local new_lines = gen_random_lines(rng, 1, 3)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)

      -- Exit and re-enter with stale DB data
      local ok3 = pcall(auditor.exit_audit_mode)
      assert(ok3, "exit errored")

      local ok4 = pcall(auditor.enter_audit_mode)
      assert(ok4, "re-enter errored")

      auditor.exit_audit_mode()
      db.clear_highlights(filepath)
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- B6-B8: cursor operations on random positions
-- ═══════════════════════════════════════════════════════════════════════════════

describe("bounds fuzz: cursor operations", function()
  local auditor

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    local tmp_db = vim.fn.tempname() .. ".db"
    auditor.setup({ db_path = tmp_db, keymaps = false })
  end)

  it("B6: highlight_cword_buffer never errors on random cursor (500 iterations)", function()
    property("B6", 500, function(rng)
      local lines = gen_random_lines(rng, 1, 5)
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.api.nvim_set_current_buf(bufnr)

      auditor.enter_audit_mode()

      local line_count = vim.api.nvim_buf_line_count(bufnr)
      local row = rng(1, line_count)
      local line_text = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
      local col = 0
      if #line_text > 0 then
        col = rng(0, #line_text - 1)
      end
      vim.api.nvim_win_set_cursor(0, { row, col })

      local colors = { "red", "blue", "half" }
      local ok, err = pcall(auditor.highlight_cword_buffer, colors[rng(1, 3)])
      assert(ok, string.format("highlight_cword_buffer errored: %s", tostring(err)))

      auditor.exit_audit_mode()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  it("B7: highlight_cword never errors on random cursor (500 iterations)", function()
    property("B7", 500, function(rng)
      local lines = gen_random_lines(rng, 1, 5)
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.api.nvim_set_current_buf(bufnr)

      auditor.enter_audit_mode()

      local line_count = vim.api.nvim_buf_line_count(bufnr)
      local row = rng(1, line_count)
      local line_text = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
      local col = 0
      if #line_text > 0 then
        col = rng(0, #line_text - 1)
      end
      vim.api.nvim_win_set_cursor(0, { row, col })

      local colors = { "red", "blue", "half" }
      local ok, err = pcall(auditor.highlight_cword, colors[rng(1, 3)])
      assert(ok, string.format("highlight_cword errored: %s", tostring(err)))

      auditor.exit_audit_mode()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  it("B8: undo_at_cursor never errors on random cursor (500 iterations)", function()
    property("B8", 500, function(rng)
      local lines = gen_random_lines(rng, 1, 5)
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.api.nvim_set_current_buf(bufnr)

      auditor.enter_audit_mode()

      -- Optionally mark something first
      local line_count = vim.api.nvim_buf_line_count(bufnr)
      local row = rng(1, line_count)
      local line_text = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
      local col = 0
      if #line_text > 0 then
        col = rng(0, #line_text - 1)
      end
      vim.api.nvim_win_set_cursor(0, { row, col })

      if rng(0, 1) == 1 then
        pcall(auditor.highlight_cword_buffer, "red")
      end

      -- Move cursor to a random position and try undo
      row = rng(1, line_count)
      line_text = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
      col = 0
      if #line_text > 0 then
        col = rng(0, #line_text - 1)
      end
      vim.api.nvim_win_set_cursor(0, { row, col })

      local ok, err = pcall(auditor.undo_at_cursor)
      assert(ok, string.format("undo_at_cursor errored: %s", tostring(err)))

      auditor.exit_audit_mode()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- B10: mixed pending + stale DB
-- ═══════════════════════════════════════════════════════════════════════════════

describe("bounds fuzz: pending + stale DB on enter", function()
  local auditor, db

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    local tmp_db = vim.fn.tempname() .. ".db"
    auditor.setup({ db_path = tmp_db, keymaps = false })
    db = require("auditor.db")
  end)

  it("B10: pending + stale DB data + buffer mutation (200 iterations)", function()
    property("B10", 200, function(rng)
      local lines = gen_random_lines(rng, 2, 6)
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.api.nvim_set_current_buf(bufnr)

      -- Seed DB with positions from initial content
      local n_db = rng(1, 5)
      local db_words = {}
      for _ = 1, n_db do
        db_words[#db_words + 1] = {
          line = rng(0, #lines + 3),
          col_start = rng(0, 50),
          col_end = rng(0, 80),
        }
      end
      local colors = { "red", "blue", "half" }
      db.save_words(filepath, db_words, colors[rng(1, 3)])

      -- Enter and mark some words (creates pending)
      auditor.enter_audit_mode()
      for _ = 1, rng(1, 3) do
        local lc = vim.api.nvim_buf_line_count(bufnr)
        local row = rng(1, lc)
        local lt = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
        if #lt > 0 then
          vim.api.nvim_win_set_cursor(0, { row, rng(0, #lt - 1) })
          pcall(auditor.highlight_cword_buffer, colors[rng(1, 3)])
        end
      end

      -- Exit, mutate buffer
      auditor.exit_audit_mode()
      local new_lines = gen_random_lines(rng, 1, 3)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)

      -- Re-enter: pending has stale positions, DB has stale positions
      local ok, err = pcall(auditor.enter_audit_mode)
      assert(ok, string.format("enter errored: %s", tostring(err)))

      auditor.exit_audit_mode()
      db.clear_highlights(filepath)
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- B11: rapid buffer mutations between operations
-- ═══════════════════════════════════════════════════════════════════════════════

describe("bounds fuzz: rapid buffer mutations", function()
  local auditor, db

  before_each(function()
    reset_modules()
    auditor = require("auditor")
    local tmp_db = vim.fn.tempname() .. ".db"
    auditor.setup({ db_path = tmp_db, keymaps = false })
    db = require("auditor.db")
  end)

  it("B11: interleaved mutations and operations (200 iterations)", function()
    property("B11", 200, function(rng)
      local bufnr = vim.api.nvim_create_buf(false, true)
      local filepath = vim.fn.tempname() .. ".lua"
      vim.api.nvim_buf_set_name(bufnr, filepath)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, gen_random_lines(rng, 2, 5))
      vim.api.nvim_set_current_buf(bufnr)

      auditor.enter_audit_mode()

      local n_ops = rng(5, 20)
      for _ = 1, n_ops do
        local op = rng(1, 7)
        local lc = vim.api.nvim_buf_line_count(bufnr)
        local row = rng(1, lc)
        local lt = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
        local col = 0
        if #lt > 0 then
          col = rng(0, #lt - 1)
        end

        if op == 1 then
          -- Mark
          vim.api.nvim_win_set_cursor(0, { row, col })
          local colors = { "red", "blue", "half" }
          pcall(auditor.highlight_cword_buffer, colors[rng(1, 3)])
        elseif op == 2 then
          -- Mark (function scope)
          vim.api.nvim_win_set_cursor(0, { row, col })
          local colors = { "red", "blue", "half" }
          pcall(auditor.highlight_cword, colors[rng(1, 3)])
        elseif op == 3 then
          -- Undo
          vim.api.nvim_win_set_cursor(0, { row, col })
          pcall(auditor.undo_at_cursor)
        elseif op == 4 then
          -- Save
          pcall(auditor.audit)
        elseif op == 5 then
          -- Mutate: replace all content
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, gen_random_lines(rng, 1, 4))
        elseif op == 6 then
          -- Mutate: truncate to 1 line
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { gen_random_word(rng) })
        elseif op == 7 then
          -- Mutate: append a line
          local cur_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          cur_lines[#cur_lines + 1] = gen_random_word(rng)
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, cur_lines)
        end
      end

      -- Exit and re-enter to trigger stale load
      local ok1 = pcall(auditor.exit_audit_mode)
      assert(ok1, "exit errored")
      local ok2 = pcall(auditor.enter_audit_mode)
      assert(ok2, "re-enter errored")

      auditor.exit_audit_mode()
      pcall(db.clear_highlights, filepath)
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- B12: edge-case buffers
-- ═══════════════════════════════════════════════════════════════════════════════

describe("bounds fuzz: edge-case buffers", function()
  local hl

  before_each(function()
    reset_modules()
    hl = require("auditor.highlights")
    hl.setup()
  end)

  it("B12: empty / single-char / whitespace-only buffers (300 iterations)", function()
    local edge_buffers = {
      { "" },                                   -- empty
      { " " },                                  -- single space
      { "x" },                                  -- single char
      { "", "", "" },                            -- multiple empty lines
      { "   ", "\t\t", "  \t  " },              -- whitespace-only
      { "a" },                                  -- single word char
      { string.rep("x", 200) },                 -- very long line
      { "a", "b", "c", "d", "e", "f", "g" },   -- many short lines
    }

    property("B12", 300, function(rng, seed)
      local buf_idx = ((seed - 1) % #edge_buffers) + 1
      local lines = edge_buffers[buf_idx]
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

      -- Random apply_word
      local line = rng(0, 10)
      local col_start = rng(0, 250)
      local col_end = rng(0, 300)
      local colors = { "red", "blue", "half" }

      local ok, err = pcall(
        hl.apply_word, bufnr, line, col_start, col_end, colors[rng(1, 3)], rng(1, 10)
      )
      assert(ok, string.format("apply_word errored: %s", tostring(err)))

      -- Random apply_words batch
      local tokens = gen_random_tokens(rng, rng(1, 8))
      local ok2, err2 = pcall(hl.apply_words, bufnr, tokens, colors[rng(1, 3)])
      assert(ok2, string.format("apply_words errored: %s", tostring(err2)))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)
end)
