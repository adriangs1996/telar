# Data access measurement plan

Status: instrumentation implemented and an exploratory campaign collected.
See [the baseline report](../performance/dod-baseline/README.md) for measurements,
rejected captures, coverage differences and ranked experiments. No application
DOD representation change has been made. The plan below records the original
measurement targets; the report states what was actually collected.

Inspected revision: `adf2acc4c5b0741d893d27336eb411462c3b7b72`.
Environment checked on 2026-09-22: Apple M3, macOS 26.6.2, Xcode 26.1,
Zig 0.16.0. Recheck these values when collecting results.

## Decision to support

Identify which recurring operations read or write which data, how much work they
perform, and which costs affect users. Produce ranked, falsifiable hypotheses
before choosing AoS, SoA, split storage, pooling or fewer traversals.

Keep GUI, TUI and runtime results separate. Each run records process, thread,
scenario, phase and amount of completed work. Attribute dependency costs such as
VT parsing, HarfBuzz, FreeType and Metal without treating them as Telar-owned code.
Do not combine scenarios into one ranking without explicit usage weights.

A function-call count, a loop iteration count and a CPU sample count are different
measurements. A once-per-frame loop can dominate data access without its function
being called frequently. A very frequent function can use the same few bytes.

## Existing tools and missing evidence

| Existing implementation | Reuse | Gap to close |
| --- | --- | --- |
| [Client metrics](../../src/client/resources/Metrics.zig) | Input, frame, cell, span, composition and transport counters; phase timings | Verify actual update sites and adapter coverage; a declared field is not evidence that GUI updates it |
| [Runtime metrics](../../src/backend/runtime/observability/RuntimeMetrics.zig) | PTY volume, ingest, encoding, damage scans, coalescing and media counters | Separate selected phase costs and normalize by completed bytes/cells |
| [Timing](../../src/core/Timing.zig) | Count, total and maximum duration | No distribution: percentiles cannot be recovered from these aggregates |
| [Heap](../../src/core/Heap.zig) | Allocation accounting by interactive, media and observation path | Does not cover every foreign allocation, GPU allocation or mapped page; complement with host tools |
| [Echo trace](../../src/core/echo_trace.zig), [Recorder](../../src/core/Recorder.zig) | Bounded phase records, optional thread CPU clocks, shutdown dump, explicit dropped-record count | No operation identity; interleaved concurrent flows cannot be paired by adjacent timestamps |
| [Storage report](../../benchmarks/client_storage.zig) | Type sizes and requested allocation bytes for 0, 1, 8 and 64 panes | Current pane fixture is 1x1; add actual cell sizes, GUI retained storage and allocation owners |
| [Benchmarks](../../benchmarks/main.zig) | Damage, encode/decode, composition, input, layout and graphics cases | Controlled kernel costs do not establish real-session frequency; native draw and agent replay need targeted cases |
| [GUI latency probe](../../tools/gui_latency.py) | Isolated runtime, native key injection, exact matching Metal completion | One outstanding key, at most 512 samples per invocation; excludes physical keyboard and display scanout |
| [Terminal runtime probe](../../tools/terminal_runtime_bench.py) | Reproducible PTY workload, runtime/client sampling and detached-runtime case | Headless TUI and DSR completion are not native GPU presentation |
| [Paired suite](../../tools/perf_suite.py) | Serial execution, alternating baseline/candidate order and raw output | Extend reporting and fixtures without inventing another benchmark scheduler |

The existing coverage build uses fuzz instrumentation. Its coverage results are
not a global function invocation census. Audit counter semantics before using
any compiler-generated counter as a frequency measurement.

## Collection modes

All performance comparisons use optimized builds with recorded CPU target,
compiler version, flags, dependency versions and executable hash. Use Debug for
correctness investigations, not as the performance baseline.

| Mode | Purpose | Instrumentation |
| --- | --- | --- |
| B0: baseline | User-visible latency, throughput, idle CPU and memory | ReleaseFast, no optional diagnostics/tracing and no attached profiler |
| B1: sampled | Locate time and cycle concentration | Same B0 executable, CPU Profiler or Time Profiler attached |
| B2: counts | Measure selected calls, iterations and work | Opt-in counters; no per-call timestamps or logging |
| B3: phases | Separate execution, queuing and delivery waits | Existing echo markers in short captures; add only missing coarse spans and safe correlation |
| B4: memory | Attribute allocations, retention and CPU memory stalls | Storage report, allocator accounting, separate Allocations/CPU Counters captures |

