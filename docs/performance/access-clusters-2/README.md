# Access clusters, second pass

This pass tested four independent candidates: removing an attachment-row copy,
removing a repeated pane-table traversal, separating background and ink quads,
and separating shaping lookup filters from their large cached results. The two
layout changes did not meet the acceptance rule. The copy and traversal changes
are retained in this worktree after the final validation below.

These are CPU workload measurements, not application-wide FPS or input latency
claims. No installed runtime or GUI was replaced by this pass.

## Reproduction and evidence

- Base: `24628c0e`; branch `perf-access-clusters-2`.
- Apple M3, macOS 26.6.2, Zig 0.16.0, 128-byte hardware cache lines.
- Frozen baseline `A`: `zig build build-dod-probe build-bench -Doptimize=ReleaseFast`.
- Scratch artifacts: `/tmp/telar-access-clusters-2.QhXJGE`.
- [Manifest](data/manifest-A.json), [paired runner](data/pair.py), and compressed
  raw measurement records in `data/` retain the actual inputs and observations.
- Candidates R, C, G, S were each built against A independently, never cumulatively.
  Final F combines only R and C. Each prefix is immutable after measurement.
- Paired order alternates A/B and B/A. Benchmarks use 6 pairs, 12 samples per
  invocation, 40 ms sample budget. Terminal probes use 7 pairs, 3,000 frames and
  300 warmups, except full redraw (1,000 frames) and font (8 frames, 2 warmups).
  Chrome uses 1,000 frames and 200 warmups per scenario, 7 pairs.
- No builds, tests or profiler captures ran alongside paired timing. Other user
  processes remained outside this pass's control.
- Tables report the median of per-pair time ratios; a ratio of medians can differ.
  Negative percentages mean less time. Probe mean frame times are not p99 input
  latency. Chrome exports frame percentiles; benchmark percentiles describe batches.
- The first C summary hit a zero-time benchmark and failed while calculating its
  ratio, after all measurements had completed. The runner now excludes undefined
  ratios, and the summary was regenerated from the preserved records without reruns.

Earlier `access-clusters`, `memory-patterns`, `record-placement`, `dod-pass-2`,
`dod-pass-3`, `runtime-work-counters`, `pane-draw-cache`, and
`persistent-pane-quads` reports were read before selecting candidates. In
particular, this pass does not repeat the rejected whole-pane geometry cache or
claim that regrouping `Pane` fields is universally beneficial.

## Where the memory work occurs

A 3-second `sample` of the retained terminal probe had 1,937 leaf samples in
`TerminalRenderer.drawPane`. A separate 10-second Instruments capture explicitly
selected `l1d_miss_sampling`. Its exported tables contained 199,978 retired
`l1d_load_miss` samples, of which 197,289 had `drawPane` as their leaf.
This is a deliberately render-heavy probe, including setup and warmup, not a
profile of a complete user session.

The recording command returned 54 after the time limit killed the launched
probe, but saved a readable trace. We exported and inspected `MetricTable`,
`CountingModeSamples`, and `SamplingModeSamples` separately. See the
[PMU summary](data/pmu-summary.json), [record log](data/pmu-record.log), and
[linked instruction mapping](data/pmu-top-loads.json). Addresses were corrected
using the trace's binary load address, not guessed from a different run.

Selected sampled load sites:

| Linked address | Instruction | Load-miss samples |
| --- | --- | ---: |
| `0x10012e9dc` | `ldrb w2, [x2, #0x3a]` | 64,618 |
| `0x100133618` | `ldp d0, d21, [x8, #0x50]` | 30,782 |
| `0x10012ea58` | `ldr s1, [x6, #0x8]` | 20,055 |
| `0x10012ea74` | `ldr s1, [x6, #0xc]` | 14,347 |

These locate metadata/geometry reads worth further investigation. They do not
supply a total-load denominator, a cache hit percentage, DRAM bytes, or a causal
before/after comparison for the accepted changes. Logical bytes below are not
measured bus traffic.

## R: iterate the attachment row by reference

`runtime/client_delivery.reportDroppedLinks` copied a fixed row before iterating
its pointers. There are 128 slots in this revision: 1,024 bytes per pumped client.
Changing `for (row)` to `for (&row)` removes that snapshot without adding state.
The body clears dropped-link flags in pointed-to records and publishes bounded
notifications; it does not add, remove, or reorder attachment slots. It executes
on the owning runtime loop, so the old snapshot provided no needed isolation.
Other snapshots in lifecycle code were deliberately left alone.

| Benchmark | A median ns/op | R median ns/op | Paired change | Wins |
| --- | ---: | ---: | ---: | ---: |
| `flush_idle_1x32` | 1,801 | 1,722.5 | -4.80% | 5/6 |
| `flush_idle_2x8` | 860.5 | 855 | +0.13% | 3/6 |

In `main.flushIdle`, the baseline emits `mov w2, #0x400; bl _memcpy`
after delivery preparation. The candidate removes that copy. See
[assembly](assembly/R-flush.s), [patch](experiments/R.patch), and
[all measurements](data/R-summary.json). Acceptance is based on 1x32; 2x8 is neutral.

