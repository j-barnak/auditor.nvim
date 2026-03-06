-- auditor/highlights.lua
-- Applies extmark highlights at the individual token level.
-- Token extraction is delegated to auditor.ts (treesitter + regex fallback).
--
-- Colors are defined via AuditorColorDef tables passed to setup().
-- Each color is either "solid" (single hl group) or "gradient" (per-character
-- interpolation between two hex endpoints).

local M = {}

local ts = require("auditor.ts")

---@type integer Extmark namespace shared across the plugin
M.ns = vim.api.nvim_create_namespace("auditor")

---@type table<integer, table<integer, integer[]>> bufnr -> { primary_id -> {sec_id, ...} }
M._half_pairs = {}

---@type integer Separate namespace for note virtual text (never affects diffs).
M.note_ns = vim.api.nvim_create_namespace("auditor_notes")

-- Note display configuration (set from init.lua during setup).
M._note_sign_icon = "\xe2\x97\x86" -- ◆
M._note_preview_len = 30

-- Number of discrete gradient steps.
local GRAD_STEPS = 16

---@class AuditorColorDef
---@field name string        Internal color key (stored in DB)
---@field label string       Display text in picker menu
---@field hl? table          { bg?: string, fg?: string, bold?: boolean } for solid colors
---@field gradient? string[] Two hex colors {from, to} for per-character gradient

-- Default color definitions when none supplied to setup().
M.DEFAULT_COLORS = {
  { name = "red", label = "Red", hl = { bg = "#CC0000", fg = "#FFFFFF", bold = true } },
  { name = "blue", label = "Blue", hl = { bg = "#0055CC", fg = "#FFFFFF", bold = true } },
  { name = "half", label = "Gradient", gradient = { "#CC0000", "#0055CC" }, hl = { fg = "#FFFFFF", bold = true } },
}

-- Color registry: name -> { type = "solid"|"gradient", hl_group?, grad_groups? }
local color_registry = {}

-- Reverse map: hl_group name -> color name (for collect_extmarks).
local hl_group_to_color = {}

-- Backward-compat alias: gradient groups for the "half" color.
local grad_groups = {}

-- Generate the highlight group name for a solid color.
---@param name string
---@return string
local function hl_group_name(name)
  return "Auditor" .. name:sub(1, 1):upper() .. name:sub(2)
end

