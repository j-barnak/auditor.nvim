-- auditor/init.lua

---@class AuditorKeymaps
---@field red? string|false        Mark cword red (default: "<leader>ar")
---@field blue? string|false       Mark cword blue (default: "<leader>ab")
---@field half? string|false       Mark cword half (default: "<leader>ah")
---@field mark? string|false       Color picker for cword (default: "<leader>am")
---@field save? string|false       Save pending highlights (default: "<leader>aS")
---@field clear? string|false      Clear buffer highlights (default: "<leader>aX")
---@field word_red? string|false   Mark all occurrences red (default: nil)
---@field word_blue? string|false  Mark all occurrences blue (default: nil)
---@field word_half? string|false  Mark all occurrences half (default: nil)
---@field word_mark? string|false  Color picker for word (default: nil)
---@field enter? string|false      Enter audit mode (default: nil)
---@field exit? string|false       Exit audit mode (default: nil)
---@field toggle? string|false     Toggle audit mode (default: nil)
---@field undo? string|false       Undo highlight under cursor (default: nil)
---@field note? string|false       Add note to highlight under cursor (default: nil)
---@field note_edit? string|false  Edit note on highlight under cursor (default: nil)
---@field note_delete? string|false Delete note from highlight under cursor (default: nil)
---@field notes? string|false      List all notes in quickfix (default: nil)
---@field note_show? string|false  Show note in floating window (default: nil)

---@class AuditorColorChoice
---@field label string  Display text in the picker menu
---@field color string  Internal color key

---@class AuditorSetupOpts
---@field db_path? string                       Override SQLite file path (default: auto per-project)
---@field keymaps? boolean|AuditorKeymaps       false to disable, true/nil for defaults, table to override
---@field colors? AuditorColorDef[]             Color definitions (solid or gradient); see highlights.DEFAULT_COLORS
---@field note_preview_len? integer             Max chars for EOL note preview (default: 30)
---@field note_sign_icon? string                Sign column icon for notes (default: "◆", "" to disable)
---@field note_save_keys? string[]              Keys that save the note editor (default: {"<C-s>", "<S-CR>"})
---@field note_cancel_keys? string[]            Keys that cancel the note editor (default: {"q", "<Esc>"})

local M = {}

local db = require("auditor.db")
local highlights = require("auditor.highlights")
local ts = require("auditor.ts")

---@type table<integer, {words: AuditorToken[], color: string}[]>
M._pending = {} -- bufnr -> list of {words, color} batches awaiting :AuditSave

---@type boolean
M._audit_mode = false

---@type boolean
M._setup_done = false

---@type table<integer, table<integer, {line: integer, col_start: integer, col_end: integer}>>
M._db_extmarks = {} -- bufnr -> extmark_id -> original DB position

---@type AuditorColorChoice[]
M._colors = {} -- populated in setup() from color defs

---@type table<integer, table<integer, string>> bufnr -> extmark_id -> note text
M._notes = {}

---@type table<integer, table<string, string>> bufnr -> "line:col_start:col_end" -> note text
M._saved_notes = {}

---@type boolean|nil When truthy, add_note/edit_note use vim.ui.input instead of float editor.
M._note_input_override = nil

---@type integer? Window ID of the current note floating window (viewer or editor).
M._note_float_win = nil

---@type integer? Buffer number of the current note floating window.
M._note_float_buf = nil

---@type string[] Keys that save the note editor (configurable via setup).
M._note_save_keys = { "<C-s>", "<S-CR>" }

---@type string[] Keys that cancel the note editor (configurable via setup).
M._note_cancel_keys = { "q", "<Esc>" }

-- Canonicalize a buffer filepath to prevent duplicate DB entries from symlinks
-- or relative paths.
---@param bufnr integer
---@return string filepath Canonical absolute path, or "" if buffer has no name.
local function canonical_filepath(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return ""
  end
  return vim.fn.resolve(vim.fn.fnamemodify(name, ":p"))
end

-- Guard: returns true when setup has been called and audit mode is active, notifies otherwise.
---@param action string
---@return boolean
local function require_audit_mode(action)
  if not M._setup_done then
    vim.notify(
      "[Auditor] Plugin not initialised. Call require('auditor').setup() first.",
      vim.log.levels.ERROR
    )
    return false
  end
  if not M._audit_mode then
    vim.notify(
      string.format("[Auditor] Cannot %s outside audit mode. Run :EnterAuditMode first.", action),
      vim.log.levels.WARN
    )
    return false
  end
  return true
end

-- Try to recover a highlight whose stored position no longer matches the buffer.
-- Searches ±RECOVERY_RADIUS lines for a whole-word match and returns the closest one.
local RECOVERY_RADIUS = 50

---@param bufnr integer
---@param row AuditorHighlightRow
---@return {line: integer, col_start: integer, col_end: integer}?
local function recover_highlight(bufnr, row)
  local word = row.word_text
  if not word or word == "" then
    return nil
  end
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local srow = math.max(0, row.line - RECOVERY_RADIUS)
  local erow = math.min(line_count - 1, row.line + RECOVERY_RADIUS)
  if srow > erow then
    return nil
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, srow, erow + 1, false)
  local pattern = "%f[%w_]" .. vim.pesc(word) .. "%f[^%w_]"
  local best = nil
  local best_dist = math.huge
  for rel, line_text in ipairs(lines) do
    local lnum = srow + rel - 1
    local pos = 1
    while pos <= #line_text do
      local s, e = line_text:find(pattern, pos)
      if not s then
        break
      end
      local col_start = s - 1
      local col_end = e
      local dist = math.abs(lnum - row.line) + math.abs(col_start - row.col_start)
      if dist < best_dist then
        best_dist = dist
        best = { line = lnum, col_start = col_start, col_end = col_end }
      end
      pos = e + 1
    end
  end
  return best
end

-- Exposed for testing.
M._recover_highlight = recover_highlight
M._RECOVERY_RADIUS = RECOVERY_RADIUS

