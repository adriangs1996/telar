# Cell mesh metadata experiment

The retained renderer improved consistently in this campaign. Native input latency did not show a clear
improvement; this is a local CPU optimization, not evidence for a global SoA
rewrite or a perceptible responsiveness claim.

## Integration on 2026-09-23

The metadata split is incorporated into `refactor/client-world-storage`, together
with the independent opt-in profiling tools and frame composition lab. The
pane draw cache, delayed admission and persistent pane storage are excluded
from active code. Their complete experimental snapshot remains at `322b8c82`
on `experiment/pane-draw-cache`; archived reports describe historical builds.

The integration compares the tools-only commit `a3eaead7` against the metadata
split using the same probe. All 768 corresponding quad/atlas digests match
across twelve modes and two sizes. This verification measures equivalence,
not performance; the performance evidence below remains the original campaign.
The combined test run completes all 150 build steps with 3,786 tests passing
and two skipped. The standalone frame challenge also passes its five tests.
ReleaseFast builds pass with profiling disabled and with both profiling flags
enabled. A retained-workload smoke check verifies disabled counters, expected
enabled cell/hit counts, zero warm allocations and a valid shutdown profile
export without dropped thread registrations. The ReleaseFast widget benchmark
also completes; these smoke timings are not a new performance campaign.
Local commands and receipts are in `/private/tmp/telar-accepted-integration/`.

## Results

| CPU fixture | Median paired reduction | Favorable pairs | Interpretation |
| --- | ---: | ---: | --- |
| terminal/retained/80x40 | 5.2% | 5/5 | Consistent local improvement |
| terminal/retained/160x40 | 6.5% | 5/5 | Consistent local improvement |
| terminal/sparse/80x40 | 7.3% | 5/5 | Consistent local improvement |
| terminal/sparse/160x40 | 6.7% | 4/5 | Variable; repeat before claiming a gain |
| terminal/full/80x40 | 1.9% | 3/5 | Inconclusive at this scale |
| terminal/full/160x40 | 6.5% | 5/5 | Consistent local improvement |

Reductions are the median of five paired ratios. These are elapsed CPU fixture
times per draw, not per-frame latency percentiles or total application CPU usage.
All cases use 10,000 measured draws. Retained/sparse requested live bytes are
24,007,115 at 80x40 and 38,739,915 at 160x40 in both builds. Full redraw retains
984 additional bytes in both builds for its glyph set. Every measured interval
has zero allocations through the fixture allocator. Foreign allocators and GPU
memory are outside that accounting.

| Native committed text to matching GPU pixels | Baseline | Candidate |
| --- | ---: | ---: |
| Samples | 1000 | 1000 |
| p50, ms | 1.165 | 1.174 |
| p95, ms | 5.684 | 5.419 |
| p99, ms | 8.261 | 8.144 |

Run-level differences exceed the pooled version difference. There is no clear
systematic input-tail regression in these runs, but five repetitions do not
prove its absence across sessions. The small full-redraw CPU case remains
inconclusive. RSS varies substantially across fresh processes; no RSS saving
is claimed. Native timings are compared only within this campaign.

Correctness: 448 corresponding frames have identical quad and full glyph-atlas
SHA-256 digests. The GUI suite passes 754/754 tests, including allocation-failure
injection for growth of either storage array. Client boundaries and source style
checks also pass. Test windows and isolated runtimes were closed after collection.

The production disassembly uses 52-byte metadata and 1,920-byte geometry strides
instead of a 1,972-byte combined stride. Per-cell retained payload is still
1,972 bytes. The extra array adds one 24-byte list header and a growth allocation
per grid. Borrowed views are temporary, not extra per-cell stored pointers.
This split also changes quad alignment and generated address calculations;
the timing result cannot attribute savings exclusively to metadata cache misses.
No new PMU miss comparison was collected for this experiment.

