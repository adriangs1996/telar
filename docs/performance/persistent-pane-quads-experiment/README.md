# Persistent pane quads experiment

Keeping pane output in place improves reuse cost and halves additional quad
capacity. It still does not remove the regression when both panes change every
draw: the median paired overhead over the cell-only reference is 9.18–13.41%.
The remaining scene-composition copy prevents accepting this as a general
optimization. This remains an isolated widget experiment.

## What changed

`PersistentPane` owns a bounded quad list for each of the lab's two panes. On a
miss, the real renderer writes directly into that list. On a hit, the list stays
unchanged. The experiment appends one copy to the ordinary native frame in either
case. The previous cache wrote misses to the scene and then copied them to a
cache, and copied hits both to the scene and to the next cache generation.

```text
                       Changed pane                  Unchanged pane
Previous cache         cells -> scene -> cache       cache -> scene + next cache
Persistent pane        cells -> pane -> scene        pane -> scene
```

There is still one composition copy per pane per preparation. This is not a
zero-copy GPU path. Both Metal and Vulkan still consume one contiguous scene and
perform their existing upload. The native ABI and submission lifecycle did not
change. The experiment also replaces a search through prior entries with a direct
pane slot; improvements cannot be attributed to copy reduction alone.

## Results

648 isolated runs measured 2,661,660 preparations. Every measured interval
reported zero allocator calls and zero allocated bytes. A separate comparison
passed for 2,412 corresponding frames across all four lab policies, checking
every quad byte and every glyph-atlas pixel. Only cells, immediate admission and
persistent storage were timed in this campaign.

The persistent policy has a lower median paired mean than the previous cache
in all 33 cases containing reuse. It wins 197/198 corresponding pairs. The
exception is the 80 × 20, two-active-pane, one-unchanged-draw case, with one
+41.5% paired regression. It remains included. That case's median is -7.60%,
with an observed paired range of -8.6% to +41.5%; no cause for the outlier was
measured, and it was not retried or discarded.

For both panes changing continuously, persistent storage and the previous cache
have similar cost, with mixed paired signs at 80 × 20 and 160 × 40. Both remain
slower than cells alone. With one continuously changing pane and one unchanged
pane, persistent storage is 7.36–10.46% faster than the previous cache across the
three sizes and wins every pair.

### Two panes of 80 × 20

A pause of N means one changed draw followed by N unchanged draws. Both panes
change one cell together. Times are microseconds for preparing both panes;
entries are medians of six per-run means, not ratios of pooled samples.

| Pause | Cells only | Previous cache | Persistent quads |
| ---: | ---: | ---: | ---: |
| 0 | 35.68 | 40.49 | 39.99 |
| 1 | 35.73 | 23.92 | 22.10 |
| 2 | 35.66 | 18.75 | 16.38 |
| 5 | 35.74 | 13.27 | 10.53 |
| 20 | 35.21 | 9.44 | 6.36 |
| 100 | 35.41 | 8.28 | 5.08 |

At a pause of 100 in this example, persistent storage reduces the paired mean
by 38.74% relative to the previous cache. With no pause, it remains 13.41% above
the cell-only reference. These are medians of paired ratios; they need not equal
the ratio between two medians in the table.

### CPU tails

Persistent storage admits immediately and avoids the extra miss introduced by
the preceding delayed-admission experiment. It does not eliminate the expensive
changed draw. Tails must be evaluated separately from the average.

| Pause, two active 80 × 20 panes | Cells p99, µs | Previous cache p99, µs | Persistent p99, µs |
| ---: | ---: | ---: | ---: |
| 0 | 41.23 | 46.50 | 46.06 |
| 1 | 41.04 | 43.79 | 43.65 |
| 2 | 40.62 | 43.19 | 43.35 |
| 5 | 41.12 | 41.25 | 41.85 |
| 20 | 40.42 | 39.42 | 39.12 |
| 100 | 40.94 | 38.29 | 13.08 |

These are medians of six per-run p99 values. All per-run p50/p95/p99 values,
paired changes and observed ranges are retained. They describe CPU preparation,
not input-to-pixel latency. No runs or outliers were excluded.