-- Load saved highlights for a buffer from DB and re-apply them.
---@param bufnr integer
function M.load_for_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local filepath = canonical_filepath(bufnr)
  if filepath == "" then
    return
  end

  local ok, rows = pcall(db.get_highlights, filepath)
  if not ok then
    vim.notify(string.format("[Auditor] Failed to load highlights: %s", rows), vim.log.levels.ERROR)
    return
  end
  M._db_extmarks[bufnr] = M._db_extmarks[bufnr] or {}
  M._notes[bufnr] = M._notes[bufnr] or {}
  local recovered = 0
  for _, row in ipairs(rows) do
    local line, col_start, col_end = row.line, row.col_start, row.col_end

    -- Check if stored position still matches the buffer text.
    local needs_recovery = false
    if row.word_text and row.word_text ~= "" then
      local line_count = vim.api.nvim_buf_line_count(bufnr)
      if line >= line_count then
        needs_recovery = true
      else
        local lt = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1]
        if not lt or col_end > #lt or col_start >= #lt then
          needs_recovery = true
        elseif lt:sub(col_start + 1, col_end) ~= row.word_text then
          needs_recovery = true
        end
      end
    end

    if needs_recovery then
      local pos = recover_highlight(bufnr, row)
      if pos then
        line, col_start, col_end = pos.line, pos.col_start, pos.col_end
        recovered = recovered + 1
      else
        -- Word not found anywhere nearby — skip this highlight.
        goto continue
      end
    end

    local id = highlights.apply_word(bufnr, line, col_start, col_end, row.color, row.word_index)
    if id then
      M._db_extmarks[bufnr][id] = {
        line = row.line,
        col_start = row.col_start,
        col_end = row.col_end,
      }
      -- Restore note if present.
      if row.note and row.note ~= "" then
        M._notes[bufnr][id] = row.note
        highlights.apply_note(bufnr, line, col_start, col_end, row.note, row.color)
      end
    end
    ::continue::
  end
  if recovered > 0 then
    vim.notify(
      string.format("[Auditor] Recovered %d stale highlight(s) by searching nearby lines.", recovered),
      vim.log.levels.INFO
    )
  end
end

-- Return the word-boundary token under the cursor, or nil if not on a word.
-- Uses the same [%w_] definition as the regex fallback in ts.lua, so no LSP
-- or treesitter parser is required. Works on any file type and on program
-- slices where referenced symbols may not be defined.
---@param bufnr integer
---@return AuditorToken?
local function cword_token(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0) -- {row (1-indexed), col (0-indexed)}
  local row = cursor[1] - 1 -- convert to 0-indexed
  local col = cursor[2] -- 0-indexed byte offset

  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  if not line or not line:sub(col + 1, col + 1):match("[%w_]") then
    return nil
  end

  -- Walk backward to find word start (Lua string positions are 1-indexed).
  local s = col + 1
  while s > 1 and line:sub(s - 1, s - 1):match("[%w_]") do
    s = s - 1
  end

  -- Walk forward to find word end (exclusive).
  local e = col + 1
  while e <= #line and line:sub(e, e):match("[%w_]") do
    e = e + 1
  end

  -- Return in the same {line, col_start, col_end} format as ts.get_tokens.
  return { line = row, col_start = s - 1, col_end = e - 1 }
end

-- Exposed for unit testing.
M._cword_token = cword_token

-- Extract the audit color name and word text from a highlight extmark tuple.
---@param bufnr integer
---@param em table extmark tuple {id, row, col, details}
---@return string? color, string? word_text
local function extmark_color_and_word(bufnr, em)
  local _, row, col, details = em[1], em[2], em[3], em[4]
  local color = nil
  local word_text = nil
  if details then
    if details.hl_group then
      color = highlights._hl_group_to_color[details.hl_group]
    end
    local end_col = details.end_col
    if end_col and end_col > col then
      local lt = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
      if lt and end_col <= #lt then
        word_text = lt:sub(col + 1, end_col)
      end
    end
  end
  return color, word_text
end

-- Scan lines [srow, erow] (0-indexed, inclusive) for whole-word occurrences of word.
-- Uses Lua frontier patterns (%f) to enforce word boundaries so that e.g. "req"
-- does not match inside "request" or "req_id".
---@param bufnr integer
---@param word string
---@param srow integer 0-indexed start row (inclusive)
---@param erow integer 0-indexed end row (inclusive)
---@return AuditorToken[]
local function find_word_occurrences(bufnr, word, srow, erow)
  local lines = vim.api.nvim_buf_get_lines(bufnr, srow, erow + 1, false)
  local out = {}
  -- %f[%w_] = word-start frontier; %f[^%w_] = word-end frontier
  local pattern = "%f[%w_]" .. vim.pesc(word) .. "%f[^%w_]"
  for rel, line_text in ipairs(lines) do
    local lnum = srow + rel - 1
    local pos = 1
    while pos <= #line_text do
      local s, e = line_text:find(pattern, pos)
      if not s then
        break
      end
      table.insert(out, { line = lnum, col_start = s - 1, col_end = e })
      pos = e + 1
    end
  end
  return out
end

-- Exposed for unit testing.
M._find_word_occurrences = find_word_occurrences

-- Refresh pending word positions from live extmark positions.
-- Extmarks move when the buffer is edited; this syncs pending data to match.
---@param bufnr integer
local function sync_pending_from_extmarks(bufnr)
  if not M._pending[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  for _, entry in ipairs(M._pending[bufnr]) do
    if entry.extmark_ids then
      local synced_words = {}
      local synced_ids = {}
      for _, id in ipairs(entry.extmark_ids) do
        local ok, mark =
          pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, highlights.ns, id, { details = true })
        if ok and mark and mark[1] then
          local row, col, details = mark[1], mark[2], mark[3]
          local end_col = details and details.end_col
          if end_col and end_col > col then
            table.insert(synced_words, { line = row, col_start = col, col_end = end_col })
            table.insert(synced_ids, id)
          end
        end
      end
      entry.words = synced_words
      entry.extmark_ids = synced_ids
    end
  end
end

-- Exposed for unit testing.
M._sync_pending_from_extmarks = sync_pending_from_extmarks

-- Remove any existing auditor extmark at an exact position (dedup on re-mark).
---@param bufnr integer
---@param line integer
---@param col_start integer
---@param col_end integer
local function remove_extmarks_at(bufnr, line, col_start, col_end)
  local marks =
    vim.api.nvim_buf_get_extmarks(bufnr, highlights.ns, { line, col_start }, { line, col_end }, { details = true })
  local had_note = false
  for _, mark in ipairs(marks) do
    local id, row, col, details = mark[1], mark[2], mark[3], mark[4]
    if row == line and col == col_start and details.end_col == col_end then
      vim.api.nvim_buf_del_extmark(bufnr, highlights.ns, id)
      highlights.del_half_pair(bufnr, id)
      -- Clean up tracking tables.
      if M._db_extmarks[bufnr] then
        M._db_extmarks[bufnr][id] = nil
      end
      if M._notes[bufnr] and M._notes[bufnr][id] then
        M._notes[bufnr][id] = nil
        had_note = true
      end
      if M._pending[bufnr] then
        for _, entry in ipairs(M._pending[bufnr]) do
          if entry.extmark_ids then
            for j = #entry.extmark_ids, 1, -1 do
              if entry.extmark_ids[j] == id then
                table.remove(entry.extmark_ids, j)
                table.remove(entry.words, j)
              end
            end
          end
        end
      end
    end
  end
  -- Refresh note extmarks on this line to clean up orphaned underlines.
  if had_note then
    M._refresh_notes_for_line(bufnr, line)
  end
