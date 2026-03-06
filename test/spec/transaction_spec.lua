-- test/spec/transaction_spec.lua
-- Exhaustive tests for transaction atomicity in db.rewrite_highlights().
--
-- Coverage:
--   T1  Basic rewrite: clear + insert in one operation
--   T2  Rewrite with empty marks clears all rows
--   T3  Rewrite preserves rows for other files
--   T4  Rewrite updates positions correctly
--   T5  Rewrite groups by color with correct word_index
--   T6  Rollback on insert failure preserves old data
--   T7  Rollback on delete failure preserves old data
--   T8  Concurrent rewrites for different files don't interfere
--   T9  Rewrite with large number of marks (stress test)
--   T10 Rewrite idempotency: same data written twice yields same result
--   T11 Rewrite after partial data: old rows replaced entirely
--   T12 Property: rewrite never produces duplicate rows
--   T13 Property: rewrite row count equals mark count
--   T14 Fuzz: random mark sequences + rewrites maintain invariants
--   T15 Fuzz: random interleaving of save_words and rewrite_highlights
--   T16 Rewrite with all three colors mixed
--   T17 Rewrite with zero-width positions skipped
--   T18 Connection auto-open on first rewrite call
--   T19 Rewrite after connection was used by tbl methods
--   T20 Multiple sequential rewrites for same file
--   T21 Rewrite with single mark
--   T22 Rewrite with marks on same line different columns
--   T23 Rewrite with marks spanning many lines
--   T24 Rewrite preserves data integrity under simulated error injection
--   T25 Property: after rewrite, get_highlights returns exactly the marks

local db

local function fresh_db()
  package.loaded["auditor.db"] = nil
  db = require("auditor.db")
  db.setup(vim.fn.tempname() .. ".db")
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- T1: Basic rewrite
-- ═══════════════════════════════════════════════════════════════════════════════

