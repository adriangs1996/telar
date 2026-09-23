# Cache admission experiment

Waiting for one repeated revision is useful for continuously changing panes,
but it is not a general replacement for immediate admission. It reduces copying
while sacrificing the first possible cache hit after each change.

The experiment ran 648 isolated processes and measured 2,661,660 preparations.
The 36 cases cover three per-pane sizes, six pause lengths and one or two changing
panes. Each case uses all six policy orders. All measured intervals reported zero
allocator calls and zero allocated bytes. A separate comparison passed for 2,412
corresponding frames, checking every emitted quad byte and the full glyph atlas.

## Main result

For continuous changes, delayed admission is 8.68–11.66% faster than always storing
at the median of the paired comparisons, across all sizes and active-pane counts.
Every pair favors delayed admission. With both panes changing continuously, its
cost is effectively the same as the cell-only reference: median paired changes
range from -0.14% to +0.16%. It recovers the cost of the unnecessary cache stores;
it does not establish a faster cell traversal.

For pauses of 1, 2, 5 or 20 draws, delayed admission is slower than immediate
admission in every pair of every case: 144/144 pairs. With one unchanged draw
between changes, it is 48.79–58.46% slower for two changing panes and 5.08–6.72%
slower than the cell-only reference. Reduced copy volume does not imply reduced
CPU time.

At a pause of 100 draws, most differences in mean preparation time are small and
change sign across rounds. The 40 × 10, one-active-pane case favors delayed
admission in 6/6 pairs by a median 2.20%; it does not establish a universal
long-pause advantage.

## A readable example

Both panes are 80 × 20 cells and change one cell together. A pause of N means
one changed draw followed by N unchanged draws. Times are microseconds per full
preparation of both panes. Each value is the median of six per-run means.

| Unchanged draws after a change | Cells only | Immediate admission | Admission after repeat |
| ---: | ---: | ---: | ---: |
| 0 | 35.84 | 40.48 | 35.78 |
| 1 | 36.22 | 24.19 | 38.38 |
| 2 | 35.87 | 18.92 | 28.17 |
| 5 | 36.01 | 13.50 | 17.98 |
| 20 | 35.93 | 9.54 | 10.82 |
| 100 | 35.73 | 8.30 | 8.53 |

With one unchanged draw, the repeating sequence is:

```text
                         changed draw     unchanged draw     changed draw
Immediate admission     scan + store     reuse + store      scan + store
Admission after repeat  scan             scan + store       scan
```

Delayed admission has zero hits in that pattern. At 80 × 20 with two active
panes, it copies 125 KiB per draw on average instead of 375 KiB, but scans all
3,200 cells every draw instead of 1,600 on average. These are first-pass cell
counts and logical copies, not measured DRAM traffic or hardware cache misses.

## Tail behavior

Mean improvements do not describe all frames. With two active panes and 100
unchanged draws, immediate admission needs one scan per 101 draws, while delayed
admission needs two. That crosses the 1% percentile boundary and changes p99.

| Per-pane size | Immediate p99, µs | Delayed p99, µs |
| --- | ---: | ---: |
| 40 × 10 | 8.21 | 9.08 |
| 80 × 20 | 17.96 | 39.31 |
| 160 × 40 | 79.65 | 158.98 |

These are medians of per-run CPU preparation p99 values, not pooled percentiles
or input-to-pixel latency. All p50, p95, p99 ranges and paired changes are retained
in the raw results; no runs or outliers were excluded.

## Memory and interpretation

Both pane-cache variants reserve the same additional quad capacity: 250 KiB,
1,000 KiB and 4,000 KiB at the three sizes. Delayed admission does not save that
memory. The cell-only policy reserves zero pane-quad capacity, while retaining
its existing cell cache. Inline cache metadata and common renderer resources
are excluded from this capacity metric.

This result supports avoiding stores in a continuously changing pane. It rejects
using a single repeated revision as a general admission rule. The fixture knows
the future pause length; production does not. Choosing the best policy using
that future knowledge would be an oracle comparison, not an implementable win.

The next design question is whether we can reduce the cost of keeping a pane's
quads available without delaying their first reuse. That would need an explicit
storage and GPU ownership design. Neither row-block caching nor reuse without
copies was implemented or measured in this campaign. No production integration
is justified by these results alone.

## Method and reproduction

```sh
zig build build-widget -Doptimize=ReleaseFast
python3 tools/cache_admission_experiment.py --output /tmp/cache-admission
zig build test-widget
zig build codestyle
```

Machine: Apple M3, macOS 26.6.2, Zig 0.16.0, ReleaseFast. Every process warms at
least 256 draws and three complete cycles, then measures at least 4096 draws
rounded to complete cycles. Timing includes renderer begin, both pane draws and
seal. Input mutation, allocation checks, sorting, result writing and correctness
comparison are outside measured intervals. The driver shuffles case order with
a recorded seed and balances all six policy permutations. No build or parallel
benchmark runs during sampling.

The lab allocates three renderers but exercises only the selected renderer in a
measured process. Process RSS therefore cannot be attributed to a policy here.
The cell-only reference is the current experimental renderer with pane storage
disabled, rather than a separately compiled version with all pane-cache code
removed. Inputs are dense ASCII, with fixed theme, scale, geometry and hidden
cursor. Changes replace one cell per active pane. Unchanged draws are requested
explicitly; this is not a production idle-scheduling test.