end

-- Highlight only the single word under the cursor. Pure regex word-boundary
-- detection — no treesitter involved.
---@param color string "red"|"blue"|"half"
function M.highlight_cword_buffer(color)
  if not require_audit_mode("highlight") then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local token = cword_token(bufnr)

  if not token then
    vim.notify("[Auditor] No word under cursor.", vim.log.levels.WARN)
    return
  end

  local line_text = vim.api.nvim_buf_get_lines(bufnr, token.line, token.line + 1, false)[1]
  if not line_text then
    return
  end
  local word = line_text:sub(token.col_start + 1, token.col_end)

  local occurrences = { token }

  -- Remove any existing highlight at this exact position (dedup on re-mark).
  for _, occ in ipairs(occurrences) do
    remove_extmarks_at(bufnr, occ.line, occ.col_start, occ.col_end)
  end

  local ids = highlights.apply_words(bufnr, occurrences, color)

  M._pending[bufnr] = M._pending[bufnr] or {}
  table.insert(M._pending[bufnr], { words = occurrences, color = color, extmark_ids = ids })

  vim.notify(
    string.format("[Auditor] Marked '%s' as '%s'. Run :AuditSave to save.", word, color),
    vim.log.levels.INFO
  )
end

-- Highlight all occurrences of the word under the cursor within the enclosing
-- function scope (uses treesitter for scope detection; falls back to the whole
-- buffer when treesitter is unavailable or no enclosing function is found).
---@param color string "red"|"blue"|"half"
function M.highlight_cword(color)
  if not require_audit_mode("highlight") then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local token = cword_token(bufnr)

  if not token then
    vim.notify("[Auditor] No word under cursor.", vim.log.levels.WARN)
    return
  end

  -- Extract word text from the token's position.
  local line_text = vim.api.nvim_buf_get_lines(bufnr, token.line, token.line + 1, false)[1]
  if not line_text then
    return
  end
  local word = line_text:sub(token.col_start + 1, token.col_end)

  -- Determine scope: innermost enclosing function, or fall back to whole buffer.
  local scope = ts.enclosing_function(bufnr, token.line, token.col_start)
  local srow = scope and scope.srow or 0
  local erow = scope and scope.erow or (vim.api.nvim_buf_line_count(bufnr) - 1)

  -- Find and highlight every occurrence of the word within the scope.
  local occurrences = find_word_occurrences(bufnr, word, srow, erow)
  if #occurrences == 0 then
    occurrences = { token } -- safety fallback; should not normally happen
  end

  -- Remove any existing highlights at these positions (dedup on re-mark).
  for _, occ in ipairs(occurrences) do
    remove_extmarks_at(bufnr, occ.line, occ.col_start, occ.col_end)
  end

  local ids = highlights.apply_words(bufnr, occurrences, color)

  M._pending[bufnr] = M._pending[bufnr] or {}
  table.insert(M._pending[bufnr], { words = occurrences, color = color, extmark_ids = ids })

  local scope_desc = scope and "function" or "buffer"
  vim.notify(
    string.format(
      "[Auditor] Marked %d occurrence(s) of '%s' as '%s' in %s. Run :AuditSave to save.",
      #occurrences,
      word,
      color,
      scope_desc
    ),
    vim.log.levels.INFO
  )
end

-- Persist all highlights to the database using a full rewrite strategy.
-- Collects live extmarks (both DB-backed and pending), clears all DB rows
-- for the file, and writes fresh. This prevents duplicates and stale rows.
function M.audit()
  if not require_audit_mode("save") then
    return
  end
  local total = 0

  -- Process all buffers that have pending or DB-backed highlights.
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      local has_pending = M._pending[bufnr] and #M._pending[bufnr] > 0
      local has_db = M._db_extmarks[bufnr] and next(M._db_extmarks[bufnr])
      if has_pending or has_db then
        local filepath = canonical_filepath(bufnr)
        if filepath ~= "" then
          -- Collect all live extmarks at their current positions.
          local marks = highlights.collect_extmarks(bufnr)

          -- Merge notes into marks before writing to DB.
          if M._notes[bufnr] then
            -- Build a reverse map: extmark position -> note.
            local ext_list =
              vim.api.nvim_buf_get_extmarks(bufnr, highlights.ns, 0, -1, { details = true })
            local id_to_pos = {}
            for _, em in ipairs(ext_list) do
              local id, row, col, details = em[1], em[2], em[3], em[4]
              local end_col = details and details.end_col
              if end_col then
                id_to_pos[id] = string.format("%d:%d:%d", row, col, end_col)
              end
            end
            local pos_to_note = {}
            for id, note in pairs(M._notes[bufnr]) do
              local key = id_to_pos[id]
              if key then
                pos_to_note[key] = note
              end
            end
            for _, m in ipairs(marks) do
              local key = string.format("%d:%d:%d", m.line, m.col_start, m.col_end)
              m.note = pos_to_note[key] or ""
            end
          end

          -- Atomic rewrite: clear old rows + insert new ones in a single transaction.
          -- If any insert fails, the transaction is rolled back and old data is preserved.
          local rewrite_ok, rewrite_err = pcall(db.rewrite_highlights, filepath, marks)
          if not rewrite_ok then
            vim.notify(
              string.format("[Auditor] DB save failed (rolled back): %s", rewrite_err),
              vim.log.levels.ERROR
            )
          else
            total = total + #marks
            M._pending[bufnr] = {}
            -- Rebuild _db_extmarks from live extmarks.
            M._db_extmarks[bufnr] = {}
            local live =
              vim.api.nvim_buf_get_extmarks(bufnr, highlights.ns, 0, -1, { details = true })
            for _, em in ipairs(live) do
              local id, row, col, details = em[1], em[2], em[3], em[4]
              local end_col = details and details.end_col
              if end_col and end_col > col then
                M._db_extmarks[bufnr][id] = {
                  line = row,
                  col_start = col,
                  col_end = end_col,
                }
              end
            end
          end
        end
      end
    end
  end

  if total > 0 then
    vim.notify(
      string.format("[Auditor] Saved %d token highlight(s) to database.", total),
      vim.log.levels.INFO
    )
  else
    vim.notify("[Auditor] Nothing new to save.", vim.log.levels.WARN)
  end
end

