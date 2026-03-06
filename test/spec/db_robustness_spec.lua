-- test/spec/db_robustness_spec.lua
-- Exhaustive SQLite robustness tests for auditor.db.
--
-- Coverage:
--   D1  Round-trip integrity — all fields preserved exactly
--   D2  SQL injection via filepath strings cannot corrupt the database
--   D3  Special characters in filepaths (spaces, quotes, unicode, metacharacters)
--   D4  Schema persistence — data survives close and reopen of the same DB file
--   D5  Bulk operations — 1000 rows inserted and all retrieved correctly
--   D6  Per-file isolation — saves to one file do not affect another
--   D7  Idempotent schema — calling setup() twice on the same file is safe
--   D8  All three color values are stored and retrieved correctly
--   D9  Large integer values for line / col fields
--   D10 Sequential word_index values are preserved
--   D11 Clear then re-save works correctly
--   D12 Querying an unknown filepath returns {} (not nil, not error)
--   D13 Duplicate position entries are both stored (no hidden unique constraint)
--   D14 All fields are present in every returned row
--   D15 Property: random round-trips always preserve data (200 iterations)

-- ── deterministic PRNG ────────────────────────────────────────────────────────

local function make_rng(seed)
  local s = math.abs(seed) + 1
  return function(lo, hi)
    s = (s * 1664525 + 1013904223) % (2 ^ 32)
    return lo + math.floor(s * (hi - lo + 1) / (2 ^ 32))
  end
end

-- ── helpers ───────────────────────────────────────────────────────────────────

local function fresh_db()
  for _, m in ipairs({ "auditor.db" }) do
    package.loaded[m] = nil
  end
  local db = require("auditor.db")
  local path = vim.fn.tempname() .. ".db"
  db.setup(path)
  return db, path
end

local function sorted_by_col(rows)
  local copy = vim.deepcopy(rows)
  table.sort(copy, function(a, b)
    if a.line ~= b.line then
      return a.line < b.line
    end
    return a.col_start < b.col_start
  end)
  return copy
end

-- ── test suite ────────────────────────────────────────────────────────────────

