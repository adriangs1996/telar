# GUI procedural glyphs

Terminal cells and chrome labels enter `GlyphAtlas.place` with UTF-8 text, color
and a `TextRun.cell_bounds` measured from the configured grid. A complete Braille
character, U+2800 through U+28FF, box-drawing character, U+2500 through U+257F,
or block element, U+2580 through U+259F, selects procedural drawing before font
coverage or shaping. Ordinary text retains
the existing font and shaping path. Mixed text separates spans at grapheme
boundaries; combining and variation-selector clusters remain intact on the font
path.

## Braille

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

## Box drawing

Font bitmaps leave gaps when their strokes do not span the configured line height
or letter spacing. `BoxDrawing` decodes each box character, and `BoxGrid` derives
its strokes from the complete physical cell. Light, heavy, double, mixed-weight,
dashed and partial lines meet at cell edges. The font's underline thickness sets
the light stroke, with at least one physical pixel; heavy strokes use twice that
width. Unicode selects the weight, so bold and italic attributes do not distort
the geometry. Double strokes collapse to one stroke when the cell cannot hold
two lines and their gap.

`box_lines` maps the Unicode characters to their four arms. `BoxGrid` joins those
arms, and `BoxInk` decomposes their union into disjoint solid rectangles. This
avoids painting intersections twice with faint text. The painter emits at most
21 ink quads, preserving the 24-quad cell budget with background, underline and
strikethrough. Straight strokes use the existing white texel without shaping,
rasterizing, changing the atlas or allocating memory.

`BoxCurve` supplies antialiased masks for the four rounded corners and three
diagonals. `GlyphAtlas` packs them in its existing alpha page. `BoxCache` holds
56 entries keyed by shape, cell dimensions and stroke thickness, including failed
admissions. Raster extents are capped at 256 by 256 pixels. Seven 16-by-32 masks
are reserved at atlas initialization; oversized cells, a full cache or a full
atlas use those masks scaled to the requested cell. This preserves a recognizable
shape under pressure, with reduced fidelity. Slots are never overwritten while
retained meshes can reference them. Rasterization writes directly into the page,
without a temporary bitmap. Cache hits do no raster work.

Stroke joins and corner geometry follow
[Ghostty's box sprite implementation](https://github.com/ghostty-org/ghostty/blob/main/src/font/sprite/draw/box.zig).
Adapted modules include its attribution and MIT license. Curves use sixteen line
segments for the cubic section and pixel-center distance coverage; their
antialiasing is not intended to match Ghostty pixel for pixel.

## Block elements

A font's block glyphs fill its em box, not the cell. With `gui.font.line_height`
above 1 the cell is taller than the em box, so U+2580 through U+259F left a gap
under every row, shades broke between rows and the Claude Code mascot split
into pieces. The fitting transform is not involved: `GlyphAtlas.transform`
returns the identity for every face that is not `fitted()`, which is only the
fallback text and symbol faces, so primary-face ink keeps its font metrics.

`BlockElement` decodes each bare block grapheme and `block_shapes` maps it to
Unicode semantics: a slab of one to eight eighths anchored to the top, bottom,
left or right edge, one of the ten quadrant sets, or a shade. `BlockInk` measures
the rectangles from the complete physical cell. Slab and quadrant boundaries
sit at `round(extent * eighths / 8)` from the cell origin, so opposite halves,
the upper eighth and lower seven eighths, and complementary quadrant sets tile
the full block exactly at every cell size, including fractional ones. Rows of a
quadrant set merge horizontally and vertically, so a cell emits at most two
disjoint solid quads. The shades U+2591, U+2592 and U+2593 cover the whole cell
with the run color at 25, 50 and 75 percent alpha, matching Ghostty's shade
levels; adjacent cells therefore blend into one continuous tone with no seam.

Ink uses the existing white texel and needs no raster, cache or atlas page, so
the path never allocates once frame capacity is reserved and cannot fail under
atlas or cache pressure. Bold and italic do not deform the geometry. Tiny cells
drop rectangles that round to zero pixels. Graphemes carrying combining marks or
variation selectors take the font path, like the box and Braille paths.

## Composition and verification

Foreground, inverse colors, faint alpha and cursor recoloring follow the normal
cell path. Retained meshes keep complete font bitmaps and their texture
coordinates. Pane composition clips ink at the pane boundary, allowing italic
overhang between adjacent cells and rows. Backgrounds and block cursors precede
ink; selection and cursor text colors follow the glyph's owning cell. Quads
already inside the pane bypass texture-coordinate adjustment.

Metal and Vulkan consume the same quads and alpha atlas. No KGP messages, images,
new textures or GPU-specific drawing code are involved. Runtime and TUI code are
unchanged by this GUI implementation.

`zig build test-gui` covers all 256 patterns, individual dot positions, blank
advance, tiny cells, configured metrics, mixed font runs, retained damage,
cursor/color behavior and allocation-free repeated updates. Box tests cover all
128 characters, joins, disjoint ink, fractional and tiny geometry, cache/atlas
saturation, retained damage and warmed updates without shaping or allocation.
Block tests cover all 32 characters, the Unicode chart, tiling of opposite
slabs and complementary quadrants at every pixel, monotonic eighths, quadrant
merging, shade alpha and cell coverage, mixed font runs, natural metrics and
cold placement without shaping, rasterization, atlas writes or allocation.
Italic tests cover the configured font, thickening, vertical and horizontal
overhang, pane edges, combining marks, selection and cursor composition.

The native probes `tools/gui_text_input.py` and
`tools/vm/gui-key-repeat-test.py` display the eight single-dot characters observed
in Codex's input animation and a 16-by-16 table of all Braille patterns. They
capture the result with an unpatched DejaVu Sans Mono font on macOS and Linux.
Screenshots require visual inspection; the tests verify the geometry and cache
contracts independently.

`tools/gui_block_elements.py` prints the Claude Code mascot, halves, eighths,
quadrants, shades and the two block rows from a shell child with the bundled
JetBrains Mono at the line height of `examples/gui.lua`; its before and after
captures live in `docs/validation/gui-procedural-glyphs/`.

Pass `--rendering` to either probe for the shared box-and-italic fixture in
`tools/gui_rendering_sample.py`. It includes the Codex-style rounded frame,
light/heavy/double joins, all 128 box characters and italic `New` text. The probes
also retain their key-repeat check and clean up their isolated runtime.