These results do not measure GPU or input latency, hardware cache misses, wire
bytes, queue depth or runtime behavior. They apply to CPU preparation of this
fixture. Eighteen runner tests pass, including all admission cycles and sizes,
UI pause/step controls and delayed native frame completion. Source-style checks
also pass.

- [Raw per-run CSV](runs.csv)
- [Raw per-run JSONL](runs.jsonl)
- [All 36 comparisons, tails and paired ranges](summary.json)
- [Correctness comparison counts](verification.json)
- [Environment, source revision and executable fingerprint](metadata.json)

Detailed command receipts, stdout/stderr, the measured executable, source snapshots
and working-tree patch are retained locally in
`/private/tmp/telar-cache-admission-20260922/`. The source revision in metadata is
only the base commit; the measured binary includes the recorded uncommitted work.

## Complete mean comparison

Changes below are medians of paired ratios. Negative means delayed admission
uses less CPU time than immediate admission. The range is the observed minimum
and maximum over six paired runs, not a confidence interval.

| Per-pane size | Active panes | Pause | Delayed vs immediate | Paired range | Faster pairs |
| --- | ---: | ---: | ---: | --- | ---: |
| 40 × 10 | 1 | 0 | -10.23% | -12.84% to -9.30% | 6/6 |
| 40 × 10 | 2 | 0 | -10.00% | -12.69% to -8.91% | 6/6 |
| 40 × 10 | 1 | 1 | +25.74% | +21.85% to +28.74% | 0/6 |
| 40 × 10 | 2 | 1 | +48.79% | +47.59% to +52.51% | 0/6 |
| 40 × 10 | 1 | 2 | +19.06% | +13.68% to +20.26% | 0/6 |
| 40 × 10 | 2 | 2 | +36.32% | +34.39% to +37.73% | 0/6 |
| 40 × 10 | 1 | 5 | +13.39% | +9.86% to +20.19% | 0/6 |
| 40 × 10 | 2 | 5 | +29.38% | +26.70% to +35.29% | 0/6 |
| 40 × 10 | 1 | 20 | +3.14% | +0.18% to +6.90% | 0/6 |
| 40 × 10 | 2 | 20 | +13.36% | +11.04% to +16.76% | 0/6 |
| 40 × 10 | 1 | 100 | -2.20% | -9.32% to -0.90% | 6/6 |
| 40 × 10 | 2 | 100 | +2.25% | -0.03% to +6.23% | 1/6 |
| 80 × 20 | 1 | 0 | -8.68% | -9.55% to -7.49% | 6/6 |
| 80 × 20 | 2 | 0 | -11.66% | -13.85% to -10.84% | 6/6 |
| 80 × 20 | 1 | 1 | +42.38% | +41.65% to +45.08% | 0/6 |
| 80 × 20 | 2 | 1 | +58.46% | +55.27% to +63.76% | 0/6 |
| 80 × 20 | 1 | 2 | +34.81% | +33.12% to +36.13% | 0/6 |
| 80 × 20 | 2 | 2 | +49.00% | +42.07% to +53.18% | 0/6 |
| 80 × 20 | 1 | 5 | +22.02% | +19.85% to +33.13% | 0/6 |
| 80 × 20 | 2 | 5 | +33.20% | +31.05% to +36.42% | 0/6 |
| 80 × 20 | 1 | 20 | +7.95% | +5.48% to +9.03% | 0/6 |
| 80 × 20 | 2 | 20 | +13.38% | +11.50% to +15.83% | 0/6 |
| 80 × 20 | 1 | 100 | +1.39% | -4.34% to +4.69% | 1/6 |
| 80 × 20 | 2 | 100 | +2.11% | -0.08% to +5.29% | 1/6 |
| 160 × 40 | 1 | 0 | -9.27% | -10.56% to -8.92% | 6/6 |
| 160 × 40 | 2 | 0 | -11.48% | -16.16% to -10.43% | 6/6 |
| 160 × 40 | 1 | 1 | +38.42% | +33.91% to +39.50% | 0/6 |
| 160 × 40 | 2 | 1 | +54.31% | +50.15% to +57.00% | 0/6 |
| 160 × 40 | 1 | 2 | +30.58% | +28.63% to +38.03% | 0/6 |
| 160 × 40 | 2 | 2 | +45.30% | +43.60% to +46.46% | 0/6 |
| 160 × 40 | 1 | 5 | +18.46% | +17.38% to +19.53% | 0/6 |
| 160 × 40 | 2 | 5 | +29.19% | +24.09% to +31.20% | 0/6 |
| 160 × 40 | 1 | 20 | +6.61% | +6.38% to +7.69% | 0/6 |
| 160 × 40 | 2 | 20 | +11.66% | +4.52% to +16.03% | 0/6 |
| 160 × 40 | 1 | 100 | +1.10% | -7.18% to +3.30% | 2/6 |
| 160 × 40 | 2 | 100 | +2.80% | -0.51% to +3.89% | 1/6 |