Counters and phase timing are independently selectable through the implemented
`-Dprofile-counts` and `-Dprofile-timing` flags. Existing trace controls remain
`-Ddiagnostics`, `-Decho-trace` and `-Decho-trace-cpu`. Record the effective
combination for every run.

Keep production code generation free of profiling branches and buffers when
profiling is disabled. Inspect representative B0 assembly and record sizes to
check this, rather than assuming a compile-time switch removed everything.

## Workloads

The following durations, scales and repetition counts are proposed experiment
settings, not measured properties of Telar.

Start with a fixed 120x40 terminal grid and record the actual native viewport,
font, scale and refresh rate. Repeat cell-heavy cases at 240x80 if the host can
provide that geometry; record and compare actual dimensions, never requested
window dimensions. Keep total viewport area fixed when varying visible panes.

| Scenario | Controlled stimulus | Primary evidence and completion condition |
| --- | --- | --- |
| Idle | 1 and 8 panes; repeat with cursor blinking enabled/disabled | CPU, wakeups and frames after initialization; unchanged scene |
| Typing | Existing cat key/erase probe, empty and dense scene | Matching GPU completion, phase delays and work per accepted key |
| Sparse updates | Deterministic one-cell and fragmented-row updates | Cells visited, compared, changed and rebuilt per delivered update |
| Scroll/output | Fixed-seed plain and styled Unicode payloads at paced and saturated rates | Accepted PTY bytes, final terminal-state validation, throughput and input latency under load |
| Multiple panes | 1, 4 and 8 visible panes; separately 8 and 64 live panes with most hidden | Work per visible cell; hidden-pane parsing and publication; memory by pane kind |
| Tabs/workspaces | 1, 8 and 64 populated tabs; fixed switch and focus sequence | Metadata scans, lookups, allocations and latency per completed switch |
| Agent conversation | Deterministic replay of synthetic thread snapshots, growing text and tool output | Snapshot bytes, items visited, layout work and completion latency; no model/network randomness |
| Change review | Fixed diff with 100, 1000 and 10000 lines; scroll, search and range selection | Visible versus total lines processed, highlighting/layout reuse and interaction latency |
| Resize/invalidation | Alternate two fixed geometries; change theme, font and selection | Full invalidation cost and correct final image/state; separate from steady state |
| Media contention | Text input plus bounded image updates | Input tail latency, media queues, drops and retained resources |
| Runtime detached | Same PTY workload with client detached | Runtime-only parsing cost and absence of client rendering work |

For agent and diff scenarios, use existing snapshot/test-fixture builders after
checking their limits. Report fixture rejection instead of silently truncating
an oversized dataset. Record every scaling value in the run manifest.

Per scenario: initialize, warm for at least five seconds and verify fixture
readiness, measure a 30-second steady interval or a fixed completed workload,
then capture the final state and shut down. Cold start and first text/image use
are separate measurements. Warm readiness requires stable configuration and
initialized resources; it is not merely a delay.

Use five independent repetitions initially and alternate comparison order.
Extend to ten when between-run variation makes a proposed gain inconclusive.
Run profiling, benchmarks and builds serially during timing measurements.
Keep power mode, foreground status, font/theme, host geometry and background
load recorded. Reject runs whose viewport or workload completion differs.

Do not interpret an isolated small-sample p99 as stable. For key latency, collect
at least 1000 completed events across separate probe runs, retain each run's
quantiles and sample count, and label the aggregate as exploratory. Respect the
GUI probe's 512-event limit and inspect trace saturation separately.

## Instrumentation inventory

Create a metric catalog with a stable enum ID, exact meaning, unit, owning
process, source function or loop, included call sites, and excluded paths.
All exports name this catalog revision. No unlabeled generic "hits" field.