-- Clear all highlights for the current buffer.
function M.clear_buffer()
  if not require_audit_mode("clear") then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local filepath = canonical_filepath(bufnr)

  -- Attempt DB clear first so extmarks stay visible if DB fails.
  if filepath ~= "" then
    local ok, err = pcall(db.clear_highlights, filepath)
    if not ok then
      vim.notify(string.format("[Auditor] DB clear failed: %s", err), vim.log.levels.ERROR)
      return
    end
  end

  vim.api.nvim_buf_clear_namespace(bufnr, highlights.ns, 0, -1)
  highlights.clear_half_pairs(bufnr)
  highlights.clear_notes(bufnr)
  M._pending[bufnr] = {}
  M._db_extmarks[bufnr] = {}
  M._notes[bufnr] = {}
  M._saved_notes[bufnr] = {}
  vim.notify("[Auditor] Cleared all highlights for this buffer.", vim.log.levels.INFO)
end

-- Interactive color picker (whole-buffer cword, no treesitter).
function M.pick_color()
  if not require_audit_mode("pick color") then
    return
  end
  vim.ui.select(M._colors, {
    prompt = "Auditor – choose highlight color:",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if choice then
      M.highlight_cword_buffer(choice.color)
    end
  end)
end

-- Interactive color picker (function-scoped cword, uses treesitter).
function M.pick_cword_color()
  if not require_audit_mode("pick color") then
    return
  end
  vim.ui.select(M._colors, {
    prompt = "Auditor – choose highlight color:",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if choice then
      M.highlight_cword(choice.color)
    end
  end)
end

-- Enter audit mode: show highlights and enable marking commands.
function M.enter_audit_mode()
  if not M._setup_done then
    vim.notify(
      "[Auditor] Plugin not initialised. Call require('auditor').setup() first.",
      vim.log.levels.ERROR
    )
    return
  end
  local was_active = M._audit_mode
  M._audit_mode = true
  -- Restore highlights for all loaded named buffers.
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      -- Sync pending from live extmarks before clearing (only if already in audit mode).
      if was_active then
        sync_pending_from_extmarks(bufnr)
        -- Convert note extmark IDs to position keys before clearing extmarks.
        if M._notes[bufnr] then
          M._saved_notes[bufnr] = M._saved_notes[bufnr] or {}
          for id, note in pairs(M._notes[bufnr]) do
            local ok_m, mark =
              pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, highlights.ns, id, { details = true })
            if ok_m and mark and mark[1] then
              local row, col, details = mark[1], mark[2], mark[3]
              local end_col = details and details.end_col
              if end_col then
                local key = string.format("%d:%d:%d", row, col, end_col)
                M._saved_notes[bufnr][key] = note
              end
            end
          end
          M._notes[bufnr] = {}
        end
      end
      -- Clear first to avoid duplicates on repeated enter calls.
      vim.api.nvim_buf_clear_namespace(bufnr, highlights.ns, 0, -1)
      highlights.clear_half_pairs(bufnr)
      highlights.clear_notes(bufnr)
      M._db_extmarks[bufnr] = {}
      M.load_for_buffer(bufnr)
      -- Re-apply any pending (unsaved) highlights, updating extmark IDs
      -- and filtering out entries whose positions are now stale.
      if M._pending[bufnr] then
        for i = #M._pending[bufnr], 1, -1 do
          local entry = M._pending[bufnr][i]
          local ids, applied = highlights.apply_words(bufnr, entry.words, entry.color)
          entry.extmark_ids = ids
          entry.words = applied
          if #applied == 0 then
            table.remove(M._pending[bufnr], i)
          end
        end
      end
      -- Restore saved notes (from position keys back to extmark IDs).
      -- Notes already loaded from DB are in M._notes[bufnr]; saved_notes
      -- may contain additional unsaved notes from a prior mode transition.
      if M._saved_notes[bufnr] and next(M._saved_notes[bufnr]) then
        M._notes[bufnr] = M._notes[bufnr] or {}
        local ext =
          vim.api.nvim_buf_get_extmarks(bufnr, highlights.ns, 0, -1, { details = true })
        for _, em in ipairs(ext) do
          local id, row, col, details = em[1], em[2], em[3], em[4]
          local end_col = details and details.end_col
          if end_col and not M._notes[bufnr][id] then
            local key = string.format("%d:%d:%d", row, col, end_col)
            if M._saved_notes[bufnr][key] then
              M._notes[bufnr][id] = M._saved_notes[bufnr][key]
              local color = extmark_color_and_word(bufnr, em)
              highlights.apply_note(bufnr, row, col, end_col, M._saved_notes[bufnr][key], color)
            end
          end
        end
        M._saved_notes[bufnr] = {}
      end
    end
  end
  vim.notify("[Auditor] Entered audit mode.", vim.log.levels.INFO)
end

-- Whether audit mode is currently active. Intended for statusline integration.
---@return boolean
function M.is_active()
  return M._audit_mode
end

-- Exit audit mode: hide all highlights (DB is untouched).
function M.exit_audit_mode()
  if not M._setup_done then
    vim.notify(
      "[Auditor] Plugin not initialised. Call require('auditor').setup() first.",
      vim.log.levels.ERROR
    )
    return
  end
  local was_active = M._audit_mode
  M._audit_mode = false
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
      -- Only sync from extmarks when leaving audit mode (extmarks are live).
      -- If already exited, extmarks don't exist and syncing would erase pending.
      if was_active then
        sync_pending_from_extmarks(bufnr)
        -- Save notes by position key so they survive mode transitions.
        if M._notes[bufnr] and next(M._notes[bufnr]) then
          M._saved_notes[bufnr] = M._saved_notes[bufnr] or {}
          for id, note in pairs(M._notes[bufnr]) do
            local ok_m, mark =
              pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, highlights.ns, id, { details = true })
            if ok_m and mark and mark[1] then
              local row, col, details = mark[1], mark[2], mark[3]
              local end_col = details and details.end_col
              if end_col then
                local key = string.format("%d:%d:%d", row, col, end_col)
                M._saved_notes[bufnr][key] = note
              end
            end
          end
          M._notes[bufnr] = {}
        end
      end
      vim.api.nvim_buf_clear_namespace(bufnr, highlights.ns, 0, -1)
      highlights.clear_half_pairs(bufnr)
      highlights.clear_notes(bufnr)
      M._db_extmarks[bufnr] = {}
    end
  end
  vim.notify("[Auditor] Exited audit mode.", vim.log.levels.INFO)
end

-- Toggle audit mode on/off.
function M.toggle_audit_mode()
  if M._audit_mode then
    M.exit_audit_mode()
  else
    M.enter_audit_mode()
  end
end