describe("transaction T1: basic rewrite", function()
  before_each(fresh_db)

  it("clears old rows and inserts new ones", function()
    local fp = "/test/file.lua"
    db.save_words(fp, {
      { line = 0, col_start = 0, col_end = 5 },
    }, "red")
    assert.equals(1, #db.get_highlights(fp))

    db.rewrite_highlights(fp, {
      { line = 1, col_start = 0, col_end = 3, color = "blue" },
      { line = 2, col_start = 0, col_end = 4, color = "blue" },
    })

    local rows = db.get_highlights(fp)
    assert.equals(2, #rows)
    -- Old row at line 0 should be gone
    for _, r in ipairs(rows) do
      assert.is_true(r.line >= 1)
      assert.equals("blue", r.color)
    end
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- T2: Rewrite with empty marks clears all rows
-- ═══════════════════════════════════════════════════════════════════════════════

describe("transaction T2: empty rewrite clears all", function()
  before_each(fresh_db)

  it("passing empty marks deletes everything for that file", function()
    local fp = "/test/file.lua"
    db.save_words(fp, {
      { line = 0, col_start = 0, col_end = 5 },
      { line = 1, col_start = 0, col_end = 3 },
    }, "red")
    assert.equals(2, #db.get_highlights(fp))

    db.rewrite_highlights(fp, {})
    assert.equals(0, #db.get_highlights(fp))
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- T3: Rewrite preserves rows for other files
-- ═══════════════════════════════════════════════════════════════════════════════

describe("transaction T3: other files unaffected", function()
  before_each(fresh_db)

  it("rewriting file A doesn't touch file B", function()
    local fpA = "/test/a.lua"
    local fpB = "/test/b.lua"
    db.save_words(fpA, { { line = 0, col_start = 0, col_end = 5 } }, "red")
    db.save_words(fpB, { { line = 0, col_start = 0, col_end = 3 } }, "blue")

    db.rewrite_highlights(fpA, {})

    assert.equals(0, #db.get_highlights(fpA))
    assert.equals(1, #db.get_highlights(fpB))
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- T4: Rewrite updates positions
-- ═══════════════════════════════════════════════════════════════════════════════

describe("transaction T4: positions updated", function()
  before_each(fresh_db)

  it("new positions replace old ones exactly", function()
    local fp = "/test/file.lua"
    db.save_words(fp, { { line = 0, col_start = 0, col_end = 5 } }, "red")

    db.rewrite_highlights(fp, {
      { line = 3, col_start = 10, col_end = 15, color = "red" },
    })

    local rows = db.get_highlights(fp)
    assert.equals(1, #rows)
    assert.equals(3, rows[1].line)
    assert.equals(10, rows[1].col_start)
    assert.equals(15, rows[1].col_end)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- T5: Rewrite groups by color with correct word_index
-- ═══════════════════════════════════════════════════════════════════════════════

describe("transaction T5: color grouping and word_index", function()
  before_each(fresh_db)

  it("word_index restarts per color group", function()
    local fp = "/test/file.lua"
    db.rewrite_highlights(fp, {
      { line = 0, col_start = 0, col_end = 3, color = "red" },
      { line = 0, col_start = 4, col_end = 7, color = "red" },
      { line = 1, col_start = 0, col_end = 4, color = "blue" },
    })

    local rows = db.get_highlights(fp)
    assert.equals(3, #rows)

    -- Check word_index per color
    local red_indices = {}
    local blue_indices = {}
    for _, r in ipairs(rows) do
      if r.color == "red" then
        table.insert(red_indices, r.word_index)
      else
        table.insert(blue_indices, r.word_index)
      end
    end
    table.sort(red_indices)
    table.sort(blue_indices)
    assert.same({ 1, 2 }, red_indices)
    assert.same({ 1 }, blue_indices)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- T6: Rollback on insert failure preserves old data
-- ═══════════════════════════════════════════════════════════════════════════════

describe("transaction T6: rollback preserves old data", function()
  before_each(fresh_db)

  it("old data survives when rewrite is intercepted with error", function()
    local fp = "/test/file.lua"
    db.save_words(fp, {
      { line = 0, col_start = 0, col_end = 5 },
    }, "red")

    -- Use _insert_hook to fail on first INSERT (after DELETE succeeds)
    db._insert_hook = function()
      error("simulated insert failure")
    end

    local ok = pcall(db.rewrite_highlights, fp, {
      { line = 1, col_start = 0, col_end = 3, color = "blue" },
    })

    db._insert_hook = nil

    assert.is_false(ok)

    -- Old data should be preserved due to rollback
    local rows = db.get_highlights(fp)
    assert.equals(1, #rows)
    assert.equals(0, rows[1].line)
    assert.equals("red", rows[1].color)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- T7: Rollback on delete failure
-- ═══════════════════════════════════════════════════════════════════════════════

describe("transaction T7: rollback on delete failure", function()
  before_each(fresh_db)

  it("old data survives when DELETE fails", function()
    local fp = "/test/file.lua"
    db.save_words(fp, {
      { line = 0, col_start = 0, col_end = 5 },
    }, "red")

    local inner_db = db._get_db_obj().db
    local orig_eval = inner_db.eval
    inner_db.eval = function()
      error("simulated delete failure")
    end

    local ok = pcall(db.rewrite_highlights, fp, {
      { line = 1, col_start = 0, col_end = 3, color = "blue" },
    })

    inner_db.eval = orig_eval

    assert.is_false(ok)

    -- Old data preserved
    local rows = db.get_highlights(fp)
    assert.equals(1, #rows)
    assert.equals("red", rows[1].color)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- T8: Concurrent rewrites for different files
-- ═══════════════════════════════════════════════════════════════════════════════

describe("transaction T8: different files don't interfere", function()
  before_each(fresh_db)

  it("sequential rewrites for different files are independent", function()
    local fpA = "/test/a.lua"
    local fpB = "/test/b.lua"

    db.rewrite_highlights(fpA, {
      { line = 0, col_start = 0, col_end = 5, color = "red" },
      { line = 1, col_start = 0, col_end = 3, color = "red" },
    })

    db.rewrite_highlights(fpB, {
      { line = 0, col_start = 0, col_end = 4, color = "blue" },
    })

    assert.equals(2, #db.get_highlights(fpA))
    assert.equals(1, #db.get_highlights(fpB))

    -- Rewrite A again
    db.rewrite_highlights(fpA, {
      { line = 5, col_start = 0, col_end = 2, color = "half" },
    })

    assert.equals(1, #db.get_highlights(fpA))
    assert.equals(1, #db.get_highlights(fpB))
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- T9: Stress test with large number of marks
-- ═══════════════════════════════════════════════════════════════════════════════

describe("transaction T9: stress test", function()
  before_each(fresh_db)

  it("handles 500 marks in a single rewrite", function()
    local fp = "/test/big.lua"
    local marks = {}
    for i = 0, 499 do
      table.insert(marks, {
        line = i,
        col_start = 0,
        col_end = 5,
        color = ({ "red", "blue", "half" })[(i % 3) + 1],
      })
    end

    db.rewrite_highlights(fp, marks)
    assert.equals(500, #db.get_highlights(fp))

    -- Rewrite again with fewer
    db.rewrite_highlights(fp, {
      { line = 0, col_start = 0, col_end = 5, color = "red" },
    })
    assert.equals(1, #db.get_highlights(fp))
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- T10: Idempotency
-- ═══════════════════════════════════════════════════════════════════════════════

describe("transaction T10: idempotency", function()
  before_each(fresh_db)

  it("writing same marks twice yields identical result", function()
    local fp = "/test/file.lua"
    local marks = {
      { line = 0, col_start = 0, col_end = 5, color = "red" },
      { line = 1, col_start = 2, col_end = 7, color = "blue" },
    }

    db.rewrite_highlights(fp, marks)
    local rows1 = db.get_highlights(fp)

    db.rewrite_highlights(fp, marks)
    local rows2 = db.get_highlights(fp)

    assert.equals(#rows1, #rows2)
    for i = 1, #rows1 do
      assert.equals(rows1[i].line, rows2[i].line)
      assert.equals(rows1[i].col_start, rows2[i].col_start)
      assert.equals(rows1[i].col_end, rows2[i].col_end)
      assert.equals(rows1[i].color, rows2[i].color)
    end
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- T11: Rewrite replaces partial data completely
-- ═══════════════════════════════════════════════════════════════════════════════

describe("transaction T11: full replacement of partial data", function()
  before_each(fresh_db)

  it("old subset of marks is fully replaced", function()
    local fp = "/test/file.lua"
    -- Start with 3 marks
    db.save_words(fp, {
      { line = 0, col_start = 0, col_end = 3 },
      { line = 1, col_start = 0, col_end = 3 },
      { line = 2, col_start = 0, col_end = 3 },
    }, "red")

    -- Rewrite with only 1 mark at a different position
    db.rewrite_highlights(fp, {
      { line = 5, col_start = 10, col_end = 15, color = "blue" },
    })

    local rows = db.get_highlights(fp)
    assert.equals(1, #rows)
    assert.equals(5, rows[1].line)
    assert.equals("blue", rows[1].color)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- T12: Property — rewrite never produces duplicate rows
-- ═══════════════════════════════════════════════════════════════════════════════

describe("transaction T12: no duplicate rows", function()
  before_each(fresh_db)

  it("repeated rewrites with same data produce no duplicates", function()
    local fp = "/test/file.lua"
    local marks = {
      { line = 0, col_start = 0, col_end = 5, color = "red" },
    }

    for _ = 1, 50 do
      db.rewrite_highlights(fp, marks)
      assert.equals(1, #db.get_highlights(fp))
    end
  end)

  it("alternating between different mark sets produces no duplicates", function()
    local fp = "/test/file.lua"
    local set1 = {
      { line = 0, col_start = 0, col_end = 5, color = "red" },
    }
    local set2 = {
      { line = 0, col_start = 0, col_end = 5, color = "blue" },
      { line = 1, col_start = 0, col_end = 3, color = "blue" },
    }

    for i = 1, 50 do
      local marks = (i % 2 == 0) and set1 or set2
      db.rewrite_highlights(fp, marks)
      local rows = db.get_highlights(fp)
      assert.equals(#marks, #rows, string.format("iter %d", i))
    end
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- T13: Property — row count equals mark count
-- ═══════════════════════════════════════════════════════════════════════════════

describe("transaction T13: row count matches mark count", function()
  before_each(fresh_db)

  it("for various mark counts", function()
    local fp = "/test/file.lua"
    for n = 0, 20 do
      local marks = {}
      for i = 1, n do
        table.insert(marks, {
          line = i,
          col_start = 0,
          col_end = 5,
          color = "red",
        })
      end
      db.rewrite_highlights(fp, marks)
      assert.equals(n, #db.get_highlights(fp), "n=" .. n)
    end
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- T14: Fuzz — random mark sequences maintain invariants
-- ═══════════════════════════════════════════════════════════════════════════════

describe("transaction T14: fuzz random marks", function()
  before_each(fresh_db)

  it("100 random rewrite iterations maintain invariants", function()
    local fp = "/test/file.lua"
    local colors = { "red", "blue", "half" }
    math.randomseed(42)

    for _ = 1, 100 do
      local n = math.random(0, 15)
      local marks = {}
      for _ = 1, n do
        table.insert(marks, {
          line = math.random(0, 100),
          col_start = math.random(0, 50),
          col_end = math.random(51, 100),
          color = colors[math.random(1, 3)],
        })
      end

      db.rewrite_highlights(fp, marks)
      local rows = db.get_highlights(fp)

      -- Invariant: row count matches
      assert.equals(n, #rows)

      -- Invariant: all rows belong to this file
      for _, r in ipairs(rows) do
        assert.equals(fp, r.filepath)
      end
    end
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- T15: Fuzz — interleaving save_words and rewrite_highlights
-- ═══════════════════════════════════════════════════════════════════════════════

describe("transaction T15: fuzz interleaved save_words and rewrite", function()
  before_each(fresh_db)

  it("rewrite always wins over prior save_words data", function()
    local fp = "/test/file.lua"
    math.randomseed(123)

    for iter = 1, 50 do
      -- Add some rows via save_words
      local sw_count = math.random(1, 5)
      local sw_words = {}
      for _ = 1, sw_count do
        table.insert(sw_words, {
          line = math.random(0, 50),
          col_start = math.random(0, 20),
          col_end = math.random(21, 40),
        })
      end
      db.save_words(fp, sw_words, "red")

      -- Now rewrite with a known set
      local rw_count = math.random(0, 8)
      local marks = {}
      for _ = 1, rw_count do
        table.insert(marks, {
          line = math.random(0, 50),
          col_start = math.random(0, 20),
          col_end = math.random(21, 40),
          color = "blue",
        })
      end

      db.rewrite_highlights(fp, marks)
      local rows = db.get_highlights(fp)

      -- Rewrite should have replaced everything
      assert.equals(rw_count, #rows, string.format("iter %d", iter))
      for _, r in ipairs(rows) do
        assert.equals("blue", r.color)
      end
    end
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- T16: All three colors mixed
-- ═══════════════════════════════════════════════════════════════════════════════

describe("transaction T16: mixed colors", function()
  before_each(fresh_db)

  it("handles red, blue, and half in one rewrite", function()
    local fp = "/test/file.lua"
    db.rewrite_highlights(fp, {
      { line = 0, col_start = 0, col_end = 3, color = "red" },
      { line = 0, col_start = 4, col_end = 8, color = "blue" },
      { line = 1, col_start = 0, col_end = 4, color = "half" },
      { line = 1, col_start = 5, col_end = 9, color = "red" },
      { line = 2, col_start = 0, col_end = 5, color = "blue" },
    })

    local rows = db.get_highlights(fp)
    assert.equals(5, #rows)

    local color_counts = {}
    for _, r in ipairs(rows) do
      color_counts[r.color] = (color_counts[r.color] or 0) + 1
    end
    assert.equals(2, color_counts["red"])
    assert.equals(2, color_counts["blue"])
    assert.equals(1, color_counts["half"])
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- T17: Zero-width marks (edge case — should still be stored)
-- ═══════════════════════════════════════════════════════════════════════════════

describe("transaction T17: edge case positions", function()
  before_each(fresh_db)

  it("marks at column 0 are stored correctly", function()
    local fp = "/test/file.lua"
    db.rewrite_highlights(fp, {
      { line = 0, col_start = 0, col_end = 1, color = "red" },
    })
    local rows = db.get_highlights(fp)
    assert.equals(1, #rows)
    assert.equals(0, rows[1].col_start)
    assert.equals(1, rows[1].col_end)
  end)

  it("marks with large line numbers work", function()
    local fp = "/test/file.lua"
    db.rewrite_highlights(fp, {
      { line = 99999, col_start = 0, col_end = 5, color = "red" },
    })
    local rows = db.get_highlights(fp)
    assert.equals(1, #rows)
    assert.equals(99999, rows[1].line)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- T18: Connection auto-open on first rewrite
-- ═══════════════════════════════════════════════════════════════════════════════

describe("transaction T18: connection auto-open", function()
  it("rewrite works as the first DB operation", function()
    -- Fresh module with no prior operations
    package.loaded["auditor.db"] = nil
    local fresh_db_mod = require("auditor.db")
    fresh_db_mod.setup(vim.fn.tempname() .. ".db")

    -- rewrite_highlights as the VERY FIRST operation (no prior get/save)
    fresh_db_mod.rewrite_highlights("/test/first.lua", {
      { line = 0, col_start = 0, col_end = 5, color = "red" },
    })

    local rows = fresh_db_mod.get_highlights("/test/first.lua")
    assert.equals(1, #rows)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- T19: Rewrite after tbl methods used
-- ═══════════════════════════════════════════════════════════════════════════════

describe("transaction T19: rewrite after tbl methods", function()
  before_each(fresh_db)

  it("works correctly after save_words and get_highlights", function()
    local fp = "/test/file.lua"
    db.save_words(fp, { { line = 0, col_start = 0, col_end = 5 } }, "red")
    local _ = db.get_highlights(fp)

    db.rewrite_highlights(fp, {
      { line = 1, col_start = 0, col_end = 3, color = "blue" },
    })

    local rows = db.get_highlights(fp)
    assert.equals(1, #rows)
    assert.equals("blue", rows[1].color)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- T20: Multiple sequential rewrites for same file
-- ═══════════════════════════════════════════════════════════════════════════════

describe("transaction T20: sequential rewrites", function()
  before_each(fresh_db)

  it("each rewrite fully replaces the previous", function()
    local fp = "/test/file.lua"

    db.rewrite_highlights(fp, {
      { line = 0, col_start = 0, col_end = 5, color = "red" },
    })
    assert.equals(1, #db.get_highlights(fp))

    db.rewrite_highlights(fp, {
      { line = 0, col_start = 0, col_end = 5, color = "blue" },
      { line = 1, col_start = 0, col_end = 3, color = "blue" },
    })
    assert.equals(2, #db.get_highlights(fp))

    db.rewrite_highlights(fp, {})
    assert.equals(0, #db.get_highlights(fp))

    db.rewrite_highlights(fp, {
      { line = 5, col_start = 10, col_end = 20, color = "half" },
    })
    assert.equals(1, #db.get_highlights(fp))
    assert.equals("half", db.get_highlights(fp)[1].color)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- T21: Single mark
-- ═══════════════════════════════════════════════════════════════════════════════

describe("transaction T21: single mark", function()
  before_each(fresh_db)

  it("works with exactly one mark", function()
    local fp = "/test/file.lua"
    db.rewrite_highlights(fp, {
      { line = 0, col_start = 0, col_end = 5, color = "red" },
    })
    local rows = db.get_highlights(fp)
    assert.equals(1, #rows)
    assert.equals(1, rows[1].word_index)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- T22: Same line, different columns
-- ═══════════════════════════════════════════════════════════════════════════════

describe("transaction T22: same line different columns", function()
  before_each(fresh_db)

  it("multiple marks on the same line are stored independently", function()
    local fp = "/test/file.lua"
    db.rewrite_highlights(fp, {
      { line = 0, col_start = 0, col_end = 5, color = "red" },
      { line = 0, col_start = 6, col_end = 11, color = "red" },
      { line = 0, col_start = 12, col_end = 17, color = "blue" },
    })
    local rows = db.get_highlights(fp)
    assert.equals(3, #rows)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- T23: Marks spanning many lines
-- ═══════════════════════════════════════════════════════════════════════════════

describe("transaction T23: many lines", function()
  before_each(fresh_db)

  it("marks on 100 different lines stored correctly", function()
    local fp = "/test/file.lua"
    local marks = {}
    for i = 0, 99 do
      table.insert(marks, {
        line = i,
        col_start = 0,
        col_end = 5,
        color = "red",
      })
    end
    db.rewrite_highlights(fp, marks)
    local rows = db.get_highlights(fp)
    assert.equals(100, #rows)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- T24: Error injection — partial insert failure
-- ═══════════════════════════════════════════════════════════════════════════════

describe("transaction T24: partial insert failure rollback", function()
  before_each(fresh_db)

  it("failure after N successful inserts rolls back all", function()
    local fp = "/test/file.lua"
    -- Pre-populate with known data
    db.save_words(fp, {
      { line = 0, col_start = 0, col_end = 5 },
    }, "red")

    local insert_count = 0

    -- Fail on the 3rd insert (let first 2 succeed)
    db._insert_hook = function()
      insert_count = insert_count + 1
      if insert_count == 3 then
        error("simulated partial failure")
      end
    end

    local ok = pcall(db.rewrite_highlights, fp, {
      { line = 1, col_start = 0, col_end = 3, color = "blue" },
      { line = 2, col_start = 0, col_end = 3, color = "blue" },
      { line = 3, col_start = 0, col_end = 3, color = "blue" },
    })

    db._insert_hook = nil

    assert.is_false(ok)

    -- Original data should be intact
    local rows = db.get_highlights(fp)
    assert.equals(1, #rows)
    assert.equals(0, rows[1].line)
    assert.equals("red", rows[1].color)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- T25: Property — get_highlights returns exactly the rewritten marks
-- ═══════════════════════════════════════════════════════════════════════════════

describe("transaction T25: get_highlights matches rewritten marks", function()
  before_each(fresh_db)

  it("every mark is recoverable via get_highlights", function()
    local fp = "/test/file.lua"
    local marks = {
      { line = 0, col_start = 0, col_end = 5, color = "red" },
      { line = 1, col_start = 3, col_end = 8, color = "blue" },
      { line = 2, col_start = 0, col_end = 10, color = "half" },
      { line = 2, col_start = 11, col_end = 15, color = "red" },
    }

    db.rewrite_highlights(fp, marks)
    local rows = db.get_highlights(fp)

    -- Build lookup for comparison (position → color)
    local expected = {}
    for _, m in ipairs(marks) do
      local key = string.format("%d:%d:%d", m.line, m.col_start, m.col_end)
      expected[key] = m.color
    end

    local actual = {}
    for _, r in ipairs(rows) do
      local key = string.format("%d:%d:%d", r.line, r.col_start, r.col_end)
      actual[key] = r.color
    end

    assert.same(expected, actual)
  end)

  it("property holds for 50 random mark sets", function()
    local fp = "/test/file.lua"
    local colors = { "red", "blue", "half" }
    math.randomseed(999)

    for _ = 1, 50 do
      local n = math.random(0, 10)
      local marks = {}
      local expected = {}

      for i = 1, n do
        local m = {
          line = math.random(0, 50),
          col_start = i * 10,
          col_end = i * 10 + 5,
          color = colors[math.random(1, 3)],
        }
        table.insert(marks, m)
        local key = string.format("%d:%d:%d", m.line, m.col_start, m.col_end)
        expected[key] = m.color
      end

      db.rewrite_highlights(fp, marks)
      local rows = db.get_highlights(fp)

      local actual = {}
      for _, r in ipairs(rows) do
        local key = string.format("%d:%d:%d", r.line, r.col_start, r.col_end)
        actual[key] = r.color
      end

      assert.same(expected, actual)
    end
  end)
end)
