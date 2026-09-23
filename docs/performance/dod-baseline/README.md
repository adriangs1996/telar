# DOD measurement baseline

Measured on 2026-09-22, before changing any application data representation.
The strongest candidate is `TerminalRenderer`'s retained `CellMesh` array.
A controlled renderer draw walks its cells twice even when every cached mesh
matches. The optimized binary uses a 1,972-byte element stride. Hardware samples
also point to loads of the mesh's `valid`, `len` and quad fields.

This supports a local experiment, not a global conversion to SoA. In a separate
PMU capture of the same mixed CPU fixture, the duration-weighted `Critical L1D
Cache Miss` fraction was 0.753%. Reducing misses need not produce a large latency
improvement. No optimization or performance improvement is claimed here.

## Artifacts and provenance

| Artifact | Contents |
| --- | --- |
| [summary.json](summary.json) | Five-run kernel comparisons, counter overhead, native input latency and rejected runs |
| [workloads.json](workloads.json) | Individual benchmark and CPU fixture results, checksums, allocations and work deltas |
| [catalog.json](catalog.json) | 41 counters with units, source boundaries and coverage |
| [profiles.json](profiles.json) | Per-process shutdown counters and bounded phase histograms |
| [layout.json](layout.json) | Actual optimized-target type sizes, alignments and field offsets |
| [cpu-pmu.json](cpu-pmu.json) | Time Profiler weights, exported PMU metrics and sampled load/store/TLB locations |
| [observations.json](observations.json) | Native frame summaries, runtime throughput, media, slow-host checks and trace loss records |
| [provenance.json](provenance.json) | Collection manifests, binary/source hashes, disassembly commands and sampled addresses |
| [evidence.json](evidence.json) | SHA-256 and size of every retained raw result file |

Raw binaries and captures are in `/private/tmp/telar-dod-analysis/`. Results are
under its `results/` directory. These local temporary artifacts are not committed;
copy that directory before purging temporary storage if the original Instruments
traces or complete disassembly are needed. The small reports above live in the
repository. JSON paths relative to `results/` identify their raw evidence.

Source base: `adf2acc4c5b0741d893d27336eb411462c3b7b72`, branch
`refactor/client-world-storage`, with the instrumentation changes present.
Apple M3, macOS 26.6.2, Xcode 26.1, Zig 0.16.0, native target, ReleaseFast,
AC power. Manifests record binary hashes and changed-source hashes at collection
time. Tooling and test discovery were completed after the main captures; final
source additionally makes the internal profile serializer private and reorders
core exports. Preserve the measured binaries when reproducing exact addresses.

## What was implemented

`-Dprofile-counts=true` and `-Dprofile-timing=true` independently enable diagnostic
counts and four synchronous wall-time histograms. Both default to false.
`TELAR_PROFILE_DIR` selects the shutdown dump directory. Files are exclusively
created as `{pid}.profile.jsonl` with mode 0600. No terminal text is recorded.
A missing or partial file means missing evidence, not zero work.

The root owns a fixed store of 64 thread banks, aligned to the target's
`std.atomic.cache_line`. A thread registers once, then writes its own counters.
Inner loops accumulate locally and merge on exit. The hot path performs no
profiling allocation or file output. Each counter saturates, each histogram
has 64 power-of-two buckets, and exports identify overflow and dropped threads.
Quantiles from these buckets are bounds, not exact durations.

The store occupies 163,968 bytes in enabled builds. Dumps happen after producers
stop. Worker banks are not read live. CPU fixture snapshots run on their writer
thread. B0 symbol inspection found no profiling banks, TLS or store; representative
optimized callers also have no counter updates. This is a checked compile-time
removal mechanism, not a claim that every byte of two builds was compared.

The catalog covers selected runtime, common-client, model, TUI and GUI boundaries.
It is not a census of every function in Telar. In particular, it does not yet
break GUI events down by tag or attribute every queue and foreign allocation.
Existing echo/frame probes supply delivery phases and frame IDs. No new IPC,
application callback layer, model representation or public GUI type was needed.

The GUI-owned `build-dod-probe` target exercises the real CPU renderer, agent
layout and diff widget. `build-bench` builds the existing benchmark binary without
running it. The Python tools reuse existing runtime/window isolation and latency
fixtures. The native split fixture now creates eight panes with balanced splits;
sequentially splitting the same pane had exhausted its minimum width.

## Collection coverage

