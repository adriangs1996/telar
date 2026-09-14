# Procedural block elements

Capture of `tools/gui_block_elements.py` on macOS with the bundled JetBrains
Mono at size 15 and `line_height = 1.15`, the values of `examples/gui.lua`.
The fixture prints the Claude Code mascot, the halves and eighths, the ten
quadrant sets, the three shades and the complete U+2580 through U+259F rows
from a `/bin/sh` child. Both images crop the pane at device resolution.

- `block-elements-before.png`: font bitmaps from JetBrains Mono. The em box is
  shorter than the cell, so every row leaves a gap below its blocks, the
  shades break between rows, and the mascot's body, arms and legs separate.
- `block-elements-after.png`: procedural rectangles measured from the cell.
  Halves, eighths and quadrants meet at cell edges, the shades blend evenly
  across adjacent cells, and the mascot is one contiguous shape.

Commands:

```sh
zig build
python3 tools/gui_block_elements.py zig-out/bin/telar /tmp/tb2
```

`zig build test`, `zig build test-gui`, `zig build test-gui-window` and
`zig build check-client-boundaries` passed on the same tree.
