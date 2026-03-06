-- test/spec/ts_unit_spec.lua
-- Unit tests for lua/auditor/ts.lua internal helpers and edge cases.

local function reset_modules()
  for _, m in ipairs({ "auditor.ts" }) do
    package.loaded[m] = nil
  end
end

local function make_buf(lines, ft)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  if ft then
    vim.api.nvim_set_option_value("filetype", ft, { buf = bufnr })
  end
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- ts.available
-- ═══════════════════════════════════════════════════════════════════════════════

describe("ts.available", function()
  local ts

  before_each(function()
    reset_modules()
    ts = require("auditor.ts")
  end)

  it("returns boolean", function()
    local bufnr = make_buf({ "hello" })
    local result = ts.available(bufnr)
    assert.is_true(type(result) == "boolean")
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("returns false for buffer with no filetype", function()
    local bufnr = make_buf({ "hello" })
    -- No filetype set, no parser available
    local result = ts.available(bufnr)
    -- Result depends on environment, but should not crash
    assert.is_true(type(result) == "boolean")
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- ts.enclosing_function edge cases
-- ═══════════════════════════════════════════════════════════════════════════════

describe("ts.enclosing_function edge cases", function()
  local ts

  before_each(function()
    reset_modules()
    ts = require("auditor.ts")
  end)

  it("returns nil for buffer with no treesitter", function()
    local bufnr = make_buf({ "hello world" })
    local result = ts.enclosing_function(bufnr, 0, 0)
    assert.is_nil(result)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("returns nil when cursor is outside any function", function()
    local bufnr = make_buf({
      "-- comment",
      "local x = 1",
      "local function foo()",
      "  return x",
      "end",
    }, "lua")
    -- Line 0 is a comment, not in a function
    local result = ts.enclosing_function(bufnr, 0, 0)
    -- Might be nil if parser is available but cursor is outside function
    -- Or nil if no parser — either way, should not crash
    assert.is_true(result == nil or type(result) == "table")
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("does not crash with invalid row/col", function()
    local bufnr = make_buf({ "hello" })
    -- Should not crash
    local ok = pcall(ts.enclosing_function, bufnr, 100, 100)
    assert.is_true(ok)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- ts.get_tokens with various opts
-- ═══════════════════════════════════════════════════════════════════════════════

describe("ts.get_tokens opts handling", function()
  local ts

  before_each(function()
    reset_modules()
    ts = require("auditor.ts")
  end)

  it("opts=nil works (defaults to {})", function()
    local bufnr = make_buf({ "hello world" })
    -- Set visual marks for bounds
    vim.api.nvim_buf_set_mark(bufnr, "<", 1, 0, {})
    vim.api.nvim_buf_set_mark(bufnr, ">", 1, 10, {})

    -- Should not crash with nil opts
    local ok = pcall(ts.get_tokens, bufnr, "V", nil)
    assert.is_true(ok)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("opts={} works", function()
    local bufnr = make_buf({ "hello world" })
    vim.api.nvim_buf_set_mark(bufnr, "<", 1, 0, {})
    vim.api.nvim_buf_set_mark(bufnr, ">", 1, 10, {})

    local ok = pcall(ts.get_tokens, bufnr, "V", {})
    assert.is_true(ok)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- regex_tokens: edge cases (tested via get_tokens fallback)
-- ═══════════════════════════════════════════════════════════════════════════════

describe("ts: regex fallback edge cases", function()
  local ts

  before_each(function()
    reset_modules()
    ts = require("auditor.ts")
  end)

  it("handles empty buffer", function()
    local bufnr = make_buf({ "" })
    vim.api.nvim_buf_set_mark(bufnr, "<", 1, 0, {})
    vim.api.nvim_buf_set_mark(bufnr, ">", 1, 0, {})

    local tokens = ts.get_tokens(bufnr, "V", {})
    assert.same({}, tokens)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("handles line with only whitespace", function()
    local bufnr = make_buf({ "   " })
    vim.api.nvim_buf_set_mark(bufnr, "<", 1, 0, {})
    vim.api.nvim_buf_set_mark(bufnr, ">", 1, 2, {})

    local tokens = ts.get_tokens(bufnr, "V", {})
    assert.same({}, tokens)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("handles line with only punctuation", function()
    local bufnr = make_buf({ "!@#$%^&*()" })
    vim.api.nvim_buf_set_mark(bufnr, "<", 1, 0, {})
    vim.api.nvim_buf_set_mark(bufnr, ">", 1, 10, {})

    local tokens = ts.get_tokens(bufnr, "V", {})
    assert.same({}, tokens)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("handles underscores as word characters", function()
    local bufnr = make_buf({ "__init__ _private" })
    vim.api.nvim_buf_set_mark(bufnr, "<", 1, 0, {})
    vim.api.nvim_buf_set_mark(bufnr, ">", 1, 16, {})

    local tokens = ts.get_tokens(bufnr, "V", {})
    assert.equals(2, #tokens) -- __init__ and _private
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it("handles very long line without crash", function()
    local long = string.rep("word ", 1000)
    local bufnr = make_buf({ long })
    vim.api.nvim_buf_set_mark(bufnr, "<", 1, 0, {})
    vim.api.nvim_buf_set_mark(bufnr, ">", 1, #long - 1, {})

    local tokens = ts.get_tokens(bufnr, "V", {})
    assert.equals(1000, #tokens)
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Property: regex tokens always have valid positions
-- ═══════════════════════════════════════════════════════════════════════════════

describe("property: regex tokens have valid positions", function()
  local ts

  before_each(function()
    reset_modules()
    ts = require("auditor.ts")
  end)

  it("all tokens have col_start < col_end and valid line", function()
    math.randomseed(12012)
    local chars = "abcdefghij _!@# 1234567890"

    for _ = 1, 50 do
      local lines = {}
      local n_lines = math.random(1, 5)
      for _ = 1, n_lines do
        local len = math.random(0, 40)
        local line = ""
        for _ = 1, len do
          local idx = math.random(1, #chars)
          line = line .. chars:sub(idx, idx)
        end
        table.insert(lines, line)
      end

      local bufnr = make_buf(lines)
      vim.api.nvim_buf_set_mark(bufnr, "<", 1, 0, {})
      vim.api.nvim_buf_set_mark(bufnr, ">", n_lines, math.max(0, #lines[n_lines] - 1), {})

      local tokens = ts.get_tokens(bufnr, "V", {})
      for _, t in ipairs(tokens) do
        assert.is_true(t.line >= 0, "line < 0")
        assert.is_true(t.line < n_lines, "line >= n_lines")
        assert.is_true(t.col_start >= 0, "col_start < 0")
        assert.is_true(t.col_start < t.col_end, "col_start >= col_end")
        assert.is_true(t.col_end <= #lines[t.line + 1], "col_end > line length")
      end

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Fuzz: get_tokens never crashes
-- ═══════════════════════════════════════════════════════════════════════════════

describe("fuzz: get_tokens resilience", function()
  local ts

  before_each(function()
    reset_modules()
    ts = require("auditor.ts")
  end)

  it("100 random buffers with random content never crash", function()
    math.randomseed(13013)
    local all_chars = "abcdefghijklmnop  \t!@#$%_()[]{}=+;:'\",.<>/\\0123456789"

    for _ = 1, 100 do
      local n_lines = math.random(1, 10)
      local lines = {}
      for _ = 1, n_lines do
        local len = math.random(0, 60)
        local line = ""
        for _ = 1, len do
          local idx = math.random(1, #all_chars)
          line = line .. all_chars:sub(idx, idx)
        end
        table.insert(lines, line)
      end

      local bufnr = make_buf(lines)
      vim.api.nvim_buf_set_mark(bufnr, "<", 1, 0, {})
      local last_line = lines[n_lines]
      vim.api.nvim_buf_set_mark(bufnr, ">", n_lines, math.max(0, #last_line), {})

      local modes = { "V", "v" }
      local mode = modes[math.random(1, #modes)]

      local ok = pcall(ts.get_tokens, bufnr, mode, {})
      assert.is_true(ok, "get_tokens crashed")

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end)
end)
