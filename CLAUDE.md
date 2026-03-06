# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this plugin does

`auditor.nvim` is a Neovim plugin for code review. Enter audit mode, place your cursor on a word, and mark it with any color: solid (red, blue, custom) or per-character gradient (red→blue, custom endpoints). Colors are fully extensible via `setup({ colors = {...} })`. Highlights persist across sessions in a per-project SQLite database and are restored when entering audit mode.

## Commands

```sh
make deps          # clone sqlite.lua into deps/ (one-time)
make test          # run full test suite via vusted
make test FILE=test/spec/ts_spec.lua  # run a single spec
make lint          # run luacheck
make fmt           # format with stylua
```

`vusted` must be installed first: `luarocks install vusted`

## Architecture

```
lua/auditor/
  init.lua       – Public API: setup(), enter/exit/toggle_audit_mode(),
                   highlight_cword_buffer(), highlight_cword(), undo_at_cursor(),
                   audit(), clear_buffer(), pick_color(), is_active(),
                   add_note(), delete_note(), recover_highlight()
  db.lua         – SQLite via sqlite.lua; per-project DB at stdpath("data")/auditor/<sha256-of-root>.db
  ts.lua         – Token extraction: treesitter leaf-node walk with %w_ regex fallback;
                   enclosing_function() for function-scope detection
  highlights.lua – Extmarks in namespace "auditor"; extensible color registry (solid + gradient);
                   note_ns for virtual text notes (separate namespace, no diff impact)
  health.lua     – :checkhealth auditor

test/
  minimal_init.lua              – Adds plugin + deps/sqlite.lua to rtp for vusted
  spec/ts_spec.lua              – Token extraction: regex fallback, treesitter walk, node_types
  spec/db_spec.lua              – SQLite save/get/clear, per-file isolation
  spec/db_robustness_spec.lua   – DB edge cases and error handling
  spec/cword_spec.lua           – Word-under-cursor detection
  spec/highlight_cword_spec.lua – AuditRed/Blue/Half, AuditWordRed/Blue/Half, property-based, fuzz
  spec/fuzz_spec.lua            – Property-based tests for token extraction and cword
  spec/integration_spec.lua     – Full lifecycle: setup → highlight → save → reload → clear
  spec/audit_mode_spec.lua      – Audit mode: state, guards, visibility, pending, multi-buffer
  spec/keymaps_spec.lua         – Configurable keymaps: defaults, disabled, overrides, functional
  spec/state_machine_spec.lua   – Enter/exit state machine: transitions, exhaustive sequences, fuzz
  spec/dedup_and_rewrite_spec.lua – Dedup on re-mark, full DB rewrite, _db_extmarks lifecycle
  spec/edit_after_mark_spec.lua   – Highlights track edits: position sync, pending sync, undo after edit
  spec/toggle_spec.lua            – Toggle audit mode state transitions
  spec/undo_spec.lua              – Undo at cursor: pending, DB-backed, after edits, edge cases
  spec/robustness_spec.lua        – Buffer validity, DB error handling, setup guard, pcall wrappers
  spec/stale_highlights_spec.lua  – Stale highlight detection and cleanup
  spec/bounds_fuzz_spec.lua       – Boundary condition fuzzing for token positions
  spec/transaction_spec.lua       – Atomic rewrite_highlights: rollback, stress, fuzz, error injection
  spec/canonical_and_warn_spec.lua – Filepath canonicalization, VimLeavePre warning, multi-step undo
  spec/e2e_lifecycle_spec.lua     – E2E: single/multi-buffer workflows, edit-during-audit, toggle, undo, color pickers
  spec/e2e_fuzz_spec.lua          – E2E fuzz/property: DB-extmark sync, crash resilience, multi-buffer isolation
  spec/health_spec.lua            – Health check: basics, after setup, pending, without setup, active mode
  spec/highlights_unit_spec.lua   – Highlights unit: hl_for mapping, apply_words/apply_word edges, collect_extmarks
  spec/ts_unit_spec.lua           – TS unit: available(), enclosing_function edges, get_tokens opts, regex fuzz
  spec/half_split_spec.lua        – Per-character gradient: red→blue, pairs, DB round-trip
  spec/custom_colors_spec.lua     – Extensible color system: custom solid/gradient, picker, E2E, property, fuzz
  spec/notes_spec.lua             – Virtual text notes: add/edit/delete, persist, mode transitions, undo/clear, stale recovery
  spec/notes_fuzz_spec.lua        – Note text fuzz: random ASCII, Unicode, SQL injection, control chars, nasty strings gauntlet
  spec/notes_display_spec.lua     – Note display: underline extmarks, sign indicators, floating viewer
  spec/notes_editor_spec.lua      – Floating note editor: create, pre-fill, save, cancel, multi-line, rapid cycles
  spec/notes_display_fuzz_spec.lua – Note display fuzz: format_note_preview fuzz, float lifecycle, nasty strings, property-based
  spec/notes_save_and_scale_spec.lua – Note save keymaps, configurable keys, many-notes scaling, DB round-trip, fuzz
  spec/stale_recovery_spec.lua    – Stale highlight recovery: line/col shifts, word boundaries, property-based, notes
  spec/notes_e2e_spec.lua         – Notes E2E: exhaustive state machine (S0–S9), float editor/viewer lifecycle, CRUD cycles, multi-buffer, toggle, undo/clear/re-mark, multi-line, DB round-trips, pick_note_action, buffer content invariants
  spec/notes_underline_spec.lua   – Note underline indicator: hl_group, word-range spans, sign colors, same-line multi-note, positions, priority, lifecycle, rapid add/delete, stopinsert
```

