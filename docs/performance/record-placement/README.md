# Record placement experiment

Fable measured these fixtures on 2026-10-01 in an isolated source copy based on
`43567b04484cade06cbebb645acf56dba3042bfe`. Codex preserved the artifacts and
recalculated the warm paired summaries during the subsequent design discussion.
Codex did not rerun the benchmarks. This is fixture evidence, not an accepted
production allocator or a measured application-wide gain.

The [manifest](manifest.json) records the original executable hash, archived
file hashes and recalculated summaries. Comparing 2,886 tracked source/build
files with the scratch copy found exactly two modified files, both represented
in the patch, plus the new allocator source. No production source was changed
when archiving this experiment.

The experiment is now maintained in the tree as benchmark tooling:
[benchmark.md](benchmark.md) has its options, runner, commands and a fresh
validation on another machine. Everything below is the original archive and
stays as it was recorded.

## Warm idle delivery

Original report: Apple M3, macOS, ReleaseFast, libc child allocator; same
executable with allocation-placement modes selected at runtime. Nine rounds
rotate/reverse variant order. Percentages below are medians of paired ratios,
not ratios of the separately reported median times.

| Fixture | Original ns/flush | Staggered ns/flush | Paired change | Natural packed ns/flush | Paired change |
| --- | ---: | ---: | ---: | ---: | ---: |
| Two clients × eight panes | 1,064 | 772 | -26.72% | 768 | -27.73% |
| One client × 32 panes | 1,742 | 638 | -63.49% | 659 | -61.75% |

All four comparisons favor the variant in 9/9 rounds. Additional controls and
their original per-run medians are in [pair_libc.json](pair_libc.json): common
offset shift and a higher size threshold intended to isolate pane placement.
The wrapper selects allocations by size/alignment, not type identity.

[pair_cold_libc.json](pair_cold_libc.json) records the intervening 512 KiB
memory-walk fixture; its label does not prove L1 eviction. The runner subtracts
its measured empty-clock interval. [pair_ecore.json](pair_ecore.json) records
runs under `taskpolicy -b`; this archive does not verify placement on a specific
CPU core. [kernel-run1.txt](kernel-run1.txt) is the synthetic field-layout run,
not dense columns implemented in the real runtime.

## Sources and reproduction

All sources are archived as experimental artifacts, outside the application
build:

- [benchmark.patch](source/benchmark.patch) changes the benchmark driver and
  adds a diagnostic layout/placement report to the fixture's `IdleDelivery`.
- [PlacementAllocator.zig](source/PlacementAllocator.zig) supplies `none`,
  `shift`, `color` and `pack` modes.
- [pair.py](source/pair.py), [pair_cold.py](source/pair_cold.py) and
  [pair_ecore.py](source/pair_ecore.py) preserve the actual pairing methods.
- [layout_kernel.zig](source/kernel/layout_kernel.zig) and
  [offsets.zig](source/kernel/offsets.zig) preserve the synthetic probes.

To reproduce, create a disposable checkout at the recorded revision, apply
`source/benchmark.patch`, and copy `source/PlacementAllocator.zig` to
`benchmarks/PlacementAllocator.zig`. Build `build-bench` with ReleaseFast into a
scratch prefix, then run `pair.py <prefix>/bin/telar-benchmarks libc 9 <output>`.
Inspect each companion script's arguments before using it. These instructions
describe reproduction; the archival review only checked patch applicability.
If incorporated into permanent benchmark tooling, move the fixture report to
benchmark code or guard it with diagnostics.

## Interpretation limits

`pack` reserves 1 GiB of virtual address space and does not individually reclaim
freed records. `color` requests an extra 16 KiB per selected allocation.
Neither measures a production pool's churn, segment release or steady retained
backing. The full source is retained so those limitations remain inspectable.

Placement changes the measured cost. Cache-set conflicts are an unconfirmed
mechanism: there is no PMU result here, no current live event-rate census, and
no native Linux/x86-64 result. Natural stride depends on object sizes; it does
not guarantee the same behavior after a layout change or across segments.
The archived JSON preserves per-run medians, not full within-run samples or
an independently established tail-latency distribution.

The [agreed design](../../plans/memory-design-agreement.md) therefore requires
layout × placement comparisons, pool churn/accounting checks, explicit
per-pool policies and target validation. The [discussion](discussion/) records
the corrections to the original interpretation.