---@param color_defs? AuditorColorDef[]
function M.setup(color_defs)
  color_defs = color_defs or M.DEFAULT_COLORS

  -- Clear registries (preserve table references for test access).
  for k in pairs(color_registry) do
    color_registry[k] = nil
  end
  for k in pairs(hl_group_to_color) do
    hl_group_to_color[k] = nil
  end
  for k in pairs(grad_groups) do
    grad_groups[k] = nil
  end

  -- Note virtual text highlight (dimmed, italic).
  vim.api.nvim_set_hl(0, "AuditorNote", { fg = "#888888", italic = true })

  -- Note sign and float highlight groups.
  vim.api.nvim_set_hl(0, "AuditorNoteSign", { fg = "#888888" })
  vim.api.nvim_set_hl(0, "AuditorNoteFloat", { link = "NormalFloat", default = true })
  vim.api.nvim_set_hl(0, "AuditorNoteFloatBorder", { link = "FloatBorder", default = true })
  vim.api.nvim_set_hl(0, "AuditorNoteFloatTitle", { fg = "#FFFFFF", bold = true })

  for _, def in ipairs(color_defs) do
    if def.gradient then
      -- Parse hex endpoints.
      local r0 = tonumber(def.gradient[1]:sub(2, 3), 16)
      local g0 = tonumber(def.gradient[1]:sub(4, 5), 16)
      local b0 = tonumber(def.gradient[1]:sub(6, 7), 16)
      local r1 = tonumber(def.gradient[2]:sub(2, 3), 16)
      local g1 = tonumber(def.gradient[2]:sub(4, 5), 16)
      local b1 = tonumber(def.gradient[2]:sub(6, 7), 16)

      local fg = (def.hl and def.hl.fg) or "#FFFFFF"
      local bold = (def.hl == nil or def.hl.bold == nil) and true or def.hl.bold

      local groups = {}
      -- "half" keeps legacy "AuditorGrad" prefix; custom gradients use "Auditor<Name>Grad".
      local prefix = (def.name == "half") and "AuditorGrad" or (hl_group_name(def.name) .. "Grad")

      for i = 0, GRAD_STEPS - 1 do
        local t = (GRAD_STEPS > 1) and (i / (GRAD_STEPS - 1)) or 0.5
        local r = math.floor(r0 + (r1 - r0) * t + 0.5)
        local g = math.floor(g0 + (g1 - g0) * t + 0.5)
        local b = math.floor(b0 + (b1 - b0) * t + 0.5)
        local gname = string.format("%s%02d", prefix, i)
        vim.api.nvim_set_hl(0, gname, {
          bg = string.format("#%02X%02X%02X", r, g, b),
          fg = fg,
          bold = bold,
        })
        groups[i] = gname
        hl_group_to_color[gname] = def.name
      end

      color_registry[def.name] = { type = "gradient", grad_groups = groups }

      -- Backward-compat: fill grad_groups alias for "half".
      if def.name == "half" then
        for k, v in pairs(groups) do
          grad_groups[k] = v
        end
      end
    else
      -- Solid color.
      local group = hl_group_name(def.name)
      local attrs
      if def.hl then
        attrs = vim.tbl_extend("force", { fg = "#FFFFFF", bold = true }, def.hl)
      else
        attrs = { bg = "#888888", fg = "#FFFFFF", bold = true }
      end
      vim.api.nvim_set_hl(0, group, attrs)

      color_registry[def.name] = { type = "solid", hl_group = group }
      hl_group_to_color[group] = def.name
    end

    -- Per-color note sign highlight.
    local sign_group = "AuditorNoteSign" .. def.name:sub(1, 1):upper() .. def.name:sub(2)
    if def.gradient then
      vim.api.nvim_set_hl(0, sign_group, { fg = def.gradient[1] })
    elseif def.hl and def.hl.bg then
      vim.api.nvim_set_hl(0, sign_group, { fg = def.hl.bg })
    else
      vim.api.nvim_set_hl(0, sign_group, { fg = "#888888" })
    end
  end
end

-- Exposed for tests.
M._grad_groups = grad_groups
M._GRAD_STEPS = GRAD_STEPS
M._color_registry = color_registry
M._hl_group_to_color = hl_group_to_color

-- Map a character position to a gradient group for a given color.
---@param color string gradient color name
---@param char_idx integer 0-based index within the word
---@param word_len integer total characters in the word
---@return string? hl_group
local function grad_for_color(color, char_idx, word_len)
  local reg = color_registry[color]
  if not reg or reg.type ~= "gradient" then
    return nil
  end
  local groups = reg.grad_groups
  if word_len <= 1 then
    return groups[math.floor(GRAD_STEPS / 2)]
  end
  local step = math.floor(char_idx * (GRAD_STEPS - 1) / (word_len - 1) + 0.5)
  return groups[step]
end

-- Backward-compat convenience: gradient step for "half" color.
---@param char_idx integer
---@param word_len integer
---@return string hl_group
local function grad_for(char_idx, word_len)
  return grad_for_color("half", char_idx, word_len)
end

-- Exposed for tests.
M._grad_for = grad_for
M._grad_for_color = grad_for_color