| Boundary or loop | Counters to collect | Access question |
| --- | --- | --- |
| `GuiClient.update`, `dispatch`, `drainInput` | Turns, events by tag, accepted keys, queue depth and deferred work | Are we doing work without new input, or waiting behind another workload? |
| `AttachedClient.receiveRuntime`, `applyPaneFrame`; model `Pane.applyFrame` | Messages, snapshots/patches, input cells, applied spans, rejected/stale frames and logical copy bytes | What work reaches the owned model, and how much is superseded before display? |
| `Scene.prepare`, `TerminalRenderer.drawPane` | Calls, visible panes, cells visited by each pass, comparisons, cache hits/misses, rebuilt cells, emitted quads | Is cost proportional to changed cells or the whole viewport? |
| `CellMesh.matches`, `replace`, `items` | Covered call counts; equality outcomes; retained and used quad capacity | Are comparison inputs mixed with geometry that this pass does not need? |
| `MultiplexerModel.find/findConst`, `GenericPaneIterator.next`, layout snapshots | Lookup calls, successful lookups, slots inspected, live panes and snapshot rebuilds | Does pointer traversal matter under realistic pane counts? |
| TUI `Compositor` and `Screen` | Compositions, visited/changed cells, encoded bytes and partial delivery | Separate shared model costs from host-specific presentation costs |
| Runtime `pane_pipeline.ingestPane`, `blit.blit`, `damage.collectSpans` | PTY batches/bytes, projected cells, dirty rows, equality calls, comparisons, spans and wire bytes | Is the expensive traversal parsing, projection, comparison or encoding? |
| Agent and review drawing after CPU discovery | Items/lines received, visited, visible and laid out; cache rebuilds | Does a small visible update rescan retained history or the whole diff? |
| Allocation and teardown boundaries | Requested, live and peak bytes, allocation/reallocation counts and retained capacity by owner | Which memory is fixed, pane-specific, temporary or retained after use? |

Inventory every update site of existing metrics before adding a counter.
Reuse returned algorithm statistics where their meaning matches. For example,
`damage.collectSpans` already reports scanned cells, but its nested comparisons
can call cell equality more than once for a cell. Do not equate those counts.

### Counting without introducing another application framework

- Store optional counters with the existing GUI, client or runtime resource
  owner. Worker-local counts travel back as owned diagnostic totals and merge
  at the existing completion boundary. Diagnostics add no backreference to
  `AttachedClient` and no host dependency to `model`.
- Batch inner-loop statistics locally and merge once per operation. Count a
  call at its entry when the owner is available. For pure leaf functions,
  enumerate all instrumented call sites and count locally around those calls;
  the catalog must state coverage. Do not export functions merely to profile them.
- First-pass counts describe logical source calls at those sites, including
  calls the optimizer inlines. They do not describe machine `call` instructions.
- Avoid a shared atomic increment per cell or glyph, dynamic string IDs,
  allocations and log formatting in measured loops. Each mutable counter bank
  has one writer. A snapshot is read on its owner or after producers join.
- Use fixed-width saturating counters with an overflow marker. Proposed initial
  bound: 128 metric IDs and 64 timing buckets per timed phase, checked at build
  time. Export actual instrumentation bytes and reject catalog overflow.
- Keep counters cumulative within a run. Capture warmup and endpoint snapshots
  on the owner and compute deltas. This avoids racing resets against workers.
- Export once after measurement and producer shutdown. If a process fails before
  that point, record the run as incomplete. A failed diagnostic sink must not
  change the application's scheduling or backpressure.

The initial report ranks only catalog-covered function calls. It must not claim
"most called function in all Telar" from partial counters or CPU samples.
Expand the catalog to investigate cheap high-frequency helpers as well as CPU
hotspots. A complete source-function census across Zig generics, inlining and
foreign libraries would require a separate compiler-instrumentation experiment;
it is not a prerequisite for data-access hypotheses and is not promised here.

### Timing, queues and causality

Reuse `Timing` for totals and maxima. For selected coarse phases, add bounded
histograms with documented bucket limits and overflow. Histogram percentiles
are intervals, not fabricated nanosecond precision. Retain raw observations only
in short bounded captures when exact quantiles are required.

Wall elapsed time and thread CPU time answer different questions. CPU intervals
must start and end on the same thread within a synchronous span. Never subtract
thread CPU timestamps across an asynchronous suspension or different processes.
Async spans use monotonic wall timestamps and explicit operation identity.

The existing echo tags are sufficient for the single-outstanding-input probe.
For concurrent analysis, reuse available request/frame/attachment identities in
an opt-in trace record, plus a process run ID and synchronous span ID where
needed. The recorder owns values only. No application pointers or terminal
contents are retained. Local sequence numbers are not cross-process causal IDs.
When events lack a real causal identity, report phase distributions separately
instead of inventing an input-to-frame pairing.

Keep the existing 16384-record cap initially, shorten captures when needed and
retain the dropped count. Any capture with losses is incomplete for end-to-end
span reconstruction; unaffected complete counters can still be reported with
that limitation. Record accepted, queued, folded, rejected and completed work
separately. Fewer frames caused by coalescing are not faster processing by default.

## CPU profiling and hardware counters

