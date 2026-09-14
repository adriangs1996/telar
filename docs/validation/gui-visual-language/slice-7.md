# Slice 7: chrome text sizes

Validated on 2026-09-14 on macOS/Metal (Apple Silicon, scale 2). Branch
`feat/gui-vl-sizes` over `e4deaa46` (`feat/gui-visual-language`).

## What changed

- `text/FontFace` keeps up to eight `FT_Size` objects, one per pixel height
  it has painted, and activates one per run (`FT_Activate_Size` plus
  `hb_ft_font_changed`); `FontSet.select` and `GlyphAtlas.select` are gone.
  `ShapingKey`, `ShapingEntry` and the set hash carry the pixel height, and
  the glyph key uses the run's height instead of the atlas's. `ascender`,
  `lineHeight` and `cellWidth` take a height; `lineBox(face, height)` gives
  chrome the Plex metrics. The macOS optical rasterizer selects its size on
  the cold raster path only. Nothing is cleared when a run at another
  height arrives.
- `ChromeMetrics` resolves `title` (x1.0), `body` (x0.87) and `small`
  (x0.73) of the scaled terminal size, times `gui.chrome.scale`, rounded to
  device pixels and never below 6. `body` is capped at the largest em whose
  1.3 em Plex line box fits the pane header; the bands do not move.
- `Label.size` (`terminal` default, `title`, `body`, `small`); `Canvas.text`,
  `textAt` and `measure` shape sans labels at the role's height and centre
  Plex's own line box in the row. Monospace labels keep the cell grid.
- Roles: card context and event rows, age, status glyph and elapsed time
  `small`; card title `title` SemiBold; sidebar header, workspace pills,
  tabs, pane header text and chip, palette rows and legend words, and the
  new-context form labels and footer `body`. `CardGeometry` rows are the
  role line boxes (15 + 20 + 15 at base 15) instead of 1.25 x cell.
- Lua: `gui.chrome.scale`, `0.5..2`, default 1, parsed like `gui.font.size`,
  applied on reload without rebuilding the atlas.

## Evidence

| Check | Result |
| --- | --- |
| `zig build test` | exit 0 (client 860 + new parser bounds, codestyle included) |
| `zig build test-gui` | exit 0, 215/215 (210 before this slice + `chrome_sizes.zig`, one reload test, `FontFace` sizes) |
| `zig build test-gui-window` | `status=0 painted=15 delivered=11 discarded=3 inputs=10 repeats=26 pointer_inputs=8 pointer_queries=75 timer_wakes=1 fullscreen=3 failures=0` (one earlier run reported `failures=1` in a cursor/focus check while another window held focus; a direct rerun and the build rerun both passed) |
| `zig build check-client-boundaries` | passed |
| `tools/gui_chrome_sizes.py zig-out/bin/telar /tmp/t7` | `stty size` 50x55 at base and at `gui.chrome.scale = 1.5`; same shell survived both windows |

Captures: [base multiplexer](slice-7-base-multiplexer.png),
[base new context](slice-7-base-new-context.png),
[scaled multiplexer](slice-7-scaled-multiplexer.png),
[scaled new context](slice-7-scaled-new-context.png). At base 15 (scale 2
display) the pills, tabs, sidebar header and form labels are 26 device
pixels of Plex against 30-pixel monospace cells; at `scale = 1.5` they are
32 device pixels (the 16 px body cap at scale 1), the terminal rows and
columns unchanged. The second run reused the same runtime, so it shows a
third tab.

The unit tests in `src/gui/tests/chrome_sizes.zig` check that `small`
measures narrower than `body` and `title`, that a small label paints inside
its own centred line box rather than the cell's, that a frame with the four
sizes and two weights repaints warm 60 times with zero shaping, zero
rasterization and zero allocation, that `chrome.scale = 1.5` changes the
three sizes and the card height but not `TerminalRenderer.measure`, the
bands or the cell size at display scales 1 and 2, and that FreeType's body
line box fits the pane header at scales 1, 1.5 and 2.
`tests/configuration.zig` reloads `gui.chrome.scale` and keeps the atlas
pointer, the host size and the resize count. `HitMap.capacity` is unchanged.

## Not verified

- A native capture with cards at 13/11 px: it needs a live agent; the
  sidebar unit tests paint the six-card list with the new rows.
- Linux/Wayland: not run; no shader or backend change.
- `tools/gui_composition_latency.py`: not run.

## Decisions the plan did not cover

- `body` is capped by the pane header rather than clipped: at base 15 it
  stops at 16 px (scale about 1.3); `title` and `small` keep growing (30 and
  22 px at scale 2).
- Monospace labels ignore the size role: keys, paths, the mode chip and the
  palette hints stay on the terminal grid, so the status band is unchanged.
- The provider chip text in `AgentCard.paintMark` was left monospace; the
  sprite slice replaces that drawing.
- Sized instances are bounded at eight per face with an error beyond, not
  an eviction, so a cached run never loses its `FT_Size`.