| Workload | Actual collection | Boundary and limits |
| --- | --- | --- |
| CPU renderer | 80x40 and 160x40; retained, sparse, full, theme, resize, selection and font invalidation; five alternating B0/B2 pairs | 200 warmup and 1,000 measured draws, except font replacement with 2 and 10; CPU only |
| Existing kernel suite | Five B0/B2 pairs, 10 samples of 40 ms per benchmark | Batch average costs, not individual-event tail latency |
| Native typing | Five B0/B2 pairs, 20 warmup and 200 measured inputs each | 1,000 observations per build; committed-text injection to matching pixels at Metal completion |
| Native pane/tab scaling | B2, 4 and 8 visible panes, separately 8 tabs; 50 measured inputs each | Exploratory single runs; fixed 1600x1000 viewport |
| Native background output | Two attempts, 4 panes, 1 MiB/s per background producer | Rejected because some checkpoint rates missed the 5% tolerance |
| Native idle/scroll/full | One 30-second capture per case, 5-second workload warmup, about 21 seconds inside the steady window | Frame IDs and GPU/main completions; separate short captures recover loss-free core traces |
| Workspace lookups | 1, 8 and 64 populated tabs; 1,000 batches per CPU run | Fixed hot lookup sequence, not random-access session latency |
| Agent thread | 32 synthetic messages, 1,000 resolves/draws per CPU run | Real retained layout; no provider/network or end-to-end snapshot replay |
| Review | 100 and 1,000 rows with search, 1,000 draws each | Plain syntax roles; excludes Tree-sitter. 10,000 rows explicitly rejected by the 1,024-row view limit |
| Runtime attached/detached | 8 MiB ASCII and ANSI per B0/B2 case | PTY write through DSR completion, not GPU presentation |
| Media and load | Five paired 4K inline compressed-image transfers and five paired input-under-output runs | Existing headless TUI probes; pixel checksum and timeouts checked |
| Slow host | Two corrected pairs, then one pair after atomic receipt publication | Foreground PTY child received all 32 input bytes while host reads were blocked |
| CPU/memory profiles | B0 native GUI sample plus vmmap; runtime/TUI sample; CPU probe Time Profiler and three CPU Counters modes | Separate captures. Allocations template timed out without usable data |

The initial plan proposed broader scales, five-second warmup everywhere, raw-key
and committed-text comparison, blinking variants and five repetitions for each
scenario. This first campaign uses the concrete coverage above. CPU fixture
warmup is iteration-based, native geometry is 88x21 cells at scale 2 rather than
120x40, and the largest CPU grid is 160x40. Hidden 64-tab storage is exercised by
the CPU fixture, not a native 64-pane session. These are exploratory baselines,
not full acceptance coverage for a subsequent optimization.

## Measured work and time

Median CPU time per measured iteration across five B0 runs:

| CPU fixture | Time | Median paired B2 overhead |
| --- | ---: | ---: |
| Retained terminal 80x40 | 38.865 µs | +2.30% |
| Full terminal 80x40 | 151.384 µs | +1.90% |
| Retained terminal 160x40 | 77.283 µs | +2.89% |
| Full terminal 160x40 | 305.073 µs | +1.63% |
| Agent, 32 messages | 63.868 µs | See individual runs |
| Review search, 100 rows | 145.311 µs | See individual runs |
| Review search, 1,000 rows | 442.987 µs | See individual runs |

B0 and B2 CPU fixtures completed equal iterations and checksums. The proposed
3% instrumentation budget does **not** pass globally. Tiny workspace lookup
batches show median overhead of about 224% to 302%. Use B2 for their work census
and B0 for timing. Do not subtract a guessed counter cost or treat B2 as an
uninstrumented performance baseline.

For each retained 80x40 draw, B2 records 3,200 mesh comparisons, 3,200 hits and
zero rebuilds. Two passes still visit 6,400 cells and make 6,400 covered
`CellMesh.items` calls. Doubling width doubles this work. Warm retained, sparse,
full and selection fixture draws have zero measured Zig allocations; that does
not cover foreign allocators or GPU allocations.

The first real B2 typing process records 253 GUI draws, 252 terminal pane draws,
499,648 comparisons, 483,723 hits, 15,925 rebuilds and 999,296 mesh-item accesses.
It applies 17,685 copied cells, or 565,920 logical bytes. These are whole-process
totals including startup and warmup. The mostly blank marker terminal emits far
fewer quads than the filled-letter CPU fixture, so their absolute costs cannot
be substituted for one another.

