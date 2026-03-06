-- auditor/ts.lua
-- Treesitter-aware token extraction for the auditor plugin.
-- Falls back to regex (%w_ pattern) when no parser is available or when the
-- treesitter path fails for any reason (incomplete code, parse errors, slices).
--
-- Public API:
--   ts.available(bufnr)              → boolean
--   ts.get_tokens(bufnr, mode, opts) → AuditorToken[]

---@class AuditorToken
---@field line integer      0-indexed line number
---@field col_start integer 0-indexed byte offset (inclusive)
---@field col_end integer   0-indexed byte offset (exclusive)
---@field ts_type? string   Treesitter node type (only present on the TS path)
---@field named? boolean    Whether this is a named TS node (only present on the TS path)

local M = {}

-- ── helpers ───────────────────────────────────────────────────────────────────

-- Read selection bounds from vim marks (0-indexed rows, exclusive ecol).
---@return integer srow, integer erow, integer scol, integer ecol
local function bounds(_mode)
  local srow = vim.fn.line("'<") - 1
  local erow = vim.fn.line("'>") - 1
  local scol = vim.fn.col("'<") - 1
  local ecol = vim.fn.col("'>") -- exclusive byte offset
  return srow, erow, scol, ecol
end

-- Lex-order comparison: is (r1,c1) < (r2,c2)?
local function lex_lt(r1, c1, r2, c2)
  return r1 < r2 or (r1 == r2 and c1 < c2)
end

-- Is leaf node [n_sr:n_sc, n_er:n_ec] inside the selection?
---@return boolean
local function node_in_selection(n_sr, n_sc, n_er, n_ec, srow, scol, erow, ecol, mode)
  if mode == "V" then
    return n_sr >= srow and n_er <= erow
  elseif mode == "\22" then -- block visual: check column band on each row
    if n_sr < srow or n_er > erow then
      return false
    end
    local lo = math.min(scol, ecol - 1)
    local hi = math.max(scol, ecol - 1) + 1
    return n_sc >= lo and n_ec <= hi
  else -- char visual "v"
    local at_or_after_start = not lex_lt(n_sr, n_sc, srow, scol)
    local at_or_before_end = not lex_lt(erow, ecol, n_er, n_ec)
    return at_or_after_start and at_or_before_end
  end
end

-- Fetch text for a single-line leaf node; returns nil for multi-line nodes.
---@return string?
local function node_text(bufnr, n_sr, n_sc, n_er, n_ec)
  if n_sr ~= n_er then
    return nil
  end -- skip multi-line nodes
  local lines = vim.api.nvim_buf_get_lines(bufnr, n_sr, n_sr + 1, false)
  if not lines[1] then
    return nil
  end
  return lines[1]:sub(n_sc + 1, n_ec)
end

-- Is this node "meaningful" to highlight?
-- Named nodes always qualify. Anonymous nodes qualify only if their text
-- contains at least one identifier character ([%w_]).
---@param named boolean
---@param text string?
---@param node_type string
---@param filter string|string[]|nil
---@return boolean
local function is_meaningful(named, text, node_type, filter)
  if filter == "named" then
    return named
  elseif type(filter) == "table" then
    for _, t in ipairs(filter) do
      if node_type == t then
        return true
      end
    end
    return false
  else -- "all" or nil: text-based heuristic
    return text ~= nil and text:match("[%w_]") ~= nil
  end
end

-- ── treesitter walk ───────────────────────────────────────────────────────────

-- Recursively walk the node tree, collecting qualifying leaf nodes.
local function walk(node, bufnr, srow, scol, erow, ecol, mode, filter, out)
  local n_sr, n_sc, n_er, n_ec = node:range()

  -- Prune: skip subtrees that don't touch the selection at all.
  if n_er < srow or n_sr > erow then
    return
  end

  if node:child_count() == 0 then
    -- Leaf node — check selection containment and meaningfulness.
    if node_in_selection(n_sr, n_sc, n_er, n_ec, srow, scol, erow, ecol, mode) then
      local text = node_text(bufnr, n_sr, n_sc, n_er, n_ec)
      local named = node:named()
      local ntype = node:type()
      if is_meaningful(named, text, ntype, filter) then
        table.insert(out, {
          line = n_sr,
          col_start = n_sc,
          col_end = n_ec,
          ts_type = ntype,
          named = named,
        })
      end
    end
  else
    for i = 0, node:child_count() - 1 do
      walk(node:child(i), bufnr, srow, scol, erow, ecol, mode, filter, out)
    end
  end
end

-- ── regex fallback ────────────────────────────────────────────────────────────

