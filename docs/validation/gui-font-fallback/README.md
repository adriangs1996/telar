# System font fallback

Validated on 2026-09-14 on macOS/Metal (Apple Silicon) on
`fix/gui-system-font-fallback`, branched from `75263cb4` on
`fix/gui-followups`.

The defect: `telar gui` painted tofu for graphemes none of the embedded faces
cover. Claude Code prints `⏵⏵ auto mode on` (U+23F5), which is in neither
`JetBrainsMono-Regular.ttf` nor `SymbolsNerdFontMono-Regular.ttf`, and neither
are U+23F4, U+23F8, U+2B95, U+2699, U+2705, U+274C or the sextants
U+1FB00–U+1FB3B.

## Captures

Both captures run `telar gui --no-config /bin/sh` in a short `/tmp` directory
driven by `tools/gui_actions.m` (the multiplexer harness in
`tools/gui_multiplexer.py`), typing

```sh
clear; printf '⏵⏵ auto mode on · ⚙ ✅ ❌ ⮕ 🬀🬻\n'
```

| Capture | Binary | Result |
| --- | --- | --- |
| [macos-before.png](macos-before.png) | `fix/gui-followups` at `6f7e1dc5` | every listed grapheme is the replacement glyph |
| [macos-after.png](macos-after.png) | this branch | `⏵⏵` from STIX Two Math, `⚙` and `·` from Menlo, `✅` and `❌` from user-installed Nerd Font Mono faces (monochrome forms), `⮕` from Hiragino Sans W3, `🬀🬻` from the user's Cascadia Code |

The faces come from `telar_gui_find_fallback_font` on this machine
(`CTFontCreateForString` over Menlo, then every descriptor whose character set
covers the grapheme, monospace first, color and LastResort faces skipped):

```
⏵ -> STIXTwoMath-Regular /System/Library/Fonts/Supplemental/STIXTwoMath.otf
⚙ -> Menlo-Regular /System/Library/Fonts/Menlo.ttc
✅ -> IosevkaNFM ~/Library/Fonts/IosevkaNerdFontMono-Regular.ttf
❌ -> BlexMonoNFM ~/Library/Fonts/BlexMonoNerdFontMono-Regular.ttf
⮕ -> HiraginoSans-W3 /System/Library/Fonts/ヒラギノ角ゴシック W3.ttc
🬀 -> CascadiaCode-Regular ~/Library/Fonts/cascadia-code-variable.ttf
😀 -> none (only Apple Color Emoji covers it; color faces are never selected)
```

A machine without those user fonts picks the next monochrome candidate; a
grapheme only color faces cover keeps the replacement glyph. That is the
documented gap: the atlas is alpha only.

## Checks

| Check | Result |
| --- | --- |
| `zig build test-gui` | exit 0, 240 tests: U+23F5 resolves to pool slot 0 fitted to the cell, a miss is looked up once, eight slots refuse a ninth without evicting, one file serves every grapheme it covers, an atlas without an `Io` never looks up, warm terminal and chrome repaints of a discovered grapheme shape, rasterize, look up and allocate nothing |
| `zig build test` | one failure unrelated to this change: `transport_integration_test` "explicit workspace creation and selection use identity instead of path" binds `<worktree>/.zig-cache/tmp/<22 chars>/workspace-identity.sock`, 110 bytes from this worktree's path (`/Users/adriangonzalez/sandbox/telar-fix-fallback`) and over macOS's 104-byte `sun_path`; from the 35-byte `sandbox/telar` path the same socket is 97 bytes. Reproduced three times, with `zig build test-transport` alone as well; the test touches no GUI code. Every other step passed, including `codestyle` and the boundary check |
| `zig build test-gui-window` | exit 0, `failures=0` |
| `zig build check-client-boundaries` | passed |
| `zig build test-gui` in the Fedora VM (`tools/vm/vm.py`, Fontconfig port) | exit 0. No installed face there covers U+23F5 (`fc-list ":charset=23f5"` is empty), so the discovery test resolves U+2699 through DejaVu Sans Mono instead; the Fontconfig port returns none for the arrow, color emoji and an empty query |

Not verified: a GUI capture on Wayland (the ssh session has no Wayland
display), font reload with a populated pool beyond the unit-level rebuild
(`ConfigurationReload` replaces the atlas and its set, so the pool is rebuilt
with it), and the CoreText descriptor enumeration cost on a machine with
thousands of installed fonts (bounded to 512 candidates per lookup, once per
grapheme thanks to the negative cache).
