# Slice 4: sidebar and card

Validated on 2026-09-14 on macOS/Metal (Apple Silicon, this machine). Branch
`feat/gui-vl-sidebar` over `38c3c833` (slices 1 and 2 merged).

## What changed

- `Canvas` gained `fillAt`, `fillRoundedAt`, `ringAt` and `textAt` over
  device-pixel rectangles; the cell primitives delegate to them. `textAt`
  centers the natural line box in a row of any height. `Label.alpha`
  multiplies the ink.
- `Sidebar.zig` and `AgentCard.zig` were rewritten: header `agents` with
  `N · M need you`, one list ordered by `agent_attention.lessThan` into a
  fixed index array re-sorted only when the snapshot identity changes, and
  the three-row card of the plan with `fillRounded` (radius 8) and an inner
  1px ring for the selected card. Geometry, degradation, age formatting,
  status glyphs and the ellipsis fit live in their own files under
  `src/gui/chrome/`.
- `GuiClient.prepare` stamps monotonic seconds on `Chrome.now_s`; the card
  age is `status_age_s` plus the seconds since the snapshot was first painted.
- The provider mark is a rounded chip with the provider glyph: the glyph atlas
  holds alpha only, so the RGBA provider artwork cannot enter it yet.
- `AgentCard.project_icon` is the hook for the favicon atlas index; while
  `null` the generic `▣` glyph is drawn.

## Evidence

| Check | Result |
| --- | --- |
| macOS `zig build test` | 3,360/3,362 passed, 2 platform skips, codestyle included |
| macOS `zig build test-gui` | 188/188 passed (176 before this slice + 12 new) |
| macOS `zig build check-client-boundaries` | Passed |
| macOS `tools/gui_lifecycle.py --config examples/gui.lua --capture` | Shell survived, input delivered, PTY `57x96` to `12x27` complete cells ([result](slice-4-macos-lifecycle.json), [capture](slice-4-macos-header.png)) |

The capture shows the new header (`agents`, `0 · 0 need you`) and `No active
agents` in Plex Sans beside monospace cells. No agent runs during the
lifecycle script, so the cards themselves are proven by
`src/gui/tests/sidebar_cards.zig`: six agents across the four groups paint in
the comparator's order with one hit per card, the selected card is the
focused pane's agent at the computed pixel position with one rounded fill
and one ring, hovering another card adds a second rounded fill, tokens leave
from the right through the four degradation levels with strictly fewer quads
at each, the working glyph reaches alpha 0.35 at frame 9, the snapshot
arrival is retained until the revision changes, thirty warm repaints across
animation frames and clock ticks allocate nothing and rasterize nothing, and
`HitMap.capacity` is unchanged.

## Not verified

- A native capture with cards: it needs a real agent in a pane. The unit
  paint test stands in for it.
- Linux/Wayland: not run on this machine in this slice; the slice adds no
  backend or shader change, only quads the slice-1 path already draws.
- `tools/gui_composition_latency.py`: not run (one build at a time on a
  memory-constrained machine).

## Findings

- `ShapingCache` is direct-mapped with 128 hashed slots and 64-byte,
  32-glyph entries. Two card labels that hash to the same slot re-shape every
  frame (`now` and ` now` did, which is why the status glyph and the elapsed
  time are separate labels), and a title longer than 32 glyphs bypasses the
  cache. Neither allocates on the Zig heap, so the warm-repaint tests hold,
  but a set-associative cache would remove the repeated HarfBuzz work.
- The atlas selects one pixel height for every face, so the 11px context
  rows of the plan keep the terminal glyph size and differ by color only.
