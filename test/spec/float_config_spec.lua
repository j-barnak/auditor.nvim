-- test/spec/float_config_spec.lua
-- Exhaustive tests for configurable note float window sizing and centering.
--
-- Coverage:
--   FC1  Default float opts are applied when no float config given
--   FC2  Custom padding is respected
--   FC3  Custom max_width (fractional) is respected
--   FC4  Custom max_height (fractional) is respected
--   FC5  Absolute max_width (>1) is respected
--   FC6  Absolute max_height (>1) is respected
--   FC7  Custom border style is applied
--   FC8  win_options are applied to the opened window
--   FC9  Float is centered relative to the editor (not cursor)
--   FC10 Viewer float uses float config
--   FC11 Editor float uses float config
--   FC12 Content smaller than max is not stretched
--   FC13 Content larger than max is clamped
--   FC14 Width and height are always >= 1
--   FC15 Padding constrains max_width/max_height
--   FC16 Title is set and centered
--   FC17 Partial float config merges with defaults
--   FC18 float={} (empty) uses all defaults
--   FC19 Very large padding still produces valid window
--   FC20 max_width=1.0 uses full editor width minus padding
--   FC21 max_height=1.0 uses full editor height minus padding
--   FC22 _compute_float_config is a pure function of _float_opts + vim dimensions
--   FC23 _compute_float_config with no title omits title/title_pos
--   FC24 Property: width and height are always within editor bounds (100 iterations)
--   FC25 Property: window is always centered (100 iterations)
--   FC26 Float config persists across mode transitions
--   FC27 win_options winblend applied
--   FC28 Custom border array is passed through
--   FC29 Viewer dimensions adapt to note content
--   FC30 Editor dimensions adapt to initial text

local function reset_modules()
  for _, m in ipairs({ "auditor", "auditor.init", "auditor.db", "auditor.highlights", "auditor.ts" }) do
    package.loaded[m] = nil
  end
end

-- Deterministic PRNG
local function make_rng(seed)
  local s = math.abs(seed) + 1
  return function(lo, hi)
    s = (s * 1664525 + 1013904223) % (2 ^ 32)
    return lo + math.floor(s * (hi - lo + 1) / (2 ^ 32))
  end
end