## C: use the geometry traversal's result

`Geometry.capture` first called `Panes.countIn`, then iterated the same table to
copy the panes' geometry. It now derives the optional location from the number
of captured panes. This removes a scan of 256 pointer slots (2,048 logical bytes)
and the corresponding live-pane tab reads. The final assembly also shows that
`countIn` made a 2,048-byte snapshot before that scan: both the `memcpy` and its
counting loop disappear from `main.timed__anon_62765`. The remaining geometry
iteration reads the model directly. [Before](assembly/A-present.s.gz),
[after](assembly/F-present.s.gz). It adds no cache or invalidation state.

| Benchmark | A median ns/op | C median ns/op | Paired change | Wins |
| --- | ---: | ---: | ---: | ---: |
| `frontend.client.present_frame` | 700 | 594.5 | -14.82% | 6/6 |
| `frontend.client.frame_event` | 120.5 | 121.5 | +1.24% | 2/6 |
| `frontend.client.machine_frame_event` | 123 | 123.5 | +0.41% | 1/6 |

The machine-frame control's small consistent loss is placement-sensitive: its
measured loop and `receiveFrame`, `finishEvent`, and `summarizeMachine` have
identical normalized instruction streams. Normalization preserves ordinary
immediates and verifies the first 32 bytes at relocated constants before matching
those operands. [Checks](data/C-placement.json), [normalizer](data/placement.py),
and the [measured loop](assembly/C-machine-loop.normalized.s) retain the evidence.
This does not turn that control's loss into a speedup.

A seeded geometry oracle checks a direct table reference against production
capture over 100 empty, fully populated and mixed-tab configurations, plus a
missing active tab. It compares the meaningful geometry fields, not padding or
unused array tails. Existing presentation tests cover attachment replacement,
geometric ABA and delivery ownership. See [patch](experiments/C.patch) and
[all measurements](data/C-summary.json).

## G: split background and first ink quad — rejected

The retained cell mesh stores two primary 80-byte quads together: background and
first ink. Drawing ink alone advances 160 bytes per cell. The experiment placed
background and ink in separate columns, retaining the existing overflow storage
and metadata. Each read stream then advances 80 bytes. Payload bytes per cell
stay constant; the owning grid gains one array descriptor and one resize-time
allocation. Steady frames keep the same allocation behavior.

All 1,056 quad/atlas frame digests matched across twelve terminal modes. GUI tests
also exercised nondefault backgrounds and allocation failure; the failure fixture
included background, first ink and overflow so every column was checked.

| Mode, 153×40 | Paired change | Wins |
| --- | ---: | ---: |
| retained | -4.39% | 6/7 |
| sparse | -5.53% | 7/7 |
| cursor | -6.42% | 7/7 |
| selection | -3.83% | 6/7 |
| two_all_active | -4.40% | 7/7 |
| full | **+2.43%** | **0/7** |

The 73×40 full redraw also lost every pair (+2.25%). This violates the general
acceptance rule despite gains in reuse. Full redraw touches both split columns,
but the precise cause of its regression is not established. The source change
was reverted; [patch](experiments/G.patch), [oracle](data/oracle-G.log), and
[all measurements](data/G-summary.json) remain available.

The actual draw loop changes stride from 160 to 80. A separate kernel using the
real `gfx.Quad` confirms the same distinction on AArch64 baseline, x86-64 baseline
and x86-64-v3. AArch64 still copies five 16-byte lanes per ink quad: this is a
locality change, not fewer payload loads. The kernel tests ran under Rosetta on
both x86 variants; these are correctness checks, not native x86 timings.

## S: split shaping filters from results — rejected

Each cache entry combines text, face/height/length keys, 64 glyph records and 64
positions. Four-way searches inspect tiny fields spread across large entries.
The experiment moved length, requested face and pixel height to a canonical
packed 32-bit filter column. Four filters occupy 16 contiguous bytes; text is
compared only after a filter match. ASCII dedicated slots, exact text matching,
font identity, heights and round-robin eviction remain unchanged.

The AArch64 match routine changes from three entry loads and comparisons to one
32-bit entry-filter load and comparison. The key still must be assembled, and a
hit still reads the original text and glyph payload. See
[before](assembly/A-shaping-matches.s) and [after](assembly/S-shaping-matches.s).

All 1,056 terminal and 1,056 chrome frame digests matched. Across all 24 chrome
scenarios (1/8/16 cards, 32/40/64/65-byte titles, widths 280/480), no case reached
6/7 wins. Several lost 6/7; the largest median regression was +1.86%. Rejected
rather than retained on the strength of cleaner assembly. See
[patch](experiments/S.patch) and [all measurements](data/S-summary.json).
The probe's `shaping_cache_bytes` field counts heap entries only and excludes the
experimental 1,536-byte inline filter column; it must not be read as total memory.
Heap payload fell from 1,012,224 to 1,010,688 bytes, exactly the 1,536 bytes
moved inline. All timed S and G scenarios had zero measured allocations; S also
preserved shape-call and raster-attempt counts.

## Remaining opportunities, not measured gains