## Copies, capacity and ownership

For dense 80 × 20 panes, persistent storage copies 250 KiB into the final scene
per draw, whether panes changed or not. The previous cache copies 250 KiB with
both panes changed, 375 KiB with one changed, and 500 KiB when neither changes.
The baseline has no pane-level copy but still assembles cell meshes. These are
logical copy volumes; hardware memory traffic was not measured.

| Per-pane size | Previous extra quad capacity | Persistent extra quad capacity |
| --- | ---: | ---: |
| 40 × 10 | 250 KiB | 125 KiB |
| 80 × 20 | 1,000 KiB | 500 KiB |
| 160 × 40 | 4,000 KiB | 2,000 KiB |

Capacity excludes inline metadata, the ordinary scene, cell meshes, atlases and
GPU buffers. The lab owns four renderer instances, even in single-policy
measurement processes; process RSS cannot be attributed to a policy here.

The renderer supplies the complete existing visual key through `paneKey`.
Content revisions, attachment identity, geometry, theme and resource epochs
remain part of invalidation. No sampled hash replaces identity. Pane-local
capacity exhaustion invalidates the entry and falls back to cell drawing.
A failed scene append preserves valid cache output for a later retry.

Native frames receive their own quad array, never a pointer into persistent
pane storage. The runner still blocks preparation and resource replacement
until the exact in-flight completion arrives. No cache action acknowledges a
runtime frame or retires pending presentation state.

This prototype uses two known slots and two quads of capacity per cell. It does
not implement a general pane allocator, eviction across hidden tabs or an
unbounded working set. Those would need separate design before integration.

## Verification

- 20/20 widget runner tests passed, including stable storage addresses, native
  scene independence, buffer exhaustion, retries, variable quad counts, visual
  and identity invalidations, and zero allocations after warmup.
- 758/758 GUI tests passed after extracting the shared visual key method.
- Source-style and whitespace checks passed.
- A native smoke run displayed all four policies, accepted play/pause and
  workload changes, and closed its own window successfully. Its UI timing is
  excluded from the campaign; previews use the runner's renderer, while the
  measured policies compare output independently.

## Reproduction and evidence

```sh
zig build build-widget -Doptimize=ReleaseFast
python3 tools/cache_admission_experiment.py --candidate retained --output /tmp/persistent-quads
zig build test-widget
zig build test-gui
zig build codestyle
```

The campaign uses Apple M3, macOS 26.6.2, Zig 0.16.0, ReleaseFast. It covers sizes
40 × 10, 80 × 20 and 160 × 40, one/two active panes, pauses 0/1/2/5/20/100,
and all six policy orders. Cases are shuffled with the recorded seed. Each
process warms at least 256 frames and three whole cycles, then measures at least
4096 frames rounded to complete cycles. No build or parallel benchmark runs
during sampling.

The timer includes begin, pane rendering/reuse, scene composition and seal.
Input mutation, correctness comparison, result counters, sorting and file output
are outside it. The cell-only reference is this experimental renderer with pane
storage disabled. Reference policies were measured again in the same campaign;
results were not compared against timings from the previous binary.

Inputs are dense ASCII with one cell changed per active pane. Theme, scale and
geometry are fixed and cursors hidden. Full redraw equivalence is covered by
widget tests, but full-redraw performance is not measured in this matrix. GPU
latency, hardware cache misses, IPC bytes, queue depth and production idle behavior
were not measured.

- [Raw runs as CSV](runs.csv)
- [Raw runs as JSONL](runs.jsonl)
- [All 36 comparisons and tail ranges](summary.json)
- [Correctness comparison counts](verification.json)
- [Machine, policy selection and executable fingerprint](metadata.json)

The measured executable, command receipts, stdout/stderr, source snapshots and
working-tree patch remain in `/private/tmp/telar-persistent-quads-20260922/`.
Native smoke screenshots and shutdown evidence are in
`/private/tmp/telar-persistent-cache-native/`. Metadata records the base commit;
the measured executable also includes the saved uncommitted source changes.

## Complete paired comparison