---@return AuditorToken[]
local function regex_tokens(bufnr, mode)
  local srow, erow, scol, ecol = bounds(mode)
  local lines = vim.api.nvim_buf_get_lines(bufnr, srow, erow + 1, false)
  local out = {}

  for rel, text in ipairs(lines) do
    local lnum = srow + rel - 1
    local lo, hi

    if mode == "V" then
      lo, hi = 0, #text
    elseif mode == "\22" then
      lo = math.max(0, math.min(scol, ecol - 1))
      hi = math.min(#text, math.max(scol, ecol - 1) + 1)
    else
      lo = (lnum == srow) and scol or 0
      hi = (lnum == erow) and ecol or #text
    end

    local pos = lo
    while pos < hi do
      local ns = text:find("[%w_]", pos + 1)
      if not ns or ns > hi then
        break
      end
      local ne = text:find("[^%w_]", ns + 1) or (#text + 1)
      local ws = ns - 1
      local we = math.min(ne - 1, hi)
      if ws < we then
        table.insert(out, { line = lnum, col_start = ws, col_end = we })
      end
      pos = ne - 1
    end
  end

  return out
end

-- ── public ────────────────────────────────────────────────────────────────────

-- Returns true when a treesitter parser is loadable for this buffer.
-- A parser being available does not guarantee a successful parse — incomplete
-- or slice code may produce partial trees, which is handled in get_tokens.
---@param bufnr integer
---@return boolean
function M.available(bufnr)
  if not (vim.treesitter and vim.treesitter.get_parser) then
    return false
  end
  local ok = pcall(vim.treesitter.get_parser, bufnr)
  return ok
end

-- Extract tokens from the last visual selection.
-- Tries the treesitter walk first; falls back to regex on any failure.
-- This makes the plugin best-effort on incomplete code, program slices, and
-- files where the parser produces error nodes.
--
-- opts.node_types: "all" (default) | "named" | { "identifier", "string", ... }
---@param bufnr integer
---@param mode string Visual mode: "v", "V", or "\22"
---@param opts {node_types?: string|string[]}
---@return AuditorToken[]
function M.get_tokens(bufnr, mode, opts)
  opts = opts or {}
  local filter = opts.node_types

  if M.available(bufnr) then
    -- Wrap the entire treesitter path in pcall so that any failure —
    -- incomplete code, error nodes, missing children, parser bugs — falls
    -- through transparently to the regex fallback rather than surfacing as
    -- an error to the user.
    local ok, result = pcall(function()
      local parser = vim.treesitter.get_parser(bufnr)
      local trees = parser:parse()
      if not (trees and trees[1]) then
        return nil
      end
      local root = trees[1]:root()
      local srow, erow, scol, ecol = bounds(mode)
      local out = {}
      walk(root, bufnr, srow, scol, erow, ecol, mode, filter, out)
      return out
    end)
    if ok and result then
      return result
    end
  end

  return regex_tokens(bufnr, mode)
end

-- ── function-scope detection ──────────────────────────────────────────────────

-- Node types that represent function or method definitions across common languages.
local FUNCTION_NODE_TYPES = {
  function_definition = true, -- C, Python, Lua, Ruby
  function_declaration = true, -- C, JavaScript
  local_function = true, -- Lua
  method_definition = true, -- Ruby, JavaScript, TypeScript
  method_declaration = true, -- Java
  arrow_function = true, -- JavaScript/TypeScript
  ["function"] = true, -- anonymous JS/TS
  func_literal = true, -- Go
  function_item = true, -- Rust
  anonymous_function = true,
  lambda_expression = true, -- Java, Kotlin
  lambda = true, -- Python
  closure_expression = true, -- Rust
  block = false, -- not a function itself
}

-- Returns the 0-indexed {srow, erow} of the innermost function/method node
-- enclosing position (row, col), or nil if treesitter is unavailable or no
-- enclosing function node is found (falls back to the call site deciding scope).
---@param bufnr integer
---@param row integer 0-indexed cursor row
---@param col integer 0-indexed cursor col
---@return {srow: integer, erow: integer}?
function M.enclosing_function(bufnr, row, col)
  if not M.available(bufnr) then
    return nil
  end
  local ok, result = pcall(function()
    local parser = vim.treesitter.get_parser(bufnr)
    local trees = parser:parse()
    if not (trees and trees[1]) then
      return nil
    end
    local root = trees[1]:root()
    local node = root:named_descendant_for_range(row, col, row, col)
    if not node then
      return nil
    end
    local current = node
    while current do
      if FUNCTION_NODE_TYPES[current:type()] then
        local sr, _, er, _ = current:range()
        return { srow = sr, erow = er }
      end
      current = current:parent()
    end
    return nil
  end)
  if ok then
    return result
  end
  return nil
end

-- Expose bounds helper for tests and the highlights module.
M._bounds = bounds

return M
