# Measurement

## Builds

One scratch prefix per variant; never overwrite a measured one.

```sh
zig build build-dod-probe build-bench -Doptimize=ReleaseFast --prefix $SCRATCH/A
```

`build-dod-probe` gives `telar-dod-probe` (CPU-only GUI renderer, agent
transcript, review and workspace workloads). `build-bench` gives
`telar-benchmarks` (runtime, wire, TUI and media kernels; `--list`, `--filter`,
`--json`). A workload with no case gets one: add a context in `benchmarks/` and
append its case at the end of `cases` and of `execute` (`case_index` order).

`telar-dod-probe` environment:

| Variable | Effect |
| --- | --- |
| `DOD_TERMINAL_ONLY=1` | only terminal renderer modes |
| `DOD_MODE=<mode>` | one terminal mode: retained, sparse, full, theme, resize, selection, font, two_one_active, two_all_active, cursor, focus, reattach |
| `DOD_SAMPLES`, `DOD_WARMUP` | measured and warmup iterations |
| `DOD_VERIFY=1` | per-frame SHA-256 of quads and atlas (oracle, not timing) |

`-Dprofile-counts=true` builds count visits, hits and rebuilds; use them for
work census, never for timing.

## Oracles

- Renderer: `.agents/skills/perf-pass/scripts/probe_verify.sh A B` compares frame digests for all
  twelve modes. Fixtures only use the default background; changes touching
  colored backgrounds also need `zig build test-gui`.
- Everything else: a test that runs the old and the new path on the same
  inputs (exhaustive where the domain is small, seeded random otherwise).

## Timing

The host is shared and noisy (20-40% swings between unpaired runs). Only
paired, alternated runs count:

```sh
python3 .agents/skills/perf-pass/scripts/probe_pair.py $SCRATCH/A $SCRATCH/B 7 retained sparse full
python3 .agents/skills/perf-pass/scripts/bench_pair.py $SCRATCH/A $SCRATCH/B 6 backend.damage
```

Both scripts compare two builds. Where a fixture's large records land is
compared inside one build, by arguments, with `tools/placement_bench.py`:
[record placement benchmark](../../../docs/performance/record-placement/benchmark.md).

Check `uptime` first; do not measure while builds or test suites run.
Compare against the previous accepted build, then re-measure the final build
against `A`.

## Acceptance rule

Accept when the target case wins at least 6 of 7 pairs (5 of 6 for
benchmarks) and no other mode regresses consistently. A consistent loss in
any mode (0-1 wins) rejects the variant unless the loss is proven to be code
placement: identical normalized disassembly of the affected function in both
builds (see [assembly.md](assembly.md)). Report such cases as placement, not
as a cost of the change.

For cost of a single system call or library routine, measure it directly with
a small C or Zig loop (e.g. `tcgetpgrp` on a `forkpty` session).