Negative changes mean persistent storage uses less CPU preparation time than
the previous cache. Ranges are observed minima/maxima over six pairs, not
confidence intervals.

| Size | Active | Pause | Persistent vs previous | Observed range | Faster pairs |
| --- | ---: | ---: | ---: | --- | ---: |
| 40 × 10 | 1 | 0 | -10.46% | -11.92% to -8.40% | 6/6 |
| 40 × 10 | 2 | 0 | +0.69% | -1.39% to +1.63% | 1/6 |
| 40 × 10 | 1 | 1 | -27.87% | -29.30% to -26.56% | 6/6 |
| 40 × 10 | 2 | 1 | -8.79% | -10.38% to -7.23% | 6/6 |
| 40 × 10 | 1 | 2 | -39.38% | -41.27% to -37.70% | 6/6 |
| 40 × 10 | 2 | 2 | -20.19% | -21.87% to -15.00% | 6/6 |
| 40 × 10 | 1 | 5 | -50.35% | -50.48% to -50.19% | 6/6 |
| 40 × 10 | 2 | 5 | -37.14% | -39.70% to -34.78% | 6/6 |
| 40 × 10 | 1 | 20 | -58.83% | -60.18% to -56.70% | 6/6 |
| 40 × 10 | 2 | 20 | -52.36% | -53.70% to -52.10% | 6/6 |
| 40 × 10 | 1 | 100 | -62.70% | -66.34% to -60.72% | 6/6 |
| 40 × 10 | 2 | 100 | -61.96% | -63.40% to -57.86% | 6/6 |
| 80 × 20 | 1 | 0 | -7.36% | -8.62% to -4.62% | 6/6 |
| 80 × 20 | 2 | 0 | -0.59% | -2.79% to +2.24% | 3/6 |
| 80 × 20 | 1 | 1 | -16.15% | -20.00% to -15.24% | 6/6 |
| 80 × 20 | 2 | 1 | -7.60% | -8.62% to +41.46% | 5/6 |
| 80 × 20 | 1 | 2 | -21.45% | -22.49% to -20.27% | 6/6 |
| 80 × 20 | 2 | 2 | -12.88% | -13.63% to -10.10% | 6/6 |
| 80 × 20 | 1 | 5 | -28.02% | -29.06% to -26.04% | 6/6 |
| 80 × 20 | 2 | 5 | -20.95% | -24.16% to -19.86% | 6/6 |
| 80 × 20 | 1 | 20 | -36.20% | -40.90% to -35.58% | 6/6 |
| 80 × 20 | 2 | 20 | -33.00% | -33.78% to -31.57% | 6/6 |
| 80 × 20 | 1 | 100 | -40.76% | -44.23% to -39.20% | 6/6 |
| 80 × 20 | 2 | 100 | -38.74% | -40.62% to -37.99% | 6/6 |
| 160 × 40 | 1 | 0 | -8.90% | -10.68% to -7.25% | 6/6 |
| 160 × 40 | 2 | 0 | -0.22% | -1.17% to +1.13% | 3/6 |
| 160 × 40 | 1 | 1 | -20.65% | -23.94% to -20.07% | 6/6 |
| 160 × 40 | 2 | 1 | -9.56% | -11.95% to -8.32% | 6/6 |
| 160 × 40 | 1 | 2 | -27.68% | -27.98% to -25.59% | 6/6 |
| 160 × 40 | 2 | 2 | -15.28% | -40.49% to -14.24% | 6/6 |
| 160 × 40 | 1 | 5 | -35.96% | -36.13% to -34.55% | 6/6 |
| 160 × 40 | 2 | 5 | -27.18% | -27.82% to -26.39% | 6/6 |
| 160 × 40 | 1 | 20 | -45.35% | -46.36% to -45.11% | 6/6 |
| 160 × 40 | 2 | 20 | -41.16% | -42.61% to -40.02% | 6/6 |
| 160 × 40 | 1 | 100 | -49.16% | -52.01% to -47.74% | 6/6 |
| 160 × 40 | 2 | 100 | -47.52% | -48.38% to -44.99% | 6/6 |
