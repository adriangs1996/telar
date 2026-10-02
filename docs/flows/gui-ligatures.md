# GUI ligatures

A pane row reaches `TerminalRenderer.drawPane` as cells. A face whose ligature
lookups read neighbouring characters (`->` in JetBrains Mono, `!=` in Fira
Code) must shape those cells together, or HarfBuzz never sees the pair. Telar
shapes runs of cells together in the primary face and keeps every glyph on the
cell grid. The runtime's cells, copy, search and the text a child wrote stay
exactly as they were; only the native window draws differently.

## Which cells join

`FontSet` reads `LigatureCoverage` from the primary face once, when the font
set opens. HarfBuzz collects the GSUB lookups of the default features that can
join graphemes (`liga`, `clig`, `calt`, `rlig`, `rclt`) and the glyphs each one
substitutes (input) or only reads around them (context). The face's cmap maps
those glyphs back to codepoints, and its OS/2 `usMaxContext` gives the longest
sequence one rule reads. Nothing names an operator: a face decides what joins.
A face without such lookups (Symbols Nerd Font, Menlo) covers nothing and its
rows draw cell by cell exactly as before.

`RowRuns` splits a changed row segment. Runs break where Ghostty's
`font/shaper/run.zig` breaks them (pinned revision `a4edca2a`): at the row's
ends, at a change of glyph ink (color, bold, italic, faint, inverse; a
background or an underline does not split), at the cursor, at wide and spacer
cells, and before a typographic `fi`, `fl` or `st`. They also break at cells no
lookup reads, procedural glyphs, invisible cells and graphemes the primary face
does not cover in full, so fallback icons keep their fitted cells. Cells
farther than `usMaxContext` from every substituted codepoint shape alone: no
rule reaches them, so the run shapes as the whole segment would and trailing
blanks never join. A run longer than `RowRuns.max_cells` shapes cell by cell
rather than being cut into pieces that could form ligatures the whole would
not.

The cursor splits the run it sits in, as in Ghostty, so the character under it
is visible and the block cursor recolors only that cell's ink. Its column comes
from where the pane draws it, not from the blink phase, so blinking never
reshapes a row. A selection is projected into the cells' style first; a
selection boundary inside a ligature therefore splits it.

## Drawing on the grid

`GlyphAtlas.shapeCells` shapes the run's text in the primary face through the
bounded shaping cache, and refuses a right-to-left result. `ShapedRun.split`
hands each cell the glyphs whose cluster starts in it; `placeGlyphs` places
them from the cell's own column, so the grid never drifts from the face's
advances, as Ghostty anchors glyphs per cell. Programming fonts draw a
ligature as spacer glyphs plus one glyph whose ink reaches back over the
previous cells (or forward, in Cascadia Code). Retained ink is drawn after
every background and is clipped only to the pane, the same path italic
overhang uses. A true ligature that merges clusters lands in its first cell.

## Invalidation

Each retained cell keys its mesh by its cell, its rectangle and a shaping
context. A cell whose share of the run is what it shapes into alone has context
zero and paints alone; any other cell is keyed by a hash of its glyphs and pen
offsets. Editing one character of `===` therefore repaints exactly the cells
whose glyphs changed, including untouched neighbours that leave or join the
ligature, and nothing else.

A warm row still compares only cells and rectangles. Contexts follow from the
row's cells, its cursor column and its segment's width, so `CellMetadata`
records the last two: a row is split again only when a cell, the cursor's
column or the segment's end changed. Splitting reserves no memory beyond the
per-column scratch `RowRuns` sizes with the grid; a run copies its glyphs to
the stack before shaping cells alone. Warm frames shape nothing, rasterize
nothing and allocate nothing; a changed row reads the shaping cache for runs
it saw before.

## Proof

`zig build test-gui` covers the coverage of three embedded faces (programming
ligatures, none, typographic only), run splitting and reach, the ligatures the
embedded JetBrains Mono draws for `->`, `!=`, `=>`, `==`, `===`, `<=`, `>=`,
`!==`, `&&`, `||`, `::`, `/*`, `<!--` and `|>`, edits that form and break
ligatures with exact repaint counts and full-redraw equality, style, row and
fallback boundaries, cursor, blink and selection splits, ordinary text drawn
exactly as cell by cell, and warm frames without shaping, rasterization or
allocation. `telar-dod-probe`'s `ligatures` mode measures a row edit that forms
and breaks a ligature; [the measurements](../performance/gui-ligatures/README.md)
compare every terminal workload with the base.

Letter spacing moves cells apart while a ligature glyph keeps the face's
advance, so its ink can sit a few pixels off the cells it covers, as in
Ghostty. Chrome labels in the terminal face, such as the link tooltip, shape
whole lines on their own path.