describe("auditor.db robustness", function()
  local db, tmp_path

  before_each(function()
    db, tmp_path = fresh_db()
  end)

  after_each(function()
    pcall(os.remove, tmp_path)
  end)

  -- D1: Round-trip integrity ─────────────────────────────────────────────────

  describe("D1: round-trip integrity", function()
    it("preserves filepath exactly", function()
      local fp = "/some/deep/path/file.lua"
      db.save_words(fp, { { line = 0, col_start = 0, col_end = 3 } }, "red")
      local rows = db.get_highlights(fp)
      assert.equals(fp, rows[1].filepath)
    end)

    it("preserves line number exactly", function()
      db.save_words("/f.lua", { { line = 42, col_start = 0, col_end = 5 } }, "red")
      local rows = db.get_highlights("/f.lua")
      assert.equals(42, rows[1].line)
    end)

    it("preserves col_start and col_end exactly", function()
      db.save_words("/f.lua", { { line = 0, col_start = 17, col_end = 23 } }, "blue")
      local rows = db.get_highlights("/f.lua")
      assert.equals(17, rows[1].col_start)
      assert.equals(23, rows[1].col_end)
    end)

    it("preserves color exactly", function()
      for _, color in ipairs({ "red", "blue", "half" }) do
        package.loaded["auditor.db"] = nil
        local db2 = require("auditor.db")
        local p2 = vim.fn.tempname() .. ".db"
        db2.setup(p2)
        db2.save_words("/c.lua", { { line = 0, col_start = 0, col_end = 1 } }, color)
        local rows = db2.get_highlights("/c.lua")
        assert.equals(color, rows[1].color)
        os.remove(p2)
      end
    end)

    it("preserves word_index exactly", function()
      local words = {
        { line = 0, col_start = 0, col_end = 3 },
        { line = 0, col_start = 4, col_end = 7 },
        { line = 0, col_start = 8, col_end = 11 },
      }
      db.save_words("/f.lua", words, "half")
      local rows = sorted_by_col(db.get_highlights("/f.lua"))
      assert.equals(1, rows[1].word_index)
      assert.equals(2, rows[2].word_index)
      assert.equals(3, rows[3].word_index)
    end)
  end)

  -- D2: SQL injection resistance ─────────────────────────────────────────────

  describe("D2: SQL injection cannot corrupt the database", function()
    local injection_paths = {
      "'; DROP TABLE highlights; --",
      '" OR "1"="1',
      "' UNION SELECT * FROM highlights; --",
      "/path/' OR '1'='1'/file.lua",
      "'; INSERT INTO highlights VALUES(999,'x',0,0,1,'red',1); --",
      "/%_LIKE%.lua",
    }

    for _, fp in ipairs(injection_paths) do
      it(string.format("handles injection path: %.40s", fp), function()
        -- Must not error
        local ok = pcall(db.save_words, fp, { { line = 0, col_start = 0, col_end = 1 } }, "red")
        assert(ok, "save_words errored on injection filepath")

        -- Data is retrievable under the exact key
        local rows = db.get_highlights(fp)
        assert.equals(1, #rows)
        assert.equals("red", rows[1].color)

        -- Clearing also works
        local clear_ok = pcall(db.clear_highlights, fp)
        assert(clear_ok, "clear_highlights errored on injection filepath")
        assert.same({}, db.get_highlights(fp))
      end)
    end

    it("injection does not affect other rows", function()
      db.save_words("/safe.lua", { { line = 0, col_start = 0, col_end = 3 } }, "blue")
      pcall(
        db.save_words,
        db,
        "'; DROP TABLE highlights; --",
        { { line = 0, col_start = 0, col_end = 1 } },
        "red"
      )
      -- Safe file's data must be intact
      local rows = db.get_highlights("/safe.lua")
      assert.equals(1, #rows)
      assert.equals("blue", rows[1].color)
    end)
  end)

  -- D3: Special characters in filepaths ─────────────────────────────────────

  describe("D3: special characters in filepaths", function()
    local special_paths = {
      "/path/with spaces/file.lua",
      "/path/with\ttab/file.lua",
      "/path/with'single'quotes.lua",
      '/path/with"double"quotes.lua',
      "/path/with\\backslash.lua",
      "/path/with\nnewline/file.lua",
      "/path/café/file.lua", -- unicode
      "/path/with%percent.lua",
      "/path/with[brackets].lua",
      string.rep("a", 500) .. ".lua", -- very long path
    }

    for _, fp in ipairs(special_paths) do
      it(string.format("round-trips filepath: %.50s", fp), function()
        db.save_words(fp, { { line = 0, col_start = 0, col_end = 5 } }, "red")
        local rows = db.get_highlights(fp)
        assert.equals(1, #rows)
        assert.equals(fp, rows[1].filepath)
        db.clear_highlights(fp)
        assert.same({}, db.get_highlights(fp))
      end)
    end
  end)

  -- D4: Schema persistence across reopen ────────────────────────────────────

  describe("D4: data persists across DB close and reopen", function()
    it("data is present after re-initialising the module with the same path", function()
      db.save_words("/persist.lua", {
        { line = 5, col_start = 10, col_end = 15 },
        { line = 5, col_start = 20, col_end = 25 },
      }, "blue")

      -- Simulate a fresh Neovim session by reloading the module
      package.loaded["auditor.db"] = nil
      local db2 = require("auditor.db")
      db2.setup(tmp_path) -- same file

      local rows = db2.get_highlights("/persist.lua")
      assert.equals(2, #rows)
      local s = sorted_by_col(rows)
      assert.equals(10, s[1].col_start)
      assert.equals(20, s[2].col_start)
      assert.equals("blue", s[1].color)
    end)

    it("clear_highlights survives reopen", function()
      db.save_words("/x.lua", { { line = 0, col_start = 0, col_end = 3 } }, "red")
      db.clear_highlights("/x.lua")

      package.loaded["auditor.db"] = nil
      local db2 = require("auditor.db")
      db2.setup(tmp_path)
      assert.same({}, db2.get_highlights("/x.lua"))
    end)
  end)

  -- D5: Bulk operations ──────────────────────────────────────────────────────

  describe("D5: bulk operations (1000 rows)", function()
    it("inserts and retrieves 1000 rows correctly", function()
      local words = {}
      for i = 1, 1000 do
        words[i] = {
          line = math.floor((i - 1) / 10),
          col_start = (i - 1) % 10 * 5,
          col_end = (i - 1) % 10 * 5 + 4,
        }
      end
      db.save_words("/bulk.lua", words, "red")

      local rows = db.get_highlights("/bulk.lua")
      assert.equals(1000, #rows)
    end)

    it("clear removes all 1000 rows", function()
      local words = {}
      for i = 1, 1000 do
        words[i] = { line = 0, col_start = i - 1, col_end = i }
      end
      db.save_words("/bulk2.lua", words, "blue")
      db.clear_highlights("/bulk2.lua")
      assert.same({}, db.get_highlights("/bulk2.lua"))
    end)
  end)

  -- D6: Per-file isolation ───────────────────────────────────────────────────

  describe("D6: per-file isolation", function()
    it("saving to file A does not affect file B", function()
      db.save_words("/a.lua", { { line = 0, col_start = 0, col_end = 3 } }, "red")
      assert.same({}, db.get_highlights("/b.lua"))
    end)

    it("clearing file A does not affect file B", function()
      db.save_words("/a.lua", { { line = 0, col_start = 0, col_end = 3 } }, "red")
      db.save_words("/b.lua", { { line = 0, col_start = 0, col_end = 3 } }, "blue")
      db.clear_highlights("/a.lua")
      assert.equals(1, #db.get_highlights("/b.lua"))
    end)

    it("100 files stored independently", function()
      for i = 1, 100 do
        db.save_words(
          string.format("/file%d.lua", i),
          { { line = 0, col_start = 0, col_end = i } },
          "red"
        )
      end
      for i = 1, 100 do
        local rows = db.get_highlights(string.format("/file%d.lua", i))
        assert.equals(1, #rows)
        assert.equals(i, rows[1].col_end)
      end
    end)
  end)

  -- D7: Idempotent schema ───────────────────────────────────────────────────

  describe("D7: idempotent schema — setup() called twice on same path", function()
    it("does not corrupt existing data", function()
      db.save_words("/idem.lua", { { line = 0, col_start = 0, col_end = 5 } }, "red")

      -- Call setup() again — should be a no-op for schema
      package.loaded["auditor.db"] = nil
      local db2 = require("auditor.db")
      db2.setup(tmp_path)

      local rows = db2.get_highlights("/idem.lua")
      assert.equals(1, #rows)
      assert.equals("red", rows[1].color)
    end)
  end)

  -- D8: All color values ─────────────────────────────────────────────────────

  describe("D8: all color values", function()
    it("red, blue, half are all stored and distinguishable", function()
      db.save_words("/colors.lua", { { line = 0, col_start = 0, col_end = 1 } }, "red")
      db.save_words("/colors.lua", { { line = 1, col_start = 0, col_end = 1 } }, "blue")
      db.save_words("/colors.lua", { { line = 2, col_start = 0, col_end = 1 } }, "half")

      local rows = db.get_highlights("/colors.lua")
      assert.equals(3, #rows)
      local colors = {}
      for _, r in ipairs(rows) do
        colors[r.color] = (colors[r.color] or 0) + 1
      end
      assert.equals(1, colors["red"])
      assert.equals(1, colors["blue"])
      assert.equals(1, colors["half"])
    end)
  end)

  -- D9: Large integer values ─────────────────────────────────────────────────

  describe("D9: large integer values", function()
    it("stores and retrieves large line numbers", function()
      db.save_words("/big.lua", { { line = 99999, col_start = 0, col_end = 5 } }, "red")
      local rows = db.get_highlights("/big.lua")
      assert.equals(99999, rows[1].line)
    end)

    it("stores and retrieves large column values", function()
      db.save_words("/big.lua", { { line = 0, col_start = 100000, col_end = 100010 } }, "blue")
      local rows = db.get_highlights("/big.lua")
      assert.equals(100000, rows[1].col_start)
      assert.equals(100010, rows[1].col_end)
    end)

    it("line = 0 and col_start = 0 are not confused with missing values", function()
      db.save_words("/zero.lua", { { line = 0, col_start = 0, col_end = 1 } }, "red")
      local rows = db.get_highlights("/zero.lua")
      assert.equals(1, #rows)
      assert.equals(0, rows[1].line)
      assert.equals(0, rows[1].col_start)
    end)
  end)

  -- D11: Clear then re-save ─────────────────────────────────────────────────

  describe("D11: clear then re-save", function()
    it("new data after clear replaces old data", function()
      db.save_words("/cycle.lua", { { line = 0, col_start = 0, col_end = 5 } }, "red")
      db.clear_highlights("/cycle.lua")
      db.save_words("/cycle.lua", { { line = 0, col_start = 10, col_end = 15 } }, "blue")

      local rows = db.get_highlights("/cycle.lua")
      assert.equals(1, #rows)
      assert.equals(10, rows[1].col_start)
      assert.equals("blue", rows[1].color)
    end)

    it("multiple clear/save cycles are stable", function()
      for i = 1, 10 do
        db.clear_highlights("/cycle2.lua")
        db.save_words("/cycle2.lua", { { line = 0, col_start = i, col_end = i + 1 } }, "red")
      end
      local rows = db.get_highlights("/cycle2.lua")
      -- Only the last save remains (each cycle clears the previous)
      assert.equals(1, #rows)
      assert.equals(10, rows[1].col_start)
    end)
  end)

  -- D12: Unknown filepath returns {} ────────────────────────────────────────

  describe("D12: unknown filepath", function()
    it("get_highlights returns {} for an unseen filepath", function()
      local rows = db.get_highlights("/never/saved/file.lua")
      assert.same({}, rows)
    end)

    it("return value is a table, not nil", function()
      local rows = db.get_highlights("/nonexistent.lua")
      assert.is_table(rows)
    end)
  end)

  -- D13: Duplicate positions ────────────────────────────────────────────────

  describe("D13: duplicate position entries", function()
    it("saving the same position twice stores two rows", function()
      local word = { line = 0, col_start = 0, col_end = 5 }
      db.save_words("/dup.lua", { word }, "red")
      db.save_words("/dup.lua", { word }, "blue")
      local rows = db.get_highlights("/dup.lua")
      assert.equals(2, #rows)
    end)
  end)

  -- D14: All fields present in returned rows ────────────────────────────────

  describe("D14: all fields present in returned rows", function()
    it("every row has filepath, line, col_start, col_end, color, word_index", function()
      db.save_words("/fields.lua", { { line = 3, col_start = 7, col_end = 12 } }, "half")
      local rows = db.get_highlights("/fields.lua")
      assert.equals(1, #rows)
      local r = rows[1]
      assert.is_string(r.filepath)
      assert.is_number(r.line)
      assert.is_number(r.col_start)
      assert.is_number(r.col_end)
      assert.is_string(r.color)
      assert.is_number(r.word_index)
    end)
  end)

  -- D15: Property-based round-trip ──────────────────────────────────────────

  describe("D15: property-based round-trip (200 iterations)", function()
    it("random filepaths and word lists always survive a save→get cycle", function()
      local fp_chars = "abcdefghijklmnopqrstuvwxyz0123456789"
      local colors = { "red", "blue", "half" }

      for seed = 1, 200 do
        local rng = make_rng(seed)

        -- Generate a random filepath
        local fp_parts = { "/tmp/fuzz_" }
        for _ = 1, rng(4, 16) do
          local idx = rng(1, #fp_chars)
          fp_parts[#fp_parts + 1] = fp_chars:sub(idx, idx)
        end
        fp_parts[#fp_parts + 1] = ".lua"
        local fp = table.concat(fp_parts)

        -- Generate random words (non-overlapping positions)
        local n_words = rng(1, 8)
        local words = {}
        local col = 0
        for i = 1, n_words do
          local len = rng(1, 10)
          words[i] = { line = rng(0, 50), col_start = col, col_end = col + len }
          col = col + len + rng(1, 5)
        end

        local color = colors[rng(1, 3)]

        -- Save and immediately verify
        db.save_words(fp, words, color)
        local rows = db.get_highlights(fp)

        assert(
          #rows == n_words,
          string.format("seed=%d: expected %d rows, got %d for fp=%s", seed, n_words, #rows, fp)
        )
        for _, r in ipairs(rows) do
          assert(r.color == color, string.format("seed=%d: color mismatch", seed))
          assert(r.filepath == fp, string.format("seed=%d: filepath mismatch", seed))
        end

        -- Clean up so next iteration starts fresh
        db.clear_highlights(fp)
      end
    end)
  end)

  -- D16: word_index is 1-based and sequential ───────────────────────────────

  describe("D16: word_index sequencing", function()
    it("word_index values are 1-based and match insertion order", function()
      local words = {
        { line = 0, col_start = 0, col_end = 3 },
        { line = 0, col_start = 5, col_end = 8 },
        { line = 0, col_start = 10, col_end = 13 },
        { line = 1, col_start = 0, col_end = 4 },
        { line = 1, col_start = 6, col_end = 9 },
      }
      db.save_words("/wi.lua", words, "half")
      local rows = db.get_highlights("/wi.lua")
      assert.equals(5, #rows)

      -- Sort by the insertion order (word_index field)
      table.sort(rows, function(a, b)
        return a.word_index < b.word_index
      end)
      for i, r in ipairs(rows) do
        assert.equals(
          i,
          r.word_index,
          string.format("expected word_index %d, got %d", i, r.word_index)
        )
      end
    end)

    it("each save_words call restarts word_index from 1", function()
      db.save_words("/wi2.lua", {
        { line = 0, col_start = 0, col_end = 3 },
        { line = 0, col_start = 4, col_end = 7 },
      }, "red")
      db.save_words("/wi2.lua", {
        { line = 1, col_start = 0, col_end = 5 },
      }, "blue")

      local rows = db.get_highlights("/wi2.lua")
      assert.equals(3, #rows)
      local by_line = {}
      for _, r in ipairs(rows) do
        by_line[r.line] = by_line[r.line] or {}
        table.insert(by_line[r.line], r)
      end
      -- Line 0: two rows, word_index 1 and 2
      table.sort(by_line[0], function(a, b)
        return a.word_index < b.word_index
      end)
      assert.equals(1, by_line[0][1].word_index)
      assert.equals(2, by_line[0][2].word_index)
      -- Line 1: one row, word_index 1 (new call restarts)
      assert.equals(1, by_line[1][1].word_index)
    end)
  end)

  -- D17: empty words array is a no-op ──────────────────────────────────────

  describe("D17: empty words array", function()
    it("save_words with empty list does not insert any rows", function()
      db.save_words("/empty.lua", {}, "red")
      assert.same({}, db.get_highlights("/empty.lua"))
    end)

    it("save_words with empty list does not error", function()
      local ok = pcall(db.save_words, "/empty2.lua", {}, "blue")
      assert(ok, "save_words errored on empty words array")
    end)
  end)

  -- D18: accumulating saves across multiple calls ───────────────────────────

  describe("D18: accumulating saves", function()
    it("three sequential save_words calls accumulate all rows", function()
      db.save_words("/acc.lua", { { line = 0, col_start = 0, col_end = 3 } }, "red")
      db.save_words("/acc.lua", { { line = 1, col_start = 0, col_end = 3 } }, "blue")
      db.save_words("/acc.lua", { { line = 2, col_start = 0, col_end = 3 } }, "half")

      local rows = db.get_highlights("/acc.lua")
      assert.equals(3, #rows)

      local by_color = {}
      for _, r in ipairs(rows) do
        by_color[r.color] = (by_color[r.color] or 0) + 1
      end
      assert.equals(1, by_color["red"])
      assert.equals(1, by_color["blue"])
      assert.equals(1, by_color["half"])
    end)

    it("saving 10 batches of 10 words = 100 rows total", function()
      for batch = 1, 10 do
        local words = {}
        for i = 1, 10 do
          words[i] = { line = batch - 1, col_start = (i - 1) * 5, col_end = (i - 1) * 5 + 4 }
        end
        db.save_words("/acc2.lua", words, "red")
      end
      assert.equals(100, #db.get_highlights("/acc2.lua"))
    end)
  end)

  -- D19: unicode and non-ASCII filepaths ────────────────────────────────────

  describe("D19: unicode filepaths", function()
    local unicode_paths = {
      "/path/中文/file.lua",
      "/path/日本語/ファイル.lua",
      "/path/العربية/ملف.lua",
      "/path/émojis 🎉/file.lua",
      "/path/Ünïcödé/file.lua",
    }

    for _, fp in ipairs(unicode_paths) do
      it(string.format("stores and retrieves unicode path: %.30s", fp), function()
        db.save_words(fp, { { line = 0, col_start = 0, col_end = 4 } }, "blue")
        local rows = db.get_highlights(fp)
        assert.equals(1, #rows)
        assert.equals(fp, rows[1].filepath)
        db.clear_highlights(fp)
      end)
    end
  end)

  -- D20: get_highlights returns all rows including duplicates ────────────────

  describe("D20: no hidden deduplication", function()
    it("saving identical positions N times returns N rows", function()
      local word = { line = 0, col_start = 0, col_end = 5 }
      db.save_words("/dup3.lua", { word }, "red")
      db.save_words("/dup3.lua", { word }, "red")
      db.save_words("/dup3.lua", { word }, "red")
      local rows = db.get_highlights("/dup3.lua")
      assert.equals(3, #rows)
    end)

    it("each duplicate row has its own id", function()
      local word = { line = 0, col_start = 0, col_end = 5 }
      db.save_words("/dup4.lua", { word }, "blue")
      db.save_words("/dup4.lua", { word }, "blue")
      local rows = db.get_highlights("/dup4.lua")
      assert.equals(2, #rows)
      -- IDs must be distinct (auto-increment PK)
      assert.is_not.equal(rows[1].id, rows[2].id)
    end)
  end)

  -- D21: property — word_index always equals position in words array ────────

  describe("D21: property — word_index matches array position (300 iterations)", function()
    it("word_index is always the 1-based array index for every random words list", function()
      for seed = 1, 300 do
        local rng = make_rng(seed)
        local fp = string.format("/tmp/wi_prop_%d.lua", seed)
        local n = rng(1, 10)
        local words = {}
        local col = 0
        for i = 1, n do
          local len = rng(1, 8)
          words[i] = { line = 0, col_start = col, col_end = col + len }
          col = col + len + rng(1, 4)
        end
        db.save_words(fp, words, "red")
        local rows = db.get_highlights(fp)
        assert(#rows == n, string.format("seed=%d: expected %d rows, got %d", seed, n, #rows))
        table.sort(rows, function(a, b)
          return a.word_index < b.word_index
        end)
        for i, r in ipairs(rows) do
          assert(
            r.word_index == i,
            string.format(
              "seed=%d word %d: expected word_index %d, got %d",
              seed,
              i,
              i,
              r.word_index
            )
          )
        end
        db.clear_highlights(fp)
      end
    end)
  end)
end)
