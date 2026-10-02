# Access clusters and optimization roadmap

Status: source and counter census completed on 2026-10-01 at `43567b04`;
implementation stages proposed. No production representation has changed.
Evidence: [current census](../performance/access-clusters/README.md) and
[raw counts](../performance/access-clusters/counts.json).

The subsequent [Codex–Fable agreement](memory-design-agreement.md) adds the
[record-placement evidence](../performance/record-placement/README.md), stable
segmented pools, retained-backing accounting and a layout × placement experiment
matrix. It refines this roadmap without claiming a production speedup.

The agreed direction is to group data by the operation consuming it, allowing
multiple representations when their reuse pays for additional memory and update
work. Telar-owned memory is the scope; child processes are measured separately.
The [memory budget](memory-budget.md) must charge every retained representation.
An allocator supplies bounded backing; it does not select a data layout or keep
copies coherent. Establish the useful representations before designing a general
`prepareFor` allocator interface.

## Frequencies and units

Use three independent rates: runtime events/s (`E`), prepared GUI scenes/s (`F`)
and changes to a projection's inputs/s (`U`). Record completed presentations/s
separately from preparation attempts and retries. Also record PTY bytes and
batches, delivered cell frames, changed cells and metadata revisions. `E`, `F`
and `U` are not interchangeable; an output flood may generate many runtime
events before the next paced presentation.

The census establishes work **per invocation**. It does not establish live Hz
on Adrian's workload. Frame pacing limits scheduling; it is not a measured
execution frequency. Historical trace rates must not fill that gap.

| Cluster and trigger | Current accesses together | Frequency / work established | Representation to evaluate |
| --- | --- | --- | --- |
| Runtime delivery eligibility after an event | Pane cell/cwd/title/foreground/progress revisions, render/exit/media flags; attachment observed revisions, outstanding frame, deadline and graphics status | One flush per non-stop runtime event; pending mask scans attachments, final pass scans pane slots. Hz unmeasured | Dense delivery columns indexed by stable internal slots; compare against a pending set maintained by transitions |
| PTY ingest, screen projection and per-client damage | PTY bytes + VT state; then row damage + current/acknowledged cells + text metadata; then wire spans | Ingest follows PTY batches; damage scans dirty rows × width per eligible attachment. Frames are paced/coalesced | Keep sequential row buffers; evaluate row summaries/ranges only where producer information is available |
| GUI cell validation | Source cell bytes/style/width + retained visual key/validity + physical rect + selection | 6,120 comparisons per draw at 153×40, even for one changed cell | Retain visual preparation by pane/row generations; visit changed rows/ranges for comparison, preserve fallback |
| GUI quad emission | Background-present flag; ink length; primary/overflow quads; clipping/cursor/layer | Another 6,120 metadata visits per same draw; quads still emitted for the scene | Separate small emission descriptors from comparison keys if measurement supports it; contiguous runs without rebuilding/copying a second complete scene |
| Sidebar/card text and fleet navigation | Machine/session/pane identities, parent/project/order/card shape; title, status, elapsed time, bounds and shaped glyphs | Order is already revision-cached. Drawing still visits list entries; 65-byte unchanged titles cause 1–2 shaping calls per card/draw in the fixture | Cached row heights/offsets and bounded prepared label runs, with stable text separated from animated status |
| Image placement and residency | Machine/image generation, placement, geometry/layer; texture residency/lease/last use/bytes | Resolution is revision-guarded; maintenance runs at preparation. Renderer checks three image layers | Existing SoA/dense occupancy first; layer spans or maintenance indexes only if measured scans justify them |
| Focus/input/layout | Active tab + layout snapshot + focused pane modes and bounds | Per semantic input/capture; pane lookup already indexed, layout already revision-cached | Keep existing layout projection; avoid a second model-wide copy without a measured lookup cost |
| Client revision capture | Presentation revision counters and versions read by `ClientModel.version()` | Per version capture; current live rate unmeasured. Earlier client-model trace found scattered counters | Compact canonical revision fields, evaluated for both read/write cost and displacement of neighboring data |
| History/proxy observation | Queued record identity + bounded payload + batch/storage fields | Per record/batch, outside rendering; no current rate census | Preserve queue/batch ownership; optimize independently if observation CPU/memory competes with interactive work |

The two renderer rows are intentionally separate: comparison reads a substantial
visual key; emission mostly needs lengths/flags and geometry. They have the same
draw trigger but different field sets. Conversely, runtime delivery is hot even
when no new visual representation is needed. A single frame arena cannot capture
these distinctions.

For each cluster, compare a compact array of records when fields are consumed
together against columns when a loop reads only a subset. Use row-sized blocks
where the operation itself is row-based. Contiguity is useful only if traversal
order follows it; packing unrelated cold values into the same record can increase
traffic. Do not align every record to a cache line or assume a universal line
size. Inspect actual offsets/strides and measure on the target architecture.