The 32-message agent fixture considers 32 rows and draws 10 visible rows per
iteration. Review search visits all 1,000 rows and 17,000 logical text bytes per
draw at the larger size. Layout also traverses rows; this does not isolate search
as the cause of the complete review-draw duration. The 64-tab lookup fixture
performs 64,000 lookups and 2,080,000 pane-model probes, averaging 32.5 probes.
That establishes scaling work, not a current user-visible bottleneck.

### Native latency and phases

| Build | Samples | p50 | p95 | p99 |
| --- | ---: | ---: | ---: | ---: |
| B0 | 1,000 | 8.750 ms | 26.249 ms | 35.571 ms |
| B2 counts | 1,000 | 9.451 ms | 24.844 ms | 34.528 ms |

These are exploratory pooled committed-text-to-GPU measurements. Run-level
medians remain in `summary.json`. They exclude physical keyboard latency and
display scanout. Lower B2 tail values are not evidence of an optimization.

| B3 steady workload | Prepared frames | Frames/s | Prepare p50 | Prepare p95 |
| --- | ---: | ---: | ---: | ---: |
| Idle | 10 | 0.476 | 0.432 ms | 0.597 ms |
| Scroll | 1,171 | 55.754 | 0.647 ms | 0.969 ms |
| Full redraw output | 1,170 | 55.711 | 0.657 ms | 1.015 ms |

Native traces report no lost native events or failed GPU/main completions.
A frame crossing the steady-window boundary accounts for the one-frame difference
between prepared and completed counts. Median observed GPU intervals are about
7.83 ms for scroll and 7.26 ms for full output. CPU preparation is only one part
of visible latency; frame pacing, drawable acquisition and GPU delivery remain
separate measurements.

Single-run B0 runtime throughput was 112.6 MiB/s ASCII and 105.3 MiB/s ANSI while
attached, and 111.7/105.9 MiB/s detached. B2 results are retained, but one run per
case cannot establish a throughput regression. The sampled runtime workload can
finish before its eight-second capture, so its sample includes idle time.
The GUI capture ran continuous full output. Its sample reported a 139.0 MiB
physical footprint and 215.9 MiB peak, distinct from allocator-requested bytes.

## Layout, access and hardware evidence

| Type or retained storage | Measured size | Interpretation |
| --- | ---: | --- |
| `Cell` | 32 B | Copied-cell accounting uses this size |
| `CellMesh` | 1,972 B | `paint` at 0, 1,920-byte `quads` at 48, `valid` at 1,968, `len` at 1,969 |
| `Quad` | 80 B | Retained quad payload dominates each mesh |
| 80x40 retained mesh array | 6,310,400 B | Derived from measured 3,200 capacity and element size |
| 160x40 retained mesh array | 12,620,800 B | Derived from measured 6,400 capacity and element size |
| `Pane` | 4,712 B | Inline composer field occupies 4,128 B at offset 480 |
| `TabsModel` | 535,144 B | Inline size, not total live heap |
| `AttachedClient` | 2,170,784 B | Contains nested state; do not add nested sizes again |
| `ThreadFlow` | 770,432 B | Large fixed layout storage |
| Review `Widget` | 616,984 B | Bounded view storage |

Renderer-plus-pane requested live bytes were 24,007,115 at 80x40 and 38,739,915
at 160x40. This includes more than retained meshes and excludes foreign/GPU
allocator internals. The existing 1x1 storage fixture uses 5,917,528 requested
bytes for 64 panes. Moving the inline composer alone could remove at most
264,192 inline bytes for those panes before replacement storage. `sizeof(Pane)`
is not the whole per-pane memory cost.

| Access | Work per retained draw | Address pattern | Lifetime/reuse |
| --- | --- | --- | --- |
| Current cell/paint vs cached paint and valid | One comparison per cell | Cell stride 32 B; retained mesh stride 1,972 B | Reused across unchanged frames |
| Cached `len` and quad payload | Two covered `items` calls per cell across two passes | Length at +1,969; quad payload at +48 | Retained geometry; variable used length |
| Review search lines | Every retained row for an active query | Variable-length slices, logical bytes counted | Same query can repeat across draws |
| Agent rows | 32 considered, 10 visible in this fixture | Retained row traversal and text layout | Rebuilt/resolved for each measured draw |
| Workspace lookup | Average 32.5 models at 64 tabs | Sequential tab search followed by pane lookup | Fixed hot IDs in the fixture |

The production `frame_widget.Widget.draw` disassembly contains the inlined
terminal draw loop and the `0x7b4` mesh stride. No forced `noinline` build was used.
The PMU sample used the separately hashed B0 CPU probe. Its sampled PCs map to:

