# Integration: all eight slices

Validated on 2026-09-14 on macOS/Metal (Apple Silicon) on
`feat/gui-visual-language`, first at `e01d884a` after merging slices 1 to 6
and the glyph and status-band follow-up, then again at `09adebfc` after
merging slices 7 (chrome text sizes) and 8 (sprite page, provider marks and
favicons).

| Check | Result |
| --- | --- |
| `zig build test` | exit 0 |
| `zig build test-gui` | exit 0 |
| `zig build test-gui-window` | exit 0, `failures=0` |
| `zig build check-client-boundaries` | passed |
| `zig build test-schema` | exit 0; schema 48, fingerprint recomputed after slices 2 and 3 each bumped to 47 |
| `tools/gui_sprites.py` at `09adebfc` | three stand-in agents and a generated `favicon.png`: cards with title, body and small sizes, sheet marks for Claude, Codex and Pi and the favicon in the project slot ([cards](final-cards.png)) |
| `telar gui --config examples/gui.lua` driven by `tools/gui_actions.m` | Osaka Jade, pixel top bar with workspace pill and location, tab strip, empty status band, sidebar header and footer metrics, palette `>` and `@`, new-context form with directory completion ([multiplexer](final-multiplexer.png), [palette](final-palette.png), [new context](final-new-context.png)) |

Not verified in this pass: Wayland/Vulkan on the merged branch (slice 8 changed both backends and its own VM run did not complete: no Wayland display in the ssh session) (each slice
that touched shaders validated on the VM on its own), captures with a live
agent (cards, chips, rings and dots are covered by unit paint tests only),
and `tools/gui_composition_latency.py`.