Sources for each row and already implemented caches are linked in the census.
These are candidate access clusters, not a claim that each merits another copy.

## Ownership and invalidation contract

Every experiment specifies these before changing a layout:

1. **Authority and owner.** Canonical runtime facts stay in `RuntimeModel`;
   client state stays per connection in `ClientModel`. Renderer-owned quads,
   glyph resources and widget presentation caches stay with the adapter. Derived
   semantic indexes belong to the model, not a new controller or service.
2. **Inputs and writers.** List the exact source columns and all procedures that
   mutate them. Reuse existing revisions where sufficient. New revisions are
   needed only when existing ones cannot distinguish the required changes.
   Runtime delivery indexes are updated on their owning event loop; an ingest
   worker reports completion rather than concurrently mutating that index.
3. **Identity.** Retained references use IDs and generations. Fleet keys include
   machine identity/generation plus pane/session identity. Table slots are only
   valid while their owning generation and structural version remain valid.
4. **Lifetime.** Synchronous preparation may borrow data; retained views own
   their values. Frame completion cannot release storage still leased by a GPU
   upload, asynchronous consumer or another connection. An allocator-mode switch
   must never invalidate live reservations.
5. **Invalidation.** A visual key includes relevant content, attachment, geometry,
   font/atlas resource epoch, theme, scale, selection, cursor, scroll and focus.
   Separate keys when only an overlay changes. Skipped frames, rejected frames,
   reconnect and slot reuse must not hide updates.
6. **Budget and fallback.** Bound descriptors, text/glyph storage and retained
   capacity; include old/new overlap during replacement and in-flight storage.
   A full optional cache falls back to the correct reference path. It does not
   drop input, corrupt a frame or borrow observation/media capacity unboundedly.

Preparation reuse is independent of delivery acknowledgement. In particular,
renderer comparison generations cannot consume damage that belongs to an
uncompleted presentation. Preserve complete scene output and all layer ordering.

## Roadmap

### 0. Complete the frequency and cost baseline

Reuse [DoD instrumentation](dod-measurement.md), existing CPU probes, native
latency runner and telemetry. Do not introduce a second metrics framework.

- Add opt-in runtime event-tag/flush counters, attachment candidates examined,
  productive preparations, pane slots examined, and dirty rows/cells. Attribute
  inline and worker ingest separately without counting the same bytes twice.
  Count pane/attachment dereferences and inventory inline worst-case payloads;
  include the fixed cost of session records and all machine-client slots.
- Add GUI invalidation reasons, comparison rows, emitted quads/logical copies,
  sidebar rows visited/drawn, order rebuilds, captures, shaping hits/misses and
  bypass reasons, and projection rebuilds/reused reads. Correct stale catalog
  descriptions. These counters are missing from the present census.
- Measure per projection both reads and source mutations. Count allocation and
  retained capacity in addition to live requested bytes; RSS/CPU backing/GPU
  residency are separate measurements, never interchangeable totals.
- Run isolated local scenarios: idle; typing; sparse output; continuous full
  output; 1/4/8 visible panes at constant total area; 8/64 live panes mostly
  hidden; one/two clients with different viewports and one slow client; synthetic
  fleet metadata; images plus typing; reconnect/font/resize.
  Replay fleet data locally; this task requires no access to Personal.
- Collect a fixed work count and wall-clock interval per scenario. Use separate
  uninstrumented ReleaseFast CPU/latency runs, count builds and timing builds.
  Record actual geometry, display interval and workload rate. Do not average
  unlike scenarios into one score without declaring their weights.

Exit: a matrix of invocations/s, mutations/s, work/invocation, CPU contribution,
latency tails and memory for each candidate. That decides the implementation
order between runtime and rendering. Counts alone cannot decide the winner.

### 1. Remove repeated semantic computation

Long unchanged card labels remain a candidate for reducing repeated work.
The review-search experiment is retired with the Reviews feature.

**Labels.** Keep the existing shaping cache. Compare bounded prepared runs for
visible labels longer than its 64-byte limit against a bounded long-run cache.
Keys include text, font resources, size and width/wrapping where relevant.
Separate title preparation from age/spinner/status drawing. Preserve full
Unicode shaping: arbitrary text chunking is not an equivalence-preserving
substitute. Do not enlarge every short-run slot merely to admit rare long text.

Exit: unchanged draws perform no repeated shaping for the admitted case;
output matches the reference; title churn includes preparation cost and remains
acceptable in paired measurements.

### 2. Runtime delivery working data

First measure the current mask-based path; the historical pass already removed
repeated availability checks per lane. Compare two mechanisms separately:

- Dense columns for the revisions/flags that eligibility actually reads, with
  relation slots into pane and attachment tables. Keep VT state, large buffers
  and media payloads outside that working set. If values are duplicated, their
  writers update the projection as one transition; no rebuild of all panes at
  every flush.
- A bounded pending set populated on output, metadata changes, attach/detach,
  ACK/credit return, deadline expiry and send completion. A productive visit
  retains or requeues work as required by backpressure and lane fairness.