| Sampled PC | Binary address | Instruction | Field | L1 load-miss samples |
| --- | --- | --- | --- | ---: |
| `0x10424a234` | `0x100122234` | `ldrb w10, [x10, #0x7b1]` | `CellMesh.len` | 40,915 |
| `0x104249054` | `0x100121054` | `ldrb w9, [x22, #0x7b0]` | `CellMesh.valid` | 31,490 |
| `0x104249bd4` | `0x100121bd4` | `ldp q0, q1, [x22, #0x30]` | Quad payload | 16,071 |

Of 144,438 sampled L1 load-miss events, 142,128 have
`ProfilingProbe.terminal` as the leaf, 98.4%. This is the mixed CPU fixture,
including setup and warmup, not 98.4% of all misses during general Telar use.
The exported event total is separate from the sampled events. Without a total-load
denominator, neither is a cache miss rate or a DRAM-byte count.

The separate processing-mode capture has a duration-weighted `Critical L1D Cache
Miss` fraction of 0.753% and `Critical L1D Cache Miss While Executing` of 1.656%.
These categories describe different overlap conditions. Do not add sample shares
to them or interpret the first as an application-wide fraction of CPU cycles.
Supported modes came from the installed Xcode registry; only a local copy of its
CPU Counters template was changed. See Apple's [CPU profiling explanation](https://developer.apple.com/videos/play/wwdc2025/308/)
and [CPU bottleneck guidance](https://developer.apple.com/documentation/xcode/addressing-cpu-bottlenecks)
for interpretation of hardware metrics and overlap.

Time Profiler attributes 999 of 2,512 running samples to the CPU fixture's terminal
leaf and 1,640 to its terminal workload ancestry. Inclusive and leaf weights are
not additive. In the real GUI's separate sample, `frame_widget.Widget.draw` has
163 leaf samples among Telar frames; glyph and cell comparison functions also
appear. Blocked-thread wait samples are not CPU execution time or call counts.

Production disassembly reserves fixed stack frames of 778,608 bytes in
`ThreadTranscript.draw`, 112,176 in `Scene.prepare` and 92,288 in `GuiClient.draw`.
These are individual frames, not measured maximum stack use. Reservation alone
does not show how many bytes each invocation touches.

## Ranked experiments

| Priority | Observation and hypothesis | Competing explanation | Isolated experiment and rejection condition |
| --- | --- | --- | --- |
| 1 | Mesh comparison/length loads are spread over 1,972-byte entries. Compact metadata could reduce working-set pressure. | Most latency is elsewhere; full redraws still need geometry; extra indirection can cancel savings. | Split only comparison metadata/length from payload. Compare B0 candidate against B0 baseline for retained, sparse and full cases plus native input. Reject if repeated CPU/memory benefit is absent or redraw/input tails regress. |
| 2 | Unchanged draws traverse the full grid twice. Valid revision/dirty information could avoid work. | Global invalidations, cursor, selection and glyph changes can require traversal. | Change traversal policy separately, preserve every invalidation and delivery rule. Reject if equivalent correctness still requires the same work or bookkeeping dominates. |
| 3 | Review search scans every line on repeated draws. | Layout or shaping may dominate the observed time. | Cache only match count using query and content revision; compare empty/unchanged/changed query controls. Reject if correctness invalidations erase the gain or total draw cost is unchanged. |
| 4 | Agent drawing carries a large `ThreadFlow` and considers offscreen rows. | Fixed storage avoids allocations and 32-row traversal may be cheap. | First isolate resolve versus draw and measure touched stack/storage; then test retained layout or smaller scratch lifetime. Reject if copies/resolution do not consume meaningful CPU or memory. |
| 5 | Tab lookups grow with tab count; panes carry inline composer storage. | Normal tab counts are small; other pane allocations dominate. | Profile actual large sessions before indexing tabs or moving composer storage. Reject unless measured session CPU or retained memory improves after maintenance costs. |

The first two are separate experiments even though they affect the same loop.
No global score combines samples, call counts, bytes and latency. No hypothesis
requires changing runtime ownership or flattening all state into one structure.

## Rejected and unavailable evidence

- Instruments Allocations failed to finish within 90 seconds. Requested-byte
  accounting, native footprint and vmmap remain available; foreign allocation
  attribution is unavailable.
- Long scroll/full core echo traces dropped 8,528/8,982 records. They cannot
  reconstruct complete causal spans. Replacement short traces have zero drops.
  Native frame traces use their own recorder and remained complete.
- The first eight-pane attempt could not create eight panes. Balanced splitting
  fixed the fixture, and the rerun reports eight created panes.
- Both native 1 MiB/s load attempts missed at least one checkpoint tolerance.
  The second missed 0.95 MiB/s in one producer's first checkpoint, measuring
  0.9412. Neither is included in qualified constant-load comparisons.
- The first slow-host probe used absent diagnostics and returned invalid zeros.
  Those results are excluded. A real foreground raw PTY reader now publishes
  atomic byte-count receipts; all six corrected runs received 32/32 bytes before
  the host was drained.
- Review data above 1,024 rows is rejected. Large-diff behavior and Tree-sitter
  costs are outside this fixture's evidence.
- Hardware instructions-retired, total load count, LLC/DRAM bandwidth, complete
  call census, idle wakeup attribution and exhaustive foreign allocations are
  not supplied by this report. Missing events are not assigned zero.

## Reproduction

Run builds before measurements, and run measurements serially. Use a fresh output
root; the tools reject existing section directories. Native probes create and
close isolated windows and runtimes and temporarily take focus.

```sh
zig build build-dod-probe build-bench -Doptimize=ReleaseFast --prefix /tmp/dod/B0
zig build -Doptimize=ReleaseFast --prefix /tmp/dod/B0
zig build build-dod-probe build-bench -Doptimize=ReleaseFast -Dprofile-counts=true --prefix /tmp/dod/B2
zig build -Doptimize=ReleaseFast -Dprofile-counts=true --prefix /tmp/dod/B2
zig build -Doptimize=ReleaseFast -Dprofile-timing=true -Decho-trace=true -Decho-trace-cpu=true --prefix /tmp/dod/B3

python3 tools/dod_measure.py --b0 /tmp/dod/B0/bin --b2 /tmp/dod/B2/bin --b3 /tmp/dod/B3/bin --output /tmp/dod/results --section kernels
python3 tools/dod_measure.py --b0 /tmp/dod/B0/bin --b2 /tmp/dod/B2/bin --output /tmp/dod/results --section native
python3 tools/dod_measure.py --b0 /tmp/dod/B0/bin --b2 /tmp/dod/B2/bin --output /tmp/dod/results --section runtime
python3 tools/dod_measure.py --b0 /tmp/dod/B0/bin --b2 /tmp/dod/B2/bin --b3 /tmp/dod/B3/bin --output /tmp/dod/results --section traces
python3 tools/dod_measure.py --b0 /tmp/dod/B0/bin --b2 /tmp/dod/B2/bin --output /tmp/dod/results --section capabilities
python3 tools/dod_pmu.py /tmp/dod/B0/bin/telar-dod-probe /tmp/dod/results/pmu/processing --mode processing
python3 tools/dod_pmu.py /tmp/dod/B0/bin/telar-dod-probe /tmp/dod/results/pmu/l1d_miss_sampling --mode l1d_miss_sampling
python3 tools/dod_gui_profile.py /tmp/dod/B0/bin/telar /tmp/dod/results/gui-profile
python3 tools/dod_assembly.py /tmp/dod/B0/bin/telar /tmp/dod/results/assembly/B0
python3 tools/dod_assembly.py /tmp/dod/B2/bin/telar /tmp/dod/results/assembly/B2
python3 tools/perf_e2e.py --baseline /tmp/dod/B0/bin/telar --candidate /tmp/dod/B2/bin/telar --output /tmp/dod/results/media --samples 100 --repetitions 5 --cases graphics load slow-host
python3 tools/dod_report.py /tmp/dod/results /tmp/dod/report
```

`dod_profiles.py` consumes exported Instruments XML. Export `MetricTable` from
`CPU Counters.trace` to `CPU Counters-MetricTable.xml`, and `time-profile` from
`Time Profiler.trace` to `Time Profiler-time-profile.xml` in `capabilities/`.
Use `xcrun xctrace export --input TRACE --toc` to verify the run/table, then
`--xpath '/trace-toc/run[@number="1"]/data/table[@schema="SCHEMA"]' --output FILE`.
Then run `python3 tools/dod_profiles.py /tmp/dod/results/capabilities /tmp/dod/report/cpu-pmu.json`.
The PMU mode tool exports its additional tables itself. The collected table
schemas and full commands are retained with each capture.

Correctness verification completed with 139/139 build steps successful and
3,024/3,026 tests passing, two skipped. This includes the four profile tests,
source layout checks and client/model import boundaries. Saturation, histogram
bounds, registration capacity, concurrent bank ownership and serialization errors
are tested. The bounded recorder's existing tests cover its trace behavior.
