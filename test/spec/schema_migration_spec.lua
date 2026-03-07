-- test/spec/schema_migration_spec.lua
-- Exhaustive tests for SQLite schema migration and ensure=false behavior.
--
-- Coverage:
--   SM1  Legacy DB (no word_text, no note) migrates on setup()
--   SM2  Partial DB (has word_text, no note) migrates on setup()
--   SM3  Current schema DB opens without error
--   SM4  Existing data in legacy DB is preserved after migration
--   SM5  New columns get default values after migration
--   SM6  Multiple setup() calls on a migrated DB are idempotent
--   SM7  rewrite_highlights works after migration from legacy schema
--   SM8  All CRUD operations work after migration
--   SM9  word_text and note round-trip correctly after migration
--   SM10 Legacy DB with many rows migrates and preserves all data
--   SM11 Schema upgrade from v1 (no word_index) to current
--   SM12 Concurrent setup() calls on same path don't corrupt
--   SM13 Migration is idempotent across module reloads
--   SM14 rewrite_highlights with notes works on migrated DB
--   SM15 remove_highlight works on migrated DB
--   SM16 Property: random legacy data always survives migration (100 iterations)
--   SM17 DB created by raw SQL (simulating unknown future schema) opens with ensure=false
--   SM18 ALTER TABLE on already-migrated DB is harmless (pcall swallows duplicate column error)

-- ── helpers ───────────────────────────────────────────────────────────────────

--- Create a raw SQLite DB with a specific schema (bypassing auditor.db).
--- Returns the temp DB file path.
---@param schema_sql string  CREATE TABLE statement
---@param insert_sqls? string[]  Optional INSERT statements to pre-populate
---@return string db_path
local function create_raw_db(schema_sql, insert_sqls)
  local sqlite_lib = require("sqlite.db")
  local path = vim.fn.tempname() .. ".db"
  local raw = sqlite_lib:open(path)
  raw:eval(schema_sql)
  if insert_sqls then
    for _, sql in ipairs(insert_sqls) do
      raw:eval(sql)
    end
  end
  raw:close()
  return path
end

--- Load a fresh auditor.db module instance.
---@return table db_module
local function fresh_db_module()
  package.loaded["auditor.db"] = nil
  return require("auditor.db")
end

--- Sort rows by line, then col_start.
local function sorted(rows)
  local copy = vim.deepcopy(rows)
  table.sort(copy, function(a, b)
    if a.line ~= b.line then return a.line < b.line end
    return a.col_start < b.col_start
  end)
  return copy
end

-- Deterministic PRNG for property tests
local function make_rng(seed)
  local s = math.abs(seed) + 1
  return function(lo, hi)
    s = (s * 1664525 + 1013904223) % (2 ^ 32)
    return lo + math.floor(s * (hi - lo + 1) / (2 ^ 32))
  end
end

-- ── V1 schema: original (no word_text, no note, no word_index) ────────────

local V1_SCHEMA = [[
  CREATE TABLE IF NOT EXISTS highlights (
    id INTEGER PRIMARY KEY,
    filepath TEXT NOT NULL,
    line INTEGER NOT NULL,
    col_start INTEGER NOT NULL,
    col_end INTEGER NOT NULL,
    color TEXT NOT NULL
  )
]]

-- ── V2 schema: added word_index (no word_text, no note) ───────────────────

local V2_SCHEMA = [[
  CREATE TABLE IF NOT EXISTS highlights (
    id INTEGER PRIMARY KEY,
    filepath TEXT NOT NULL,
    line INTEGER NOT NULL,
    col_start INTEGER NOT NULL,
    col_end INTEGER NOT NULL,
    color TEXT NOT NULL,
    word_index INTEGER DEFAULT 1
  )
]]

-- ── V3 schema: added word_text (no note) ──────────────────────────────────

local V3_SCHEMA = [[
  CREATE TABLE IF NOT EXISTS highlights (
    id INTEGER PRIMARY KEY,
    filepath TEXT NOT NULL,
    line INTEGER NOT NULL,
    col_start INTEGER NOT NULL,
    col_end INTEGER NOT NULL,
    color TEXT NOT NULL,
    word_index INTEGER DEFAULT 1,
    word_text TEXT DEFAULT ''
  )
]]

-- ── V4 (current) schema ───────────────────────────────────────────────────