The latter can remove scans; the former only reduces the cost of scans that
remain. Maintaining either has a write cost. Do not combine both before each
has an isolated comparison. Reopen the previously rejected nested `Pane.hot`
grouping under controlled placement; its earlier regression remains evidence
for that configuration, with cause unestablished.

Use at least current/dense layout × current/staggered placement, extending with
grouped-hot and natural-packed variants. Do not attribute placement savings to
field grouping or add their measured percentages. Include churn and page offsets
across multiple pool segments. Pending-set scheduling remains a separate factor.
PMU can test the conflict hypothesis; repeatable timings with unknown mechanism
must be labeled accordingly. Test target-specific placement natively before
generalizing from the M3 fixture.

Exit: fewer candidates per idle/unrelated event or measured faster scans; no
missed wakeup, stale revision, starvation or loss under backpressure. Test two
independent clients, projected viewports, disconnect/reuse and shutdown. Preserve
VT dirty ownership and per-attachment acknowledgements.

### 3. Renderer comparison and emission

Retain the existing metadata/primary/overflow split. First try row/range-level
preparation validity using existing client damage plus explicit preparation
generations; cold/invalid rows take the reference cell comparison path. Geometry,
font and other global invalidations remain full rebuilds. Selection, cursor and
scroll need explicit coverage even without an incoming cell frame.

Then measure whether separate compact emission descriptors or dense runs of
ink-bearing cells save enough second-pass work to cover their update cost.
Keep physical rectangles and comparison keys out of a flags-only scan where
they are not needed. Do not retain pointers into resized arrays.

This stage can reduce comparisons for sparse updates; it does **not** promise
constant-time drawing. Emitting all required scene quads and native uploads
remain work proportional to output. Removing that work would require a separate
renderer/submission design, with GPU lifetime and complete-frame oracles.

Exit: byte-identical quads/atlas and matching native pixels across retained,
sparse, full, multi-pane, selection, images, cursor, theme, resize and reconnect.
Require measured improvements without the previously observed continuously
changing-pane regression. Full-pane copied caches are not the default proposal;
the three earlier experiments already establish their tradeoff.

### 4. Fleet list traversal and conditional secondary work

Keep revision-cached fleet ordering. If stage 0 shows list traversal is material,
retain row heights/offsets keyed by order, card shape, metrics and width. Locate
the visible range without repeatedly walking every offscreen row; prepare each
machine's shared drawing context once per preparation, then consume compact
visible-card records. Preserve exact machine/session navigation identities and
successful-frame hit-map publication. Active animation updates only its fields.

Image layer ranges, GPU maintenance indexes, additional input projections and
observation batch layouts remain conditional on the census. Image storage
already has dense occupied rows and revision gates; ordinary indexed pane
lookups and cached layout are not reasons to copy an entire model.

Exit: work scales with visible cards for drawing plus actual metadata changes
for ordering; disconnected machines, orphaned tasks, cycles and stale identities
retain current behavior. Image changes, if justified, retain quota and lease
invariants while input stays responsive.

### 5. Consolidate measured storage requirements into the memory budget

Record each accepted representation's capacity, alignment, lifetime, replacement
peak and owner. Use retained typed arrays for stable projections; scratch arenas
only for synchronous temporary results. Large records use reusable slots in
stable segments, charged in full; empty-segment release returns backing credit.
Small hot columns may be reserved once at an inventory-validated capacity.
Reserve before entering steady interactive work. The placement/churn experiment
can run earlier to isolate its benefit without waiting for a whole allocator.

Each earlier stage already accounts for its added memory. This stage connects
those capacities to the aggregate runtime/window allowance and evaluates the
pool against actual demand. Avoid reserving a maximum-sized copy for all 17
machine clients when a projection only serves the active view. No universal LRU,
ring policy or phase-switching allocator API is selected by this roadmap.

## Acceptance for every experiment

The relevant tradeoff is measured over the whole operation:

```text
saved read work = reads × (old read cost − new read cost)
added work      = rebuilds × rebuild cost + extra per-write maintenance
                 + copying/composition + admission/eviction work
```

All terms use the same scenario and interval. Additional retained memory,
working-set pressure and p95/p99 latency are separate acceptance dimensions.
More cache hits or fewer logical bytes alone do not prove a faster result.

Freeze the current reference before each change. Choose an oracle first; compare
alternating uninstrumented ReleaseFast runs using the existing
[measurement rules](../../.agents/skills/perf-pass/measurement.md). Inspect
assembly and target-specific lowering when relevant; test macOS/Linux and
AArch64/x86-64 before accepting architecture-dependent conclusions. Run targeted
correctness checks per experiment and the required integration checks before
merging. Record rejected variants as well as accepted ones.

The next implementation milestone is stage 0. The current evidence is sufficient
to name and test the candidates, but not to claim a speedup or an optimal layout.
