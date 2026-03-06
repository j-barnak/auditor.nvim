# auditor.nvim

A Neovim plugin for code-review annotation. Enter audit mode, place your cursor on a word, and mark it with any color — solid (red, blue, custom) or per-character gradient (red→blue, custom endpoints). Colors are fully extensible. Highlights are persisted across sessions in a per-project SQLite database.

## Requirements

- Neovim 0.9+
- [kkharji/sqlite.lua](https://github.com/kkharji/sqlite.lua) and its native dependency `libsqlite3`

```sh
# Debian/Ubuntu
sudo apt install libsqlite3-dev

# macOS
brew install sqlite
```

## Installation with lazy.nvim

**Step 1 — install the system SQLite library** (if not already present):

```sh
# Debian/Ubuntu
sudo apt install libsqlite3-dev

# macOS
brew install sqlite
```

**Step 2 — add this to your Neovim config** (e.g. `~/.config/nvim/lua/plugins/auditor.lua`):

```lua
return {
  dir = "~/Projects/auditor.nvim",
  dependencies = { "kkharji/sqlite.lua" },
  config = function()
    require("auditor").setup()
  end,
}
```

The `dir` key tells lazy.nvim to load the plugin from a local path instead of GitHub. lazy.nvim will still manage its dependency (`sqlite.lua`) normally.

**Step 3 — sync** inside Neovim to install `sqlite.lua`:

```
:Lazy sync
```

**Step 4 — verify** by running `:EnterAuditMode`, placing your cursor on a word, and running `:AuditRed`. You should see a notification confirming the marked token.

### Configuration

The database is automatically scoped per project: the plugin walks up from `cwd` looking for `.git`, `Cargo.toml`, `go.mod`, `package.json`, etc., then hashes the root path to name the DB file. All highlights you save inside one project stay isolated from others.

| Option | Default | Description |
|--------|---------|-------------|
| `db_path` | auto | Override the SQLite file path |
| `keymaps` | `true` | `false` to disable all, `true` for defaults, or a table to customize (see below) |
| `colors` | built-in | Color definitions (solid or gradient); see below |
| `note_preview_len` | `30` | Max characters for the truncated note preview at end of line |
| `note_sign_icon` | `"◆"` | Sign column icon for notes (`""` to disable) |
| `note_save_keys` | `{"<C-s>", "<S-CR>"}` | Keys that save the floating note editor (both normal + insert mode) |
| `note_cancel_keys` | `{"q", "<Esc>"}` | Keys that cancel the floating note editor (normal mode only) |

#### Configuring colors

The `colors` option defines which colors are available for marking and in the color picker. Each entry is either a **solid** color or a **gradient**:

```lua
require("auditor").setup({
  colors = {
    -- Solid colors: single highlight group
    { name = "red",    label = "Red",    hl = { bg = "#CC0000", fg = "#FFFFFF", bold = true } },
    { name = "blue",   label = "Blue",   hl = { bg = "#0055CC", fg = "#FFFFFF", bold = true } },
    { name = "green",  label = "Green",  hl = { bg = "#00CC00", fg = "#FFFFFF", bold = true } },
    { name = "yellow", label = "Yellow", hl = { bg = "#CCCC00", fg = "#000000", bold = true } },

    -- Gradient colors: per-character interpolation between two endpoints
    { name = "half", label = "Gradient", gradient = { "#CC0000", "#0055CC" } },
    { name = "warm", label = "Warm",     gradient = { "#FF0000", "#FFFF00" } },
  },
})
```

Each color definition has:

| Field | Required | Description |
|-------|----------|-------------|
| `name` | yes | Internal key stored in the database (e.g. `"red"`, `"green"`) |
| `label` | yes | Display text shown in the color picker |
| `hl` | for solid | `{ bg = "#hex", fg = "#hex", bold = bool }` — highlight attributes |
| `gradient` | for gradient | `{ "#from_hex", "#to_hex" }` — per-character color interpolation |

**Defaults** (used when `colors` is not specified):

| Name | Type | Description |
|------|------|-------------|
| `red` | solid | Red highlight (`#CC0000`) |
| `blue` | solid | Blue highlight (`#0055CC`) |
| `half` | gradient | Per-character red→blue gradient |

Solid colors create a single highlight group named `Auditor<Name>` (e.g. `AuditorGreen`). Gradient colors create 16 interpolated groups named `Auditor<Name>Grad00` through `Auditor<Name>Grad15`. All custom colors work with every command (`:AuditMark` picker, save/load, undo, etc.) and are stored by name in the database, so they persist across sessions.

#### Configuring keymaps

The `keymaps` option controls which key bindings are registered. It accepts three forms:

```lua
-- 1. Use all defaults
require("auditor").setup()

-- 2. Disable all keymaps (use commands only)
require("auditor").setup({ keymaps = false })

-- 3. Customize individual bindings
require("auditor").setup({
  keymaps = {
    red = "<leader>mr",       -- override default <leader>ar
    blue = "<leader>mb",      -- override default <leader>ab
    half = false,             -- disable this specific keymap
    save = "<leader>ms",      -- override default <leader>aS

    -- Bind actions that have no default keymap
    word_red = "<leader>mwr",
    enter = "<leader>me",
    exit = "<leader>mx",
  },
})
```

Any key not specified in the table keeps its default. Set a key to `false` to disable just that binding.

**Available actions and their defaults:**

| Action | Default keymap | Description |
|--------|----------------|-------------|
| `red` | `<leader>ar` | Mark cword red |
| `blue` | `<leader>ab` | Mark cword blue |
| `half` | `<leader>ah` | Mark cword with gradient |
| `mark` | `<leader>am` | Interactive color picker |
| `save` | `<leader>aS` | Save pending highlights to database |
| `clear` | `<leader>aX` | Clear all highlights for current buffer |
| `word_red` | *none* | Mark all occurrences red (function scope) |
| `word_blue` | *none* | Mark all occurrences blue (function scope) |
| `word_half` | *none* | Mark all occurrences with gradient (function scope) |
| `word_mark` | *none* | Interactive color picker (function scope) |
| `enter` | *none* | Enter audit mode |
| `exit` | *none* | Exit audit mode |
| `toggle` | *none* | Toggle audit mode on/off |
| `undo` | *none* | Remove highlight under cursor |
| `note` | *none* | Add note to highlighted word |
| `note_edit` | *none* | Edit note on highlighted word |
| `note_delete` | *none* | Delete note from highlighted word |
| `note_show` | *none* | Show note in floating window |
| `note_menu` | `<leader>al` | Context-aware note action picker |
| `notes` | *none* | List all notes in quickfix |

## Usage

### Audit mode

All marking commands require audit mode. Enter it to show highlights and enable commands; exit to hide everything:

| Command | Description |
|---------|-------------|
| `:EnterAuditMode` | Show highlights and enable all marking/saving commands |
| `:ExitAuditMode` | Hide all highlights (database is untouched) |
| `:AuditToggle` | Toggle audit mode on/off |

### Commands

There are two families of mark commands:

- **`Audit*`** — marks only the single word under the cursor (no treesitter)
- **`AuditWord*`** — marks all occurrences of the word within the enclosing function scope (uses treesitter; falls back to entire buffer when no parser is available)

| Command | Description |
|---------|-------------|
| `:AuditRed` | Mark the word under cursor red (single cword) |
| `:AuditBlue` | Mark the word under cursor blue (single cword) |
| `:AuditHalf` | Mark the word under cursor with gradient (single cword) |
| `:AuditMark` | Interactive color picker (single cword) |
| `:AuditWordRed` | Mark all occurrences red (function scope) |
| `:AuditWordBlue` | Mark all occurrences blue (function scope) |
| `:AuditWordHalf` | Mark all occurrences with gradient (function scope) |
| `:AuditWordMark` | Interactive color picker (function scope) |
| `:AuditUndo` | Remove highlight from word under cursor (extmark + pending + DB) |
| `:AuditNote` | Add a note to the highlighted word (opens floating editor) |
| `:AuditNoteEdit` | Edit the note on the highlighted word (opens floating editor pre-filled) |
| `:AuditNoteDelete` | Delete the note from the highlighted word under cursor |
| `:AuditNoteShow` | Show the full note in a read-only floating window |
| `:AuditNoteMenu` | Context-aware note action picker (add/edit/delete/show/list) |
| `:AuditNotes` | List all notes in the current buffer in a quickfix window |
| `:AuditSave` | Save pending highlights to database |
| `:AuditClear` | Clear all highlights for the current buffer (extmarks + DB) |

### Workflow

1. `:EnterAuditMode` (or `:AuditToggle`) — show saved highlights, enable commands
2. Place cursor on a word and run `:AuditRed` / `:AuditBlue` / `:AuditHalf` — the single word is highlighted immediately
3. Use `:AuditWordRed` to mark all occurrences of that word within the enclosing function
4. Use `:AuditNote` to attach a note to a highlighted word (opens floating editor; sign icon + truncated preview shown at end of line)
5. Made a mistake? `:AuditUndo` removes the highlight on the word under your cursor (including its note)
6. `:AuditSave` — persist to SQLite (highlights and notes survive Neovim restarts)
7. `:ExitAuditMode` (or `:AuditToggle`) — hide all highlights (database is untouched)

Unsaved highlights (not yet `:AuditSave`d) survive enter/exit mode transitions but are **lost when Neovim closes**.

### Notes

Notes are virtual text annotations attached to highlighted words. Each note is indicated by a **sign column icon** (`◆` by default, colored to match the highlight) and a **truncated preview** at end of line (`  word: first line...`). For the full content, use `:AuditNoteShow` to open a scrollable floating window.

**Editing**: `:AuditNote` and `:AuditNoteEdit` open a floating editor buffer. Multi-line notes are supported. `<C-s>` or `<S-CR>` saves, `q`/`<Esc>` cancels (in normal mode). These bindings are configurable via `note_save_keys` and `note_cancel_keys` in `setup()`.

> **Note**: `<S-CR>` (Shift+Enter) requires a terminal that sends a distinct keycode. In WezTerm, add to your `wezterm.lua`:
> ```lua
> { key = "Enter", mods = "SHIFT", action = act.SendString("\x1b[13;2u") }
> ```

Notes are:

- **Not in the file** — they use Neovim virtual text and signs, so they never appear in diffs or affect the buffer content
- **Multi-line** — the floating editor supports multi-line notes; the EOL preview shows the first line with `(+N lines)` suffix
- **Persisted in the database** — saved alongside highlights with `:AuditSave`, restored when entering audit mode
- **Attached to highlights** — removing a highlight with `:AuditUndo` also removes its note; `:AuditClear` removes all notes

### Stale highlight recovery

When you edit a file outside of audit mode (or the file changes on disk), saved highlight positions may no longer match. On `:EnterAuditMode`, the plugin automatically searches ±50 lines for the original word text and applies the highlight at the closest match. A notification shows how many highlights were recovered.

### Statusline integration

Use `require("auditor").is_active()` to show audit mode status in your statusline. Example with [lualine.nvim](https://github.com/nvim-lualine/lualine.nvim):

```lua
require("lualine").setup({
  sections = {
    lualine_x = {
      {
        function() return "AUDIT" end,
        cond = function() return require("auditor").is_active() end,
        color = { fg = "#FFFFFF", bg = "#CC0000" },
      },
    },
  },
})
```

## Development

### Prerequisites

```sh
# Install luarocks (if not present)
# Debian/Ubuntu: sudo apt install luarocks
# macOS:         brew install luarocks

# Install the test runner (one-time, installs to ~/.luarocks)
luarocks install vusted --local

# Add ~/.luarocks/bin to your PATH if not already there
echo 'export PATH="$HOME/.luarocks/bin:$PATH"' >> ~/.profile
source ~/.profile
```

### Running tests

```sh
# Fetch test dependencies (clones sqlite.lua into deps/ — one-time)
make deps

# Run the full test suite
make test

# Run a single spec file while iterating
make test FILE=test/spec/ts_spec.lua
make test FILE=test/spec/audit_mode_spec.lua
```

### Linting and formatting

```sh
make lint       # luacheck
make fmt        # stylua
make fmt-check  # stylua --check (CI)
```

### Test coverage

Tests run inside a real headless Neovim process via [vusted](https://github.com/notomo/vusted), using the [busted](https://lunarmodules.github.io/busted/) framework. The suite covers:

- **`ts_spec.lua`** — token extraction: regex fallback and treesitter walk, `node_types` filters, byte offset correctness, multi-line node skipping, char/line/block mode bounds
- **`db_spec.lua`** — SQLite save/get/clear, per-file isolation, `word_index` ordering, all color values
- **`db_robustness_spec.lua`** — DB edge cases and error handling
- **`cword_spec.lua`** — word-under-cursor detection: all cursor position classes, underscore/digit handling, nil cases, real-world C code
- **`highlight_cword_spec.lua`** — `AuditRed/Blue/Half` (single cword) vs `AuditWordRed/Blue/Half` (all occurrences): exact extmark positions, duplicate words, multi-line isolation, color correctness, pending state, persistence round-trip, exhaustive cursor sweep, property-based (P1-P7), fuzz (F1-F3), `_find_word_occurrences` unit tests
- **`fuzz_spec.lua`** — property-based tests (P1-P13): token validity, ordering, non-overlap, maximality, reference comparison, cword invariants, find_word_occurrences correctness
- **`integration_spec.lua`** — full lifecycle: setup registers commands, pending queue, `:AuditSave` saves, `load_for_buffer` restores extmarks, `clear_buffer` removes DB rows and extmarks
- **`audit_mode_spec.lua`** — audit mode: state flag, command guards, highlight visibility, pending preservation, multi-buffer, simulated restart, property-based enter/exit sequences, fuzz random op interleaving, edge cases
- **`keymaps_spec.lua`** — configurable keymaps: defaults registered, disabled with `false`, overrides, individual disable, extra bindings (`word_*`, `enter`, `exit`, `toggle`, `undo`), functional tests via feedkeys, edge cases
- **`state_machine_spec.lua`** — enter/exit state machine: basic transitions, idempotency, pending across transitions, command gating, exhaustive 2^4 and 2^6 sequences, property-based (P1-P6), fuzz
- **`toggle_spec.lua`** — `AuditToggle` and `is_active()`: state transitions, extmark visibility, multi-buffer, exhaustive 3^4 and 3^5 {enter,exit,toggle} sequences, property-based (P1-P6), fuzz, edge cases
- **`undo_spec.lua`** — `AuditUndo` and `db.remove_highlight()`: DB removal, guard checks, unsaved/saved undo, multi-word isolation, multi-occurrence, mode transitions, idempotency, re-mark round-trips, property-based (P1-P6), fuzz (F1-F3), edge cases
- **`notes_spec.lua`** — virtual text notes: add/edit/delete lifecycle, DB persistence, mode transition survival, undo/clear cleanup, stale recovery with notes, list_notes quickfix, guard checks, edge cases
- **`notes_fuzz_spec.lua`** — note text fuzz: random ASCII (200 iterations), Unicode/CJK/emoji, SQL injection attempts, control characters, long strings (10K+), property-based DB round-trip/enter-exit/undo/clear/re-mark, rapid op cycles, multi-buffer isolation, nasty strings gauntlet (~43 adversarial inputs including `$(rm -rf /)`, shell injection, RTL text)
- **`stale_recovery_spec.lua`** — stale highlight recovery: line/column shifts, word deletion/rename, closest-match selection, RECOVERY_RADIUS boundary, gradient colors, note recovery, property-based random shifts (100 iterations), unit tests for recover_highlight
- **`custom_colors_spec.lua`** — custom color definitions: solid and gradient setup, highlight group creation, mark/save/load round-trip, color picker integration
- **`half_split_spec.lua`** — gradient (half) color splitting: per-character interpolation, word_index driven hl_for mapping, multi-word gradient sequences
- **`dedup_and_rewrite_spec.lua`** — dedup on re-mark, full DB rewrite, `_db_extmarks` lifecycle
- **`edit_after_mark_spec.lua`** — highlights track edits: position sync, pending sync, undo after edit
- **`robustness_spec.lua`** — buffer validity, DB error handling, setup guard, pcall wrappers
- **`stale_highlights_spec.lua`** — stale highlight detection and cleanup
- **`bounds_fuzz_spec.lua`** — boundary condition fuzzing for token positions
- **`transaction_spec.lua`** — atomic `rewrite_highlights`: rollback, stress, fuzz, error injection
- **`canonical_and_warn_spec.lua`** — filepath canonicalization, VimLeavePre warning, multi-step undo
- **`e2e_lifecycle_spec.lua`** — E2E: single/multi-buffer workflows, edit-during-audit, toggle, undo, color pickers
- **`e2e_fuzz_spec.lua`** — E2E fuzz/property: DB-extmark sync, crash resilience, multi-buffer isolation
- **`health_spec.lua`** — health check: basics, after setup, pending, without setup, active mode
- **`highlights_unit_spec.lua`** — highlights unit: `hl_for` mapping, `apply_words`/`apply_word` edges, `collect_extmarks`
- **`ts_unit_spec.lua`** — TS unit: `available()`, `enclosing_function` edges, `get_tokens` opts, regex fuzz
