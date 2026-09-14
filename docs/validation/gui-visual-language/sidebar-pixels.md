# Sidebar band: the sidebar in pixels

Validated on 2026-09-14 on macOS/Metal 4 (Apple Silicon, this machine).
Branch `feat/gui-pixel-sidebar` over `ba5311e3` (main after the sidebar
edge and padding commits).

## What changed

- The sidebar is a band of device pixels (`chrome/SidebarBand.zig`)
  resolved by `TerminalRenderer.measure` from the shared visibility and the
  window's width preference: `gui.sidebar.width` logical px (default 284,
  220..480) scaled and rounded, an 8 px gap, clamped to leave the workbench
  20 columns after the gap and the right padding, hidden when the window
  cannot hold the narrowest band. The grid and the pointer origin start
  after it; `Regions` no longer splits a column and the runtime-retained
  column preference is TUI-only.
- `Bands` carries the sidebar band; the tab strip shoulder and the top bar
  toggle follow it. `Sidebar` paints the header, cards, scrollbar, footer
  slot row (`SlotRow.paintIn`), edge line and a 6 px resize handle in
  pixels, with every card and the handle in `BandHitMap` (capacity grew by
  the 64 cards and the handle; `HitMap.capacity` is unchanged).
- Drag: a band press on the handle turns drags and the release into a
  `BandCommand.sidebar_width` that `GuiClient.adoptSidebarWidth` clamps into
  `SidebarPreference`. Keyboard: `resize_sidebar` steps 16 logical px in
  `input/InputHandler.zig`. Reload: a changed `gui.sidebar.width` replaces
  the preference in `ConfigurationReload.apply`. The wheel over the band
  scrolls one card pitch through the band path.

## Evidence

| Check | Result |
| --- | --- |
| `zig build test` | exit 0; `3383/3385 tests passed (2 skipped)`, codestyle and boundary checks included |
| `zig build test-gui` | exit 0; 263/263 (new: `tests/sidebar_band.zig`, `SidebarBand`, `SidebarPreference` unit tests) |
| `zig build test-gui-window` | `status=0 painted=16 delivered=12 discarded=3 inputs=10 repeats=26 pointer_inputs=8 pointer_queries=53 timer_wakes=1 fullscreen=3 failures=0` |
| `zig build check-client-boundaries` | passed |
| `tools/gui_multiplexer.py zig-out/bin/telar /tmp/pxsb` | passed: 15 receipts, five shells, fullscreen and reconnect; the focused left pane records `64×67` with the sidebar off and `64×51` with it on, 16 columns of a half-width pane, that is 32 columns of about 18 px at the 2x display for the 292 logical px of band and gap ([records](sidebar-pixels-macos-multiplexer.json), [splits](sidebar-pixels-splits.png)) |
| `tools/gui_sprites.py zig-out/bin/telar /tmp/pxsp` | three stand-in agents in three splits: the cards, the header `agents · 3 · 0 need you`, the sheet marks, the selected card, the footer `CPU / MEM` slots and the edge line all sit inside the band, the tab strip starts after the gap ([capture](sidebar-pixels-cards.png)) |

The unit tests check the band at scale 1 and 2, clamping at 220 and 480
and against twenty workbench columns, columns shrinking by the band and
gap while rows stay, a card press focusing its agent and a gap press
hitting nothing, a drag setting the exact width and the grid following,
the keyboard step leaving the shared width alone, hiding returning the
pixels to the grid, a reload applying a new width without changing the
rows, the footer slots painting in the band and warm repaints with six
cards shaping and allocating nothing.

## Not verified

- Wayland: not run. The change is in shared chrome and renderer code over
  the same quad ABI.
- `tools/gui_composition_latency.py`: not run on this memory-constrained
  machine. The interactive path gained one `SidebarBand.resolve` per
  measurement (a handful of integer operations) and one more band in the
  pointer's band test.
- The favicon in the sprite capture: the first card shows the generic glyph
  in this run; the favicon path is unchanged by this branch and covered by
  the slice 8 tests.
- A real drag with the mouse on the native window: covered by the band
  pointer tests through `Chrome.bandPointer` and `PointerRouting`, not by
  a scripted pointer drag.

## Decisions not covered by the plan

- The band and its gap replace the left window padding while visible; the
  right padding stays and counts against the room the band may take.
- The band spans from under the tab strip to the status bar, so the strip's
  shoulder covers the band and the gap.
- A reload that leaves `gui.sidebar.width` unchanged keeps a width chosen by
  drag or keyboard; only a changed value replaces it. There is no per-window
  preference store: `WindowIdentity` holds no data, so the width is
  config-only.
- The footer row is one terminal cell tall (the slots paint in lent cells)
  and appears once the band is five cell rows tall, as the cell footer did.