-- Remove the highlight on the single word under the cursor.
-- Clears the extmark, removes from pending queue, and deletes DB row if saved.
function M.undo_at_cursor()
  if not require_audit_mode("undo") then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local token = cword_token(bufnr)

  if not token then
    vim.notify("[Auditor] No word under cursor.", vim.log.levels.WARN)
    return
  end

  -- Find extmark that exactly covers the token.
  local extmarks = vim.api.nvim_buf_get_extmarks(
    bufnr,
    highlights.ns,
    { token.line, token.col_start },
    { token.line, token.col_end },
    { details = true }
  )

  local removed = false
  local removed_id = nil
  for _, mark in ipairs(extmarks) do
    local id, row, col, details = mark[1], mark[2], mark[3], mark[4]
    if row == token.line and col == token.col_start and details.end_col == token.col_end then
      vim.api.nvim_buf_del_extmark(bufnr, highlights.ns, id)
      highlights.del_half_pair(bufnr, id)
      removed = true
      removed_id = id
      break
    end
  end

  if not removed then
    vim.notify("[Auditor] No highlight on this word.", vim.log.levels.WARN)
    return
  end

  -- Remove from pending queue.
  if M._pending[bufnr] then
    for _, entry in ipairs(M._pending[bufnr]) do
      if removed_id and entry.extmark_ids then
        -- Match by extmark ID (works after buffer edits).
        for j = #entry.extmark_ids, 1, -1 do
          if entry.extmark_ids[j] == removed_id then
            table.remove(entry.extmark_ids, j)
            table.remove(entry.words, j)
          end
        end
      else
        -- Fallback: position-based match.
        for j = #entry.words, 1, -1 do
          local w = entry.words[j]
          if
            w.line == token.line
            and w.col_start == token.col_start
            and w.col_end == token.col_end
          then
            table.remove(entry.words, j)
          end
        end
      end
    end
    -- Clean up empty entries.
    for i = #M._pending[bufnr], 1, -1 do
      if #M._pending[bufnr][i].words == 0 then
        table.remove(M._pending[bufnr], i)
      end
    end
  end

  -- Remove from DB using tracked original position (correct after buffer edits).
  local filepath = canonical_filepath(bufnr)
  if filepath ~= "" then
    local db_pos = M._db_extmarks[bufnr] and M._db_extmarks[bufnr][removed_id]
    if db_pos then
      local ok, err = pcall(db.remove_highlight, filepath, db_pos.line, db_pos.col_start, db_pos.col_end)
      if not ok then
        vim.notify(string.format("[Auditor] DB remove failed: %s", err), vim.log.levels.ERROR)
      end
      M._db_extmarks[bufnr][removed_id] = nil
    else
      -- Fallback: use current token position (works when no edit has occurred).
      local ok, err = pcall(db.remove_highlight, filepath, token.line, token.col_start, token.col_end)
      if not ok then
        vim.notify(string.format("[Auditor] DB remove failed: %s", err), vim.log.levels.ERROR)
      end
    end
  end

  -- Clean up any note associated with this extmark.
  if removed_id and M._notes[bufnr] and M._notes[bufnr][removed_id] then
    M._notes[bufnr][removed_id] = nil
  end

  local line_text = vim.api.nvim_buf_get_lines(bufnr, token.line, token.line + 1, false)[1]
  local word = line_text and line_text:sub(token.col_start + 1, token.col_end) or "<unknown>"
  -- Refresh note virtual text for this line (removes orphaned note extmarks).
  M._refresh_notes_for_line(bufnr, token.line)
  vim.notify(string.format("[Auditor] Removed highlight from '%s'.", word), vim.log.levels.INFO)
end

-- Refresh note virtual text for a single line.
-- Clears all note extmarks on this line and re-applies from M._notes.
---@param bufnr integer
---@param line integer
function M._refresh_notes_for_line(bufnr, line)
  -- Clear existing note extmarks on this line.
  local note_marks = vim.api.nvim_buf_get_extmarks(bufnr, highlights.note_ns, { line, 0 }, { line, -1 }, {})
  for _, m in ipairs(note_marks) do
    vim.api.nvim_buf_del_extmark(bufnr, highlights.note_ns, m[1])
  end
  -- Re-apply notes for extmarks on this line.
  if not M._notes[bufnr] then
    return
  end
  local ext = vim.api.nvim_buf_get_extmarks(bufnr, highlights.ns, { line, 0 }, { line, -1 }, { details = true })
  for _, em in ipairs(ext) do
    local id, _, col, details = em[1], em[2], em[3], em[4]
    if M._notes[bufnr][id] then
      local end_col = details and details.end_col
      if end_col then
        local color = extmark_color_and_word(bufnr, em)
        highlights.apply_note(bufnr, line, col, end_col, M._notes[bufnr][id], color)
      end
    end
  end
end

-- Add a note to the highlight under the cursor.
-- Prompts the user for text via vim.ui.input.
function M.add_note()
  if not require_audit_mode("add note") then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local token = cword_token(bufnr)
  if not token then
    vim.notify("[Auditor] No word under cursor.", vim.log.levels.WARN)
    return
  end

  -- Find the highlight extmark at this position.
  local extmarks = vim.api.nvim_buf_get_extmarks(
    bufnr,
    highlights.ns,
    { token.line, token.col_start },
    { token.line, token.col_end },
    { details = true }
  )
  local target_id = nil
  for _, mark in ipairs(extmarks) do
    local id, row, col, details = mark[1], mark[2], mark[3], mark[4]
    if row == token.line and col == token.col_start and details.end_col == token.col_end then
      target_id = id
      break
    end
  end
  if not target_id then
    vim.notify("[Auditor] No highlight on this word. Mark it first.", vim.log.levels.WARN)
    return
  end

  if M._note_input_override then
    vim.ui.input({ prompt = "Auditor note: " }, function(text)
      if not text or text == "" then
        return
      end
      M._notes[bufnr] = M._notes[bufnr] or {}
      M._notes[bufnr][target_id] = text
      M._refresh_notes_for_line(bufnr, token.line)
      vim.notify("[Auditor] Note added. Run :AuditSave to persist.", vim.log.levels.INFO)
    end)
  else
    M._open_note_editor(bufnr, target_id, token, "")
  end
end

-- Delete the note from the highlight under the cursor.
function M.delete_note()
  if not require_audit_mode("delete note") then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local token = cword_token(bufnr)
  if not token then
    vim.notify("[Auditor] No word under cursor.", vim.log.levels.WARN)
    return
  end

  local extmarks = vim.api.nvim_buf_get_extmarks(
    bufnr,
    highlights.ns,
    { token.line, token.col_start },
    { token.line, token.col_end },
    { details = true }
  )
  local target_id = nil
  for _, mark in ipairs(extmarks) do
    local id, row, col, details = mark[1], mark[2], mark[3], mark[4]
    if row == token.line and col == token.col_start and details.end_col == token.col_end then
      target_id = id
      break
    end
  end
  if not target_id then
    vim.notify("[Auditor] No highlight on this word.", vim.log.levels.WARN)
    return
  end

  if not M._notes[bufnr] or not M._notes[bufnr][target_id] then
    vim.notify("[Auditor] No note on this word.", vim.log.levels.WARN)
    return
  end

  M._notes[bufnr][target_id] = nil
  M._refresh_notes_for_line(bufnr, token.line)
  vim.notify("[Auditor] Note removed.", vim.log.levels.INFO)
