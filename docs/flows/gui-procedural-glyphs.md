# GUI procedural glyphs

Terminal cells and chrome labels enter `GlyphAtlas.place` with UTF-8 text, color
and a `TextRun.cell_bounds` measured from the configured grid. A complete Braille
character, U+2800 through U+28FF, selects procedural drawing before font coverage
or shaping. Ordinary text retains the existing font and shaping path. Mixed
text separates spans at grapheme boundaries; combining clusters remain intact.

Braille encodes eight positions in the low byte of its codepoint:

```text
01 08
02 10
04 20
40 80
```

The painter distributes square dots inside the physical cell, including the
configured line height and letter spacing. The normal pixel distribution follows
Ghostty's Braille sprite algorithm; its attribution and MIT license accompany the
adapted implementation. Tiny cells remain bounded by their available pixels.
U+2800 advances one cell and emits no ink. Bold and italic do not deform the
pattern's dot positions.

Each pattern emits at most eight solid quads using the atlas's existing white
texel. Braille draws change no atlas pixels or glyph-cache entries. Once frame
capacity is reserved, they need no allocation. The geometry fits the existing
24-quad cell budget, including background and text decorations. Retained cells
own these quads just as they own font glyph quads; changing a pattern replaces
the complete cell mesh, and unchanged cells reuse their geometry.

Foreground, inverse colors, faint alpha, clipping and cursor recoloring follow
the normal cell path. Metal and Vulkan consume the same quads. No KGP messages,
images, new textures or GPU-specific drawing code are involved. Runtime and TUI
code are unchanged by this GUI implementation.

`zig build test-gui` covers all 256 patterns, individual dot positions, blank
advance, tiny cells, configured metrics, mixed font runs, retained damage,
cursor/color behavior and allocation-free repeated updates.

The native probes `tools/gui_text_input.py` and
`tools/vm/gui-key-repeat-test.py` display the eight single-dot characters observed
in Codex's input animation and a 16-by-16 table of all Braille patterns. They
capture the result with an unpatched DejaVu Sans Mono font on macOS and Linux.
Screenshots require visual inspection; the tests verify the geometry and cache
contracts independently.