describe("float config", function()
  local auditor, hl

  before_each(function()
    reset_modules()
  end)

  local function setup_with(float_opts)
    local tmp_db = vim.fn.tempname() .. ".db"
    auditor = require("auditor")
    local setup_opts = { db_path = tmp_db, keymaps = false }
    if float_opts then
      setup_opts.float = float_opts
    end
    auditor.setup(setup_opts)
    hl = require("auditor.highlights")
  end

  local function setup_buf(lines, cursor_row, cursor_col)
    local bufnr = vim.api.nvim_create_buf(false, true)
    local filepath = vim.fn.tempname() .. ".lua"
    vim.api.nvim_buf_set_name(bufnr, filepath)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_set_current_buf(bufnr)
    auditor.enter_audit_mode()
    if cursor_row then
      vim.api.nvim_win_set_cursor(0, { cursor_row, cursor_col or 0 })
    end
    return bufnr
  end

  local function find_target_id(bufnr, token)
    local extmarks = vim.api.nvim_buf_get_extmarks(
      bufnr, hl.ns,
      { token.line, token.col_start },
      { token.line, token.col_end },
      { details = true }
    )
    for _, mark in ipairs(extmarks) do
      local id, row, col, details = mark[1], mark[2], mark[3], mark[4]
      if row == token.line and col == token.col_start and details.end_col == token.col_end then
        return id
      end
    end
    return nil
  end

  local function stub_input(text)
    auditor._note_input_override = true
    local orig = vim.ui.input
    vim.ui.input = function(opts, on_confirm)
      on_confirm(text)
    end
    return function()
      vim.ui.input = orig
      auditor._note_input_override = nil
    end
  end

  -- ── FC1: defaults ───────────────────────────────────────────────────────

  describe("FC1: default float opts", function()
    it("uses padding=3, max_width=0.9, max_height=0.9, border=rounded", function()
      setup_with(nil)
      assert.equals(3, auditor._float_opts.padding)
      assert.equals(0.9, auditor._float_opts.max_width)
      assert.equals(0.9, auditor._float_opts.max_height)
      assert.equals("rounded", auditor._float_opts.border)
    end)

    it("default win_options has winblend=0", function()
      setup_with(nil)
      assert.equals(0, auditor._float_opts.win_options.winblend)
    end)
  end)

  -- ── FC2: custom padding ─────────────────────────────────────────────────

  describe("FC2: custom padding", function()
    it("padding=5 reduces available space", function()
      setup_with({ padding = 5 })
      assert.equals(5, auditor._float_opts.padding)

      local cfg = auditor._compute_float_config(200, 100)
      local columns = vim.o.columns
      local lines = vim.o.lines - vim.o.cmdheight
      assert.is_true(cfg.width <= columns - 10)
      assert.is_true(cfg.height <= lines - 10)
    end)

    it("padding=0 allows max space", function()
      setup_with({ padding = 0 })
      local cfg = auditor._compute_float_config(200, 100)
      local columns = vim.o.columns
      local lines = vim.o.lines - vim.o.cmdheight
      local max_w = math.floor(columns * 0.9)
      local max_h = math.floor(lines * 0.9)
      assert.equals(math.min(200, max_w), cfg.width)
      assert.equals(math.min(100, max_h), cfg.height)
    end)
  end)

  -- ── FC3: fractional max_width ───────────────────────────────────────────

  describe("FC3: fractional max_width", function()
    it("max_width=0.5 caps at half editor width", function()
      setup_with({ max_width = 0.5 })
      local columns = vim.o.columns
      local max_w = math.min(math.floor(columns * 0.5), columns - 6)
      local cfg = auditor._compute_float_config(500, 10)
      assert.equals(max_w, cfg.width)
    end)
  end)

  -- ── FC4: fractional max_height ──────────────────────────────────────────

  describe("FC4: fractional max_height", function()
    it("max_height=0.5 caps at half editor height", function()
      setup_with({ max_height = 0.5 })
      local lines = vim.o.lines - vim.o.cmdheight
      local max_h = math.min(math.floor(lines * 0.5), lines - 6)
      local cfg = auditor._compute_float_config(10, 500)
      assert.equals(max_h, cfg.height)
    end)
  end)

  -- ── FC5: absolute max_width ─────────────────────────────────────────────

  describe("FC5: absolute max_width (>1)", function()
    it("max_width=60 caps at 60 columns", function()
      setup_with({ max_width = 60 })
      local cfg = auditor._compute_float_config(200, 10)
      local columns = vim.o.columns
      local expected = math.min(60, columns - 6)
      assert.equals(expected, cfg.width)
    end)
  end)

  -- ── FC6: absolute max_height ────────────────────────────────────────────

  describe("FC6: absolute max_height (>1)", function()
    it("max_height=10 caps at 10 rows", function()
      setup_with({ max_height = 10 })
      local cfg = auditor._compute_float_config(10, 200)
      local lines = vim.o.lines - vim.o.cmdheight
      local expected = math.min(10, lines - 6)
      assert.equals(expected, cfg.height)
    end)
  end)

  -- ── FC7: custom border ──────────────────────────────────────────────────

  describe("FC7: custom border style", function()
    it("border='single' is passed through", function()
      setup_with({ border = "single" })
      local cfg = auditor._compute_float_config(40, 10)
      assert.equals("single", cfg.border)
    end)

    it("border='none' is passed through", function()
      setup_with({ border = "none" })
      local cfg = auditor._compute_float_config(40, 10)
      assert.equals("none", cfg.border)
    end)

    it("border='double' is passed through", function()
      setup_with({ border = "double" })
      local cfg = auditor._compute_float_config(40, 10)
      assert.equals("double", cfg.border)
    end)
  end)

  -- ── FC8: win_options applied ────────────────────────────────────────────

  describe("FC8: win_options applied to window", function()
    it("custom winblend is stored", function()
      setup_with({ win_options = { winblend = 15 } })
      assert.equals(15, auditor._float_opts.win_options.winblend)
    end)
  end)

  -- ── FC9: float is centered ──────────────────────────────────────────────

  describe("FC9: float is centered relative to editor", function()
    it("relative is 'editor' not 'cursor'", function()
      setup_with(nil)
      local cfg = auditor._compute_float_config(40, 10)
      assert.equals("editor", cfg.relative)
    end)

    it("row and col center the window", function()
      setup_with(nil)
      local cfg = auditor._compute_float_config(40, 10)
      local lines = vim.o.lines - vim.o.cmdheight
      local columns = vim.o.columns
      local expected_row = math.floor((lines - cfg.height) / 2)
      local expected_col = math.floor((columns - cfg.width) / 2)
      assert.equals(expected_row, cfg.row)
      assert.equals(expected_col, cfg.col)
    end)
  end)

  -- ── FC10: viewer float uses config ──────────────────────────────────────

  describe("FC10: show_note uses float config", function()
    it("viewer float is centered with configured border", function()
      setup_with({ border = "double", padding = 2 })
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input("my note")
      auditor.add_note()
      ri()

      auditor.show_note()
      assert.is_not_nil(auditor._note_float_win)
      local config = vim.api.nvim_win_get_config(auditor._note_float_win)
      assert.equals("editor", config.relative)

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── FC11: editor float uses config ──────────────────────────────────────

  describe("FC11: editor float uses float config", function()
    it("editor float is centered", function()
      setup_with({ padding = 4 })
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")
      assert.is_not_nil(auditor._note_float_win)
      local config = vim.api.nvim_win_get_config(auditor._note_float_win)
      assert.equals("editor", config.relative)

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── FC12: content smaller than max is not stretched ─────────────────────

  describe("FC12: small content not stretched", function()
    it("10x5 content stays 10x5 when max is larger", function()
      setup_with(nil)
      local cfg = auditor._compute_float_config(10, 5)
      assert.equals(10, cfg.width)
      assert.equals(5, cfg.height)
    end)
  end)

  -- ── FC13: content larger than max is clamped ────────────────────────────

  describe("FC13: large content is clamped", function()
    it("1000x1000 content is clamped to max", function()
      setup_with({ max_width = 0.8, max_height = 0.8, padding = 2 })
      local columns = vim.o.columns
      local lines = vim.o.lines - vim.o.cmdheight
      local max_w = math.min(math.floor(columns * 0.8), columns - 4)
      local max_h = math.min(math.floor(lines * 0.8), lines - 4)

      local cfg = auditor._compute_float_config(1000, 1000)
      assert.equals(max_w, cfg.width)
      assert.equals(max_h, cfg.height)
    end)
  end)

  -- ── FC14: width/height always >= 1 ──────────────────────────────────────

  describe("FC14: width and height >= 1", function()
    it("zero content produces width=1, height=1", function()
      setup_with(nil)
      local cfg = auditor._compute_float_config(0, 0)
      assert.equals(1, cfg.width)
      assert.equals(1, cfg.height)
    end)

    it("negative content produces width=1, height=1", function()
      setup_with(nil)
      local cfg = auditor._compute_float_config(-5, -5)
      assert.equals(1, cfg.width)
      assert.equals(1, cfg.height)
    end)
  end)

  -- ── FC15: padding constrains dimensions ─────────────────────────────────

  describe("FC15: padding constrains max dimensions", function()
    it("large padding reduces available space below max_width/max_height", function()
      local columns = vim.o.columns
      local lines = vim.o.lines - vim.o.cmdheight
      -- Use padding that fits within both dimensions
      local big_pad = math.floor(math.min(columns, lines) / 4)
      setup_with({ padding = big_pad, max_width = 0.99, max_height = 0.99 })
      local cfg = auditor._compute_float_config(1000, 1000)
      assert.is_true(cfg.width <= columns - big_pad * 2)
      assert.is_true(cfg.height <= lines - big_pad * 2)
    end)
  end)

  -- ── FC16: title ─────────────────────────────────────────────────────────

  describe("FC16: title handling", function()
    it("title is set and centered when provided", function()
      setup_with(nil)
      local cfg = auditor._compute_float_config(40, 10, "My Title")
      assert.equals("My Title", cfg.title)
      assert.equals("center", cfg.title_pos)
    end)

    it("title is omitted when nil", function()
      setup_with(nil)
      local cfg = auditor._compute_float_config(40, 10)
      assert.is_nil(cfg.title)
      assert.is_nil(cfg.title_pos)
    end)
  end)

  -- ── FC17: partial config merges with defaults ───────────────────────────

  describe("FC17: partial config merges with defaults", function()
    it("specifying only border keeps other defaults", function()
      setup_with({ border = "shadow" })
      assert.equals("shadow", auditor._float_opts.border)
      assert.equals(3, auditor._float_opts.padding)
      assert.equals(0.9, auditor._float_opts.max_width)
      assert.equals(0.9, auditor._float_opts.max_height)
    end)

    it("specifying only padding keeps other defaults", function()
      setup_with({ padding = 10 })
      assert.equals(10, auditor._float_opts.padding)
      assert.equals("rounded", auditor._float_opts.border)
      assert.equals(0.9, auditor._float_opts.max_width)
    end)

    it("specifying only max_width keeps other defaults", function()
      setup_with({ max_width = 0.5 })
      assert.equals(0.5, auditor._float_opts.max_width)
      assert.equals(3, auditor._float_opts.padding)
      assert.equals(0.9, auditor._float_opts.max_height)
      assert.equals("rounded", auditor._float_opts.border)
    end)

    it("specifying only win_options merges with defaults", function()
      setup_with({ win_options = { winblend = 20 } })
      assert.equals(20, auditor._float_opts.win_options.winblend)
      assert.equals(3, auditor._float_opts.padding)
    end)
  end)

  -- ── FC18: empty float config ────────────────────────────────────────────

  describe("FC18: empty float config uses defaults", function()
    it("float={} changes nothing", function()
      setup_with({})
      assert.equals(3, auditor._float_opts.padding)
      assert.equals(0.9, auditor._float_opts.max_width)
      assert.equals(0.9, auditor._float_opts.max_height)
      assert.equals("rounded", auditor._float_opts.border)
      assert.equals(0, auditor._float_opts.win_options.winblend)
    end)
  end)

  -- ── FC19: very large padding ────────────────────────────────────────────

  describe("FC19: very large padding still produces valid window", function()
    it("padding larger than half screen still results in width/height >= 1", function()
      local columns = vim.o.columns
      setup_with({ padding = columns })
      local cfg = auditor._compute_float_config(100, 100)
      assert.is_true(cfg.width >= 1)
      assert.is_true(cfg.height >= 1)
    end)
  end)

  -- ── FC20: max_width=1.0 ────────────────────────────────────────────────

  describe("FC20: max_width=1.0 uses full width minus padding", function()
    it("max_width=1.0 with padding=3", function()
      setup_with({ max_width = 1.0, padding = 3 })
      local columns = vim.o.columns
      local expected = columns - 6
      local cfg = auditor._compute_float_config(1000, 10)
      assert.equals(expected, cfg.width)
    end)
  end)

  -- ── FC21: max_height=1.0 ───────────────────────────────────────────────

  describe("FC21: max_height=1.0 uses full height minus padding", function()
    it("max_height=1.0 with padding=3", function()
      setup_with({ max_height = 1.0, padding = 3 })
      local lines = vim.o.lines - vim.o.cmdheight
      local expected = lines - 6
      local cfg = auditor._compute_float_config(10, 1000)
      assert.equals(expected, cfg.height)
    end)
  end)

  -- ── FC22: pure function of state ────────────────────────────────────────

  describe("FC22: _compute_float_config is deterministic", function()
    it("same inputs produce same outputs", function()
      setup_with({ padding = 5, max_width = 0.7, max_height = 0.6 })
      local a = auditor._compute_float_config(50, 20, "test")
      local b = auditor._compute_float_config(50, 20, "test")
      assert.same(a, b)
    end)
  end)

  -- ── FC23: no title ──────────────────────────────────────────────────────

  describe("FC23: no title omits title/title_pos", function()
    it("config has no title keys when title is nil", function()
      setup_with(nil)
      local cfg = auditor._compute_float_config(40, 10, nil)
      assert.is_nil(rawget(cfg, "title"))
      assert.is_nil(rawget(cfg, "title_pos"))
    end)
  end)

  -- ── FC24: property — bounds (100 iterations) ───────────────────────────

  describe("FC24: property — width/height within editor bounds", function()
    it("100 random configs all produce valid dimensions", function()
      local columns = vim.o.columns
      local lines = vim.o.lines - vim.o.cmdheight

      for seed = 1, 100 do
        local rng = make_rng(seed)
        local padding = rng(0, 10)
        local mw = rng(1, 10) / 10 -- 0.1 to 1.0
        local mh = rng(1, 10) / 10
        local cw = rng(1, 500)
        local ch = rng(1, 500)

        reset_modules()
        auditor = require("auditor")
        auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false,
          float = { padding = padding, max_width = mw, max_height = mh } })

        local cfg = auditor._compute_float_config(cw, ch)
        assert.is_true(cfg.width >= 1,
          string.format("seed=%d: width=%d < 1", seed, cfg.width))
        assert.is_true(cfg.height >= 1,
          string.format("seed=%d: height=%d < 1", seed, cfg.height))
        assert.is_true(cfg.width <= columns,
          string.format("seed=%d: width=%d > columns=%d", seed, cfg.width, columns))
        assert.is_true(cfg.height <= lines,
          string.format("seed=%d: height=%d > lines=%d", seed, cfg.height, lines))
      end
    end)
  end)

  -- ── FC25: property — centered (100 iterations) ─────────────────────────

  describe("FC25: property — window is always centered", function()
    it("100 random configs all produce centered positions", function()
      local columns = vim.o.columns
      local lines = vim.o.lines - vim.o.cmdheight

      for seed = 1, 100 do
        local rng = make_rng(seed)
        local padding = rng(0, 8)
        local cw = rng(1, 300)
        local ch = rng(1, 300)

        reset_modules()
        auditor = require("auditor")
        auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false,
          float = { padding = padding } })

        local cfg = auditor._compute_float_config(cw, ch)
        local expected_row = math.floor((lines - cfg.height) / 2)
        local expected_col = math.floor((columns - cfg.width) / 2)
        assert.equals(expected_row, cfg.row,
          string.format("seed=%d: row %d != %d", seed, cfg.row, expected_row))
        assert.equals(expected_col, cfg.col,
          string.format("seed=%d: col %d != %d", seed, cfg.col, expected_col))
      end
    end)
  end)

  -- ── FC26: config persists across mode transitions ───────────────────────

  describe("FC26: float config persists across mode transitions", function()
    it("enter/exit audit mode does not reset float opts", function()
      setup_with({ padding = 7, border = "single" })
      auditor.enter_audit_mode()
      auditor.exit_audit_mode()
      auditor.enter_audit_mode()
      assert.equals(7, auditor._float_opts.padding)
      assert.equals("single", auditor._float_opts.border)
    end)
  end)

  -- ── FC27: winblend applied ──────────────────────────────────────────────

  describe("FC27: winblend applied to actual window", function()
    it("viewer window gets configured winblend", function()
      setup_with({ win_options = { winblend = 10 } })
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input("test note")
      auditor.add_note()
      ri()

      auditor.show_note()
      assert.is_not_nil(auditor._note_float_win)
      local wb = vim.api.nvim_get_option_value("winblend", { win = auditor._note_float_win })
      assert.equals(10, wb)

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("editor window gets configured winblend", function()
      setup_with({ win_options = { winblend = 25 } })
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")
      assert.is_not_nil(auditor._note_float_win)
      local wb = vim.api.nvim_get_option_value("winblend", { win = auditor._note_float_win })
      assert.equals(25, wb)

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── FC28: border array ──────────────────────────────────────────────────

  describe("FC28: custom border array", function()
    it("border array is passed through to config", function()
      local border = { "╔", "═", "╗", "║", "╝", "═", "╚", "║" }
      setup_with({ border = border })
      local cfg = auditor._compute_float_config(40, 10)
      assert.same(border, cfg.border)
    end)
  end)

  -- ── FC29: viewer dimensions adapt to content ────────────────────────────

  describe("FC29: viewer dimensions adapt to note content", function()
    it("short note gets small window", function()
      setup_with(nil)
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local ri = stub_input("hi")
      auditor.add_note()
      ri()

      auditor.show_note()
      local config = vim.api.nvim_win_get_config(auditor._note_float_win)
      assert.is_true(config.width >= 20) -- min width for viewer
      assert.equals(1, config.height) -- single line

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("multi-line note gets taller window", function()
      setup_with(nil)
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      local ri = stub_input("line1\nline2\nline3\nline4\nline5")
      auditor.highlight_cword_buffer("red")
      auditor.add_note()
      ri()

      auditor.show_note()
      local config = vim.api.nvim_win_get_config(auditor._note_float_win)
      assert.equals(5, config.height)

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)

  -- ── FC30: editor dimensions adapt to initial text ───────────────────────

  describe("FC30: editor dimensions adapt to initial text", function()
    it("empty initial text gets min dimensions", function()
      setup_with(nil)
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)

      auditor._open_note_editor(bufnr, target_id, token, "")
      local config = vim.api.nvim_win_get_config(auditor._note_float_win)
      assert.is_true(config.width >= 40) -- min width for editor
      assert.is_true(config.height >= 3) -- min height for editor

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)

    it("long initial text gets wider window", function()
      setup_with(nil)
      local bufnr = setup_buf({ "hello world" }, 1, 0)
      auditor.highlight_cword_buffer("red")
      local token = auditor._cword_token(bufnr)
      local target_id = find_target_id(bufnr, token)
      local long_text = string.rep("x", 60)

      auditor._open_note_editor(bufnr, target_id, token, long_text)
      local config = vim.api.nvim_win_get_config(auditor._note_float_win)
      assert.is_true(config.width >= 60)

      auditor._close_note_float()
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end)
  end)
end)
