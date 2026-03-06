-- test/spec/ts_spec.lua
-- Unit tests for auditor.ts token extraction.
-- Covers both the regex fallback (plain buffers) and the treesitter walk
-- (filetype=lua buffers, which always have a parser in this environment).

local ts = require("auditor.ts")

-- ── helpers ───────────────────────────────────────────────────────────────────

local function make_buf(lines, ft)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  if ft then
    vim.bo[bufnr].filetype = ft
  end
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr
end

-- All args 1-indexed (as Neovim's setpos expects).
local function set_marks(srow, scol, erow, ecol)
  vim.fn.setpos("'<", { 0, srow, scol, 0 })
  vim.fn.setpos("'>", { 0, erow, ecol, 0 })
end

-- Resolve token positions back to text strings using the source lines table.
-- t.line is 0-indexed; col_start/col_end are 0-indexed byte offsets.
local function token_texts(tokens, lines)
  local out = {}
  for _, t in ipairs(tokens) do
    out[#out + 1] = lines[t.line + 1]:sub(t.col_start + 1, t.col_end)
  end
  return out
end

local function texts_set(tokens, lines)
  local s = {}
  for _, t in ipairs(tokens) do
    s[lines[t.line + 1]:sub(t.col_start + 1, t.col_end)] = true
  end
  return s
end

-- ── ts.available() ────────────────────────────────────────────────────────────

describe("ts.available()", function()
  it("returns false for a plain buffer with no filetype", function()
    local bufnr = make_buf({ "hello world" })
    assert.is_false(ts.available(bufnr))
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("returns true for a buffer with filetype=lua", function()
    local bufnr = make_buf({ "local x = 1" }, "lua")
    assert.is_true(ts.available(bufnr))
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)

-- ── regex fallback ────────────────────────────────────────────────────────────

describe("auditor.ts – regex fallback (plain buffer)", function()
  local bufnr

  after_each(function()
    if bufnr then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      bufnr = nil
    end
  end)

  describe("line-mode (V)", function()
    it("extracts all word tokens from a single line", function()
      local lines = { "hello world" }
      bufnr = make_buf(lines)
      set_marks(1, 1, 1, #lines[1])

      local tokens = ts.get_tokens(bufnr, "V", {})
      assert.equals(2, #tokens)
      assert.same({ "hello", "world" }, token_texts(tokens, lines))
    end)

    it("returns correct 0-indexed byte offsets", function()
      local lines = { "hello world" }
      bufnr = make_buf(lines)
      set_marks(1, 1, 1, #lines[1])

      local tokens = ts.get_tokens(bufnr, "V", {})
      assert.equals(0, tokens[1].col_start)
      assert.equals(5, tokens[1].col_end)
      assert.equals(6, tokens[2].col_start)
      assert.equals(11, tokens[2].col_end)
    end)

    it("extracts tokens from all selected lines", function()
      local lines = { "foo bar", "baz qux" }
      bufnr = make_buf(lines)
      set_marks(1, 1, 2, #lines[2])

      local got = texts_set(ts.get_tokens(bufnr, "V", {}), lines)
      assert.truthy(got["foo"] and got["bar"] and got["baz"] and got["qux"])
    end)

    it("reports correct 0-indexed line numbers for each token", function()
      local lines = { "alpha", "beta" }
      bufnr = make_buf(lines)
      set_marks(1, 1, 2, #lines[2])

      local tokens = ts.get_tokens(bufnr, "V", {})
      assert.equals(0, tokens[1].line)
      assert.equals(1, tokens[2].line)
    end)

    it("returns empty list for whitespace-only content", function()
      bufnr = make_buf({ "   " })
      set_marks(1, 1, 1, 3)
      assert.same({}, ts.get_tokens(bufnr, "V", {}))
    end)

    it("treats underscores as part of a word", function()
      local lines = { "my_var = other_var" }
      bufnr = make_buf(lines)
      set_marks(1, 1, 1, #lines[1])

      local got = texts_set(ts.get_tokens(bufnr, "V", {}), lines)
      assert.truthy(got["my_var"] and got["other_var"])
      assert.falsy(got["="])
    end)

    it("skips pure-punctuation tokens", function()
      local lines = { "a + b" }
      bufnr = make_buf(lines)
      set_marks(1, 1, 1, #lines[1])

      local got = texts_set(ts.get_tokens(bufnr, "V", {}), lines)
      assert.falsy(got["+"])
      assert.truthy(got["a"] and got["b"])
    end)
  end)

  describe("char-mode (v)", function()
    it("only returns tokens whose byte range fits inside the selection", function()
      -- "aaa bbb ccc" — select only "bbb" (1-indexed cols 5-7)
      local lines = { "aaa bbb ccc" }
      bufnr = make_buf(lines)
      set_marks(1, 5, 1, 7)

      assert.same({ "bbb" }, token_texts(ts.get_tokens(bufnr, "v", {}), lines))
    end)

    it("excludes tokens outside the column window", function()
      local lines = { "foo bar baz" }
      bufnr = make_buf(lines)
      set_marks(1, 5, 1, 7) -- "bar"

      local got = texts_set(ts.get_tokens(bufnr, "v", {}), lines)
      assert.truthy(got["bar"])
      assert.falsy(got["foo"])
      assert.falsy(got["baz"])
    end)
  end)
end)

-- ── treesitter walk ───────────────────────────────────────────────────────────

describe("auditor.ts – treesitter walk (filetype=lua)", function()
  local bufnr

  after_each(function()
    if bufnr then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      bufnr = nil
    end
  end)

  -- Confirm the treesitter path is taken by checking for the ts_type field,
  -- which only the TS walk sets (regex fallback never sets it).
  local function assert_ts_path(tokens)
    assert.is_true(#tokens > 0, "expected at least one token")
    assert.not_nil(
      tokens[1].ts_type,
      "ts_type field missing – regex fallback was used instead of treesitter"
    )
  end

  describe("node_types = nil (default: all meaningful nodes)", function()
    it("returns named AND anonymous keyword nodes", function()
      -- "local" is anonymous in the Lua grammar; "foo" and "bar" are identifiers.
      local lines = { "local foo = bar" }
      bufnr = make_buf(lines, "lua")
      set_marks(1, 1, 1, #lines[1])

      local tokens = ts.get_tokens(bufnr, "V", {})
      assert_ts_path(tokens)

      local got = texts_set(tokens, lines)
      -- Anonymous keyword "local" passes the [%w_] text heuristic
      assert.truthy(got["local"])
      assert.truthy(got["foo"])
      assert.truthy(got["bar"])
      -- Pure punctuation "=" has no [%w_] chars → excluded
      assert.falsy(got["="])
    end)

    it("returns correct byte offsets for treesitter tokens", function()
      local lines = { "local foo = bar" }
      bufnr = make_buf(lines, "lua")
      set_marks(1, 1, 1, #lines[1])

      local tokens = ts.get_tokens(bufnr, "V", {})
      assert_ts_path(tokens)

      -- Find "foo"
      local foo
      for _, t in ipairs(tokens) do
        if lines[1]:sub(t.col_start + 1, t.col_end) == "foo" then
          foo = t
          break
        end
      end
      assert.not_nil(foo)
      assert.equals(6, foo.col_start)
      assert.equals(9, foo.col_end)
    end)

    it("respects column bounds in char-mode selection", function()
      -- "local foo = bar" — select only "foo" (1-indexed cols 7-9)
      local lines = { "local foo = bar" }
      bufnr = make_buf(lines, "lua")
      set_marks(1, 7, 1, 9)

      local tokens = ts.get_tokens(bufnr, "v", {})
      assert_ts_path(tokens)

      local got = texts_set(tokens, lines)
      assert.truthy(got["foo"])
      assert.falsy(got["local"])
      assert.falsy(got["bar"])
    end)
  end)

  describe('node_types = "named"', function()
    it("excludes anonymous nodes like the 'local' keyword", function()
      local lines = { "local foo = bar" }
      bufnr = make_buf(lines, "lua")
      set_marks(1, 1, 1, #lines[1])

      local tokens = ts.get_tokens(bufnr, "V", { node_types = "named" })
      assert_ts_path(tokens)

      local got = texts_set(tokens, lines)
      assert.falsy(got["local"]) -- anonymous keyword
      assert.truthy(got["foo"]) -- named identifier
      assert.truthy(got["bar"]) -- named identifier
    end)

    it("sets named=true on every returned token", function()
      local lines = { "local foo = bar" }
      bufnr = make_buf(lines, "lua")
      set_marks(1, 1, 1, #lines[1])

      local tokens = ts.get_tokens(bufnr, "V", { node_types = "named" })
      for _, t in ipairs(tokens) do
        assert.is_true(t.named)
      end
    end)
  end)

  describe("node_types = { table of types }", function()
    it("only returns nodes whose ts_type is in the list", function()
      local lines = { "local foo = bar" }
      bufnr = make_buf(lines, "lua")
      set_marks(1, 1, 1, #lines[1])

      local tokens = ts.get_tokens(bufnr, "V", { node_types = { "identifier" } })
      assert_ts_path(tokens)

      local got = texts_set(tokens, lines)
      assert.falsy(got["local"]) -- type "local", not in list
      assert.truthy(got["foo"]) -- type "identifier"
      assert.truthy(got["bar"]) -- type "identifier"
    end)

    it("ts_type field matches the filter list entries", function()
      local lines = { "local foo = bar" }
      bufnr = make_buf(lines, "lua")
      set_marks(1, 1, 1, #lines[1])

      local tokens = ts.get_tokens(bufnr, "V", { node_types = { "identifier" } })
      for _, t in ipairs(tokens) do
        assert.equals("identifier", t.ts_type)
      end
    end)
  end)

  describe("multi-line node handling", function()
    it(
      "skips multi-line string nodes but still returns single-line tokens on same lines",
      function()
        -- The Lua long string [[...]] spans lines 1-3; "local" and "x" are on line 1.
        local lines = { "local x = [[", "multiline", "]]" }
        bufnr = make_buf(lines, "lua")
        set_marks(1, 1, 3, #lines[3])

        local tokens = ts.get_tokens(bufnr, "V", {})
        assert_ts_path(tokens)

        local got = texts_set(tokens, lines)
        -- Long string spans lines → skipped by node_text (returns nil for n_sr ~= n_er)
        assert.falsy(got["[["])
        assert.falsy(got["multiline"])
        -- Single-line tokens on line 1 survive
        assert.truthy(got["local"] or got["x"])
      end
    )
  end)

  describe("line-mode multi-line selection", function()
    it("extracts identifiers from every selected line", function()
      local lines = {
        "local alpha = 1",
        "local beta  = 2",
        "local gamma = 3",
      }
      bufnr = make_buf(lines, "lua")
      set_marks(1, 1, 3, #lines[3])

      local tokens = ts.get_tokens(bufnr, "V", { node_types = "named" })
      assert_ts_path(tokens)

      local got = texts_set(tokens, lines)
      assert.truthy(got["alpha"])
      assert.truthy(got["beta"])
      assert.truthy(got["gamma"])
    end)
  end)
end)