## Audit mode

All marking/saving/clearing commands require audit mode to be active. This is the core workflow:

1. `:EnterAuditMode` — sets `_audit_mode = true`, restores highlights from DB + pending for all loaded buffers (with stale recovery)
2. Cursor on word → `:AuditRed`/`:AuditBlue`/`:AuditHalf` (single cword) or `:AuditWordRed` etc. (function scope)
3. `:AuditNote` — open floating editor to add note to highlighted word (stored in DB, never in file)
   `:AuditNoteShow` — open read-only floating window to view full note
4. `:AuditSave` — flushes `_pending` to SQLite via `db.rewrite_highlights` (includes notes)
5. `:AuditUndo` — removes highlight on word under cursor (extmark + pending + DB + note)
6. `:ExitAuditMode` — clears extmarks from all buffers (DB and pending are untouched)

`:AuditToggle` combines enter/exit into a single command.

## Data flow

1. `:EnterAuditMode` — enables commands, restores DB highlights + pending extmarks
2. Cursor on word → `:AuditRed`/`:AuditBlue`/`:AuditHalf`
3. `init.highlight_cword_buffer` → `cword_token` (regex word-boundary detection)
4. Token stored in `M._pending[bufnr]` and applied as extmark immediately
5. For `:AuditWordRed` etc.: `init.highlight_cword` → `ts.enclosing_function` for scope → `find_word_occurrences`
6. `:AuditSave` flushes `_pending` to SQLite via `db.save_words`
7. On `BufReadPost` (if in audit mode), `db.get_highlights` reloads and re-applies extmarks
8. `:ExitAuditMode` — clears all extmarks (DB untouched, pending preserved)

## Key details

- **Audit mode gate**: `_audit_mode` boolean guards `highlight_cword_buffer`, `highlight_cword`, `audit`, `clear_buffer`, `pick_color`, `pick_cword_color`, `undo_at_cursor`, `add_note`, `delete_note`, `show_note`. Commands notify and return early when not in audit mode.
- **`is_active()`**: Returns `_audit_mode` for statusline integration (e.g. lualine).
- **Per-project scoping**: `db.lua` walks up from `cwd` to find `.git`/`Cargo.toml`/etc., hashes the root path to name the DB file. Pass `db_path` to `setup()` to override.
- **Treesitter vs regex**: `ts.lua` tries `vim.treesitter.get_parser`; falls back to `%w_` regex when no parser is loaded. All token positions are 0-indexed byte offsets `{line, col_start, col_end}`.
- **Extensible colors**: `setup({ colors = {...} })` accepts `AuditorColorDef[]`. Each entry has `name`, `label`, and either `hl = { bg, fg, bold }` (solid) or `gradient = { from_hex, to_hex }` (per-character gradient). Defaults: red (solid), blue (solid), half (gradient red→blue). Custom solid colors create `Auditor<Name>` hl groups; custom gradients create `Auditor<Name>Grad00..15`. The built-in "half" gradient uses `AuditorGrad00..15` for backward compat.
- **Gradient rendering**: Per-character extmarks with primary (full word, priority 100) + per-character overlays (priority 101). Tracked in `_half_pairs[bufnr][primary_id] = {sec_ids}`. `collect_extmarks` skips secondaries.
- **Highlight groups**: Dynamically created by `highlights.setup()` from color definitions. Default: `AuditorRed`, `AuditorBlue`, `AuditorGrad00..15`.
- **sqlite.lua API used**: `tbl:get({ where={...} })`, `tbl:insert({...})`, `tbl:remove({ key=val })`.
- **Pending preservation**: pending survives enter/exit cycles but is lost on Neovim restart. Only `:AuditSave` makes highlights persistent.
- **Configurable keymaps**: `setup({ keymaps = ... })` — `false` disables all, `true`/nil for defaults, table to override individual bindings. See README for full action table.
- **Note display**: Notes are indicated by a subtle underline on the highlighted word (`AuditorNote` hl group: `underline = true, sp = "#888888"`, priority 200) + sign column icon (configurable, default `◆`) tinted per-color. Full notes viewable in read-only floating window (`:AuditNoteShow`). Editing uses a floating scratch buffer. Save keys: `_note_save_keys` (default `{"<C-s>", "<S-CR>"}`), cancel keys: `_note_cancel_keys` (default `{"q", "<Esc>"}`). Both configurable via `setup({ note_save_keys = ..., note_cancel_keys = ... })`. Save keys bind in n+i modes, cancel keys in n only. `_note_input_override` flag makes `add_note`/`edit_note` fall back to `vim.ui.input` (for tests). `note_sign_hl()` is a pure function on `highlights` module.
- **Note internals**: `_notes[bufnr][extmark_id] = text` during audit mode. On exit, saved to `_saved_notes[bufnr]["line:col_start:col_end"] = text` for position-keyed persistence across mode transitions. Notes are stored in DB `note` column. Note underlines are rendered as word-range extmarks in `note_ns` (separate namespace, never affects diffs). `apply_note(bufnr, line, col_start, col_end, text, color, word_text)` creates the underline extmark. `_note_float_win`/`_note_float_buf` track the current floating window.
- **Stale highlight recovery**: `word_text` stored in DB alongside positions. On `load_for_buffer`, if text at stored position doesn't match, `recover_highlight()` searches ±50 lines for a whole-word match and picks closest. Notification shown when highlights are recovered.
- **Color picker**: `M._colors` (picker entries) are built from color defs during `setup()`. Each entry has `{ label, color }` where `color` is the internal name. `pick_color()` and `pick_cword_color()` use `vim.ui.select` on this list.
