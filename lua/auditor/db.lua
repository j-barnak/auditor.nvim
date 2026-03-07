-- auditor/db.lua
-- SQLite persistence for token highlights, scoped per project root.
-- The database lives in stdpath("data")/auditor/<sha256-of-root>.db and
-- is NEVER written inside the project directory, so it produces no git diffs.

---@class AuditorHighlightRow
---@field id integer
---@field filepath string
---@field line integer
---@field col_start integer
---@field col_end integer
---@field color string
---@field word_index integer
---@field word_text string
---@field note string

local M = {}

-- Store db_obj in a global so it survives module reloads (tests use
-- package.loaded["auditor.db"] = nil). Without this, the old connection
-- becomes unreachable and leaks a file descriptor on every reload.
local db_obj = _G._auditor_db_obj

-- Walk up from cwd to find a project root marker.
---@return string
local function project_root()
  local markers = { ".git", ".hg", "Cargo.toml", "go.mod", "package.json", "pyproject.toml" }
  local path = vim.fn.getcwd()
  while path ~= "/" do
    for _, m in ipairs(markers) do
      if
        vim.fn.filereadable(path .. "/" .. m) == 1
        or vim.fn.isdirectory(path .. "/" .. m) == 1
      then
        return path
      end
    end
    path = vim.fn.fnamemodify(path, ":h")
  end
  return vim.fn.getcwd()
end

---@param db_path? string Override the SQLite file path (default: auto per-project)
function M.setup(db_path)
  local ok, sqlite = pcall(require, "sqlite")
  if not ok then
    error("[auditor.nvim] sqlite.lua not found. Add 'kkharji/sqlite.lua' as a dependency.", 2)
  end

  if not db_path then
    local data_dir = vim.fn.stdpath("data") .. "/auditor"
    vim.fn.mkdir(data_dir, "p")
    local root = project_root()
    local slug = vim.fn.sha256(root):sub(1, 12)
    db_path = data_dir .. "/" .. slug .. ".db"
  end

  M._db_path = db_path

  -- Close previous connection to avoid leaking file descriptors when
  -- setup() is called repeatedly (e.g. in test before_each).
  if db_obj then
    pcall(function()
      local inner = db_obj.db
      if not inner.closed then
        inner:close()
      end
    end)
  end

  -- Use lazy=true so sqlite.lua does NOT run check_for_auto_alter during
  -- construction.  That check errors on column-count changes (e.g. when a
  -- DB from an older schema version is opened).  We handle migration ourselves
  -- via ALTER TABLE before any tbl method is called.
  db_obj = sqlite({
    uri = db_path,
    opts = { lazy = true },
    highlights = {
      id = true, -- auto integer primary key
      filepath = { "text", required = true },
      line = { "integer", required = true },
      col_start = { "integer", required = true },
      col_end = { "integer", required = true },
      color = { "text", required = true },
      word_index = { "integer", default = 1 },
      word_text = { "text", default = "''" },
      note = { "text", default = "''" },
    },
  })
  _G._auditor_db_obj = db_obj

  local inner = db_obj.db
  if inner.closed then
    inner:open()
  end

  -- Check if the table already exists from a previous session.
  local table_exists = inner:exists("highlights")

  if table_exists then
    -- Migrate existing databases: add new columns if they don't exist.
    -- ALTER TABLE ADD COLUMN errors on duplicate; pcall swallows it.
    pcall(function()
      inner:eval("ALTER TABLE highlights ADD COLUMN word_index INTEGER DEFAULT 1")
    end)
    pcall(function()
      inner:eval("ALTER TABLE highlights ADD COLUMN word_text TEXT DEFAULT ''")
    end)
    pcall(function()
      inner:eval("ALTER TABLE highlights ADD COLUMN note TEXT DEFAULT ''")
    end)

    -- Inform sqlite.lua that the table already exists and provide the current
    -- DB schema.  This prevents check_for_auto_alter from running on the first
    -- tbl method call — we've already handled migration via ALTER TABLE above.
    local tbl = db_obj.highlights
    tbl.tbl_exists = true
    tbl.db_schema = inner:schema("highlights")
  else
    -- Table does not exist yet (fresh DB).  Trigger sqlite.lua's lazy init
    -- to create it from the schema above, so raw-SQL callers like
    -- rewrite_highlights() find the table immediately.
    db_obj.highlights:get({ where = { filepath = "" } })
  end
end

