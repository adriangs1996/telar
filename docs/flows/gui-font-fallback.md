# GUI font fallback

A cell or chrome label enters `GlyphAtlas.place` as UTF-8 and paint attributes.
`FontRuns` keeps each grapheme together and chooses the first face that covers
it: the configured family, embedded JetBrains Mono, then the complete embedded
Symbols Nerd Font Mono. Font discovery and byte loading happen only while
constructing the renderer, through `FontSource`; painting never queries the OS
for another family. Unsupported graphemes retain the primary replacement glyph.

`FontFace` owns FreeType/HarfBuzz and, when optical thickening is enabled on
macOS, that face's CoreText rasterizer. `FontSet` owns at most three faces. All
faces borrow the same alpha atlas, use the same configured size and synthetic
bold/italic settings, and are destroyed with it. Hot reload creates a complete
replacement renderer before swapping resources after GPU consumers finish.

The primary face alone defines cell width, line height and baseline. Covered
text keeps its original shaping and rasterization. Fallback spans advance by
whole primary cells, and `GlyphTransform` fits their ink proportionally inside
those cells without cropping wider Nerd symbols. Each fallback grapheme keeps
its own cell advance; adjacent icons cannot accumulate the fallback font's
wider advances.

The bounded shaping cache remembers the chosen face with its glyphs. Glyph
atlas keys include face identity, glyph index, pixel size, bold and italic, so
an index shared by two faces cannot select another face's cached bitmap. The
existing 1024-square page, failure cache and frame budgets remain unchanged.
Glyphs are packed once; cached repainting performs no shaping, rasterization
or adapter allocation. Font-size changes invalidate shaping but preserve the
identity of already packed glyphs at their original size.

`zig build test-gui` covers installed DejaVu Sans Mono (or macOS Menlo when
DejaVu is unavailable), BMP and supplementary Nerd icons, variation selectors,
combined text, four styles with thickening, exact primary metrics, fitted ink
bounds, colliding glyph indices, mixed runs and 120 warm repaints. The full
symbols font's source, version, SHA-256 and license are recorded in
[`src/assets/README.md`](../../src/assets/README.md).

This is a GUI presentation change. It changes neither the runtime's cells and
PTY behavior nor the TUI's small embedded icon subset.
