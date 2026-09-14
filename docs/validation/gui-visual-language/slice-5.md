# Slice 5: tab strip, pane header, rings, top bar location

Validated on 2026-09-14 on macOS/Metal 4 (Apple Silicon, this machine).
Branch `feat/gui-vl-chrome` over `38c3c833` (integration branch with slices 1
and 2).

## Geometry

Chrome heights in logical pixels at the reference font size 15: top bar 38,
tab strip 32, status bar 26, pane header 22 (`ChromeMetrics`). Each scales by
`display scale × gui.font.size / 15` and rounds to device pixels. The
renderer subtracts top + strip + status from the window height before it
counts rows, and the grid origin is `(padding.x, top + strip + padding.y)`;
`PointerRouting` receives that same origin. A window shorter than one row
plus its bands drops the status bar, then the strip, then the top bar.

The pane header is the pane's border row: it is one cell tall and
`pane_header` only caps the text band inside it, so a header never covers a
terminal row. At font 15 the row is about 20 logical pixels.

## Attention aggregation

`chrome/attention.zig` resolves the agent of a pane through
`agents.keyForPane`, and the most urgent agent of a tab or workspace with
`telar-client.agent_attention.compare`. A dot appears only when that agent's
group is `needs_input` (`blocked` → `yellow`, `failed` → `red`). The pane
ring uses the same test and colour; the chip text comes from
`blocked_reason` (`permission`, `question`, `plan`, else `blocked`),
`working <age>`, `done`, `failed`, `ready`.

## Evidence

| Check | Result |
| --- | --- |
| `zig build test` | Passed (exit 0), codestyle and client boundaries included |
| `zig build test-gui` | 186/186 passed (176 at slice 1; new: 6 in `tests/visual_chrome.zig` plus the `ChromeMetrics`, `HomePrefix`, `RingFades` and `ShapingCache` unit tests) |
| `zig build test-gui-window` | `status=0 painted=16 delivered=12 discarded=3 inputs=10 repeats=26 pointer_inputs=8 pointer_queries=117 timer_wakes=1 fullscreen=3 failures=0` |
| `zig build check-client-boundaries codestyle` | Passed |
| `tools/gui_multiplexer.py zig-out/bin/telar` | Fails at `pid('right') == pid('pointer-right')`: this run's window opened 615×1424 pt, so the 42-column sidebar took 62 % of the width and the click at `x = 0.75` landed in the left pane. Every keyboard stage before it passed. |
| Same script with clicks at `x = 0.9` (scratch copy, driver unchanged) | Passed: 15 receipts, five distinct shells, fullscreen `62×47` over `30×22`, sidebar off `62×43` on `62×22`, reconnect returned the same shell and split ([records](slice-5-macos-multiplexer.json)) |

Captures from the passing run: [splits](slice-5-splits.png),
[fullscreen](slice-5-fullscreen.png), [workspace](slice-5-workspace.png),
[picker](slice-5-picker.png), [before close](slice-5-before-close.png),
[reconnected](slice-5-reconnected.png). They show the top bar with the
toggle, `1 original` / `2 renamed` pills and the mono location, the strip with
`1 main` as a rounded-top block, `2 logs` and `+`, pane headers `1 bash` with
the accent focus border, and the status bar with the `metrics` slot.

The new unit tests check that bands leave complete cells and share the
pointer origin (including the tiny-window fallback), that tab hits keep
their identities and `+` emits `create_tab` while a band gesture survives a
drag over cells, that a blocked or failed agent puts one dot on its tab and
its workspace pill and a working one puts none, that the ring and the dim
quad exist only on the unfocused blocked pane and the chip sits in its
header, that toasts cap at two and skip a visible pane, and that sixty warm
repaints with rings, chips, dots and a location label shape and allocate
nothing.

## Not verified

- No agent was run inside the validation session, so the chip, ring and
  dots are covered by unit tests only, not by a capture.
- Wayland: not run. The change is in shared chrome code over the same quad
  ABI; the Linux backend was not rebuilt here.
- `tools/gui_composition_latency.py`: not run on this memory-constrained
  machine. The interactive-path cost added is one pixel hit table lookup per
  band sample and O(tabs + workspaces + panes) label measurements per paint,
  all warm cache hits.

## Decisions the plan did not cover

- The status bar keeps painting the Lua `bottom` slots in normal mode until
  the sidebar footer slot exists; only the `tabs` slot is empty there.
- The ring fades over three animation ticks (120 ms each) while the model's
  counter runs; when nothing animates the ring appears at once rather than
  freezing partly faded.
- Rings, headers and the dim apply only when the layout has borders (two or
  more panes, or fullscreen); a single borderless pane has no header row to
  paint into.
- A worktree tab shows its name in the location because the workspace list
  replica carries no path or branch for worktrees.
- The location path glyph `▣` is served by the symbols fallback face.