end

-- Edit the note on the highlight under the cursor.
-- Pre-fills the prompt with the current note text.
function M.edit_note()
  if not require_audit_mode("edit note") then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local token = cword_token(bufnr)
  if not token then
    vim.notify("[Auditor] No word under cursor.", vim.log.levels.WARN)
    return
  end

  local extmarks = vim.api.nvim_buf_get_extmarks(
    bufnr,
    highlights.ns,
    { token.line, token.col_start },
    { token.line, token.col_end },
    { details = true }
  )
  local target_id = nil
  for _, mark in ipairs(extmarks) do
    local id, row, col, details = mark[1], mark[2], mark[3], mark[4]
    if row == token.line and col == token.col_start and details.end_col == token.col_end then
      target_id = id
      break
    end
  end
  if not target_id then
    vim.notify("[Auditor] No highlight on this word.", vim.log.levels.WARN)
    return
  end

  local current = (M._notes[bufnr] and M._notes[bufnr][target_id]) or ""
  if current == "" then
    vim.notify("[Auditor] No note on this word. Use :AuditNote to add one.", vim.log.levels.WARN)
    return
  end

  if M._note_input_override then
    vim.ui.input({ prompt = "Edit note: ", default = current }, function(text)
      if text == nil then
        return -- user cancelled
      end
      M._notes[bufnr] = M._notes[bufnr] or {}
      if text == "" then
        M._notes[bufnr][target_id] = nil
        M._refresh_notes_for_line(bufnr, token.line)
        vim.notify("[Auditor] Note removed.", vim.log.levels.INFO)
      else
        M._notes[bufnr][target_id] = text
        M._refresh_notes_for_line(bufnr, token.line)
        vim.notify("[Auditor] Note updated. Run :AuditSave to persist.", vim.log.levels.INFO)
      end
    end)
  else
    M._open_note_editor(bufnr, target_id, token, current)
  end
end

-- List all notes in the current buffer as a quickfix list.
function M.list_notes()
  if not require_audit_mode("list notes") then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  if not M._notes[bufnr] or not next(M._notes[bufnr]) then
    vim.notify("[Auditor] No notes in this buffer.", vim.log.levels.INFO)
    return
  end

  local filepath = canonical_filepath(bufnr)
  if filepath == "" then
    filepath = vim.api.nvim_buf_get_name(bufnr)
  end

  local items = {}
  for id, note_text in pairs(M._notes[bufnr]) do
    local ok, mark =
      pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, highlights.ns, id, { details = true })
    if ok and mark and mark[1] then
      local row, col, details = mark[1], mark[2], mark[3]
      local end_col = details and details.end_col
      local word = ""
      if end_col then
        local lt = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
        if lt then
          word = lt:sub(col + 1, end_col)
        end
      end
      table.insert(items, {
        filename = filepath,
        lnum = row + 1,
        col = col + 1,
        text = string.format("[%s] %s", word, note_text),
      })
    end
  end

  table.sort(items, function(a, b)
    if a.lnum ~= b.lnum then
      return a.lnum < b.lnum
    end
    return a.col < b.col
  end)

  vim.fn.setqflist(items, "r")
  vim.fn.setqflist({}, "a", { title = "Auditor Notes" })
  vim.cmd("copen")
end

