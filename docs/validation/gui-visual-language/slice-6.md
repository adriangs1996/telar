# Slice 6: command palette

Validated on 2026-09-14 on macOS/Metal (Apple Silicon, this machine, scale 2).
Branch `feat/gui-vl-palette` over `a700f512` (`feat/gui-visual-language`).

## What changed

- `telar-client` gains the `palette` prompt target (`model/command_palette.zig`,
  `CommandEntry`, `CommandMatch`, `CommandResults`). The field's first byte
  selects the list: `>` filters a static catalogue of 22 built-in actions with
  `core.score`, `@` reuses `goto_picker.collect` over the query after the
  prefix, `?` asks the suggestion engine. Text without a recognised prefix
  behaves like `@`. The controllers finish each mode exactly as the existing
  `goto` and `suggest` targets do; a chosen action runs through
  `controllers/input/actions.apply`, the same dispatch as its key binding.
- `Intent.prompt_row` submits one visible row from a pointer press
  (`name_prompts.chooseRow`: select, clamp, Enter).
- `NamePromptState.select` moves a list selection to an exact row.
- GUI: `overlays/CommandPalette.zig` paints one rounded `panel_bg` surface
  (radius 10, 1px `surface1` ring) 620 logical pixels wide anchored at 11% of
  the host height; prefix in `accent`; rows with an icon column, sans label,
  muted secondary text and a right-aligned monospace hint (the bound chord
  from the native keymap for actions, the item kind for `@`, `enter ask` /
  `enter paste` for `?`); selected row `surface0`; footer legend with the
  active prefix in the accent. `PaletteHits` is the overlay's own bounded hit
  map of 16 rows; the chrome `HitMap` is untouched.
- `input/InputHandler.action` opens the palette prefixed for `.goto_picker`
  (`@`) and `.suggest_command` (`?`), leaving copy mode first as the shared
  native action policy does. Actions reaching `action_routing.apply` from
  Lua or plugins still open the plain goto picker and suggestion modals.
- `text/ShapingCache.zig`: the hashed region is four-way set-associative
  (32 sets) with round-robin eviction. Two short workspace names (`alpha`,
  `beta`) collided in the direct-mapped table and re-shaped every frame.
- History (`/`) keeps its modal; `tools/gui_palette.py` drives the capture.

## Evidence

| Check | Result |
| --- | --- |
| macOS `zig build test` | 3,380/3,382 passed, 2 platform skips, codestyle included |
| macOS `zig build test-gui` | 186/186 passed (179 before the palette suite + 7 new) |
| macOS `zig build check-client-boundaries` | Passed |
| macOS `zig build test-gui-window` | `status=0 painted=17 delivered=13 discarded=3 inputs=10 repeats=26 pointer_inputs=8 pointer_queries=99 timer_wakes=1 fullscreen=3 failures=0` |
| macOS `tools/gui_palette.py zig-out/bin/telar /tmp/tp6` | Three distinct shell PIDs: initial, tab two, and the tab created by `>new tab` + Enter from the palette; the shell after `esc` is unchanged |

Captures: [goto](slice-6-palette-goto.png), [actions](slice-6-palette-actions.png),
[actions filtered](slice-6-palette-actions-filtered.png),
[suggest](slice-6-palette-suggest.png). The palette spans 620 logical pixels
in an 837-pixel window; the 16-row action list shows `Ctrl+b %` style chords
resolved from the effective keymap.

The unit tests in `src/gui/tests/palette.zig` check prefix switching and row
counts for the three modes, the modal height and top anchor, quads clipped to
the surface, row hits that yield `prompt_row` with the scrolled index, the
bound chord column, eight warm repaints per mode with zero shaping,
rasterizing and allocation, history not recording palette rows, and the key
path through the native router: `Ctrl-b g` opens `@`, `Ctrl-b ?` opens `?`,
`>toggle sidebar` + Enter toggles the sidebar and sends nothing to the child,
`Ctrl-b /` still opens history.

## Not verified

- Wayland: not run; the palette uses only `fillRounded`, `ring`, `fill` and
  `text`, already validated on Vulkan in slice 1.
- Labels longer than `ShapingEntry.max_bytes` (64) bypass the shaping cache
  and shape every frame; `describe` may produce up to 160 bytes for an agent
  row. This is the atlas's existing bound, not a palette allocation.
- `tools/gui_composition_latency.py`: not run (memory-constrained machine).