local V4_SCHEMA = [[
  CREATE TABLE IF NOT EXISTS highlights (
    id INTEGER PRIMARY KEY,
    filepath TEXT NOT NULL,
    line INTEGER NOT NULL,
    col_start INTEGER NOT NULL,
    col_end INTEGER NOT NULL,
    color TEXT NOT NULL,
    word_index INTEGER DEFAULT 1,
    word_text TEXT DEFAULT '',
    note TEXT DEFAULT ''
  )
]]

-- ── test suite ────────────────────────────────────────────────────────────────

describe("auditor.db schema migration", function()
  local tmp_paths = {}

  after_each(function()
    for _, p in ipairs(tmp_paths) do
      pcall(os.remove, p)
    end
    tmp_paths = {}
  end)

  local function track(path)
    table.insert(tmp_paths, path)
    return path
  end

  -- SM1: Legacy DB (V1: no word_index, no word_text, no note) ──────────────

  describe("SM1: V1 legacy DB (no word_index, word_text, note) migrates", function()
    it("setup() succeeds on a V1 database", function()
      local path = track(create_raw_db(V1_SCHEMA))
      local db = fresh_db_module()
      assert.has_no.errors(function() db.setup(path) end)
    end)

    it("setup() succeeds on V1 DB with existing rows", function()
      local path = track(create_raw_db(V1_SCHEMA, {
        "INSERT INTO highlights (filepath, line, col_start, col_end, color) VALUES ('/f.lua', 0, 0, 5, 'red')",
      }))
      local db = fresh_db_module()
      assert.has_no.errors(function() db.setup(path) end)
    end)
  end)

  -- SM2: V2 DB (has word_index, no word_text, no note) ─────────────────────

  describe("SM2: V2 DB (word_index only) migrates", function()
    it("setup() succeeds on a V2 database", function()
      local path = track(create_raw_db(V2_SCHEMA))
      local db = fresh_db_module()
      assert.has_no.errors(function() db.setup(path) end)
    end)

    it("setup() succeeds on V2 DB with existing rows", function()
      local path = track(create_raw_db(V2_SCHEMA, {
        "INSERT INTO highlights (filepath, line, col_start, col_end, color, word_index) VALUES ('/f.lua', 0, 0, 5, 'blue', 1)",
        "INSERT INTO highlights (filepath, line, col_start, col_end, color, word_index) VALUES ('/f.lua', 1, 0, 3, 'red', 2)",
      }))
      local db = fresh_db_module()
      assert.has_no.errors(function() db.setup(path) end)
    end)
  end)

  -- SM3: V3 DB (has word_text, no note) ────────────────────────────────────

  describe("SM3: V3 DB (word_text, no note) migrates", function()
    it("setup() succeeds on a V3 database", function()
      local path = track(create_raw_db(V3_SCHEMA))
      local db = fresh_db_module()
      assert.has_no.errors(function() db.setup(path) end)
    end)

    it("setup() succeeds on V3 DB with existing rows including word_text", function()
      local path = track(create_raw_db(V3_SCHEMA, {
        "INSERT INTO highlights (filepath, line, col_start, col_end, color, word_index, word_text) VALUES ('/f.lua', 0, 0, 5, 'red', 1, 'hello')",
      }))
      local db = fresh_db_module()
      assert.has_no.errors(function() db.setup(path) end)
    end)
  end)

  -- SM4: Current schema DB opens without error ─────────────────────────────

  describe("SM4: current schema (V4) DB opens without error", function()
    it("setup() succeeds on a current-schema database", function()
      local path = track(create_raw_db(V4_SCHEMA))
      local db = fresh_db_module()
      assert.has_no.errors(function() db.setup(path) end)
    end)

    it("setup() succeeds on V4 DB with all columns populated", function()
      local path = track(create_raw_db(V4_SCHEMA, {
        "INSERT INTO highlights (filepath, line, col_start, col_end, color, word_index, word_text, note) VALUES ('/f.lua', 0, 0, 5, 'red', 1, 'hello', 'a note')",
      }))
      local db = fresh_db_module()
      assert.has_no.errors(function() db.setup(path) end)
    end)
  end)

  -- SM5: Existing data preserved after migration ───────────────────────────

  describe("SM5: existing data preserved after V1→current migration", function()
    it("V1 rows are readable after setup()", function()
      local path = track(create_raw_db(V1_SCHEMA, {
        "INSERT INTO highlights (filepath, line, col_start, col_end, color) VALUES ('/a.lua', 3, 10, 15, 'red')",
        "INSERT INTO highlights (filepath, line, col_start, col_end, color) VALUES ('/a.lua', 7, 0, 4, 'blue')",
      }))
      local db = fresh_db_module()
      db.setup(path)
      local rows = sorted(db.get_highlights("/a.lua"))
      assert.equals(2, #rows)
      assert.equals(3, rows[1].line)
      assert.equals(10, rows[1].col_start)
      assert.equals(15, rows[1].col_end)
      assert.equals("red", rows[1].color)
      assert.equals(7, rows[2].line)
      assert.equals(0, rows[2].col_start)
      assert.equals("blue", rows[2].color)
    end)

    it("V2 rows preserve word_index after migration", function()
      local path = track(create_raw_db(V2_SCHEMA, {
        "INSERT INTO highlights (filepath, line, col_start, col_end, color, word_index) VALUES ('/b.lua', 0, 0, 3, 'half', 42)",
      }))
      local db = fresh_db_module()
      db.setup(path)
      local rows = db.get_highlights("/b.lua")
      assert.equals(1, #rows)
      assert.equals(42, rows[1].word_index)
    end)

    it("V3 rows preserve word_text after migration", function()
      local path = track(create_raw_db(V3_SCHEMA, {
        "INSERT INTO highlights (filepath, line, col_start, col_end, color, word_index, word_text) VALUES ('/c.lua', 5, 2, 8, 'red', 1, 'myvar')",
      }))
      local db = fresh_db_module()
      db.setup(path)
      local rows = db.get_highlights("/c.lua")
      assert.equals(1, #rows)
      assert.equals("myvar", rows[1].word_text)
    end)
  end)

  -- SM6: New columns get defaults after migration ──────────────────────────

  describe("SM6: new columns get default values after migration", function()
    it("V1 rows get empty word_text and note after migration", function()
      local path = track(create_raw_db(V1_SCHEMA, {
        "INSERT INTO highlights (filepath, line, col_start, col_end, color) VALUES ('/d.lua', 0, 0, 5, 'red')",
      }))
      local db = fresh_db_module()
      db.setup(path)
      local rows = db.get_highlights("/d.lua")
      assert.equals(1, #rows)
      assert.equals("", rows[1].word_text)
      assert.equals("", rows[1].note)
    end)

    it("V2 rows get empty word_text and note after migration", function()
      local path = track(create_raw_db(V2_SCHEMA, {
        "INSERT INTO highlights (filepath, line, col_start, col_end, color, word_index) VALUES ('/e.lua', 0, 0, 5, 'blue', 1)",
      }))
      local db = fresh_db_module()
      db.setup(path)
      local rows = db.get_highlights("/e.lua")
      assert.equals(1, #rows)
      assert.equals("", rows[1].word_text)
      assert.equals("", rows[1].note)
    end)

    it("V3 rows get empty note after migration", function()
      local path = track(create_raw_db(V3_SCHEMA, {
        "INSERT INTO highlights (filepath, line, col_start, col_end, color, word_index, word_text) VALUES ('/f.lua', 0, 0, 5, 'half', 1, 'xyz')",
      }))
      local db = fresh_db_module()
      db.setup(path)
      local rows = db.get_highlights("/f.lua")
      assert.equals(1, #rows)
      assert.equals("xyz", rows[1].word_text)
      assert.equals("", rows[1].note)
    end)
  end)

  -- SM7: Multiple setup() calls on migrated DB are idempotent ──────────────

  describe("SM7: multiple setup() calls are idempotent", function()
    it("calling setup() 5 times on same V1 DB does not error or corrupt", function()
      local path = track(create_raw_db(V1_SCHEMA, {
        "INSERT INTO highlights (filepath, line, col_start, col_end, color) VALUES ('/g.lua', 0, 0, 5, 'red')",
      }))
      for _ = 1, 5 do
        local db = fresh_db_module()
        assert.has_no.errors(function() db.setup(path) end)
        local rows = db.get_highlights("/g.lua")
        assert.equals(1, #rows)
        assert.equals("red", rows[1].color)
      end
    end)

    it("calling setup() 5 times on same V4 DB does not error or corrupt", function()
      local path = track(create_raw_db(V4_SCHEMA, {
        "INSERT INTO highlights (filepath, line, col_start, col_end, color, word_index, word_text, note) VALUES ('/h.lua', 0, 0, 5, 'blue', 1, 'foo', 'bar')",
      }))
      for _ = 1, 5 do
        local db = fresh_db_module()
        assert.has_no.errors(function() db.setup(path) end)
        local rows = db.get_highlights("/h.lua")
        assert.equals(1, #rows)
        assert.equals("foo", rows[1].word_text)
        assert.equals("bar", rows[1].note)
      end
    end)
  end)

  -- SM8: rewrite_highlights works after migration ──────────────────────────

  describe("SM8: rewrite_highlights works after migration", function()
    it("rewrite on V1-migrated DB succeeds", function()
      local path = track(create_raw_db(V1_SCHEMA, {
        "INSERT INTO highlights (filepath, line, col_start, col_end, color) VALUES ('/i.lua', 0, 0, 5, 'red')",
      }))
      local db = fresh_db_module()
      db.setup(path)
      assert.has_no.errors(function()
        db.rewrite_highlights("/i.lua", {
          { line = 1, col_start = 0, col_end = 3, color = "blue", word_text = "new", note = "" },
        })
      end)
      local rows = db.get_highlights("/i.lua")
      assert.equals(1, #rows)
      assert.equals(1, rows[1].line)
      assert.equals("blue", rows[1].color)
      assert.equals("new", rows[1].word_text)
    end)

    it("rewrite on V2-migrated DB succeeds", function()
      local path = track(create_raw_db(V2_SCHEMA, {
        "INSERT INTO highlights (filepath, line, col_start, col_end, color, word_index) VALUES ('/j.lua', 0, 0, 5, 'red', 1)",
      }))
      local db = fresh_db_module()
      db.setup(path)
      assert.has_no.errors(function()
        db.rewrite_highlights("/j.lua", {
          { line = 2, col_start = 0, col_end = 4, color = "half", word_text = "test", note = "a note" },
        })
      end)
      local rows = db.get_highlights("/j.lua")
      assert.equals(1, #rows)
      assert.equals("half", rows[1].color)
      assert.equals("test", rows[1].word_text)
      assert.equals("a note", rows[1].note)
    end)

    it("rewrite on V3-migrated DB succeeds", function()
      local path = track(create_raw_db(V3_SCHEMA, {
        "INSERT INTO highlights (filepath, line, col_start, col_end, color, word_index, word_text) VALUES ('/k.lua', 0, 0, 5, 'blue', 1, 'old')",
      }))
      local db = fresh_db_module()
      db.setup(path)
      assert.has_no.errors(function()
        db.rewrite_highlights("/k.lua", {
          { line = 0, col_start = 0, col_end = 5, color = "red", word_text = "replaced", note = "note!" },
        })
      end)
      local rows = db.get_highlights("/k.lua")
      assert.equals(1, #rows)
      assert.equals("replaced", rows[1].word_text)
      assert.equals("note!", rows[1].note)
    end)
  end)

  -- SM9: All CRUD operations work after migration ──────────────────────────

  describe("SM9: all CRUD operations after V1 migration", function()
    local db, path

    before_each(function()
      path = track(create_raw_db(V1_SCHEMA, {
        "INSERT INTO highlights (filepath, line, col_start, col_end, color) VALUES ('/crud.lua', 0, 0, 5, 'red')",
        "INSERT INTO highlights (filepath, line, col_start, col_end, color) VALUES ('/crud.lua', 1, 0, 3, 'blue')",
      }))
      db = fresh_db_module()
      db.setup(path)
    end)

    it("get_highlights returns pre-existing rows", function()
      local rows = db.get_highlights("/crud.lua")
      assert.equals(2, #rows)
    end)

    it("save_words inserts new rows", function()
      db.save_words("/crud.lua", { { line = 2, col_start = 0, col_end = 4 } }, "half")
      local rows = db.get_highlights("/crud.lua")
      assert.equals(3, #rows)
    end)

    it("remove_highlight deletes a specific row", function()
      db.remove_highlight("/crud.lua", 0, 0, 5)
      local rows = db.get_highlights("/crud.lua")
      assert.equals(1, #rows)
      assert.equals(1, rows[1].line)
    end)

    it("clear_highlights removes all rows for a file", function()
      db.clear_highlights("/crud.lua")
      assert.same({}, db.get_highlights("/crud.lua"))
    end)

    it("rewrite_highlights replaces all rows atomically", function()
      db.rewrite_highlights("/crud.lua", {
        { line = 10, col_start = 0, col_end = 8, color = "half", word_text = "new", note = "note" },
      })
      local rows = db.get_highlights("/crud.lua")
      assert.equals(1, #rows)
      assert.equals(10, rows[1].line)
    end)
  end)

  -- SM10: word_text and note round-trip after migration ────────────────────

  describe("SM10: word_text and note round-trip after migration", function()
    it("save_words then rewrite with word_text and note preserves them", function()
      local path = track(create_raw_db(V1_SCHEMA))
      local db = fresh_db_module()
      db.setup(path)
      db.save_words("/rt.lua", { { line = 0, col_start = 0, col_end = 5 } }, "red")
      db.rewrite_highlights("/rt.lua", {
        { line = 0, col_start = 0, col_end = 5, color = "red", word_text = "hello", note = "world" },
      })
      local rows = db.get_highlights("/rt.lua")
      assert.equals(1, #rows)
      assert.equals("hello", rows[1].word_text)
      assert.equals("world", rows[1].note)
    end)

    it("special characters in word_text and note survive migration round-trip", function()
      local path = track(create_raw_db(V2_SCHEMA))
      local db = fresh_db_module()
      db.setup(path)
      local specials = {
        { word_text = "it's", note = "has 'quotes'" },
        { word_text = 'say "hi"', note = 'double "quotes"' },
        { word_text = "line1\nline2", note = "multi\nline\nnote" },
        { word_text = "café", note = "日本語" },
        { word_text = "$(rm -rf /)", note = "'; DROP TABLE highlights; --" },
      }
      for i, s in ipairs(specials) do
        db.rewrite_highlights(string.format("/sp%d.lua", i), {
          { line = 0, col_start = 0, col_end = 5, color = "red", word_text = s.word_text, note = s.note },
        })
        local rows = db.get_highlights(string.format("/sp%d.lua", i))
        assert.equals(1, #rows)
        assert.equals(s.word_text, rows[1].word_text, "word_text mismatch for: " .. s.word_text)
        assert.equals(s.note, rows[1].note, "note mismatch for: " .. s.note)
      end
    end)
  end)

  -- SM11: Legacy DB with many rows migrates correctly ──────────────────────

  describe("SM11: legacy DB with many rows migrates", function()
    it("100 V1 rows all accessible after migration", function()
      local inserts = {}
      for i = 1, 100 do
        table.insert(inserts, string.format(
          "INSERT INTO highlights (filepath, line, col_start, col_end, color) VALUES ('/big.lua', %d, %d, %d, '%s')",
          math.floor((i - 1) / 10), (i - 1) % 10 * 5, (i - 1) % 10 * 5 + 4,
          i % 2 == 0 and "red" or "blue"
        ))
      end
      local path = track(create_raw_db(V1_SCHEMA, inserts))
      local db = fresh_db_module()
      db.setup(path)
      local rows = db.get_highlights("/big.lua")
      assert.equals(100, #rows)
      for _, r in ipairs(rows) do
        assert.equals("", r.word_text)
        assert.equals("", r.note)
      end
    end)

    it("500 V2 rows all accessible after migration", function()
      local inserts = {}
      for i = 1, 500 do
        table.insert(inserts, string.format(
          "INSERT INTO highlights (filepath, line, col_start, col_end, color, word_index) VALUES ('/bulk.lua', %d, %d, %d, 'half', %d)",
          math.floor((i - 1) / 20), (i - 1) % 20 * 5, (i - 1) % 20 * 5 + 4, i
        ))
      end
      local path = track(create_raw_db(V2_SCHEMA, inserts))
      local db = fresh_db_module()
      db.setup(path)
      local rows = db.get_highlights("/bulk.lua")
      assert.equals(500, #rows)
    end)
  end)

  -- SM12: Migration from V1 (no word_index) to current ─────────────────────

  describe("SM12: V1→current word_index defaults", function()
    it("V1 rows get default word_index after migration", function()
      local path = track(create_raw_db(V1_SCHEMA, {
        "INSERT INTO highlights (filepath, line, col_start, col_end, color) VALUES ('/wi.lua', 0, 0, 5, 'red')",
      }))
      local db = fresh_db_module()
      db.setup(path)
      local rows = db.get_highlights("/wi.lua")
      assert.equals(1, #rows)
      assert.is_number(rows[1].word_index)
    end)
  end)

  -- SM13: Migration idempotent across module reloads ───────────────────────

  describe("SM13: migration idempotent across module reloads", function()
    it("reload→setup→reload→setup on V1 DB preserves data each time", function()
      local path = track(create_raw_db(V1_SCHEMA, {
        "INSERT INTO highlights (filepath, line, col_start, col_end, color) VALUES ('/reload.lua', 0, 0, 5, 'red')",
      }))
      for iter = 1, 5 do
        local db = fresh_db_module()
        db.setup(path)
        local rows = db.get_highlights("/reload.lua")
        assert.equals(1, #rows, string.format("iter %d: expected 1 row", iter))
        assert.equals("red", rows[1].color, string.format("iter %d: color mismatch", iter))
      end
    end)

    it("data written after migration survives subsequent reloads", function()
      local path = track(create_raw_db(V1_SCHEMA))
      local db = fresh_db_module()
      db.setup(path)
      db.rewrite_highlights("/rw.lua", {
        { line = 0, col_start = 0, col_end = 5, color = "blue", word_text = "abc", note = "def" },
      })

      for iter = 1, 3 do
        db = fresh_db_module()
        db.setup(path)
        local rows = db.get_highlights("/rw.lua")
        assert.equals(1, #rows, string.format("iter %d: expected 1 row", iter))
        assert.equals("abc", rows[1].word_text, string.format("iter %d: word_text", iter))
        assert.equals("def", rows[1].note, string.format("iter %d: note", iter))
      end
    end)
  end)

  -- SM14: rewrite_highlights with notes on migrated DB ─────────────────────

  describe("SM14: rewrite_highlights with notes on migrated DB", function()
    it("multiple marks with notes on V1-migrated DB", function()
      local path = track(create_raw_db(V1_SCHEMA))
      local db = fresh_db_module()
      db.setup(path)
      db.rewrite_highlights("/notes.lua", {
        { line = 0, col_start = 0, col_end = 5, color = "red", word_text = "hello", note = "note1" },
        { line = 1, col_start = 0, col_end = 5, color = "blue", word_text = "world", note = "note2" },
        { line = 2, col_start = 0, col_end = 3, color = "half", word_text = "foo", note = "" },
      })
      local rows = sorted(db.get_highlights("/notes.lua"))
      assert.equals(3, #rows)
      assert.equals("note1", rows[1].note)
      assert.equals("note2", rows[2].note)
      assert.equals("", rows[3].note)
    end)
  end)

  -- SM15: remove_highlight on migrated DB ──────────────────────────────────

  describe("SM15: remove_highlight on migrated DB", function()
    it("removes exact row from V1-migrated DB", function()
      local path = track(create_raw_db(V1_SCHEMA, {
        "INSERT INTO highlights (filepath, line, col_start, col_end, color) VALUES ('/rm.lua', 0, 0, 5, 'red')",
        "INSERT INTO highlights (filepath, line, col_start, col_end, color) VALUES ('/rm.lua', 1, 0, 3, 'blue')",
      }))
      local db = fresh_db_module()
      db.setup(path)
      db.remove_highlight("/rm.lua", 0, 0, 5)
      local rows = db.get_highlights("/rm.lua")
      assert.equals(1, #rows)
      assert.equals(1, rows[1].line)
    end)
  end)

  -- SM16: Property — random legacy data survives migration ─────────────────

  describe("SM16: property — random V1 data survives migration (100 iterations)", function()
    it("all randomly generated V1 rows are accessible after setup()", function()
      local colors = { "red", "blue", "half" }

      for seed = 1, 100 do
        local rng = make_rng(seed)
        local n = rng(1, 20)
        local inserts = {}
        local expected = {}
        for i = 1, n do
          local line = rng(0, 100)
          local col_s = rng(0, 200)
          local col_e = col_s + rng(1, 10)
          local color = colors[rng(1, 3)]
          table.insert(inserts, string.format(
            "INSERT INTO highlights (filepath, line, col_start, col_end, color) VALUES ('/prop.lua', %d, %d, %d, '%s')",
            line, col_s, col_e, color
          ))
          table.insert(expected, { line = line, col_start = col_s, col_end = col_e, color = color })
        end

        local path = track(create_raw_db(V1_SCHEMA, inserts))
        local db = fresh_db_module()
        assert.has_no.errors(function() db.setup(path) end)
        local rows = db.get_highlights("/prop.lua")
        assert.equals(n, #rows, string.format("seed=%d: expected %d rows, got %d", seed, n, #rows))

        -- Verify each expected row exists
        local row_set = {}
        for _, r in ipairs(rows) do
          local key = string.format("%d:%d:%d:%s", r.line, r.col_start, r.col_end, r.color)
          row_set[key] = (row_set[key] or 0) + 1
        end
        local exp_set = {}
        for _, e in ipairs(expected) do
          local key = string.format("%d:%d:%d:%s", e.line, e.col_start, e.col_end, e.color)
          exp_set[key] = (exp_set[key] or 0) + 1
        end
        for key, count in pairs(exp_set) do
          assert.equals(count, row_set[key] or 0,
            string.format("seed=%d: missing row %s", seed, key))
        end
      end
    end)
  end)

  -- SM17: DB with extra columns (future schema) opens with ensure=false ───

  describe("SM17: DB with extra/unknown columns opens fine", function()
    it("setup() succeeds on a DB with extra columns", function()
      local future_schema = [[
        CREATE TABLE IF NOT EXISTS highlights (
          id INTEGER PRIMARY KEY,
          filepath TEXT NOT NULL,
          line INTEGER NOT NULL,
          col_start INTEGER NOT NULL,
          col_end INTEGER NOT NULL,
          color TEXT NOT NULL,
          word_index INTEGER DEFAULT 1,
          word_text TEXT DEFAULT '',
          note TEXT DEFAULT '',
          future_col TEXT DEFAULT 'future'
        )
      ]]
      local path = track(create_raw_db(future_schema, {
        "INSERT INTO highlights (filepath, line, col_start, col_end, color, word_index, word_text, note, future_col) VALUES ('/future.lua', 0, 0, 5, 'red', 1, 'hi', 'note', 'extra')",
      }))
      local db = fresh_db_module()
      assert.has_no.errors(function() db.setup(path) end)
      local rows = db.get_highlights("/future.lua")
      assert.equals(1, #rows)
      assert.equals("red", rows[1].color)
      assert.equals("hi", rows[1].word_text)
      assert.equals("note", rows[1].note)
    end)

    it("rewrite works on a DB with extra columns", function()
      local future_schema = [[
        CREATE TABLE IF NOT EXISTS highlights (
          id INTEGER PRIMARY KEY,
          filepath TEXT NOT NULL,
          line INTEGER NOT NULL,
          col_start INTEGER NOT NULL,
          col_end INTEGER NOT NULL,
          color TEXT NOT NULL,
          word_index INTEGER DEFAULT 1,
          word_text TEXT DEFAULT '',
          note TEXT DEFAULT '',
          extra1 TEXT DEFAULT '',
          extra2 INTEGER DEFAULT 0
        )
      ]]
      local path = track(create_raw_db(future_schema))
      local db = fresh_db_module()
      db.setup(path)
      assert.has_no.errors(function()
        db.rewrite_highlights("/future2.lua", {
          { line = 0, col_start = 0, col_end = 5, color = "blue", word_text = "ok", note = "fine" },
        })
      end)
      local rows = db.get_highlights("/future2.lua")
      assert.equals(1, #rows)
      assert.equals("blue", rows[1].color)
    end)
  end)

  -- SM18: ALTER TABLE on already-migrated DB is harmless ───────────────────

  describe("SM18: ALTER TABLE idempotency", function()
    it("pcall swallows duplicate column error silently", function()
      local path = track(create_raw_db(V4_SCHEMA))
      local db = fresh_db_module()
      -- First setup: migration ALTERs are no-ops (columns exist)
      assert.has_no.errors(function() db.setup(path) end)
      -- Second setup: same ALTERs, still no error
      db = fresh_db_module()
      assert.has_no.errors(function() db.setup(path) end)
    end)

    it("data integrity after double-migration attempt", function()
      local path = track(create_raw_db(V4_SCHEMA, {
        "INSERT INTO highlights (filepath, line, col_start, col_end, color, word_index, word_text, note) VALUES ('/double.lua', 0, 0, 5, 'red', 1, 'hi', 'note')",
      }))
      -- Setup twice
      local db = fresh_db_module()
      db.setup(path)
      db = fresh_db_module()
      db.setup(path)
      -- Data still intact
      local rows = db.get_highlights("/double.lua")
      assert.equals(1, #rows)
      assert.equals("hi", rows[1].word_text)
      assert.equals("note", rows[1].note)
    end)
  end)

  -- SM19: Empty DB (table exists but no rows) ──────────────────────────────

  describe("SM19: empty legacy DBs", function()
    for label, schema in pairs({ V1 = V1_SCHEMA, V2 = V2_SCHEMA, V3 = V3_SCHEMA }) do
      it(label .. " empty DB migrates and accepts new data", function()
        local path = track(create_raw_db(schema))
        local db = fresh_db_module()
        db.setup(path)
        db.save_words("/new.lua", { { line = 0, col_start = 0, col_end = 5 } }, "red")
        local rows = db.get_highlights("/new.lua")
        assert.equals(1, #rows)
        assert.equals("red", rows[1].color)
      end)
    end
  end)

  -- SM20: Mixed files in legacy DB ─────────────────────────────────────────

  describe("SM20: multi-file legacy DB", function()
    it("multiple files in V1 DB all accessible after migration", function()
      local inserts = {}
      for i = 1, 10 do
        table.insert(inserts, string.format(
          "INSERT INTO highlights (filepath, line, col_start, col_end, color) VALUES ('/file%d.lua', 0, 0, %d, 'red')",
          i, i
        ))
      end
      local path = track(create_raw_db(V1_SCHEMA, inserts))
      local db = fresh_db_module()
      db.setup(path)
      for i = 1, 10 do
        local rows = db.get_highlights(string.format("/file%d.lua", i))
        assert.equals(1, #rows)
        assert.equals(i, rows[1].col_end)
      end
    end)
  end)

  -- SM21: Full lifecycle on migrated DB ────────────────────────────────────

  describe("SM21: full lifecycle on migrated DB", function()
    it("V1 DB: migrate → save → rewrite → remove → clear", function()
      local path = track(create_raw_db(V1_SCHEMA, {
        "INSERT INTO highlights (filepath, line, col_start, col_end, color) VALUES ('/life.lua', 0, 0, 5, 'red')",
      }))
      local db = fresh_db_module()
      db.setup(path)

      -- Verify migration
      local rows = db.get_highlights("/life.lua")
      assert.equals(1, #rows)

      -- Save new words
      db.save_words("/life.lua", { { line = 1, col_start = 0, col_end = 3 } }, "blue")
      rows = db.get_highlights("/life.lua")
      assert.equals(2, #rows)

      -- Rewrite
      db.rewrite_highlights("/life.lua", {
        { line = 5, col_start = 0, col_end = 4, color = "half", word_text = "final", note = "done" },
      })
      rows = db.get_highlights("/life.lua")
      assert.equals(1, #rows)
      assert.equals("final", rows[1].word_text)
      assert.equals("done", rows[1].note)

      -- Remove
      db.remove_highlight("/life.lua", 5, 0, 4)
      assert.same({}, db.get_highlights("/life.lua"))

      -- Save again after removal
      db.save_words("/life.lua", { { line = 10, col_start = 0, col_end = 2 } }, "red")
      rows = db.get_highlights("/life.lua")
      assert.equals(1, #rows)

      -- Clear
      db.clear_highlights("/life.lua")
      assert.same({}, db.get_highlights("/life.lua"))
    end)
  end)

  -- SM22: Brand new DB (no pre-existing file) ──────────────────────────────

  describe("SM22: brand new DB file", function()
    it("setup() on non-existent path creates working DB", function()
      local path = track(vim.fn.tempname() .. ".db")
      local db = fresh_db_module()
      assert.has_no.errors(function() db.setup(path) end)
      db.save_words("/brand.lua", { { line = 0, col_start = 0, col_end = 5 } }, "red")
      local rows = db.get_highlights("/brand.lua")
      assert.equals(1, #rows)
    end)
  end)
end)
