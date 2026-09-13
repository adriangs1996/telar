# Procedural Braille validation

Validated on 2026-09-13 at `8b6a0414`. Baseline `e9afd957` already includes the
Nerd font and held-key fixes, but renders the Codex input animation's Braille
characters as missing-glyph boxes. This change draws U+2800–U+28FF directly in
the GUI cell grid. See [the drawing path](../../../flows/gui-procedural-glyphs.md).

| Check | macOS / Metal | Linux / Wayland / Vulkan |
| --- | --- | --- |
| GUI tests | 123 passed | 122 passed, 1 skipped |
| Source style and client boundaries | Passed | Passed |
| Native window | Passed on isolated repeat; first run failed one assertion | Passed, including rejected-frame cleanup |
| Native text/input probe | Neovim line 1 → 12 after one press and ten injected repeats | 15 `j` bytes during a 1.2-second virtual key hold; stopped on release |

The Linux skip is the macOS optical-weight test. The four new renderer
integration tests fail against the baseline and pass with procedural Braille.
Unit tests cover all 256 masks, Unicode dot order and 33,153 small/fractional
cell sizes. Integration checks cover retained replacement, blank erasure,
clipping, cursor recoloring and 120 updates with allocation disabled and no
additional shaping, rasterization or atlas mutation.

Both native probes use unpatched DejaVu Sans Mono. Visual inspection confirms
that the eight individual dots observed in Codex and all 256 patterns now draw
as dots, with an empty U+2800. These fixtures reproduce the characters; they do
not run Codex itself or establish pixel equivalence to Ghostty.

| Platform | Before | After |
| --- | --- | --- |
| macOS | [Missing glyphs](macos-before.png) | [Procedural dots](macos-after.png) |
| Linux | [Missing glyphs](linux-before.png) | [Procedural dots](linux-after.png) |

The macOS native window test first reported `failures=1` when run alongside
compilation. The exact same cached executable then passed in isolation without
code changes. Its aggregate counter does not identify the failed assertion.
The fixture starts a one-second deadline before AppKit/Metal initialization and
also expects no repaint during an idle interval despite legitimate focus and
occlusion redraws; either is a possible explanation, not a confirmed cause.
This test uses a fixed native quad and never invokes the changed glyph path.
The Neovim probe passed with an empty runtime error log; Vulkan validation
reported no errors in the Linux probe.

Reproduce the text captures with:

```sh
zig build install test-gui codestyle check-client-boundaries
zig build test-gui-window
python3 tools/gui_text_input.py zig-out/bin/telar /tmp/telar-braille-check
python3 tools/vm/gui-key-repeat-test.py /tmp/telar-braille-linux-check
```

Use new output directories. Build the Linux binary in the running Wayland VM
before its probe. The macOS probe injects AppKit repeat events; it does not test
hardware repeat generation. The Linux probe uses virtual hardware input.