- `CellMetadata` interleaves paint identity with the length and flags used by
  geometry emission. A dense length/flags column could reduce second-pass stride,
  but also add writes and streams on rebuild; the G result makes that tradeoff
  worth measuring rather than assuming.
- `lib/vtgrid/damage.zig` rechecks boundary cells when switching between equal and
  unequal runs. Inspect optimized assembly first, then compare against an
  independent span reference and measure fragmented/full damage.
- `lib/cellcodec/cell_run.zig` prepares fixed-size storage for tiny cell payloads.
  A scalar one-byte case might reduce stores, at the expense of a branch. Wire
  equivalence and actual encoder timing are required.
- Attachment deadline scans chase large records for small scheduling fields.
  Canonical deadline columns plus occupancy bits could help; attach, detach, ACK
  and pacing transitions must keep one owner and one authoritative value.
- `Projection.prompt` and path-picker input contain large by-value data. Borrowing
  within synchronous presentation might avoid copies, but needs an explicit
  lifetime audit, disassembly proof and a modal-input workload.
- The client cell reader may benefit from repeated-style/one-byte fast paths.
  Existing schema header benchmarks do not measure the actual cell-application
  loop and cannot establish that gain.

No architecture-wide SoA conversion follows from this pass. Keep fields together
when the dominant pass consumes them together; separate streams only after both
reuse and rebuild workloads justify it.

## Final validation

The final A/F CPU probe has identical `__text` and every other `__TEXT` section,
including addresses and read-only constants ([section hashes](data/F-probe-sections.json)).
The combined changes do not reach the probe's rendering machine code. The final
oracle compared 1,232 frames across all fourteen modes, including images and
ligatures, with identical quads and atlas ([result](data/oracle-F.log)).

The combined command completed with exit 0: **399/399 build steps succeeded;
3,583/3,585 tests passed, 2 skipped**. [Full log](data/validation-F.log).

```sh
zig build test test-gui cross codestyle check-client-boundaries \
  check-model-boundaries check-programs build-bench build-dod-probe \
  -Doptimize=ReleaseFast --prefix /tmp/telar-access-clusters-2.QhXJGE/F \
  -j2 --summary all
```

The Zig runner prints `failed command` after some suites that emit expected
warning logs, even when those suites succeed; the final step summary and exit
status above distinguish that output from a failed test. The new geometry oracle
ran with the shared client tests. [Combined source patch](experiments/F.patch).

No native Linux timing or native x86 timing was collected. Cross compilation and
Rosetta correctness checks do not establish performance on those hosts.

The final comparison completed all **31 benchmark cases in 6 alternating pairs**,
all **33 full-probe workloads in 7 pairs**, and all **24 chrome workloads in 7
pairs**. The full probe uses 64 measured frames and 4 warmups for broad coverage;
the candidate-specific G timing above uses longer runs. One benchmark,
`request_group_query`, reports a zero-nanosecond baseline at this resolution, so
its percentage is undefined and omitted. Ties are recorded separately from losses.

| Final target | A median ns/op | F median ns/op | Paired change | Wins |
| --- | ---: | ---: | ---: | ---: |
| delivery, 1 client × 32 panes | 1,846.5 | 1,762 | **-4.83%** | **6/6** |
| delivery, 2 clients × 8 panes | 837 | 832.5 | -0.78% | 4/6 |
| client presentation | 699.5 | 594 | **-15.26%** | **6/6** |

Unrelated controls did have consistent losses. They are retained here rather
than hidden in an aggregate:

| Control | Paired change | Losing pairs |
| --- | ---: | ---: |
| full-screen damage | +0.24% | 5/6 |
| shared-frame publication | +2.64% | 5/6 |
| inbox event | +1.41% | 6/6 |
| key event | +3.26% | 5/6 |
| directional focus | +0.88% | 6/6 |
| Lua callback | +4.81% | 6/6 |

These qualify for the placement exception: the benchmark driver, corresponding
unchanged timed loops and hot callees have identical normalized instructions.
The comparisons include `collectSpans`, `SharedFrameContext.publish`, inbox
handling, `finishEvent`, `WorkspaceLayout.focusDirection`,
`Generation.invokeCallback`, `lua_pcallk` and `luaV_execute`. ADRP-derived data
addresses and branch addresses are normalized; ordinary immediates are preserved.
This final check compares instructions, not equality of pointer-bearing constant
payloads. The changed presentation timed loop is explicitly **not** classified as
identical. [Results](data/F-instruction-placement.json),
[reproducer](data/normalize-instructions.py), and compressed listings in `assembly/`.

Likewise the unchanged GUI probe still fluctuated: for example,
`two_one_active/153x40` measured +2.94% with 0/7 wins despite its identical code
and read-only sections. We claim no GUI rendering gain from F. The independent
G and S results above, with actual layout changes, decide their rejection.

[Full benchmark table](data/F-bench-summary.json),
[full probe table](data/F-probe-summary.json),
[chrome table](data/F-chrome-summary.json). Raw records accompany each table as
compressed JSON, including exported percentiles and allocation counters. The
accepted source changes pass their target thresholds and the placement audit;
that does not guarantee a net speedup in every differently linked application
binary or in a complete interactive session.
