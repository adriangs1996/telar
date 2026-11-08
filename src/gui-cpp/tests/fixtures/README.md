# Font metric fixtures

`metrics-variable.ttf` and `metrics-collection.ttc` are modified, subsetted
derivatives of `assets/JetBrainsMono-Regular.ttf`. The renamed families are
Telar Metrics Fixture and Telar Static Fixture. The included
`metrics-variable-OFL.txt` preserves the original SIL Open Font License.

The variable face has a `wdth` axis from 100 to 200, named Regular and Wide
instances, HVAR advances and MVAR changes to ascent, descent, line gap and
underline thickness. The collection contains a distinct static face followed
by the variable face. Tests exercise these files without relying on installed
system fonts or creating a GUI window.

To regenerate both files, install the optional development dependency
`fontTools` and run:

```sh
python3 src/gui-cpp/tools/generate_font_fixture.py
```

The checked-in binaries are sufficient for normal builds and tests.
