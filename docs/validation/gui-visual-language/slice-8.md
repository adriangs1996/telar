# Slice 8: sprites, provider marks and favicons

Validated on 2026-09-14 on macOS/Metal 4 (Apple Silicon, this machine).
Branch `feat/gui-vl-sprites` over `e4deaa46` (slices 1 to 6 merged). The
Fedora aarch64/Sway VM compiled the Vulkan backend and the GLSL shaders but
its window test did not run (see below).

## What changed

- `render/Quad`'s first reserved shape component is the texture selector:
  zero samples the alpha atlas as coverage as before, one samples a 512²
  premultiplied RGBA8 sprite page with linear filtering, divided back to
  straight alpha for the blend state. `native/telar_gui.h`, `linux/shaders.c`
  asserts, both native window tests and the three shaders mirror it.
  `telar_gui_frame` and `native.Frame` carry the page pointer, side and
  version beside the atlas.
- Metal binds the page at texture index 1 and Vulkan at descriptor binding 2
  with a second, linear sampler; each uploads once per version through its
  own staging path, and the atlas stands in until a page arrives.
- `image/SpritePage` box-filters the embedded provider sheet into cells of
  16 logical pixels at the display scale (8..48 texels) and keeps room for at
  most 64 favicons; `TerminalRenderer` builds it with the atlas and `seal`
  advances `sprites_version` only when a cell was written.
  `Canvas.spriteAt` draws one cell; `AgentCard` draws Claude, Codex and Pi
  from the sheet and keeps the glyph chip for other providers; the favicon
  takes the project slot through `project_icon`.
- `image/png` decodes 8-bit non-interlaced RGB, RGBA and palette files
  through `std.compress.flate` into an exact scanline buffer under
  `PngLimits` (4096 px a side, 1 Mi pixels); `image/box_filter` area-averages
  into the cell.
- telar-client gains the favicon job, completion, runner port, the bounded
  `favicon_lookup` (`favicon.png` then `.telar/icon.png`, regular files up to
  256 KiB) and a controller keeping one lookup in flight. The GUI binds the
  runner, runs the job on an inbox task, and `chrome/Favicons` places the
  landed image at the next preparation and starts the next lookup.

## Evidence

| Check | Result |
| --- | --- |
| macOS `zig build test-gui` | exit 0 on every run after each commit; the run before the favicon tests reported `218 pass` of 221 with the three PNG encoder crashes that were fixed in the same commit |
| macOS `zig build test` | exit 0; the client binary reports `All 605 tests passed`, the runtime binary `1086 passed; 1 skipped; 0 failed` (Linux proc metrics), boundary checks passed |
| macOS `zig build test-gui-window` | `failures=3` once immediately after the shader build (the one-second burst/idle timing checks, as in slice 1), then `status=0 painted=16 delivered=12 discarded=3 ... failures=0` |
| macOS `zig build check-client-boundaries` | passed |
| macOS `zig build codestyle` | passed |
| Linux `zig build test-gui-window` with `VK_LAYER_KHRONOS_validation` and `VK_LAYER_VALIDATE_SYNC=1` | not completed: the tree was synced to a separate guest directory over plain ssh so as not to clobber a sibling agent's `~/src/telar`; the backend, `shaders.c` asserts and both GLSL shaders compiled with glslc, but the session had no `WAYLAND_DISPLAY` and the test exited with `status=-1 painted=0` before opening a window. Rerun with `tools/vm/vm.py test test-gui-window` once the VM is free |
| Linux `zig build test-gui` | compiled; the run reported a failed test binary whose output was not captured by the ssh wrapper. Not verified |
| macOS `tools/gui_sprites.py zig-out/bin/telar /tmp/telar-s8` | Three compiled stand-in agents named `claude`, `codex` and `pi` printing once a second in three splits, a generated `favicon.png` (orange disc on transparency) in the workspace root: the sidebar shows the three sheet marks and the favicon before `telar` on every card ([capture](slice-8-cards.png), [sidebar detail](slice-8-cards-detail.png)) |

The unit tests in `src/gui/tests/sprites.zig` and the image modules check
that the page holds the three marks then at most 64 favicons and
premultiplies on write, that the renderer versions the page only when a cell
changes and rebuilds it at another scale, that sprite quads carry the
selector while fills and glyphs stay on the atlas, that the card draws the
sheet mark for the three providers and the chip for unknown and custom ones,
that a warm repaint with sprites shapes, rasterizes, uploads and allocates
nothing, that the decoder round-trips every filter type and a palette with
transparency and rejects interlaced, 16-bit, oversized, corrupt and lying
streams, that the registry places, forgets and bounds its entries, that the
worker decodes a real file into the cell, and that a favicon written to
`.telar/icon.png` reaches the card one preparation after the completion
lands through the inbox. `controllers/workspaces/favicons.zig` checks one
lookup at a time, stale and cancelled results released, and an idle runner
after a start failure.

## Not verified

- A pixel comparison of the sprite branch between Metal and Vulkan: neither
  window test reads pixels back; both draw the same 2x2 page and the branch
  is identical in both shaders.
- `tools/gui_composition_latency.py`: not run (one build at a time on a
  memory-constrained machine). The interactive-path cost of this slice is
  one flat float per vertex and one uniform branch per fragment; favicon
  lookups start at most once per workspace per page.
- A real Claude, Codex or Pi session: the stand-in agents exercise the same
  foreground-process identification, not the agents' own output.

## Decisions the plan left open

- Sampling: linear, on a page whose cell equals the mark size at the display
  scale, so an on-grid mark samples one texel per pixel and a favicon drawn
  in a smaller slot averages neighbouring premultiplied texels instead of
  aliasing. `spriteAt` snaps the corner to whole pixels.
- The PNG area bound is 1 Mi pixels (1024² equivalent) beside the 4096 px
  side cap, so a small file cannot inflate to a 64 MiB decode; the decoded
  buffer is at most 4 MiB plus scanlines.
- Page identity is the pixel storage address: a page rebuilt for another
  scale or by a font reload forgets its placements and the lookups run
  again. Cells are never reused; a workspace that leaves and returns takes a
  new cell, bounded by the 64-favicon cap.
- The mark box scales with `ChromeMetrics.px`, so the 16 logical pixel mark
  of the plan is 32 device pixels on a 2x display; the previous chip kept 16
  device pixels.
- Stand-in agents for the capture are compiled C programs: a renamed copy of
  `/bin/sh` is killed by macOS, and the runtime inspects the foreground
  process only after it produces output.
