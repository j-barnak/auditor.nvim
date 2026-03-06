-- test/spec/fuzz_spec.lua
-- Property-based and fuzz tests for token extraction and cword detection.
--
-- Each property test runs a deterministic pseudo-random generator over many
-- seeds so failures are always reproducible (re-run the same seed to replay).
--
-- Properties verified:
--   P1  Token text is always a non-empty [%w_]+ run
--   P2  Tokens are sorted by col_start
--   P3  No two tokens overlap
--   P4  Every token is maximal (chars just outside boundaries are non-word)
--   P5  Tokenizer output matches an independent reference implementation
--   P6  cword_token cursor-is-within-token invariant
--   P7  cword_token nil-on-non-word invariant
--   P8  cword_token matches the corresponding get_tokens result
--   P9  DB round-trip preserves all fields for random inputs

local ts = require("auditor.ts")

-- Expose _cword_token from the already-setup auditor module
local function get_cword_token()
  -- Re-use the module if already loaded (setup called by cword_spec or integration_spec).
  local a = package.loaded["auditor"] or require("auditor")
  return a._cword_token
end

-- ── deterministic PRNG (Numerical Recipes LCG) ───────────────────────────────

---@param seed integer
---@return fun(lo: integer, hi: integer): integer
local function make_rng(seed)
  local s = math.abs(seed) + 1
  return function(lo, hi)
    s = (s * 1664525 + 1013904223) % (2 ^ 32)
    return lo + (math.floor(s * (hi - lo + 1) / (2 ^ 32)))
  end
end

-- ── generators ───────────────────────────────────────────────────────────────

local WORD_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"
local SEP_CHARS = " +-*/=<>!@#$%&()[];:,.|^~"