-- Interactive note action picker: add, edit, delete, or list notes.
function M.pick_note_action()
  if not require_audit_mode("note menu") then
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local token = cword_token(bufnr)

  -- Build menu based on context.
  local actions = {}
  local has_highlight = false
  local has_note = false

  if token then
    local extmarks = vim.api.nvim_buf_get_extmarks(
      bufnr,
      highlights.ns,
      { token.line, token.col_start },
      { token.line, token.col_end },
      { details = true }
    )
    for _, mark in ipairs(extmarks) do
      local id, row, col, details = mark[1], mark[2], mark[3], mark[4]
      if row == token.line and col == token.col_start and details.end_col == token.col_end then
        has_highlight = true
        if M._notes[bufnr] and M._notes[bufnr][id] then
          has_note = true
        end
        break
      end
    end
  end

  if has_highlight and not has_note then
    table.insert(actions, { label = "Add note", fn = M.add_note })
  end
  if has_note then
    table.insert(actions, { label = "Show note", fn = M.show_note })
    table.insert(actions, { label = "Edit note", fn = M.edit_note })
    table.insert(actions, { label = "Delete note", fn = M.delete_note })
  end
  table.insert(actions, { label = "List all notes", fn = M.list_notes })

  vim.ui.select(actions, {
    prompt = "Auditor – note actions:",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if choice then
      choice.fn()
    end
  end)
end

-- Close any open note floating window (viewer or editor).
function M._close_note_float()
  if M._note_float_buf and vim.api.nvim_buf_is_valid(M._note_float_buf) then
    vim.bo[M._note_float_buf].modified = false
  end
  if M._note_float_win and vim.api.nvim_win_is_valid(M._note_float_win) then
    vim.api.nvim_win_close(M._note_float_win, true)
  end
  M._note_float_win = nil
  M._note_float_buf = nil
end

-- Show the full note in a read-only floating window.
function M.show_note()
  if not require_audit_mode("show note") then
    return
  end
  M._close_note_float()

  local bufnr = vim.api.nvim_get_current_buf()
  local token = cword_token(bufnr)
  if not token then
    vim.notify("[Auditor] No word under cursor.", vim.log.levels.WARN)
    return
  end

  local extmarks = vim.api.nvim_buf_get_extmarks(
    bufnr,
    highlights.ns,
    { token.line, token.col_start },
    { token.line, token.col_end },
    { details = true }
  )
  local target_id = nil
  for _, mark in ipairs(extmarks) do
    local id, row, col, details = mark[1], mark[2], mark[3], mark[4]
    if row == token.line and col == token.col_start and details.end_col == token.col_end then
      target_id = id
      break
    end
  end

  if not target_id or not M._notes[bufnr] or not M._notes[bufnr][target_id] then
    vim.notify("[Auditor] No note on this word.", vim.log.levels.WARN)
    return
  end

  local note_text = M._notes[bufnr][target_id]
  local lt = vim.api.nvim_buf_get_lines(bufnr, token.line, token.line + 1, false)[1]
  local word_text = lt and lt:sub(token.col_start + 1, token.col_end) or ""

  local float_buf = vim.api.nvim_create_buf(false, true)
  local lines = vim.split(note_text, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
  vim.bo[float_buf].modifiable = false
  vim.bo[float_buf].bufhidden = "wipe"

  local max_line_len = 0
  for _, l in ipairs(lines) do
    max_line_len = math.max(max_line_len, #l)
  end
  local width = math.max(20, math.min(80, max_line_len + 2))
  local height = math.min(math.max(1, #lines), 15)

  local win = vim.api.nvim_open_win(float_buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. word_text .. " ",
    title_pos = "center",
  })
  vim.api.nvim_set_option_value(
    "winhl",
    "Normal:AuditorNoteFloat,FloatBorder:AuditorNoteFloatBorder,FloatTitle:AuditorNoteFloatTitle",
    { win = win }
  )

  M._note_float_win = win
  M._note_float_buf = float_buf

  vim.keymap.set("n", "q", function()
    M._close_note_float()
  end, { buffer = float_buf, desc = "Close note viewer" })
  vim.keymap.set("n", "<Esc>", function()
    M._close_note_float()
  end, { buffer = float_buf, desc = "Close note viewer" })

  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = float_buf,
    once = true,
    callback = function()
      vim.schedule(function()
        M._close_note_float()
      end)
    end,
  })
end

-- Open a floating editor for composing/editing a note.
---@param bufnr integer source buffer
---@param target_id integer highlight extmark ID
---@param token AuditorToken cursor word token
---@param initial_text string pre-fill text ("" for new note)
function M._open_note_editor(bufnr, target_id, token, initial_text)
  M._close_note_float()

  local float_buf = vim.api.nvim_create_buf(false, true)
  local lines
  if initial_text and initial_text ~= "" then
    lines = vim.split(initial_text, "\n", { plain = true })
  else
    lines = { "" }
  end
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
  vim.bo[float_buf].bufhidden = "wipe"
  vim.bo[float_buf].buftype = "acwrite"
  vim.bo[float_buf].modifiable = true
  vim.api.nvim_buf_set_name(float_buf, "auditor://note")

  local max_line_len = 0
  for _, l in ipairs(lines) do
    max_line_len = math.max(max_line_len, #l)
  end
  local width = math.max(40, math.min(80, max_line_len + 4))
  local height = math.max(3, math.min(15, #lines + 1))

  local lt = vim.api.nvim_buf_get_lines(bufnr, token.line, token.line + 1, false)[1]
  local word_text = lt and lt:sub(token.col_start + 1, token.col_end) or ""

  local win = vim.api.nvim_open_win(float_buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    border = "rounded",
    title = " Note: " .. word_text .. " ",
    title_pos = "center",
  })
  vim.api.nvim_set_option_value(
    "winhl",
    "Normal:AuditorNoteFloat,FloatBorder:AuditorNoteFloatBorder,FloatTitle:AuditorNoteFloatTitle",
    { win = win }
  )

  M._note_float_win = win
  M._note_float_buf = float_buf

  local saving = false
  local function save_note()
    if saving then
      return
    end
    if not vim.api.nvim_buf_is_valid(float_buf) then
      return
    end
    saving = true
    local note_lines = vim.api.nvim_buf_get_lines(float_buf, 0, -1, false)
    local text = table.concat(note_lines, "\n")
    text = text:gsub("%s+$", "")

    vim.bo[float_buf].modified = false
    -- Escape insert mode via feedkeys so mode change completes before close
    local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    vim.api.nvim_feedkeys(esc, "nx", false)
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    M._note_float_win = nil
    M._note_float_buf = nil

    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    M._notes[bufnr] = M._notes[bufnr] or {}
    if text == "" then
      M._notes[bufnr][target_id] = nil
      M._refresh_notes_for_line(bufnr, token.line)
      vim.notify("[Auditor] Note removed.", vim.log.levels.INFO)
    else
      M._notes[bufnr][target_id] = text
      M._refresh_notes_for_line(bufnr, token.line)
      vim.notify("[Auditor] Note saved. Run :AuditSave to persist.", vim.log.levels.INFO)
    end
  end

  local function cancel()
    if vim.api.nvim_buf_is_valid(float_buf) then
      vim.bo[float_buf].modified = false
    end
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    M._note_float_win = nil
    M._note_float_buf = nil
  end

  for _, key in ipairs(M._note_save_keys) do
    vim.keymap.set({ "n", "i" }, key, save_note, { buffer = float_buf, noremap = true, desc = "Save note" })
  end
  for _, key in ipairs(M._note_cancel_keys) do
    vim.keymap.set("n", key, cancel, { buffer = float_buf, noremap = true, desc = "Cancel note editor" })
  end

  -- Make :w and :wq trigger save (buffer is scratch so BufWriteCmd intercepts).
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = float_buf,
    once = true,
    callback = function()
      save_note()
    end,
  })

  if not initial_text or initial_text == "" then
    vim.cmd("startinsert")
  end
end

---@param opts? AuditorSetupOpts
function M.setup(opts)
  if M._setup_done then
    vim.notify("[Auditor] setup() already called. Ignoring duplicate call.", vim.log.levels.WARN)
    return
  end
  opts = opts or {}

  local color_defs = opts.colors or highlights.DEFAULT_COLORS

  db.setup(opts.db_path)
  highlights.setup(color_defs)

  -- Apply note display settings to highlights module.
  highlights._note_preview_len = opts.note_preview_len or 30
  if opts.note_sign_icon ~= nil then
    highlights._note_sign_icon = opts.note_sign_icon
  end

  -- Apply note editor key bindings.
  if opts.note_save_keys then
    M._note_save_keys = opts.note_save_keys
  end
  if opts.note_cancel_keys then
    M._note_cancel_keys = opts.note_cancel_keys
  end

  -- Build picker entries from color definitions.
  M._colors = {}
  for _, def in ipairs(color_defs) do
    table.insert(M._colors, { label = def.label, color = def.name })
  end

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
    group = vim.api.nvim_create_augroup("AuditorLoad", { clear = true }),
    desc = "Restore auditor highlights for newly opened buffers",
    callback = function(ev)
      vim.schedule(function()
        if M._audit_mode and vim.api.nvim_buf_is_valid(ev.buf) then
          M.load_for_buffer(ev.buf)
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = vim.api.nvim_create_augroup("AuditorCleanup", { clear = true }),
    desc = "Clean up pending highlights for deleted buffers",
    callback = function(ev)
      M._pending[ev.buf] = nil
      M._db_extmarks[ev.buf] = nil
      M._notes[ev.buf] = nil
      M._saved_notes[ev.buf] = nil
      highlights.clear_half_pairs(ev.buf)
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("AuditorLeaveWarning", { clear = true }),
    desc = "Warn about unsaved audit highlights on quit",
    callback = function()
      local count = 0
      for bufnr, entries in pairs(M._pending) do
        if vim.api.nvim_buf_is_valid(bufnr) then
          for _, entry in ipairs(entries) do
            count = count + #entry.words
          end
        end
      end
      if count > 0 then
        vim.notify(
          string.format("[Auditor] %d unsaved highlight(s) will be lost. Run :AuditSave to persist.", count),
          vim.log.levels.WARN
        )
      end
    end,
  })

  vim.api.nvim_create_user_command("EnterAuditMode", function()
    M.enter_audit_mode()
  end, { desc = "Enter audit mode — show highlights and enable marking commands" })

  vim.api.nvim_create_user_command("ExitAuditMode", function()
    M.exit_audit_mode()
  end, { desc = "Exit audit mode — hide all highlights" })

  vim.api.nvim_create_user_command("AuditToggle", function()
    M.toggle_audit_mode()
  end, { desc = "Toggle audit mode on/off" })

  vim.api.nvim_create_user_command("AuditUndo", function()
    M.undo_at_cursor()
  end, { desc = "Remove highlight from word under cursor" })

  vim.api.nvim_create_user_command("AuditNote", function()
    M.add_note()
  end, { desc = "Add a note to the highlighted word under cursor" })

  vim.api.nvim_create_user_command("AuditNoteDelete", function()
    M.delete_note()
  end, { desc = "Delete the note from the highlighted word under cursor" })

  vim.api.nvim_create_user_command("AuditNoteEdit", function()
    M.edit_note()
  end, { desc = "Edit the note on the highlighted word under cursor" })

  vim.api.nvim_create_user_command("AuditNoteMenu", function()
    M.pick_note_action()
  end, { desc = "Note action picker (add/edit/delete/list)" })

  vim.api.nvim_create_user_command("AuditNoteShow", function()
    M.show_note()
  end, { desc = "Show note in floating window" })

  vim.api.nvim_create_user_command("AuditNotes", function()
    M.list_notes()
  end, { desc = "List all notes in current buffer (quickfix)" })

  vim.api.nvim_create_user_command("AuditSave", function()
    M.audit()
  end, { desc = "Save pending auditor token highlights to database" })

  vim.api.nvim_create_user_command("AuditClear", function()
    M.clear_buffer()
  end, { desc = "Clear all auditor highlights for current buffer" })

  -- AuditRed/Blue/Half: highlight word under cursor across entire buffer (no treesitter)
  for _, spec in ipairs({
    { "AuditRed", "red", "Mark word under cursor red (whole buffer)" },
    { "AuditBlue", "blue", "Mark word under cursor blue (whole buffer)" },
    { "AuditHalf", "half", "Mark word under cursor half red / blue (whole buffer)" },
  }) do
    local cmd, color, desc = spec[1], spec[2], spec[3]
    vim.api.nvim_create_user_command(cmd, function()
      M.highlight_cword_buffer(color)
    end, { desc = desc })
  end

  vim.api.nvim_create_user_command("AuditMark", function()
    M.pick_color()
  end, { desc = "Pick audit color for word under cursor (whole buffer)" })

  -- AuditWordRed/Blue/Half: highlight word under cursor within function scope (uses treesitter)
  for _, spec in ipairs({
    { "AuditWordRed", "red", "Mark word under cursor red (function scope)" },
    { "AuditWordBlue", "blue", "Mark word under cursor blue (function scope)" },
    { "AuditWordHalf", "half", "Mark word under cursor half red / blue (function scope)" },
  }) do
    local cmd, color, desc = spec[1], spec[2], spec[3]
    vim.api.nvim_create_user_command(cmd, function()
      M.highlight_cword(color)
    end, { desc = desc })
  end

  vim.api.nvim_create_user_command("AuditWordMark", function()
    M.pick_cword_color()
  end, { desc = "Pick audit color for word under cursor (function scope)" })

  if opts.keymaps ~= false then
    local defaults = {
      red = "<leader>ar",
      blue = "<leader>ab",
      half = "<leader>ah",
      mark = "<leader>am",
      note_menu = "<leader>al",
      save = "<leader>aS",
      clear = "<leader>aX",
    }
    local user_maps = type(opts.keymaps) == "table" and opts.keymaps or {}
    local keys = vim.tbl_extend("force", defaults, user_maps)

    local map = vim.keymap.set
    local kopt = { silent = true }

    ---@type table<string, {fn: function, desc: string}>
    local bindings = {
      red = {
        fn = function()
          M.highlight_cword_buffer("red")
        end,
        desc = "Audit: red",
      },
      blue = {
        fn = function()
          M.highlight_cword_buffer("blue")
        end,
        desc = "Audit: blue",
      },
      half = {
        fn = function()
          M.highlight_cword_buffer("half")
        end,
        desc = "Audit: half&half",
      },
      mark = {
        fn = function()
          M.pick_color()
        end,
        desc = "Audit: pick color",
      },
      save = {
        fn = function()
          M.audit()
        end,
        desc = "Audit: save",
      },
      clear = {
        fn = function()
          M.clear_buffer()
        end,
        desc = "Audit: clear",
      },
      word_red = {
        fn = function()
          M.highlight_cword("red")
        end,
        desc = "Audit: word red",
      },
      word_blue = {
        fn = function()
          M.highlight_cword("blue")
        end,
        desc = "Audit: word blue",
      },
      word_half = {
        fn = function()
          M.highlight_cword("half")
        end,
        desc = "Audit: word half",
      },
      word_mark = {
        fn = function()
          M.pick_cword_color()
        end,
        desc = "Audit: word pick color",
      },
      enter = {
        fn = function()
          M.enter_audit_mode()
        end,
        desc = "Audit: enter mode",
      },
      exit = {
        fn = function()
          M.exit_audit_mode()
        end,
        desc = "Audit: exit mode",
      },
      toggle = {
        fn = function()
          M.toggle_audit_mode()
        end,
        desc = "Audit: toggle mode",
      },
      undo = {
        fn = function()
          M.undo_at_cursor()
        end,
        desc = "Audit: undo highlight",
      },
      note = {
        fn = function()
          M.add_note()
        end,
        desc = "Audit: add note",
      },
      note_delete = {
        fn = function()
          M.delete_note()
        end,
        desc = "Audit: delete note",
      },
      note_edit = {
        fn = function()
          M.edit_note()
        end,
        desc = "Audit: edit note",
      },
      notes = {
        fn = function()
          M.list_notes()
        end,
        desc = "Audit: list notes",
      },
      note_menu = {
        fn = function()
          M.pick_note_action()
        end,
        desc = "Audit: note menu",
      },
      note_show = {
        fn = function()
          M.show_note()
        end,
        desc = "Audit: show note",
      },
    }

    for action, lhs in pairs(keys) do
      if lhs and bindings[action] then
        map(
          "n",
          lhs,
          bindings[action].fn,
          vim.tbl_extend("force", kopt, { desc = bindings[action].desc })
        )
      end
    end
  end

  M._setup_done = true
  vim.g.auditor_setup_done = true
end

return M
