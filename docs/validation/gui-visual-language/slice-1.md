# Slice 1: rounded quads and chrome face

Validated on 2026-09-14 on macOS/Metal 4 (Apple Silicon, this machine) and the
Fedora aarch64/Sway VM with Mesa llvmpipe Vulkan (`tools/vm`). Branch
`feat/gui-vl-render` over `4472c4f9`.

## What changed

- `render/Quad.zig` grew from 48 to 80 bytes: rect, uv, fill color, shape
  (radius, border, two reserved zeros) and border color. `native/telar_gui.h`,
  `linux/shaders.c` static asserts, both native window tests and the three
  shaders mirror it. The fragment shaders branch on zero shape to the previous
  textured formula; otherwise they resolve a rounded rectangle with an inner
  border band by signed distance.
- `Canvas.fillRounded` and `Canvas.ring` emit one shaped quad each.
- IBM Plex Sans Regular and SemiBold (`@ibm/plex-sans@1.1.0`, OFL) are the
  fourth and fifth faces of `FontSet`. `Label.face = .sans` shapes a label as
  one proportional HarfBuzz run; `bold` selects the SemiBold file.
  `Canvas.measure` returns the pixel width. Shaping-cache keys include the
  requested face. Terminal cells keep `.primary` and never reach the sans faces.
- The sidebar placeholder header is the one shipped chrome label set in the
  sans face, so a native capture shows it on both backends.

## Evidence

| Check | Result |
| --- | --- |
| macOS `zig build test` | 3,343/3,345 passed, 2 platform skips, codestyle and client boundaries included |
| macOS `zig build test-gui` | 176/176 passed (170 before this slice + 6 new) |
| macOS `zig build test-gui-window` | 4 runs on this tree: `failures=2` once immediately after the first shader build, then `failures=0` three times (`painted=16 delivered=12`, `16/12`, `14/10`); baseline `4472c4f9` once with `failures=0`. The failing run tripped the one-second burst/idle timing checks, not the shader or ABI. |
| macOS `zig build check-client-boundaries` | Passed |
| Linux `zig build test-gui` | 175/176 passed, one macOS-only skip |
| Linux `zig build test-gui-window` with `VK_LAYER_KHRONOS_validation` and `VK_LAYER_VALIDATE_SYNC=1` | `status=0 painted=15 delivered=13 retries=2 failures=0`; rejected-scene cleanup passed; no validation output |
| Linux `zig build check-client-boundaries codestyle` | Passed |
| Wayland matrix `tools/vm/gui-multiplexer-test.py --mode both` | Both matrices passed: 7 stages and 41 shell receipts each, Vulkan core and synchronization validation clean ([default](linux-multiplexer-default.json), [configured](linux-multiplexer-configured.json)) |
| macOS `tools/gui_lifecycle.py --config examples/gui.lua --capture` | Shell survived, input delivered, PTY `89x167` to `12x27` complete cells ([result](macos-lifecycle.json), [capture](macos-sans-header.png)) |
| Wayland `tools/vm/vm.py gui-smoke` | Window opened and closed cleanly ([capture](linux-sans-header.png)) |

Both captures show `minions` in Plex Sans SemiBold beside monospace cells.
The native window tests draw a plain quad, an 8 px rounded card and a 2 px
rounded ring through each backend; the Metal and Vulkan runs above are the
proof that both fragment paths compile and present without errors.

The new unit tests in `src/gui/tests/visual_language.zig` check that a plain
fill equals `pushRect` field for field with zero shape, that `fillRounded` and
`ring` carry radius, border and border color on one quad, that a sans label
measures a width that is not a cell multiple and clips inside its area, that
bold sans selects `IBMPlexSans-SmBld` with no synthetic-bold atlas key, that
`fonts.source` never picks the sans faces for `.primary` requests and equal
glyph indices do not alias, and that 120 warm sans repaints shape, rasterize
and allocate nothing.

## Not verified

- Pixel comparison of the rounded-quad SDF between Metal and Vulkan: neither
  window test reads pixels back. The analytic path is identical in both
  shaders; parity is by construction, not by image diff.
- `tools/gui_composition_latency.py`: not run. It needs a baseline binary
  built from `main` next to the candidate and three rounds of GUI launches;
  on this memory-constrained machine with one build at a time it was left
  out. The interactive-path cost of this slice is the 80-byte quad copy per
  frame and one uniform branch per fragment.
- Sans labels at a chrome size different from the terminal size: the atlas
  selects one pixel height for every face, so this slice keeps the terminal
  size for sans labels. A second size is a later slice concern.