-- Apply per-character gradient extmarks for a single word.
-- Returns the primary extmark ID and records secondaries in _half_pairs.
---@param color string gradient color name
---@param bufnr integer
---@param line integer
---@param col_start integer
---@param col_end integer
---@return integer primary_id
local function apply_gradient(color, bufnr, line, col_start, col_end)
  local word_len = col_end - col_start
  local reg = color_registry[color]

  -- Primary extmark: covers the full word with the first gradient color.
  local primary_group = (word_len <= 1) and grad_for_color(color, 0, 1) or reg.grad_groups[0]
  local id = vim.api.nvim_buf_set_extmark(bufnr, M.ns, line, col_start, {
    end_row = line,
    end_col = col_end,
    hl_group = primary_group,
    priority = 100,
  })

  -- Per-character overlay extmarks (skip char 0 since primary covers it).
  if word_len > 1 then
    local secs = {}
    for j = 1, word_len - 1 do
      local sec_id = vim.api.nvim_buf_set_extmark(bufnr, M.ns, line, col_start + j, {
        end_row = line,
        end_col = col_start + j + 1,
        hl_group = grad_for_color(color, j, word_len),
        priority = 101,
      })
      secs[#secs + 1] = sec_id
    end
    M._half_pairs[bufnr] = M._half_pairs[bufnr] or {}
    M._half_pairs[bufnr][id] = secs
  end

  return id
end

-- Return tokens for the current visual selection.
---@param bufnr integer
---@param mode string
---@param opts {node_types?: string|string[]}
---@return AuditorToken[]
function M.get_tokens_in_selection(bufnr, mode, opts)
  return ts.get_tokens(bufnr, mode, opts)
end

-- Whether treesitter is active for this buffer.
---@param bufnr integer
---@return boolean
function M.ts_available(bufnr)
  return ts.available(bufnr)
end

-- Check if a color name is registered.
---@param color string
---@return boolean
function M.is_registered(color)
  return color_registry[color] ~= nil
end

-- Check if a color is a gradient type.
---@param color string
---@return boolean
function M.is_gradient(color)
  local reg = color_registry[color]
  return reg ~= nil and reg.type == "gradient"
end

-- Apply highlights for a list of token positions.
---@param bufnr integer
---@param words AuditorToken[]
---@param color string
---@return integer[] extmark_ids
function M.apply_words(bufnr, words, color)
  local ids = {}
  local applied = {}
  local reg = color_registry[color]
  if not reg then
    return ids, applied
  end
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  for _, w in ipairs(words) do
    if w.line < line_count then
      local line_text = vim.api.nvim_buf_get_lines(bufnr, w.line, w.line + 1, false)[1]
      if line_text and w.col_end > w.col_start and w.col_start < #line_text and w.col_end <= #line_text then
        if reg.type == "gradient" then
          local id = apply_gradient(color, bufnr, w.line, w.col_start, w.col_end)
          table.insert(ids, id)
          table.insert(applied, w)
        else
          local id = vim.api.nvim_buf_set_extmark(bufnr, M.ns, w.line, w.col_start, {
            end_row = w.line,
            end_col = w.col_end,
            hl_group = reg.hl_group,
            priority = 100,
          })
          table.insert(ids, id)
          table.insert(applied, w)
        end
      end
    end
  end

  return ids, applied
end

-- Resolve hl_group → color string.
---@param hl_group string
---@return string? color
local function color_from_hl_group(hl_group)
  return hl_group_to_color[hl_group]
end

-- Collect all auditor extmarks in a buffer with their resolved colors.
-- Returns a flat list sorted by position, ready for DB persistence.
-- Secondary gradient extmarks are skipped; the primary already records
-- the complete span with its color. Each entry includes `word_text`
-- extracted from the buffer at the extmark's current position.
---@param bufnr integer
---@return {line: integer, col_start: integer, col_end: integer, color: string, word_text: string}[]
function M.collect_extmarks(bufnr)
  -- Build set of secondary gradient IDs to skip.
  local secondary = {}
  if M._half_pairs[bufnr] then
    for _, secs in pairs(M._half_pairs[bufnr]) do
      for _, sec_id in ipairs(secs) do
        secondary[sec_id] = true
      end
    end
  end

  -- Cache lines for word_text extraction.
  local line_cache = {}
  local function get_line(lnum)
    if line_cache[lnum] == nil then
      local lines = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)
      line_cache[lnum] = lines[1] or false
    end
    return line_cache[lnum]
  end

  local marks = vim.api.nvim_buf_get_extmarks(bufnr, M.ns, 0, -1, { details = true })
  local result = {}
  for _, m in ipairs(marks) do
    if not secondary[m[1]] then
      local row, col, details = m[2], m[3], m[4]
      local end_col = details and details.end_col
      local hl_group = details and details.hl_group
      if end_col and end_col > col and hl_group then
        local color = color_from_hl_group(hl_group)
        if color then
          local text = ""
          local lt = get_line(row)
          if lt and end_col <= #lt then
            text = lt:sub(col + 1, end_col)
          end
          table.insert(result, {
            line = row,
            col_start = col,
            col_end = end_col,
            color = color,
            word_text = text,
          })
        end
      end
    end
  end
  return result
