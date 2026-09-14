# GUI font fallback

A cell or chrome label enters `GlyphAtlas.place` as UTF-8 and paint attributes.
Complete Braille characters use [procedural drawing](gui-procedural-glyphs.md)
before consulting fonts. For the remaining text,
`FontRuns` keeps each grapheme together and chooses the first face that covers
it: the configured family, embedded JetBrains Mono, then the complete embedded
Symbols Nerd Font Mono. Font discovery and byte loading happen only while
constructing the renderer, through `FontSource`; painting never queries the OS
for another family. Unsupported graphemes retain the primary replacement glyph.

`FontFace` owns FreeType/HarfBuzz and, when optical thickening is enabled on
macOS, that face's CoreText rasterizer. `FontSet` owns at most five faces: the
three terminal faces plus IBM Plex Sans Regular and SemiBold, which only chrome
labels request (see [native appearance](native-appearance.md)). All
faces borrow the same alpha atlas, use the same configured size and synthetic
bold/italic settings, and are destroyed with it. Hot reload creates a complete
replacement renderer before swapping resources after GPU consumers finish.

The primary face supplies the font metrics; the configured letter spacing and
line height determine the final grid and baseline. Covered text keeps its
original shaping and rasterization. Terminal cells and chrome labels pass their
measured grid to `TextRun`. `GlyphTransform` fits fallback ink proportionally
inside those cells without cropping wider Nerd symbols, including compressed
spacing. Each fallback grapheme keeps its own cell advance; adjacent icons
cannot accumulate the fallback font's wider advances.

The bounded shaping cache remembers the requested face, the chosen face and
the glyphs. Glyph atlas keys include face identity, glyph index, pixel size,
bold and italic, so an index shared by two faces cannot select another face's
cached bitmap. The
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

For a native visual check on macOS, build the GUI and run the Neovim probe with
a new temporary directory:

```sh
zig build install
python3 tools/gui_text_input.py zig-out/bin/telar /tmp/telar-font-check
```

It creates an isolated runtime and opens Neovim with DejaVu Sans Mono, size 22,
line height 1.4 and optical thickening. `icons.png` captures BMP and supplementary
icons plus all Braille patterns next to primary text; `repeated.png` and
`result.json` check repeated `j`
delivery at the child. The probe requires DejaVu and Neovim to be installed.
Screenshots require visual inspection; the glyph-selection and cache assertions
live in `test-gui`. The injected AppKit repeats test event delivery, not hardware
repeat generation or visual equivalence to another terminal's rasterizer.

The companion Linux probe is documented in [native input](native-input.md).
