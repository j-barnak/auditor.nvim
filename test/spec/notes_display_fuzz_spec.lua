-- test/spec/notes_display_fuzz_spec.lua
-- Fuzz and property-based tests for format_note_preview and note display.
--
-- Coverage:
--   DF1  format_note_preview fuzz: random ASCII input (200 iterations)
--   DF2  format_note_preview fuzz: unicode input
--   DF3  format_note_preview fuzz: SQL injection strings
--   DF4  format_note_preview fuzz: control characters
--   DF5  format_note_preview fuzz: very long strings (100K)
--   DF6  Property: preview always starts with "  " (non-empty input)
--   DF7  Property: preview length <= max_len + 2 (for indent)
--   DF8  Property: multi-line always has (+N lines) suffix
--   DF9  Property: empty/nil always returns ""
--   DF10 Float lifecycle fuzz: rapid open/close viewer
--   DF11 Multi-note same line fuzz: N random notes on one line
--   DF12 Nasty strings gauntlet: format_note_preview
--   DF13 Property: sign_hl always returns a string
--   DF14 Property: apply_note never crashes
--   DF15 format_note_preview: random max_len values

local function reset_modules()
  for _, m in ipairs({ "auditor", "auditor.init", "auditor.db", "auditor.highlights", "auditor.ts" }) do
    package.loaded[m] = nil
  end
end

local function make_rng(seed)
  local s = math.abs(seed) + 1
  return function(lo, hi)
    s = (s * 1664525 + 1013904223) % (2 ^ 32)
    return lo + math.floor(s * (hi - lo + 1) / (2 ^ 32))
  end
end

local function random_ascii(rng, len)
  local chars = {}
  for i = 1, len do
    chars[i] = string.char(rng(32, 126))
  end
  return table.concat(chars)
end

local NASTY_STRINGS = {
  "",
  " ",
  "\t",
  "\n",
  "\r\n",
  "hello\x01world",
  string.rep("a", 1000),
  string.rep("x", 10000),
  "'; DROP TABLE highlights; --",
  "$(rm -rf /)",
  "`rm -rf /`",
  "foo'bar\"baz",
  "\x1b[31mred\x1b[0m",
  "\xfe\xff",
  "\xc0\xaf",
  "日本語テスト",
  "🎉🔥💀🚀",
  "café résumé naïve",
  "a\xcc\x81",
  string.rep("🔥", 500),
  "note with\nnewline",
  "note with\rcarriage return",
  "first\nsecond\nthird\nfourth\nfifth",
  ("a"):rep(100000),
}