end

-- Re-apply a single token highlight when loading from DB.
---@param bufnr integer
---@param line integer
---@param col_start integer
---@param col_end integer
---@param color string
---@param _word_index integer (unused, kept for API compat)
---@return integer? extmark_id
function M.apply_word(bufnr, line, col_start, col_end, color, _word_index)
  if line >= vim.api.nvim_buf_line_count(bufnr) then
    return nil
  end
  local line_text = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1]
  if not line_text then
    return nil
  end
  local line_len = #line_text
  if col_start >= line_len or col_end > line_len then
    return nil
  end

  local reg = color_registry[color]
  if not reg then
    return nil
  end

  if reg.type == "gradient" then
    return apply_gradient(color, bufnr, line, col_start, col_end)
  end

  return vim.api.nvim_buf_set_extmark(bufnr, M.ns, line, col_start, {
    end_row = line,
    end_col = col_end,
    hl_group = reg.hl_group,
    priority = 100,
  })
end

-- Delete all secondary gradient extmarks for a primary.
---@param bufnr integer
---@param primary_id integer
function M.del_half_pair(bufnr, primary_id)
  if M._half_pairs[bufnr] and M._half_pairs[bufnr][primary_id] then
    for _, sec_id in ipairs(M._half_pairs[bufnr][primary_id]) do
      pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns, sec_id)
    end
    M._half_pairs[bufnr][primary_id] = nil
  end
end

-- Clear gradient tracking for a buffer (call after clearing namespace).
---@param bufnr integer
function M.clear_half_pairs(bufnr)
  M._half_pairs[bufnr] = nil
end

-- Format the truncated EOL preview for a note.
-- Returns the preview string including leading indent.
---@param text string note text
---@param word_text? string word the note is attached to
---@param max_len? integer maximum content length (default M._note_preview_len or 30)
---@return string
function M.format_note_preview(text, word_text, max_len)
  max_len = max_len or M._note_preview_len or 30
  if not text or text == "" then
    return ""
  end
  local lines = vim.split(text, "\n", { plain = true })
  local first = lines[1] or ""
  local multi = #lines > 1 and string.format(" (+%d lines)", #lines - 1) or ""
  local prefix = (word_text and word_text ~= "") and (word_text .. ": ") or ""
  local body = prefix .. first .. multi
  if #body > max_len then
    local target = max_len - #prefix - #multi - 3 -- 3 for "..."
    if target > 0 then
      body = prefix .. first:sub(1, target) .. "..." .. multi
    else
      body = body:sub(1, max_len)
    end
  end
  return "  " .. body
end

-- Return the sign highlight group for a given audit color.
---@param color? string audit color name
---@return string hl_group
function M.note_sign_hl(color)
  if color and color ~= "" then
    local group = "AuditorNoteSign" .. color:sub(1, 1):upper() .. color:sub(2)
    if vim.fn.hlexists(group) == 1 then
      return group
    end
  end
  return "AuditorNoteSign"
end

-- Apply a note as sign + truncated EOL preview.
-- Returns the note extmark ID in note_ns.
---@param bufnr integer
---@param line integer 0-indexed line number
---@param text string note text
---@param color? string audit color for sign tinting
---@param word_text? string word the note is attached to
---@return integer note_extmark_id
function M.apply_note(bufnr, line, text, color, word_text)
  local preview = M.format_note_preview(text, word_text, M._note_preview_len)
  local opts = {
    virt_text = { { preview, "AuditorNote" } },
    virt_text_pos = "eol",
  }
  if M._note_sign_icon and M._note_sign_icon ~= "" then
    opts.sign_text = M._note_sign_icon
    opts.sign_hl_group = M.note_sign_hl(color)
  end
  return vim.api.nvim_buf_set_extmark(bufnr, M.note_ns, line, 0, opts)
end

-- Clear all note extmarks for a buffer.
---@param bufnr integer
function M.clear_notes(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, M.note_ns, 0, -1)
end

return M
