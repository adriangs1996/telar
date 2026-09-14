# Integration: all six slices

Validated on 2026-09-14 on macOS/Metal (Apple Silicon) at `e01d884a` on
`feat/gui-visual-language`, after merging slices 1 to 6 and the glyph and
status-band follow-up.

| Check | Result |
| --- | --- |
| `zig build test` | exit 0 |
| `zig build test-gui` | exit 0 |
| `zig build test-gui-window` | exit 0, `failures=0` |
| `zig build check-client-boundaries` | passed |
| `zig build test-schema` | exit 0; schema 48, fingerprint recomputed after slices 2 and 3 each bumped to 47 |
| `telar gui --config examples/gui.lua` driven by `tools/gui_actions.m` | Osaka Jade, pixel top bar with workspace pill and location, tab strip, empty status band, sidebar header and footer metrics, palette `>` and `@`, new-context form with directory completion ([multiplexer](final-multiplexer.png), [palette](final-palette.png), [new context](final-new-context.png)) |

Not verified in this pass: Wayland/Vulkan on the merged branch (each slice
that touched shaders validated on the VM on its own), captures with a live
agent (cards, chips, rings and dots are covered by unit paint tests only),
and `tools/gui_composition_latency.py`.