describe("notes display fuzz", function()
  local hl

  before_each(function()
    reset_modules()
    local tmp_db = vim.fn.tempname() .. ".db"
    require("auditor").setup({ db_path = tmp_db, keymaps = false })
    hl = require("auditor.highlights")
  end)

  -- ── DF1: random ASCII input (200 iterations) ─────────────────────────
  describe("DF1: random ASCII (200 iterations)", function()
    it("never crashes", function()
      for seed = 1, 200 do
        local rng = make_rng(seed)
        local text = random_ascii(rng, rng(1, 200))
        local word = random_ascii(rng, rng(1, 20))
        local max_len = rng(5, 100)
        local ok, result = pcall(hl.format_note_preview, text, word, max_len)
        assert(ok, string.format("seed=%d: %s", seed, tostring(result)))
        assert.is_string(result)
      end
    end)
  end)

  -- ── DF2: unicode input ───────────────────────────────────────────────
  describe("DF2: unicode input", function()
    local unicode_strings = {
      "日本語テスト", "中文测试", "한국어", "العربية",
      "🎉🔥💀🚀", "café résumé", "Ñoño", "θ∑∂ƒ∆",
      "🏳️\u{200D}🌈", "a\xcc\x81b\xcc\x82",
    }

    for i, text in ipairs(unicode_strings) do
      it(string.format("unicode %d: does not crash", i), function()
        local ok, result = pcall(hl.format_note_preview, text, "word", 30)
        assert(ok, tostring(result))
        assert.is_string(result)
      end)
    end
  end)

  -- ── DF3: SQL injection strings ───────────────────────────────────────
  describe("DF3: SQL injection", function()
    local sql_strings = {
      "'; DROP TABLE highlights; --",
      "\" OR 1=1 --",
      "Robert'); DROP TABLE Students;--",
    }

    for i, text in ipairs(sql_strings) do
      it(string.format("SQL %d: returns string containing the text", i), function()
        local result = hl.format_note_preview(text, nil, 100)
        -- Use plain find to avoid pattern issues with special chars.
        assert.is_truthy(result:find(text:sub(1, 10), 1, true))
      end)
    end
  end)

  -- ── DF4: control characters ──────────────────────────────────────────
  describe("DF4: control characters", function()
    local ctrl_strings = {
      "\t\t\t",
      "line1\nline2\nline3",
      "\x1b[31mcolored\x1b[0m",
      "bell\x07char",
    }

    for i, text in ipairs(ctrl_strings) do
      it(string.format("ctrl %d: does not crash", i), function()
        local ok, result = pcall(hl.format_note_preview, text, "w", 30)
        assert(ok, tostring(result))
        assert.is_string(result)
      end)
    end
  end)

  -- ── DF5: very long strings ───────────────────────────────────────────
  describe("DF5: very long strings", function()
    for _, len in ipairs({ 1000, 10000, 100000 }) do
      it(string.format("length %d: truncates safely", len), function()
        local text = string.rep("x", len)
        local result = hl.format_note_preview(text, "word", 30)
        -- result should be bounded
        assert.is_true(#result <= 40) -- 30 + "  " + some overhead
      end)
    end
  end)

  -- ── DF6: Property: preview starts with "  " ─────────────────────────
  describe("DF6: property — preview starts with indent", function()
    it("always starts with two spaces for non-empty input", function()
      for seed = 1, 100 do
        local rng = make_rng(seed)
        local text = random_ascii(rng, rng(1, 50))
        local result = hl.format_note_preview(text, nil, 30)
        assert.equals("  ", result:sub(1, 2),
          string.format("seed=%d: missing indent", seed))
      end
    end)
  end)

  -- ── DF7: Property: preview content <= max_len ────────────────────────
  describe("DF7: property — content bounded by max_len", function()
    it("content after indent <= max_len", function()
      for seed = 1, 100 do
        local rng = make_rng(seed)
        local text = random_ascii(rng, rng(1, 200))
        local max_len = rng(5, 50)
        local result = hl.format_note_preview(text, nil, max_len)
        local content = result:sub(3) -- strip "  "
        assert.is_true(#content <= max_len,
          string.format("seed=%d: content %d > max %d", seed, #content, max_len))
      end
    end)
  end)

  -- ── DF8: Property: multi-line has suffix ─────────────────────────────
  describe("DF8: property — multi-line suffix", function()
    it("multi-line notes have (+N lines) suffix", function()
      for seed = 1, 50 do
        local rng = make_rng(seed)
        local n_lines = rng(2, 10)
        local lines = {}
        for i = 1, n_lines do
          lines[i] = random_ascii(rng, rng(1, 20))
        end
        local text = table.concat(lines, "\n")
        local result = hl.format_note_preview(text, nil, 200) -- large max to avoid truncation
        local expected_suffix = string.format("(+%d lines)", n_lines - 1)
        assert.is_truthy(result:match(vim.pesc(expected_suffix)),
          string.format("seed=%d: missing suffix in '%s'", seed, result))
      end
    end)
  end)

  -- ── DF9: Property: empty/nil returns "" ──────────────────────────────
  describe("DF9: property — empty returns empty", function()
    it("nil text", function()
      assert.equals("", hl.format_note_preview(nil, "word", 30))
    end)

    it("empty text", function()
      assert.equals("", hl.format_note_preview("", "word", 30))
    end)

    it("nil text nil word", function()
      assert.equals("", hl.format_note_preview(nil, nil, 30))
    end)
  end)

  -- ── DF10: Float lifecycle fuzz ───────────────────────────────────────
  describe("DF10: float lifecycle fuzz", function()
    it("rapid show_note/close cycles don't crash (30 iterations)", function()
      reset_modules()
      local tmp_db = vim.fn.tempname() .. ".db"
      local auditor = require("auditor")
      auditor.setup({ db_path = tmp_db, keymaps = false })
      auditor._note_input_override = true
      hl = require("auditor.highlights")

      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(bufnr, vim.fn.tempname() .. ".lua")
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })
      vim.api.nvim_set_current_buf(bufnr)
      auditor.enter_audit_mode()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      auditor.highlight_cword_buffer("red")

      local orig = vim.ui.input
      vim.ui.input = function(_, cb) cb("test note") end
      auditor.add_note()
      vim.ui.input = orig

      for i = 1, 30 do
        local ok, err = pcall(auditor.show_note)
        assert(ok, string.format("iter=%d show: %s", i, tostring(err)))
        ok, err = pcall(auditor._close_note_float)
        assert(ok, string.format("iter=%d close: %s", i, tostring(err)))
      end

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── DF11: Multi-note same line fuzz ──────────────────────────────────
  describe("DF11: multi-note same line fuzz", function()
    it("3 notes on one line each have correct preview", function()
      reset_modules()
      local tmp_db = vim.fn.tempname() .. ".db"
      local auditor = require("auditor")
      auditor.setup({ db_path = tmp_db, keymaps = false })
      auditor._note_input_override = true
      hl = require("auditor.highlights")

      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(bufnr, vim.fn.tempname() .. ".lua")
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "aaa bbb ccc" })
      vim.api.nvim_set_current_buf(bufnr)
      auditor.enter_audit_mode()

      local words = { { col = 0, note = "n_aaa" }, { col = 4, note = "n_bbb" }, { col = 8, note = "n_ccc" } }
      for _, w in ipairs(words) do
        vim.api.nvim_win_set_cursor(0, { 1, w.col })
        auditor.highlight_cword_buffer("red")
        local orig = vim.ui.input
        vim.ui.input = function(_, cb) cb(w.note) end
        auditor.add_note()
        vim.ui.input = orig
      end

      local marks = vim.api.nvim_buf_get_extmarks(bufnr, hl.note_ns, 0, -1, { details = true })
      assert.equals(3, #marks)

      local all_text = {}
      for _, m in ipairs(marks) do
        local vt = m[4].virt_text
        if vt then
          table.insert(all_text, vt[1][1])
        end
      end
      local joined = table.concat(all_text, "|")
      assert.is_truthy(joined:match("n_aaa"))
      assert.is_truthy(joined:match("n_bbb"))
      assert.is_truthy(joined:match("n_ccc"))

      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── DF12: Nasty strings gauntlet ─────────────────────────────────────
  describe("DF12: nasty strings gauntlet", function()
    for i, text in ipairs(NASTY_STRINGS) do
      it(string.format("nasty %d (%d bytes): format_note_preview", i, #text), function()
        local ok, result = pcall(hl.format_note_preview, text, "word", 30)
        assert(ok, string.format("nasty %d: %s", i, tostring(result)))
        if text ~= "" then
          assert.is_true(#result > 0)
        end
      end)
    end
  end)

  -- ── DF13: Property: sign_hl always returns string ────────────────────
  describe("DF13: property — note_sign_hl returns string", function()
    it("for various inputs", function()
      local inputs = { nil, "", "red", "blue", "half", "unknown", "AuditorRed", "\n", "'; DROP" }
      for _, input in ipairs(inputs) do
        local ok, result = pcall(hl.note_sign_hl, input)
        assert(ok, tostring(result))
        assert.is_string(result)
      end
    end)
  end)

  -- ── DF14: Property: apply_note never crashes ─────────────────────────
  describe("DF14: property — apply_note never crashes", function()
    it("with various color/word_text combinations (50 iterations)", function()
      for seed = 1, 50 do
        local rng = make_rng(seed)
        local text = random_ascii(rng, rng(1, 100))
        local color = ({ "red", "blue", "half", nil, "" })[rng(1, 5)]
        local word = random_ascii(rng, rng(0, 20))
        if #word == 0 then word = nil end

        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })

        local ok, err = pcall(hl.apply_note, bufnr, 0, text, color, word)
        assert(ok, string.format("seed=%d: %s", seed, tostring(err)))

        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end)
  end)

  -- ── DF15: random max_len values ──────────────────────────────────────
  describe("DF15: random max_len values", function()
    it("handles max_len from 1 to 1000", function()
      for seed = 1, 100 do
        local rng = make_rng(seed)
        local text = random_ascii(rng, rng(1, 200))
        local max_len = rng(1, 1000)
        local ok, result = pcall(hl.format_note_preview, text, "word", max_len)
        assert(ok, string.format("seed=%d max=%d: %s", seed, max_len, tostring(result)))
        assert.is_string(result)
      end
    end)
  end)
end)