-- Return all saved highlights for a file.
---@param filepath string
---@return AuditorHighlightRow[]
function M.get_highlights(filepath)
  return db_obj.highlights:get({ where = { filepath = filepath } })
end

-- Persist a list of token positions with the given color.
---@param filepath string
---@param words AuditorToken[]
---@param color string
function M.save_words(filepath, words, color)
  for i, w in ipairs(words) do
    db_obj.highlights:insert({
      filepath = filepath,
      line = w.line,
      col_start = w.col_start,
      col_end = w.col_end,
      color = color,
      word_index = i,
    })
  end
end

-- Delete a single highlight row by exact position.
---@param filepath string
---@param line integer
---@param col_start integer
---@param col_end integer
function M.remove_highlight(filepath, line, col_start, col_end)
  db_obj.highlights:remove({
    filepath = filepath,
    line = line,
    col_start = col_start,
    col_end = col_end,
  })
end

-- Delete all highlight rows for a file.
---@param filepath string
function M.clear_highlights(filepath)
  db_obj.highlights:remove({ filepath = filepath })
end

-- Atomically replace all highlights for a file: clear old rows and insert new
-- ones inside a single transaction. Uses raw SQL via db:eval() to avoid
-- sqlite.lua's internal BEGIN/COMMIT wrapping in tbl methods.
-- If any insert fails, the transaction is rolled back and old data is preserved.
---@param filepath string
---@param marks {line: integer, col_start: integer, col_end: integer, color: string}[]
function M.rewrite_highlights(filepath, marks)
  local clib = require("sqlite.defs")
  local s = require("sqlite.stmt")
  local inner_db = db_obj.db

  -- Ensure connection is open (tbl methods auto-open via h.run, but we bypass that).
  if inner_db.closed then
    inner_db:open()
  end

  local conn = inner_db.conn

  local begin_code = clib.exec_stmt(conn, "BEGIN")
  if begin_code ~= 0 then
    error(
      string.format("[auditor] BEGIN failed: %s", clib.last_errmsg(conn)),
      2
    )
  end

  -- Prepare the INSERT statement once, reuse per row, finalize in all paths.
  -- Uses index-based bind to avoid sqlite.lua's table-bind bug where strings
  -- matching "^[%S]+%(.*%)$" (e.g. "$(rm -rf /)") are silently skipped.
  local insert_sql = "INSERT INTO highlights"
    .. "(filepath, line, col_start, col_end, color, word_index, word_text, note)"
    .. " VALUES(?, ?, ?, ?, ?, ?, ?, ?)"
  local stmt = s:parse(conn, insert_sql)

  local ok, err = pcall(function()
    inner_db:eval(
      "DELETE FROM highlights WHERE filepath = ?",
      filepath
    )
    -- Group by color so word_index restarts per color (matches save_words).
    local by_color = {}
    for _, m in ipairs(marks) do
      by_color[m.color] = by_color[m.color] or {}
      table.insert(by_color[m.color], m)
    end
    for color, words in pairs(by_color) do
      for i, w in ipairs(words) do
        -- _insert_hook allows tests to inject errors for rollback testing.
        if M._insert_hook then
          M._insert_hook(filepath, w, color, i)
        end
        stmt:bind(1, filepath)
        stmt:bind(2, w.line)
        stmt:bind(3, w.col_start)
        stmt:bind(4, w.col_end)
        stmt:bind(5, color)
        stmt:bind(6, i)
        stmt:bind(7, w.word_text or "")
        stmt:bind(8, w.note or "")
        stmt:step()
        stmt:reset()
        stmt:bind_clear()
      end
    end
  end)

  -- Always finalize the prepared statement to avoid leaking file descriptors.
  stmt:finalize()

  if ok then
    local commit_code = clib.exec_stmt(conn, "COMMIT")
    if commit_code ~= 0 then
      clib.exec_stmt(conn, "ROLLBACK")
      error(string.format("[auditor] COMMIT failed: %s", clib.last_errmsg(conn)), 2)
    end
  else
    clib.exec_stmt(conn, "ROLLBACK")
    error(err, 2)
  end
end

-- Close the database connection.
function M.close()
  if db_obj then
    pcall(function()
      local inner = db_obj.db
      if not inner.closed then
        inner:close()
      end
    end)
    db_obj = nil
    _G._auditor_db_obj = nil
  end
end

-- Expose the raw db object for testing purposes only.
function M._get_db_obj()
  return db_obj
end

return M