Evidence: [CPU pairs](cpu.json), [native runs summary](native.json),
[frame equivalence](verify.json), [isolated renderer patch](candidate.patch),
[artifact hashes](evidence.json). The three phase manifests identify the measured
binaries. Shared probe sources are retained beside the raw artifacts.
This experiment separates the frequently read cell metadata from its fixed quad
payload. It preserves both renderer passes, the 24-quad cell capacity, comparison
semantics, invalidations, clipping and cursor ordering. The client renderer still
owns both arrays; no runtime, IPC or delivery policy changes.

`RetainedCells` now stores compact `CellMetadata` records and a parallel array of
quad payloads. `CellMesh` is a synchronous borrowed view into one entry of each.
The view expires on resize or destruction. Both reservations must succeed before
lengths, dimensions or validity change. An allocation failure can retain extra
capacity but preserves the previous usable grid.

The total per-cell payload is unchanged. This tests access locality, not geometry
compression or traversal reduction. A second allocation is allowed when growing
the grid; no allocation is added during steady frames.

## Protocol

- Branch `experiment/cell-mesh-metadata`; baseline includes the preceding DOD
  instrumentation work. That earlier work is preserved separately from this
  experiment's patch.
- Both binaries use ReleaseFast with optional profiling disabled. The same
  extended CPU fixture is compiled into both. Builds finish before measurements.
- Correctness compares SHA-256 of all quad bytes and complete glyph atlas bytes
  after each of 448 frames. Cases cover retained, sparse, full, theme, subcell
  resize, selection and font changes at 80x40 and 160x40.
- CPU measurements use five alternating baseline/candidate pairs, at least five
  seconds of warmup per fixture and 10,000 measured draws per case. Cases are
  retained, sparse and full output at both sizes. Duration-based warmup advances
  cyclic stimuli by different counts, then completes a full stimulus cycle.
  Measurement starts with the same cell contents and stimulus index. Warmup
  work is excluded from timings. The sparse fixture requires exactly one
  rebuilt cell per warm draw; full redraw requires all cells rebuilt.
- Native checks use the existing isolated committed-text probe, fixed viewport,
  20 warmup inputs and 200 measured inputs per run, five alternating pairs.
  Its endpoint is verified matching pixels at Metal completion, not scanout.
- Acceptance requires repeated CPU savings beyond run variation, equivalent
  output, no steady allocation, and no material full-redraw or native input-tail
  regression. A small isolated timing change is inconclusive.

Raw evidence lives in `/private/tmp/telar-cell-mesh-experiment/`. Preserve that
local directory before cleaning temporary files. Its `A/` and `B/` directories
hold the actual measured binaries; `baseline-source/` and `candidate.patch`
retain the isolated production change.

## Reproduction

Build the baseline with the shared probe enhancements before applying the
isolated renderer patch, then build the candidate with that patch. Each build:

```sh
zig build install build-dod-probe -Doptimize=ReleaseFast --prefix /tmp/cell-mesh/A
```

Use `/tmp/cell-mesh/B` for the candidate. Run each phase serially with a fresh
results directory:

```sh
python3 tools/cell_mesh_experiment.py verify --baseline /tmp/cell-mesh/A/bin --candidate /tmp/cell-mesh/B/bin --output /tmp/cell-mesh/results
python3 tools/cell_mesh_experiment.py cpu --baseline /tmp/cell-mesh/A/bin --candidate /tmp/cell-mesh/B/bin --output /tmp/cell-mesh/results
python3 tools/cell_mesh_experiment.py native --baseline /tmp/cell-mesh/A/bin --candidate /tmp/cell-mesh/B/bin --output /tmp/cell-mesh/results
```

The verification phase deliberately hashes outside performance measurement.
Do not use its durations as benchmark results. No baseline/candidate timing
comparison uses enabled counters or an attached profiler.

An initial timing campaign was rejected because the older sparse stimulus wrote
position-dependent values that became unchanged after a full traversal. The
corrected fixture toggles the selected cell, validates the rebuild count, and
finishes a whole warmup cycle before resetting the measured stimulus index.
Both CPU probes were rebuilt with that identical correction. Results in the
original `results/cpu/` directory are superseded, not pooled with the rerun.
