-- test/spec/health_spec.lua
-- Tests for lua/auditor/health.lua (:checkhealth auditor)

local function reset_modules()
  for _, m in ipairs({ "auditor", "auditor.init", "auditor.db", "auditor.highlights", "auditor.ts" }) do
    package.loaded[m] = nil
  end
end

-- Capture all vim.health.* calls
local function capture_health()
  local calls = {}
  local orig = {
    start = vim.health.start,
    ok = vim.health.ok,
    warn = vim.health.warn,
    error = vim.health.error,
    info = vim.health.info,
  }

  vim.health.start = function(name)
    table.insert(calls, { type = "start", msg = name })
  end
  vim.health.ok = function(msg)
    table.insert(calls, { type = "ok", msg = msg })
  end
  vim.health.warn = function(msg, advice)
    table.insert(calls, { type = "warn", msg = msg, advice = advice })
  end
  vim.health.error = function(msg, advice)
    table.insert(calls, { type = "error", msg = msg, advice = advice })
  end
  vim.health.info = function(msg)
    table.insert(calls, { type = "info", msg = msg })
  end

  return function()
    for k, v in pairs(orig) do
      vim.health[k] = v
    end
  end, calls
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- Health check basics
-- ═══════════════════════════════════════════════════════════════════════════════

describe("health.check", function()
  it("runs without error", function()
    reset_modules()
    local health = require("auditor.health")
    local restore, calls = capture_health()
    health.check()
    restore()

    -- Should have at least the start call
    assert.is_true(#calls > 0)
    assert.equals("start", calls[1].type)
    assert.equals("auditor.nvim", calls[1].msg)
  end)

  it("reports Neovim version ok on 0.9+", function()
    reset_modules()
    local health = require("auditor.health")
    local restore, calls = capture_health()
    health.check()
    restore()

    local found = false
    for _, c in ipairs(calls) do
      if c.type == "ok" and c.msg:match("Neovim >= 0.9") then
        found = true
      end
    end
    assert.is_true(found)
  end)

  it("reports sqlite.lua installed", function()
    reset_modules()
    local health = require("auditor.health")
    local restore, calls = capture_health()
    health.check()
    restore()

    local found = false
    for _, c in ipairs(calls) do
      if c.type == "ok" and c.msg:match("sqlite.lua is installed") then
        found = true
      end
    end
    assert.is_true(found)
  end)

  it("checks libsqlite3 functionality", function()
    reset_modules()
    local health = require("auditor.health")
    local restore, calls = capture_health()
    health.check()
    restore()

    -- Should report either ok or error about libsqlite3
    local found = false
    for _, c in ipairs(calls) do
      if c.msg and c.msg:match("libsqlite3") then
        found = true
        assert.is_true(c.type == "ok" or c.type == "error")
      end
    end
    assert.is_true(found)
  end)

  it("reports treesitter availability", function()
    reset_modules()
    local health = require("auditor.health")
    local restore, calls = capture_health()
    health.check()
    restore()

    local found = false
    for _, c in ipairs(calls) do
      if c.msg and c.msg:match("treesitter") then
        found = true
      end
    end
    assert.is_true(found)
  end)

  it("reports data directory info", function()
    reset_modules()
    local health = require("auditor.health")
    local restore, calls = capture_health()
    health.check()
    restore()

    local found = false
    for _, c in ipairs(calls) do
      if c.msg and (c.msg:match("Data directory") or c.msg:match("data directory")) then
        found = true
      end
    end
    assert.is_true(found)
  end)

  it("reports DB info at end", function()
    reset_modules()
    local health = require("auditor.health")
    local restore, calls = capture_health()
    health.check()
    restore()

    local found = false
    for _, c in ipairs(calls) do
      if c.msg and c.msg:match("Databases are stored") then
        found = true
      end
    end
    assert.is_true(found)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Health check with setup done
-- ═══════════════════════════════════════════════════════════════════════════════

describe("health.check after setup", function()
  before_each(function()
    reset_modules()
    local auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
  end)

  it("reports setup() has been called", function()
    package.loaded["auditor.health"] = nil
    local health = require("auditor.health")
    local restore, calls = capture_health()
    health.check()
    restore()

    local found = false
    for _, c in ipairs(calls) do
      if c.type == "ok" and c.msg:match("setup%(%) has been called") then
        found = true
      end
    end
    assert.is_true(found)
  end)

  it("reports audit mode status", function()
    package.loaded["auditor.health"] = nil
    local health = require("auditor.health")
    local restore, calls = capture_health()
    health.check()
    restore()

    local found = false
    for _, c in ipairs(calls) do
      if c.msg and c.msg:match("Audit mode is") then
        found = true
      end
    end
    assert.is_true(found)
  end)

  it("reports DB file info", function()
    package.loaded["auditor.health"] = nil
    local health = require("auditor.health")
    local restore, calls = capture_health()
    health.check()
    restore()

    local found = false
    for _, c in ipairs(calls) do
      if c.msg and c.msg:match("DB file") then
        found = true
      end
    end
    assert.is_true(found)
  end)

  it("reports no pending when none exist", function()
    package.loaded["auditor.health"] = nil
    local health = require("auditor.health")
    local restore, calls = capture_health()
    health.check()
    restore()

    local found = false
    for _, c in ipairs(calls) do
      if c.type == "ok" and c.msg:match("No unsaved pending") then
        found = true
      end
    end
    assert.is_true(found)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Health check with pending highlights
-- ═══════════════════════════════════════════════════════════════════════════════

describe("health.check with pending", function()
  it("warns about unsaved pending highlights", function()
    reset_modules()
    local auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, vim.fn.tempname() .. ".lua")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello world" })
    vim.api.nvim_set_current_buf(bufnr)

    auditor.enter_audit_mode()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    auditor.highlight_cword_buffer("red")

    package.loaded["auditor.health"] = nil
    local health = require("auditor.health")
    local restore, calls = capture_health()
    health.check()
    restore()

    local found = false
    for _, c in ipairs(calls) do
      if c.type == "warn" and c.msg:match("pending highlight") then
        found = true
      end
    end
    assert.is_true(found)

    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Health check without setup
-- ═══════════════════════════════════════════════════════════════════════════════

describe("health.check without setup", function()
  it("warns that setup hasn't been called", function()
    reset_modules()
    vim.g.auditor_setup_done = nil

    local health = require("auditor.health")
    local restore, calls = capture_health()
    health.check()
    restore()

    local found = false
    for _, c in ipairs(calls) do
      if c.type == "warn" and c.msg:match("setup%(%) has not been called") then
        found = true
      end
    end
    assert.is_true(found)
  end)
end)

-- ═══════════════════════════════════════════════════════════════════════════════
-- Health check with audit mode active
-- ═══════════════════════════════════════════════════════════════════════════════

describe("health.check with audit mode active", function()
  it("reports audit mode is ACTIVE", function()
    reset_modules()
    local auditor = require("auditor")
    auditor.setup({ db_path = vim.fn.tempname() .. ".db", keymaps = false })
    auditor.enter_audit_mode()

    package.loaded["auditor.health"] = nil
    local health = require("auditor.health")
    local restore, calls = capture_health()
    health.check()
    restore()

    local found = false
    for _, c in ipairs(calls) do
      if c.type == "ok" and c.msg:match("ACTIVE") then
        found = true
      end
    end
    assert.is_true(found)
  end)
end)
