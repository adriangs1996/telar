# GUI ligatures: terminal preparation cost

2 October 2026, branch `font-atlas-ligatures` against its base `1f6ba9ea`.
Apple Silicon, macOS, `zig 0.16.0`, ReleaseFast with `-Dprofile-counts=true`.
See [GUI ligatures](../../flows/gui-ligatures.md) for the design.

The question: does shaping rows into ligature runs cost the interactive path
anything when the embedded JetBrains Mono, whose `calt` lookups join, is the
terminal face? Warm frames must stay free of shaping and allocation, and a
changed row must not repaint more cells than before.

## Method

`telar-dod-probe` drives the real `TerminalRenderer` without a window. Both
trees were built and run alternately, five repetitions per workload, 1,000
frames each after the probe's warm-up:

```sh
zig build build-dod-probe -Doptimize=ReleaseFast -Dprofile-counts=true --prefix <out>
DOD_TERMINAL_ONLY=1 DOD_MODE=<mode> <out>/bin/telar-dod-probe
```

The `ligatures` mode is new: rows repeat `a -> b != c `, and each frame turns
one `->` into `=>` or back, which the probe requires to repaint exactly two
cells (the edited spacer cell and the ligature beside it).

## Results

Median nanoseconds per frame; `rebuild` is the probe's `mesh_rebuild`
counter over the run, and every workload measured zero allocations.

| Workload | Base | Branch | Rebuilds (both) |
| --- | ---: | ---: | ---: |
| retained 153×40 | 42,319 | 41,461 | 0 |
| cursor 153×40 | 45,173 | 44,871 | 0 |
| focus 153×40 | 43,876 | 43,305 | 0 |
| sparse 153×40 | 42,291 | 41,969 | 1,000 |
| two_one_active 153×40 | 42,285 | 42,007 | 1,000 |
| selection 153×40 | 66,150 | 66,347 | 298,429 |
| full 153×40 | 158,760 | 168,465 | 6,120,000 |
| ligatures 153×40 | — | 36,850 | 2,000 |

The 73×40 grids follow the same pattern (full: 75,557 → 79,755 ns).

Warm, cursor, focus, sparse and selection frames are unchanged within run
noise. A frame that rewrites every cell costs about 6% more: each changed row
is scanned once for a codepoint the face can substitute before it is painted.
The first version cost 60% more because the per-cell repaint was no longer
inlined into the row loops; `repaint` and `paintCell` are now `inline`.

`zig build test-gui` asserts the rest: warm repaints shape, rasterize and
allocate nothing, and repeating edits that form and break ligatures reads the
shaping cache only.
