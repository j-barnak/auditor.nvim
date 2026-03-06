-- test/spec/db_spec.lua
-- Tests for auditor.db: SQLite persistence layer.
-- Each test gets a fresh temp database file.

local db
local tmp_path

local function fresh_db()
  package.loaded["auditor.db"] = nil
  db = require("auditor.db")
  tmp_path = vim.fn.tempname() .. ".db"
  db.setup(tmp_path)
end

describe("auditor.db", function()
  before_each(fresh_db)

  after_each(function()
    pcall(os.remove, tmp_path)
  end)

  it("returns an empty list for an unknown filepath", function()
    assert.same({}, db.get_highlights("/no/such/file.lua"))
  end)

  it("saves and retrieves highlights for a file", function()
    local words = {
      { line = 0, col_start = 0, col_end = 5 },
      { line = 0, col_start = 6, col_end = 11 },
    }
    db.save_words("/test/file.lua", words, "red")

    local rows = db.get_highlights("/test/file.lua")
    assert.equals(2, #rows)

    table.sort(rows, function(a, b)
      return a.col_start < b.col_start
    end)
    assert.equals(0, rows[1].line)
    assert.equals(0, rows[1].col_start)
    assert.equals(5, rows[1].col_end)
    assert.equals("red", rows[1].color)
    assert.equals(1, rows[1].word_index)
    assert.equals(6, rows[2].col_start)
    assert.equals(2, rows[2].word_index)
  end)

  it("stores sequential word_index values for half/half alternation", function()
    local words = {
      { line = 0, col_start = 0, col_end = 3 },
      { line = 0, col_start = 4, col_end = 7 },
      { line = 0, col_start = 8, col_end = 11 },
    }
    db.save_words("/file.lua", words, "half")

    local rows = db.get_highlights("/file.lua")
    table.sort(rows, function(a, b)
      return a.col_start < b.col_start
    end)
    assert.equals(1, rows[1].word_index)
    assert.equals(2, rows[2].word_index)
    assert.equals(3, rows[3].word_index)
  end)

  it("isolates highlights by filepath", function()
    db.save_words("/a.lua", { { line = 0, col_start = 0, col_end = 3 } }, "red")
    db.save_words("/b.lua", { { line = 0, col_start = 0, col_end = 3 } }, "blue")

    assert.equals(1, #db.get_highlights("/a.lua"))
    assert.equals(1, #db.get_highlights("/b.lua"))
    assert.equals("red", db.get_highlights("/a.lua")[1].color)
    assert.equals("blue", db.get_highlights("/b.lua")[1].color)
  end)

  it("clears highlights for one file without affecting others", function()
    db.save_words("/a.lua", { { line = 0, col_start = 0, col_end = 3 } }, "red")
    db.save_words("/b.lua", { { line = 0, col_start = 0, col_end = 3 } }, "blue")

    db.clear_highlights("/a.lua")

    assert.same({}, db.get_highlights("/a.lua"))
    assert.equals(1, #db.get_highlights("/b.lua"))
  end)

  it("accumulates rows across multiple save_words calls for the same file", function()
    db.save_words("/file.lua", { { line = 0, col_start = 0, col_end = 3 } }, "red")
    db.save_words("/file.lua", { { line = 1, col_start = 0, col_end = 3 } }, "blue")

    assert.equals(2, #db.get_highlights("/file.lua"))
  end)

  it("supports all three color values", function()
    db.save_words("/f.lua", { { line = 0, col_start = 0, col_end = 1 } }, "red")
    db.save_words("/f.lua", { { line = 1, col_start = 0, col_end = 1 } }, "blue")
    db.save_words("/f.lua", { { line = 2, col_start = 0, col_end = 1 } }, "half")

    local rows = db.get_highlights("/f.lua")
    assert.equals(3, #rows)
    local colors = {}
    for _, r in ipairs(rows) do
      colors[r.color] = true
    end
    assert.truthy(colors["red"])
    assert.truthy(colors["blue"])
    assert.truthy(colors["half"])
  end)
end)
