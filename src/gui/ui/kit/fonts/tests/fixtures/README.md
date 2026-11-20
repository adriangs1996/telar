# Font metric fixtures

`metrics-variable.ttf`, `metrics-collection.ttc` and `metrics-wide-glyph.ttf`
are modified, subsetted derivatives of `assets/JetBrainsMono-Regular.ttf`. The
renamed families are Telar Metrics Fixture, Telar Static Fixture and Telar Wide
Glyph Fixture. The included
`metrics-variable-OFL.txt` preserves the original SIL Open Font License.

The variable face has a `wdth` axis from 100 to 200, named Regular and Wide
instances, HVAR advances and MVAR changes to ascent, descent, line gap and
underline thickness. The collection contains a distinct static face followed
by the variable face. The wide-glyph face keeps every ASCII advance at 600
units and doubles the em dash, so its `hhea.advanceWidthMax` is twice the cell
width. Tests exercise these files without relying on installed
system fonts or creating a GUI window.

The binaries are checked in.
