# Access cluster census

Source `43567b04484cade06cbebb645acf56dba3042bfe`, measured on 2026-10-01,
macOS 26.6.2 arm64, Zig 0.16.0, ReleaseFast with counters. This census supports
the [optimization roadmap](../../plans/access-clusters.md). It changes no
production code and does not contact Personal or run the user's application.

[counts.json](counts.json) records the build, executable SHA-256, layout output,
fixture counts and normalized counts. Timings from the instrumented executable
are deliberately excluded. Counts establish work performed, not CPU dominance,
hardware cache misses, FPS or a speedup. Prior allocation measurements remain
in [memory patterns](../memory-patterns/README.md).

## Reproduction

```sh
zig build build-dod-probe -Doptimize=ReleaseFast -Dprofile-counts=true --prefix /tmp/telar-memory-patterns.fnZXsC/counts -j2
DOD_SAMPLES=128 DOD_WARMUP=64 /tmp/telar-memory-patterns.fnZXsC/counts/bin/telar-dod-probe
DOD_SAMPLES=128 DOD_WARMUP=64 DOD_CHROME_ONLY=1 /tmp/telar-memory-patterns.fnZXsC/counts/bin/telar-dod-probe
```

Both invocations exited successfully. Terminal and card fixtures use 128
measured iterations after 64 warmups. Workspace and review probes ignore those
overrides: each runs 1,000 measured iterations; review warms 200. There are 57
completed workloads and one capacity result. The probe requested 10,000 diff
rows, retained 4,096 and skipped timing/counting that case; it is not a measured
10,000-row workload.

## Measured work per operation

| Fixture | Per measured iteration |
| --- | --- |
| Retained, 73×40 cells | 2,920 cell comparisons + 2,920 ink-pass visits; no mesh rebuild |
| Retained, 153×40 cells | 6,120 cell comparisons + 6,120 ink-pass visits; no mesh rebuild |
| One changed cell, 153×40 | Same two full walks; 6,119 mesh hits, one rebuild |
| All cells changed, 153×40 | Same two walks; 6,120 rebuilds |
| Two visible panes, one changing, total 153×40 | Two pane draws, 6,120 comparisons + 6,120 ink visits in total; one rebuild |
| Two visible panes, both changing, total 153×40 | Same visits; two rebuilds |
| Cursor-only, 153×40 | Same two walks; no cell rebuild, 6,121 terminal quads |
| Diff search, 100 rows | One draw scans 100 rows / 1,700 logical text bytes |
| Diff search, 1,000 rows | One draw scans 1,000 rows / 17,000 logical text bytes |
| Workspace lookup, 1/8/64 tabs | 1/8/64 successful indexed pane lookups per iteration; zero pane-iterator slots |
| 16 cards, unchanged 32/40/64-byte titles, widths 280 and 480 | Zero shaping calls and raster attempts after warmup |
| 16 cards, unchanged 65-byte titles, width 280 | 16 shaping calls per iteration; zero raster attempts |
| 16 cards, unchanged 65-byte titles, width 480 | 32 shaping calls per iteration; zero raster attempts |

Terminal geometries are the actual cells after chrome, not the probe's requested
80/160 columns. Two-pane fixtures divide the same total area; they do not double
it. The card fixture directly draws cards, including all requested rows; it does
not exercise sidebar clipping, fleet ordering or multiple machine replicas.
All 24 card fixtures report zero allocations through their renderer allocator
during the measured interval. This excludes foreign-library allocation hooks.

At **an assumed** 120 preparations/s, the measured 153×40 retained traversal
would perform 1,468,800 combined cell/ink visits per second. At 40/s it would
perform 489,600. Neither rate was observed in the running application. In
particular, changing input production frequency does not establish presentation
frequency. The operation counters have no wall-clock workload denominator here.

## Source checks and existing solutions

- [TerminalRenderer.drawPane](../../../src/gui/render/TerminalRenderer.zig)
  performs the two walks. [RetainedCells](../../../src/gui/render/RetainedCells.zig)
  already separates cell metadata, primary quads and overflow quads. The second
  pass still walks `CellMetadata`, although many entries only need their length
  checked. Background/ink order preserves cursor and glyph-overhang semantics.
- [Paint.searchStatus](../../../src/gui/change_review/Paint.zig) scans the
  selected file on every draw with a query, counting overlapping substring
  matches and optionally restricting them to the visual hunk and side.
- [ShapingEntry](../../../src/gui/text/ShapingEntry.zig) accepts 64 bytes/glyphs;
  [ShapingCache](../../../src/gui/text/ShapingCache.zig) bypasses longer input.
  The 65-byte fixture therefore demonstrates repeated preparation for unchanged
  text, not a need to rasterize the glyphs again.
- [tab_layout.snapshot](../../../src/model/workspace/tab_layout.zig) already
  keys geometry by tab, layout revision, area and bottom reservation.
- [SidebarState.observe](../../../src/gui/widgets/SidebarState.zig) already
  keys fleet order by snapshot/workspace/link/machine generations and focus.
  [Sidebar.drawActivity](../../../src/gui/widgets/Sidebar.zig) still computes
  total height, walks to visible entries and captures a source projection for
  each visible card. No execution counts were collected for these operations.
- [Runtime.update](../../../src/backend/runtime/Runtime.zig) calls delivery
  flush once per non-stop event. This is not once per presented frame.
  [Delivery](../../../src/backend/runtime/delivery/Delivery.zig) already builds
  a pending-attachment mask using `Attachment.hasDelivery`; later lanes visit
  pending attachments. Flush also traverses pane slots to start media and
  settle damage. No current flush/event-rate census was collected.
- [vtgrid.damage](../../../lib/vtgrid/damage.zig) scans full dirty rows, not the
  entire grid, and merges spans according to encoded byte cost. The client
  already retains finer [DamageRow](../../../lib/cellgrid/DamageRow.zig) ranges.
  These describe different pipeline stages; the client's ranges are not evidence
  that the runtime emulator supplies equally precise damage.
- [pane_images](../../../src/gui/image/pane_images.zig) already guards placement
  resolution and upload starts by versions;
  [GpuImages](../../../src/gui/image/GpuImages.zig) uses columns and a dense list
  of occupied rows. Do not propose either mechanism as missing.

The profiler's descriptive catalog has drift: `mesh_items` claims two calls per
fully drawn cell, but the current call sites count emitted background/ink
groups conditionally. Some source labels retain old function/type names. This
report uses the increment sites, not those labels, as its definition.

## Earlier experiments that constrain the roadmap

These results are historical evidence, not measurements repeated in this census:

- [Runtime pass 3](../dod-pass-3/README.md): a nested hot-field grouping helped
  one shape but regressed the other; a fresh dense-table experiment needs its
  own evidence. The availability mask and observer bitset are already present.
- [Pane draw cache](../pane-draw-cache-experiment/README.md): large retained-pane
  gains came with sparse and continuously changing pane regressions.
- [Cache admission](../cache-admission-experiment/README.md): delayed admission
  avoided stores under continuous change but lost useful reuse during short pauses.
- [Persistent quads](../persistent-pane-quads-experiment/README.md): removing
  one copy still regressed both-changing workloads by 9.18–13.41% at the paired
  median. More retained memory alone did not solve scene composition.

There is no current PMU capture or representative native frequency trace in
this census. Those gaps are explicit prerequisites for ordering the expensive
runtime/renderer layout experiments by actual time saved.