Use CPU Profiler or Time Profiler to discover active functions and calling
contexts in optimized GUI and runtime binaries. Retain own and inclusive cost;
never add inclusive costs of callers and callees as disjoint totals. Record
unresolved symbols and dependency frames instead of attributing them to Telar.
Run separate comparable captures for each process; the OS profiler remains
external to Telar's control flow.

Time Profiler samples execution and cannot determine exact invocation counts.
Apple documents this in [Determining execution frequency](https://developer.apple.com/tutorials/instruments/determining-execution-frequency).

Local `xctrace` lists CPU Profiler, Time Profiler, CPU Counters and Processor
Trace, and `llvm-objdump` is installed. Template listing does not prove hardware
support or attach permission. The inspected Mac has an M3. Apple's
[CPU profiling session](https://developer.apple.com/videos/play/wwdc2025/308/)
specifies M4 support for Processor Trace on Mac, so this plan does not depend on
hardware tracing of every function call.

First perform a short capability capture with CPU Counters. Record supported
event names, units, scope, attribution, any sampling/multiplexing and tool version.
Collect cycles, instructions, load/store stalls, branch events and cache/TLB
metrics only where supported. Missing events are `unavailable`, not zero. Refer
to Apple's [CPU bottleneck guidance](https://developer.apple.com/documentation/xcode/addressing-cpu-bottlenecks)
when interpreting the available events. A missing PMU facility reduces confidence
in a cache hypothesis; it does not block CPU, logical-access or storage analysis.

If a separate frame-pointer build is needed for readable stacks, retain both
binaries and measure that build's effect. Do not silently substitute it for B0.
Do not disable inlining or optimization just to make a preferred function appear.

## Data layout and assembly

Extend the existing storage probe with `@sizeOf`, `@alignOf` and `@offsetOf` for
selected types and fields. Include `Pane`, `Tab`, `TabsModel`, `Cell`, `CellPaint`,
`CellMesh`, retained cells and quad storage. Obtain GUI-private layouts through
a GUI-owned probe, without making private files public or reversing imports.

Separate inline capacity, live heap payloads, allocator overhead, RSS, shared
mappings and GPU memory. Nested `@sizeOf` values must not be added together.
Use small and realistic terminal geometries; the current 1x1 fixture isolates
some per-pane costs but is not representative of cell storage.

For each ranked loop, produce an access table:

| Field or array | Read/write | Elements per operation | Stride | Indirection | Reuse and lifetime |
| --- | --- | --- | --- | --- | --- |
| Populate from the selected loop and generated code | R / W / both | Measured or explicitly derived | Bytes or irregular | Dependent loads | Within loop / across frames / rare |

Analyze the exact B0 executable used for the profile. Preserve its hash and debug
information. Correlate inlined instructions with their callers and source ranges.
On this host the installed disassembler accepts:

```sh
xcrun llvm-objdump --disassemble --demangle --line-numbers --source /path/to/profiled/telar > /path/to/run/assembly.txt
```

Inspect AArch64 loads/stores, indexed strides, dependent address chains, copies,
stack spills, vector operations and branches in the measured loops. Separate
loop-carried work from setup and teardown. Large stack reservation alone does
not prove those bytes are accessed on each iteration; a load does not prove a
cache miss. Fewer instructions do not by themselves establish a faster path.

Compiler help also exposes `-femit-asm` and optimized LLVM IR emission. These are
compiler options, not existing `zig build` project flags. Add a targeted build
artifact only if binary disassembly cannot answer the question; preserve the
production target and module graph. A microbenchmark's assembly must be checked
against the real caller before its result is generalized.

Count logical bytes read/written or copied only with an explicit accounting
rule. They are not measured DRAM traffic: compiler elimination, cache reuse,
cache-line fetches and writebacks change physical traffic. Record proposed
cache-line footprints as estimates using the target's verified line geometry.

## Instrumentation cost and validity

Run B0 versus B2 on identical fixtures before trusting B2 counts as representative
of normal scheduling. Compare completed work, input latency, CPU, allocations,
queue depth, frame folding and memory. Repeat separately for B1, B3 and B4;
do not enable every profiler and recorder at once.

As an initial experiment gate, investigate any repeatable overhead above 3% in
median CPU time per fixed unit of work. This is a proposed budget, not a known
instrumentation cost. Scheduling/folding changes invalidate timing attribution
even below that percentage. Reduce counter density or capture duration when
needed; do not subtract a guessed constant overhead from candidate timings.

Tests for the instrumentation must cover counter ownership and merging,
overflow, bounded histograms, dropped traces, dump failure, disabled builds and
failure/cancellation paths. Differential fixtures must produce the same final
cells, focus, generations and review state in B0 and B2. Validate existing
presentation retry and resource-retirement behavior.

Keep the [engineering invariants](../engineering-invariants.md) and
[presentation contract](../../src/client/presentation/README.md): no allocation,
file output or blocking profiler operation in steady interactive work; no
protocol change; no borrowed model pointer in async measurement records; no
retirement of damage before the existing successful delivery boundary.

## Results and hypothesis register

The proposed runner records one fresh output directory per run, using the
existing isolation helpers. It closes only processes and windows created for
that run. It never attaches workloads to the user's live runtime or edits
personal configuration.

Retain these artifacts:

- `manifest.json`: source revision and dirty-patch hash, binary hashes, compiler,
  target/CPU, flags, dependencies, OS, tools, config and fixture hashes, random
  seed, process identities, viewport, workload counts, warmup and repetition.
- `counts.jsonl`: catalog ID, owner, phase, counter value, unit, coverage and
  completeness. Every rate names its denominator and observation interval.
- `latency.jsonl`: measurement endpoints, raw samples or histogram bounds,
  sample counts, failures and dropped observations.
- `cpu.trace` and exported call trees per process; `pmu.json` with availability,
  units and attribution. Sample counts remain labeled as samples.
- `storage.jsonl`, `layout.json`, and annotations of selected disassembly with
  binary hash and source ranges.
- `summary.md`: per-scenario rankings, five-run variation, own/inclusive cost,
  calls or iterations per work unit, memory, unknowns and links to raw evidence.
- `hypotheses.md`: observation, proposed mechanism, competing explanation,
  isolated experiment, expected outcome and rejection condition.

Report per-scenario rankings by own CPU cost, covered call frequency, loop work,
allocation cost and user-visible latency. Do not multiply these into an arbitrary
single score. Benchmark p95/p99 of batch averages are not per-event latency
percentiles. Preserve run-level results rather than pooling away variance.

Examples to test, not current conclusions:

| Hypothesis | Required evidence | Isolated experiment | Rejection condition |
| --- | --- | --- | --- |
| Cell comparison walks bulky geometry records | Native comparison loop consumes relevant CPU; layout/disassembly confirms stride and accessed fields | Compact comparison inputs separate from retained geometry | No reproducible gain in B0 or extra copying cancels it |
| Unchanged views still trigger excessive traversal | Visited/changed ratios and phase CPU rise with viewport while changed cells stay fixed | Reduce work through valid dirty-region or revision information | Comparison is cheap or correctness requires equivalent invalidations |
| Pane traversal is limited by dependent loads | Frequent traversal, dependent address chain, scaling evidence; PMU support if available | Dense descriptors or a pool, without changing pane authority | Typical pane counts show no useful gain or lookup maintenance dominates |
| Agent-only state wastes terminal pane storage | Per-kind allocation inventory and current inline fields | Allocate bounded agent state at agent activation | Memory saving is negligible for real sessions or lifecycle costs outweigh it |
| Tab metadata traversal carries large inactive models | Live/reserved layout and actual tab-access profile | Compact tab metadata with separately owned content | Operation is rare/cheap or retained memory does not improve |

Change one representation or traversal policy per experiment. Compare B0
baseline/candidate in alternating order and check correctness before timings.
Retain an inconclusive or negative result. The next refactor is selected by the
measured user impact and data-access evidence, not by a preselected SoA design.

## Delivery order and completion gates

1. Inventory current metrics and benchmark coverage, save B0 artifacts and verify
   CPU-profile symbolization. Complete when every planned measurement has a
   source or an explicit gap and process endpoints are reproducible.
2. Extend isolated fixtures for missing native, agent and review cases. Complete
   when readiness, final-state checks, cleanup and repeated workloads agree.
3. Add opt-in counts and selected phase distributions with bounded storage.
   Complete when instrumentation tests and the B0/B2 equivalence and overhead
   checks pass. This step changes diagnostics, not model representation.
4. Collect the scenario matrix serially, then inspect selected layouts and B0
   assembly. Complete when each result has raw evidence, units and coverage;
   unsupported hardware data is explicitly unavailable.
5. Produce the hypothesis register and select the first experiment. Complete
   when each candidate names a measurable mechanism, an alternative explanation,
   an expected result and a rejection condition. No performance improvement is
   claimed by this analysis alone.
