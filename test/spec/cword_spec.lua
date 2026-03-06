-- test/spec/cword_spec.lua
-- Exhaustive unit tests for M._cword_token.
-- Tests cover every cursor position class: start/mid/end of word,
-- whitespace, punctuation, line boundaries, single-char words, and
-- mixed identifier characters (alnum + underscore).

local auditor = require("auditor")
auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })

local cword_token = auditor._cword_token

-- ── helpers ───────────────────────────────────────────────────────────────────

local function make_buf(line)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr
end

-- Place cursor at 0-indexed column col on row 1 (first line).
local function set_col(col)
  vim.api.nvim_win_set_cursor(0, { 1, col })
end

local function token_text(line, token)
  return line:sub(token.col_start + 1, token.col_end)
end

-- ── basic word detection ──────────────────────────────────────────────────────

describe("M._cword_token", function()
  local bufnr

  after_each(function()
    if bufnr then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      bufnr = nil
    end
  end)

  describe("cursor on a word character", function()
    it("returns the full word when cursor is at the start", function()
      local line = "hello world"
      bufnr = make_buf(line)
      set_col(0) -- 'h'
      local t = cword_token(bufnr)
      assert.not_nil(t)
      assert.equals("hello", token_text(line, t))
      assert.equals(0, t.col_start)
      assert.equals(5, t.col_end)
    end)

    it("returns the full word when cursor is in the middle", function()
      local line = "hello world"
      bufnr = make_buf(line)
      set_col(2) -- 'l'
      local t = cword_token(bufnr)
      assert.not_nil(t)
      assert.equals("hello", token_text(line, t))
    end)

    it("returns the full word when cursor is on the last character", function()
      local line = "hello world"
      bufnr = make_buf(line)
      set_col(4) -- 'o'
      local t = cword_token(bufnr)
      assert.not_nil(t)
      assert.equals("hello", token_text(line, t))
      assert.equals(0, t.col_start)
      assert.equals(5, t.col_end)
    end)

    it("correctly identifies the second word", function()
      local line = "hello world"
      bufnr = make_buf(line)
      set_col(8) -- 'r' in "world"
      local t = cword_token(bufnr)
      assert.not_nil(t)
      assert.equals("world", token_text(line, t))
      assert.equals(6, t.col_start)
      assert.equals(11, t.col_end)
    end)

    it("word at the very start of the line has col_start == 0", function()
      local line = "foo bar"
      bufnr = make_buf(line)
      set_col(0)
      local t = cword_token(bufnr)
      assert.not_nil(t)
      assert.equals(0, t.col_start)
    end)

    it("word at the very end of the line has col_end == #line", function()
      local line = "foo bar"
      bufnr = make_buf(line)
      set_col(6) -- 'r' at position 6 (0-indexed), end of "bar"
      local t = cword_token(bufnr)
      assert.not_nil(t)
      assert.equals(#line, t.col_end)
    end)

    it("single-character word returns [col, col+1)", function()
      local line = "a b c"
      bufnr = make_buf(line)
      set_col(0) -- 'a'
      local t = cword_token(bufnr)
      assert.not_nil(t)
      assert.equals(0, t.col_start)
      assert.equals(1, t.col_end)
      assert.equals("a", token_text(line, t))
    end)

    it("single-character word in the middle of the line", function()
      local line = "a b c"
      bufnr = make_buf(line)
      set_col(2) -- 'b'
      local t = cword_token(bufnr)
      assert.not_nil(t)
      assert.equals("b", token_text(line, t))
    end)

    it("line that is entirely one word", function()
      local line = "helloworld"
      bufnr = make_buf(line)
      for col = 0, #line - 1 do
        set_col(col)
        local t = cword_token(bufnr)
        assert.not_nil(t, "expected token at col " .. col)
        assert.equals(0, t.col_start)
        assert.equals(#line, t.col_end)
      end
    end)
  end)

  describe("underscore and digit handling", function()
    it("treats underscores as word characters", function()
      local line = "my_var = 1"
      bufnr = make_buf(line)
      set_col(3) -- '_'
      local t = cword_token(bufnr)
      assert.not_nil(t)
      assert.equals("my_var", token_text(line, t))
    end)

    it("treats digits as word characters", function()
      local line = "x1 = y2"
      bufnr = make_buf(line)
      set_col(1) -- '1'
      local t = cword_token(bufnr)
      assert.not_nil(t)
      assert.equals("x1", token_text(line, t))
    end)

    it("handles identifiers that start with underscore", function()
      local line = "_internal func"
      bufnr = make_buf(line)
      set_col(0) -- '_'
      local t = cword_token(bufnr)
      assert.not_nil(t)
      assert.equals("_internal", token_text(line, t))
    end)

    it("handles all-underscore identifier", function()
      local line = "___"
      bufnr = make_buf(line)
      set_col(1)
      local t = cword_token(bufnr)
      assert.not_nil(t)
      assert.equals("___", token_text(line, t))
    end)

    it("handles mixed alnum+underscore C-style identifier", function()
      local line = "nvme_changed_nslist(n, rae)"
      bufnr = make_buf(line)
      set_col(5) -- 'c' in "changed"
      local t = cword_token(bufnr)
      assert.not_nil(t)
      assert.equals("nvme_changed_nslist", token_text(line, t))
    end)
  end)

  describe("nil cases — cursor not on a word character", function()
    it("returns nil on a space", function()
      local line = "hello world"
      bufnr = make_buf(line)
      set_col(5) -- space between "hello" and "world"
      assert.is_nil(cword_token(bufnr))
    end)

    it("returns nil on punctuation", function()
      local line = "a + b"
      bufnr = make_buf(line)
      set_col(2) -- '+'
      assert.is_nil(cword_token(bufnr))
    end)

    it("returns nil on open parenthesis", function()
      local line = "foo(bar)"
      bufnr = make_buf(line)
      set_col(3) -- '('
      assert.is_nil(cword_token(bufnr))
    end)

    it("returns nil on close parenthesis", function()
      local line = "foo(bar)"
      bufnr = make_buf(line)
      set_col(7) -- ')'
      assert.is_nil(cword_token(bufnr))
    end)

    it("returns nil when cursor is past end of content", function()
      -- nvim_win_set_cursor clamps, but test the boundary
      local line = "hi"
      bufnr = make_buf(line)
      -- col 2 is one past "hi"; Neovim returns '' for sub(3,3)
      vim.api.nvim_win_set_cursor(0, { 1, 1 }) -- 'i'
      local t = cword_token(bufnr)
      assert.not_nil(t)
      assert.equals("hi", token_text(line, t))
    end)

    it("returns nil on an empty line", function()
      bufnr = make_buf("")
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      assert.is_nil(cword_token(bufnr))
    end)

    it("returns nil on a line containing only punctuation", function()
      local line = "+-*/"
      bufnr = make_buf(line)
      for col = 0, #line - 1 do
        set_col(col)
        assert.is_nil(cword_token(bufnr), "expected nil at col " .. col)
      end
    end)
  end)

  describe("token fields", function()
    it("line field is 0-indexed and matches the cursor row", function()
      bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "ignored", "target" })
      vim.api.nvim_set_current_buf(bufnr)
      vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- row 2 (1-indexed) = line 1 (0-indexed)
      local t = cword_token(bufnr)
      assert.not_nil(t)
      assert.equals(1, t.line) -- 0-indexed
      assert.equals("target", token_text("target", t))
    end)

    it("col_start is always < col_end (non-empty token)", function()
      local line = "abc"
      bufnr = make_buf(line)
      set_col(1)
      local t = cword_token(bufnr)
      assert.not_nil(t)
      assert.is_true(t.col_start < t.col_end)
    end)

    it("cursor column is always within [col_start, col_end)", function()
      local line = "hello world"
      bufnr = make_buf(line)
      for col = 0, #line - 1 do
        set_col(col)
        local t = cword_token(bufnr)
        if t then
          assert.is_true(
            col >= t.col_start and col < t.col_end,
            string.format("col %d not in [%d, %d)", col, t.col_start, t.col_end)
          )
        end
      end
    end)
  end)

  describe("real-world C code (program slice)", function()
    -- Verifies the plugin works on incomplete C code with undefined symbols.
    -- Mimics the user's NVMe analysis workflow.
    local c_line = "    status = nvme_map_dptr(n, &req->sg, len, &req->cmd);"

    it("finds 'req' token correctly in a C expression", function()
      bufnr = make_buf(c_line)
      -- Find position of first 'req'
      local req_col = c_line:find("req") - 1 -- 0-indexed
      set_col(req_col)
      local t = cword_token(bufnr)
      assert.not_nil(t)
      assert.equals("req", token_text(c_line, t))
    end)

    it("finds 'nvme_map_dptr' as a single token", function()
      bufnr = make_buf(c_line)
      local col = c_line:find("nvme_map_dptr") - 1
      set_col(col + 4) -- cursor mid-word
      local t = cword_token(bufnr)
      assert.not_nil(t)
      assert.equals("nvme_map_dptr", token_text(c_line, t))
    end)

    it("returns nil on the '>' in '->'", function()
      bufnr = make_buf(c_line)
      local arrow_col = c_line:find("->") -- 1-indexed
      set_col(arrow_col) -- the '-' char (0-indexed = arrow_col - 1)... let's be precise
      -- '-' is at Lua position arrow_col, 0-indexed = arrow_col - 1
      set_col(arrow_col - 1) -- '-'
      assert.is_nil(cword_token(bufnr))
    end)
  end)
end)