---@param rng fun(lo:integer,hi:integer):integer
---@return string line, {col_start:integer, col_end:integer}[] expected_tokens
local function gen_line_with_tokens(rng)
  local n_words = rng(1, 7)
  local parts = {}
  local expected = {}
  local pos = 0 -- current byte offset

  for i = 1, n_words do
    -- Separator (skipped before first word sometimes)
    if i > 1 or rng(0, 1) == 1 then
      local sep_len = rng(1, 4)
      for _ = 1, sep_len do
        local idx = rng(1, #SEP_CHARS)
        parts[#parts + 1] = SEP_CHARS:sub(idx, idx)
        pos = pos + 1
      end
    end
    -- Word
    local word_len = rng(1, 10)
    local word_start = pos
    for _ = 1, word_len do
      local idx = rng(1, #WORD_CHARS)
      parts[#parts + 1] = WORD_CHARS:sub(idx, idx)
      pos = pos + 1
    end
    table.insert(expected, { col_start = word_start, col_end = pos })
  end

  return table.concat(parts), expected
end

--- Reference tokeniser — a dead-simple forward scan used to verify the plugin.
---@param line string
---@return {col_start:integer, col_end:integer}[]
local function reference_tokens(line)
  local out = {}
  local i = 1
  while i <= #line do
    if line:sub(i, i):match("[%w_]") then
      local j = i
      while j <= #line and line:sub(j, j):match("[%w_]") do
        j = j + 1
      end
      table.insert(out, { col_start = i - 1, col_end = j - 1 })
      i = j
    else
      i = i + 1
    end
  end
  return out
end

-- ── helpers ───────────────────────────────────────────────────────────────────

local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr
end

local function set_line_selection(_bufnr, line_num)
  -- 1-indexed row, select the full line in V mode
  vim.fn.setpos("'<", { 0, line_num, 1, 0 })
  vim.fn.setpos("'>", { 0, line_num, 9999, 0 })
end

-- Run a property over `n` seeds; error message includes the seed + input.
local function property(desc, n, fn)
  for seed = 1, n do
    local rng = make_rng(seed)
    local ok, err = pcall(fn, rng, seed)
    if not ok then
      error(
        string.format("[fuzz] Property '%s' failed at seed=%d:\n%s", desc, seed, tostring(err)),
        2
      )
    end
  end
end

-- ── P1-P5: regex tokeniser invariants ────────────────────────────────────────

describe("fuzz: regex token extraction (P1-P5)", function()
  local bufnr

  after_each(function()
    if bufnr then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      bufnr = nil
    end
  end)

  it("P1: every token text matches ^[%w_]+$", function()
    property("P1 token text validity", 300, function(rng)
      local line, _ = gen_line_with_tokens(rng)
      bufnr = make_buf({ line })
      set_line_selection(bufnr, 1)
      local tokens = ts.get_tokens(bufnr, "V", {})
      for _, t in ipairs(tokens) do
        local text = line:sub(t.col_start + 1, t.col_end)
        assert(
          #text > 0 and text:match("^[%w_]+$"),
          string.format(
            "invalid token text %q at [%d,%d) in %q",
            text,
            t.col_start,
            t.col_end,
            line
          )
        )
      end
    end)
  end)

  it("P2: tokens are sorted by col_start", function()
    property("P2 token ordering", 300, function(rng)
      local line, _ = gen_line_with_tokens(rng)
      bufnr = make_buf({ line })
      set_line_selection(bufnr, 1)
      local tokens = ts.get_tokens(bufnr, "V", {})
      for i = 2, #tokens do
        assert(
          tokens[i].col_start >= tokens[i - 1].col_start,
          string.format(
            "out-of-order tokens: [%d,%d) before [%d,%d) in %q",
            tokens[i - 1].col_start,
            tokens[i - 1].col_end,
            tokens[i].col_start,
            tokens[i].col_end,
            line
          )
        )
      end
    end)
  end)

  it("P3: no two tokens overlap", function()
    property("P3 non-overlap", 300, function(rng)
      local line, _ = gen_line_with_tokens(rng)
      bufnr = make_buf({ line })
      set_line_selection(bufnr, 1)
      local tokens = ts.get_tokens(bufnr, "V", {})
      for i = 2, #tokens do
        assert(
          tokens[i - 1].col_end <= tokens[i].col_start,
          string.format(
            "overlapping tokens [%d,%d) and [%d,%d) in %q",
            tokens[i - 1].col_start,
            tokens[i - 1].col_end,
            tokens[i].col_start,
            tokens[i].col_end,
            line
          )
        )
      end
    end)
  end)

  it("P4: every token is maximal (chars outside are non-word)", function()
    property("P4 token maximality", 300, function(rng)
      local line, _ = gen_line_with_tokens(rng)
      bufnr = make_buf({ line })
      set_line_selection(bufnr, 1)
      local tokens = ts.get_tokens(bufnr, "V", {})
      for _, t in ipairs(tokens) do
        if t.col_start > 0 then
          local before = line:sub(t.col_start, t.col_start) -- byte just before
          assert(
            not before:match("[%w_]"),
            string.format(
              "token [%d,%d) not maximal at start (char before: %q) in %q",
              t.col_start,
              t.col_end,
              before,
              line
            )
          )
        end
        if t.col_end < #line then
          local after = line:sub(t.col_end + 1, t.col_end + 1) -- byte just after
          assert(
            not after:match("[%w_]"),
            string.format(
              "token [%d,%d) not maximal at end (char after: %q) in %q",
              t.col_start,
              t.col_end,
              after,
              line
            )
          )
        end
      end
    end)
  end)

  it("P5: output matches independent reference implementation", function()
    property("P5 reference comparison", 300, function(rng)
      local line, _ = gen_line_with_tokens(rng)
      bufnr = make_buf({ line })
      set_line_selection(bufnr, 1)
      local tokens = ts.get_tokens(bufnr, "V", {})
      local ref = reference_tokens(line)

      assert(
        #tokens == #ref,
        string.format("token count mismatch: got %d, expected %d for line %q", #tokens, #ref, line)
      )
      for i, t in ipairs(tokens) do
        assert(
          t.col_start == ref[i].col_start and t.col_end == ref[i].col_end,
          string.format(
            "token %d mismatch: got [%d,%d), expected [%d,%d) in %q",
            i,
            t.col_start,
            t.col_end,
            ref[i].col_start,
            ref[i].col_end,
            line
          )
        )
      end
    end)
  end)

  it("P5b: handles lines containing ONLY separators (no tokens expected)", function()
    property("P5b all-separator lines", 100, function(rng)
      local len = rng(1, 20)
      local parts = {}
      for _ = 1, len do
        local idx = rng(1, #SEP_CHARS)
        parts[#parts + 1] = SEP_CHARS:sub(idx, idx)
      end
      local line = table.concat(parts)
      bufnr = make_buf({ line })
      set_line_selection(bufnr, 1)
      local tokens = ts.get_tokens(bufnr, "V", {})
      assert(
        #tokens == 0,
        string.format("expected 0 tokens for separator-only line %q, got %d", line, #tokens)
      )
    end)
  end)
end)

-- ── P6-P8: cword_token invariants ────────────────────────────────────────────

describe("fuzz: cword_token (P6-P8)", function()
  local bufnr

  after_each(function()
    if bufnr then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      bufnr = nil
    end
  end)

  it("P6: cursor-within-token invariant — token always contains the cursor column", function()
    local cword_token = get_cword_token()
    property("P6 cword contains cursor", 400, function(rng)
      local line, expected = gen_line_with_tokens(rng)
      bufnr = make_buf({ line })

      -- Test a cursor on each word character position
      for _, w in ipairs(expected) do
        for col = w.col_start, w.col_end - 1 do
          vim.api.nvim_win_set_cursor(0, { 1, col })
          local t = cword_token(bufnr)
          assert(t ~= nil, string.format("expected token at col %d (word char) in %q", col, line))
          assert(
            col >= t.col_start and col < t.col_end,
            string.format(
              "cursor col %d not in token [%d,%d) for %q",
              col,
              t.col_start,
              t.col_end,
              line
            )
          )
        end
      end
    end)
  end)

  it("P7: nil-on-non-word — cursor on separator always returns nil", function()
    local cword_token = get_cword_token()
    property("P7 cword nil on separator", 400, function(rng)
      local line, expected = gen_line_with_tokens(rng)
      bufnr = make_buf({ line })

      -- Build a set of word-character positions
      local word_positions = {}
      for _, w in ipairs(expected) do
        for col = w.col_start, w.col_end - 1 do
          word_positions[col] = true
        end
      end

      -- Every position NOT in a word must return nil
      for col = 0, #line - 1 do
        if not word_positions[col] then
          vim.api.nvim_win_set_cursor(0, { 1, col })
          local t = cword_token(bufnr)
          assert(
            t == nil,
            string.format(
              "expected nil at separator col %d (char=%q) in %q",
              col,
              line:sub(col + 1, col + 1),
              line
            )
          )
        end
      end
    end)
  end)

  it("P8: cword_token agrees with get_tokens for all word positions", function()
    local cword_token = get_cword_token()
    property("P8 cword matches get_tokens", 300, function(rng)
      local line, _ = gen_line_with_tokens(rng)
      bufnr = make_buf({ line })
      set_line_selection(bufnr, 1)
      local all_tokens = ts.get_tokens(bufnr, "V", {})

      -- Build position-to-token map from get_tokens
      local pos_to_token = {}
      for _, t in ipairs(all_tokens) do
        for col = t.col_start, t.col_end - 1 do
          pos_to_token[col] = t
        end
      end

      -- For each word position, cword_token must return the same boundaries
      for col = 0, #line - 1 do
        if line:sub(col + 1, col + 1):match("[%w_]") then
          vim.api.nvim_win_set_cursor(0, { 1, col })
          local cw = cword_token(bufnr)
          local gt = pos_to_token[col]
          assert(cw ~= nil, string.format("cword nil at word col %d in %q", col, line))
          assert(gt ~= nil, string.format("get_tokens missing word at col %d in %q", col, line))
          assert(
            cw.col_start == gt.col_start and cw.col_end == gt.col_end,
            string.format(
              "cword [%d,%d) != get_tokens [%d,%d) at col %d in %q",
              cw.col_start,
              cw.col_end,
              gt.col_start,
              gt.col_end,
              col,
              line
            )
          )
        end
      end
    end)
  end)
end)

-- ── P9-P13: find_word_occurrences invariants ─────────────────────────────────

describe("fuzz: find_word_occurrences (P9-P13)", function()
  local bufnr

  -- Access the exposed helper from the auditor module.
  local function get_find_occurrences()
    local a = package.loaded["auditor"] or require("auditor")
    return a._find_word_occurrences
  end

  after_each(function()
    if bufnr then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      bufnr = nil
    end
  end)

  it("P9: finds every occurrence of a word in a line (no false negatives)", function()
    local find = get_find_occurrences()
    property("P9 no false negatives", 400, function(rng)
      -- Build a line that contains the target word N times separated by non-word chars.
      local target = "req"
      local n_occurrences = rng(1, 6)
      local parts = {}
      local expected_starts = {}
      local pos = 0

      for i = 1, n_occurrences do
        -- separator (at least 1 non-word char)
        if i > 1 then
          local sep_len = rng(1, 4)
          for _ = 1, sep_len do
            local idx = rng(1, #SEP_CHARS)
            parts[#parts + 1] = SEP_CHARS:sub(idx, idx)
            pos = pos + 1
          end
        end
        table.insert(expected_starts, pos)
        parts[#parts + 1] = target
        pos = pos + #target
      end

      local line = table.concat(parts)
      bufnr = make_buf({ line })

      local results = find(bufnr, target, 0, 0)
      assert(
        #results == n_occurrences,
        string.format(
          "expected %d occurrences of %q in %q, got %d",
          n_occurrences,
          target,
          line,
          #results
        )
      )
      for i, r in ipairs(results) do
        assert(
          r.col_start == expected_starts[i],
          string.format(
            "occurrence %d: expected col_start %d, got %d in %q",
            i,
            expected_starts[i],
            r.col_start,
            line
          )
        )
        assert(r.col_end == expected_starts[i] + #target)
      end
    end)
  end)

  it("P10: no false positives — partial-word matches are never returned", function()
    local find = get_find_occurrences()
    -- Embed the target word inside longer words on both sides and verify it is NOT found.
    property("P10 no false positives", 400, function(rng)
      local target = "foo"
      -- Generate a word that contains `target` as a substring but is longer
      local prefix_len = rng(1, 4)
      local suffix_len = rng(1, 4)
      local prefix = WORD_CHARS:sub(1, prefix_len):rep(1) -- just use first N chars
      local suffix = WORD_CHARS:sub(2, suffix_len + 1):rep(1)
      local longer_word = prefix .. target .. suffix -- e.g. "abcfoodef"
      local line = longer_word .. " " .. target .. " " .. "x" .. target

      bufnr = make_buf({ line })
      local results = find(bufnr, target, 0, 0)

      -- Only the standalone `target` in the middle should match
      local standalone_count = 0
      local start = 1
      while true do
        local s, e = line:find("%f[%w_]" .. target .. "%f[^%w_]", start)
        if not s then
          break
        end
        standalone_count = standalone_count + 1
        start = e + 1
      end
      assert(
        #results == standalone_count,
        string.format("P10: expected %d matches in %q, got %d", standalone_count, line, #results)
      )
    end)
  end)

  it("P11: multi-line buffer — occurrence count equals sum across all lines", function()
    local find = get_find_occurrences()
    property("P11 multi-line count", 300, function(rng)
      local target = "x"
      local n_lines = rng(2, 6)
      local lines = {}
      local total_expected = 0

      for _ = 1, n_lines do
        local line, expected = gen_line_with_tokens(rng)
        -- Count occurrences of "x" (a single-char token) in this line
        local count = 0
        for _, tok in ipairs(expected) do
          local word = line:sub(tok.col_start + 1, tok.col_end)
          if word == target then
            count = count + 1
          end
        end
        total_expected = total_expected + count
        table.insert(lines, line)
      end

      bufnr = make_buf(lines)
      local results = find(bufnr, target, 0, n_lines - 1)
      assert(
        #results == total_expected,
        string.format("P11: expected %d, got %d across %d lines", total_expected, #results, n_lines)
      )
    end)
  end)

  it("P12: every result has line within [srow, erow]", function()
    local find = get_find_occurrences()
    property("P12 line bounds respected", 300, function(rng)
      local n_lines = rng(3, 8)
      local lines = {}
      for _ = 1, n_lines do
        local line, _ = gen_line_with_tokens(rng)
        table.insert(lines, line)
      end
      local srow = rng(0, n_lines - 2)
      local erow = rng(srow, n_lines - 1)

      bufnr = make_buf(lines)
      local results = find(bufnr, "a", srow, erow)
      for _, r in ipairs(results) do
        assert(
          r.line >= srow and r.line <= erow,
          string.format("P12: result line %d outside [%d,%d]", r.line, srow, erow)
        )
      end
    end)
  end)

  it(
    "P13: find_word_occurrences is idempotent (two identical calls return same results)",
    function()
      local find = get_find_occurrences()
      property("P13 idempotency", 200, function(rng)
        local line, _ = gen_line_with_tokens(rng)
        bufnr = make_buf({ line })

        -- Pick any word from the line as target
        local ref_toks = reference_tokens(line)
        if #ref_toks == 0 then
          return
        end
        local tok = ref_toks[rng(1, #ref_toks)]
        local target = line:sub(tok.col_start + 1, tok.col_end)

        local r1 = find(bufnr, target, 0, 0)
        local r2 = find(bufnr, target, 0, 0)

        assert(
          #r1 == #r2,
          string.format("P13: idempotency broken: %d vs %d for %q in %q", #r1, #r2, target, line)
        )
        for i = 1, #r1 do
          assert(r1[i].col_start == r2[i].col_start and r1[i].col_end == r2[i].col_end)
        end
      end)
    end
  )
end)

-- ── robustness: incomplete / slice code ──────────────────────────────────────

describe("fuzz: robustness on incomplete and slice code", function()
  -- The C snippet from the user's real NVMe analysis workflow.
  -- Types like NvmeCtrl are not defined here — this is a program slice.
  local C_SLICE = [[
static uint16_t nvme_changed_nslist(NvmeCtrl *n, uint8_t rae, uint32_t buf_len,
                                    uint64_t off, NvmeRequest *req)
{
    uint32_t nslist[1024];
    uint32_t trans_len;
    int i = 0;
    uint32_t nsid;

    memset(nslist, 0x0, sizeof(nslist));
    trans_len = MIN(sizeof(nslist) - off, buf_len);

    while ((nsid = find_first_bit(n->changed_nsids, NVME_CHANGED_NSID_SIZE)) !=
            NVME_CHANGED_NSID_SIZE) {
        if (i == ARRAY_SIZE(nslist)) {
            memset(nslist, 0x0, sizeof(nslist));
            nslist[0] = 0xffffffff;
            break;
        }
        nslist[i++] = nsid;
        clear_bit(nsid, n->changed_nsids);
    }

    return nvme_c2h(n, ((uint8_t *)nslist) + off, trans_len, req);
}]]

  local function lines_of(s)
    local t = {}
    for l in (s .. "\n"):gmatch("([^\n]*)\n") do
      t[#t + 1] = l
    end
    return t
  end

  it("get_tokens does not error on a C program slice (treesitter or regex)", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    local c_lines = lines_of(C_SLICE)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, c_lines)
    vim.bo[bufnr].filetype = "c"
    vim.api.nvim_set_current_buf(bufnr)

    vim.fn.setpos("'<", { 0, 1, 1, 0 })
    vim.fn.setpos("'>", { 0, #c_lines, 9999, 0 })

    local ok, result = pcall(ts.get_tokens, bufnr, "V", {})
    assert(ok, "get_tokens raised an error on a C slice: " .. tostring(result))
    assert(type(result) == "table", "get_tokens returned non-table")

    -- "req" must appear as a token somewhere in the result
    local found_req = false
    for _, t in ipairs(result) do
      local row_text = c_lines[t.line + 1]
      if row_text then
        local text = row_text:sub(t.col_start + 1, t.col_end)
        if text == "req" then
          found_req = true
          break
        end
      end
    end
    assert(found_req, "'req' not found in tokens for C slice")

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("get_tokens does not error on syntactically incomplete code", function()
    -- Missing closing brace — tree-sitter error recovery must not propagate
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "void foo() {",
      "  int x = bar(",
      "  // incomplete — no closing brace or paren",
    })
    vim.bo[bufnr].filetype = "c"
    vim.api.nvim_set_current_buf(bufnr)
    vim.fn.setpos("'<", { 0, 1, 1, 0 })
    vim.fn.setpos("'>", { 0, 3, 9999, 0 })

    local ok, result = pcall(ts.get_tokens, bufnr, "V", {})
    assert(ok, "get_tokens errored on incomplete code: " .. tostring(result))
    assert(type(result) == "table")

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("cword_token works on a C slice without any parser", function()
    local cword_token = get_cword_token()
    -- Plain buffer (no filetype) — exercises the word-boundary scan directly
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "    status = nvme_map_dptr(n, &req->sg, len, &req->cmd);",
    })
    vim.api.nvim_set_current_buf(bufnr)

    local line = "    status = nvme_map_dptr(n, &req->sg, len, &req->cmd);"
    local req_col = line:find("req") - 1
    vim.api.nvim_win_set_cursor(0, { 1, req_col })
    local t = cword_token(bufnr)
    assert(t ~= nil, "expected cword token on 'req'")
    assert.equals("req", line:sub(t.col_start + 1, t.col_end))

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("multi-line selection across the full C slice returns tokens without error", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    local c_lines = lines_of(C_SLICE)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, c_lines)
    vim.api.nvim_set_current_buf(bufnr)
    vim.fn.setpos("'<", { 0, 1, 1, 0 })
    vim.fn.setpos("'>", { 0, #c_lines, 9999, 0 })

    -- No filetype set — exercises regex path
    local ok, result = pcall(ts.get_tokens, bufnr, "V", {})
    assert(ok)
    assert(#result > 0, "expected tokens from C slice via regex fallback")

    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)
