# Pane draw cache experiment

This experiment compares the metadata-separated cell renderer against reuse of
complete pane quad output. The reference includes the preceding cell mesh
experiment. Branch: `experiment/pane-draw-cache`. No main integration or push.

## CPU results

| Fixture | Reference, µs/frame | Candidate, µs/frame | Median paired change | Faster candidate pairs |
| --- | ---: | ---: | ---: | ---: |
| terminal/retained/80x40 | 39.26 | 7.36 | -80.80% | 5/5 |
| terminal/retained/160x40 | 77.66 | 17.20 | -77.86% | 5/5 |
| terminal/sparse/80x40 | 40.73 | 42.70 | +8.07% | 0/5 |
| terminal/sparse/160x40 | 80.38 | 84.62 | +7.15% | 0/5 |
| terminal/full/80x40 | 152.45 | 153.87 | +1.86% | 2/5 |
| terminal/full/160x40 | 299.60 | 307.07 | +1.18% | 1/5 |
| terminal/two_one_active/80x40 | 36.88 | 25.00 | -34.20% | 5/5 |
| terminal/two_one_active/160x40 | 74.51 | 49.56 | -33.99% | 5/5 |
| terminal/two_all_active/80x40 | 38.17 | 40.95 | +7.89% | 0/5 |
| terminal/two_all_active/160x40 | 78.40 | 82.41 | +8.13% | 0/5 |

A negative change means less preparation time. All retained and mixed-pane pairs
improve. All sparse and both-active pairs regress. Full-redraw differences change
sign between repetitions and are inconclusive. The table reports medians of
per-run mean frame times and paired ratios, not per-frame latency percentiles.

The five cases, two sizes, two binaries and five repetitions contain 1,000,000
measured preparations in total. Every measured interval reports zero allocations
through the fixture allocator. Warmup and verification hashes are excluded.

Live requested bytes at 80x40 rise from 24,197,302 to 25,221,302 for the retained
fixture, an extra 1,024,000 bytes. At 160x40 they rise from 39,032,502 to 41,080,502,
an extra 2,048,000 bytes. The renderer value grows from 51,872 to 80,656 bytes,
including 28,784 bytes of inline pane-cache state. These are owned CPU allocations,
not an RSS or GPU-memory estimate.

With 3,200 output quads, a retained hit copies 512,000 logical bytes: once to the
new scene, once to the new cache. A miss stores 256,000 extra bytes. The mixed
fixture copies 384,000 bytes at 80x40. Those volumes double at 160x40. They are
logical copy volume, not measured DRAM traffic.

A separate counter-enabled build confirms zero cell/ink visits on retained
frames and half the visits in the mixed-pane fixture. Sparse, full and both-active
fixtures retain the original traversal counts. Counter timings are excluded from
the performance comparison. See [counter evidence](counts.json).

Correctness: 768 identical corresponding quad/atlas digests; 758/758 GUI tests
pass, together with source-style and module-boundary checks. Existing direct-cell
test fixtures now advance frame IDs with content mutations, matching the identity
contract of `Pane.applyFrame`. Their old rendering assertions remain unchanged.

The prototype failed its sparse/both-active cost criterion. Do not integrate it
as a general improvement. A follow-up hypothesis is to admit geometry only after
observing the same pane key in consecutive preparations, so continuously changing
panes do not pay for a copy that will be discarded. That policy is not implemented
or measured here.

## Native input results

| Committed text to matching Metal pixels | Reference | Candidate |
| --- | ---: | ---: |
| Samples | 1,000 | 1,000 |
| p50, ms | 5.487 | 4.276 |
| p95, ms | 14.846 | 13.183 |
| p99, ms | 19.919 | 17.719 |

All five paired medians and p99 values favor the candidate. Four of five p95
values favor it. This supports the mixed-pane case in this campaign; it does not
cancel the sparse/both-active CPU regression or prove a universal latency gain.
The endpoint is matching GPU pixels, not screen scanout. See [native results](native.json).

Every accepted run has a 1600x1000 pixel viewport, backing scale 1, reported
maximum display rate 100 Hz and a primary PTY of 86x44 cells. Both versions have
two panes. All 2,200 inputs including warmup complete with matching pixels and
zero probe failures in the accepted campaign. RSS ranges overlap substantially;
no RSS saving is claimed. Frame-queue depth and IPC byte counts were not measured
in this renderer-only experiment; no queue or wire protocol was added.

The first native campaign stopped when its geometry check rejected a candidate
window after 123 responses. Its earlier valid runs used backing scale 2 and a
42x19 primary PTY. The entire interrupted campaign is excluded from the table.
A fresh five-pair campaign completed under the geometry above. All original
results, the rejection, and shutdown receipts remain in `results/native/`.
Accepted native results live in `results-native-retry/native/`. The runner now
retries an entire pair, at most three times, only for geometry rejection; missing
or incorrect pixels still fail immediately. No retry was needed in the accepted
campaign. This retry policy does not filter samples by their latency.

## Ownership and bounds

`TerminalRenderer.drawPane` checks an owned key before traversing cells. The key
includes pane ID, location, attachment and pane generations, applied frame ID,
cell resource epoch, geometry, physical metrics, scale, colors, cursor, selection,
scroll offset and focus. Unattached or unversioned panes use the cell renderer.
Runtime frames remain the authority for buffer contents. Direct buffer mutation
without advancing its frame identity is not an admissible production update.

`PaneDrawCache` keeps two buffers and at most `max_panes_per_tab` entries per
buffer. A begin swaps current/previous preparations and empties the new current
buffer. A hit appends previous pane quads to the new scene and copies them into
current cache storage. A miss draws normally and stores successful output when
it fits. Thus hits add two bulk copies, misses add one cache copy. Neither path
allocates during steady frames. Copies are CPU geometry, not GPU submissions.

Reservation happens at geometry changes. Each buffer reserves two quads per
screen cell, capped below 4 MiB. The total quad budget is below 8 MiB, plus fixed
entry metadata. Existing capacity is retained after shrinking. A dense pane or
exhausted entry/quad budget falls back to ordinary drawing. Reservation failure
disables reuse until a successful reservation; it does not fail the renderer.
No model pointer, native frame pointer or atlas allocation is retained by the
cache. Font/resource replacement invalidates via the cell resource epoch.

Preparation reuse neither retires damage nor acknowledges delivery. Retried
frames still append and submit their complete output. The shared lifecycle and
runtime protocol are unchanged. The cache introduces no timer, task or repaint.

## Measurement protocol

Both builds use ReleaseFast with optional counters and timing disabled. The
same probe source is compiled into each version. Cell mutations advance applied
frame IDs. Sparse and split workloads toggle actual cell bytes and assert their
expected rebuild count. Warmup finishes a full stimulus cycle before measured
indices restart.

- Correctness: compare SHA-256 of every emitted quad byte and the complete glyph
  atlas across deterministic fixtures. Include retained, sparse, full, theme,
  resize, selection, font, cursor, focus, reattachment and two-pane cases.
- Unit/integration tests: independent cached/reference renderers compare byte
  output after each invalidation and again on a cache hit. Exercise attachment
  replacement with equal frame IDs, detach, failed append/retry, memory quotas,
  absent panes and allocation failure. Existing GUI tests remain enabled.
- CPU: five alternating pairs, 10,000 measured draws per case after at least
  five seconds of warmup. Sizes 80x40 and 160x40. Cases: retained, one changed
  cell, full redraw, two panes with one active, and two panes both active.
- Native: five alternating pairs, 200 measured committed-text inputs per run
  after 20 warmup inputs. Fixed 1600x1000 viewport, two visible panes, one receiving
  input. Endpoint is matching pixels at Metal completion, not scanout.
- Idle: separately compare prepared frames and completions with no child output.
  Idle trace hooks are excluded from input-latency timings.

Raw evidence and source snapshots live in
`/private/tmp/telar-pane-cache-experiment/`. CPU fixture time is not application
CPU usage or input latency. No cache-miss attribution is claimed without PMU
measurements. Allocation accounting excludes foreign allocators and GPU memory.

Acceptance requires equivalent output, no steady allocation and a repeatable
benefit in the intended mixed-pane workload. Continuous changes and native tails
must be reported even when they regress. Results determine whether the current
cache is a candidate for integration or needs a different retention policy.

## Idle observation and limitations

In the 25-second quiet workload windows, the reference prepared/completed 11
frames and the candidate 9. Both had zero child output bytes, zero busy requests,
zero failed GPU/main completions, and zero dropped trace events. Both used a
177x46 PTY. This is a one-pair smoke check, not evidence of lower idle power or
zero-work idle. Both versions still prepare occasional frames with a silent child;
their cause was not investigated in this experiment. See [idle evidence](idle.json).
All test windows, runtimes and child fixtures were closed after collection.

## Reproduction and evidence

Build the reference with the common probe before applying [the renderer and test
patch](candidate.patch), then build the candidate with it:

```sh
zig build install build-dod-probe -Doptimize=ReleaseFast --prefix /tmp/pane-cache/A
# Apply candidate.patch, keeping the same ProfilingProbe.zig in both builds.
zig build install build-dod-probe -Doptimize=ReleaseFast --prefix /tmp/pane-cache/B
python3 tools/cell_mesh_experiment.py verify --baseline /tmp/pane-cache/A/bin --candidate /tmp/pane-cache/B/bin --output /tmp/pane-cache/results
python3 tools/cell_mesh_experiment.py cpu --baseline /tmp/pane-cache/A/bin --candidate /tmp/pane-cache/B/bin --output /tmp/pane-cache/results --modes retained sparse full two_one_active two_all_active --rounds 5
python3 tools/cell_mesh_experiment.py native --baseline /tmp/pane-cache/A/bin --candidate /tmp/pane-cache/B/bin --output /tmp/pane-cache/results --panes 2 --rounds 5
zig build test-gui codestyle check-client-boundaries
```

The runner rejects pooling native runs with different viewport, PTY geometry,
display scale or display rate. The completed campaign also passed that check
explicitly after measurement. The measured runner versions are preserved with the
raw evidence; the current runner adds this final cross-run guard.

[Artifact hashes and validation receipts](evidence.json) identify the binaries,
source snapshots, manifests and raw directories. [CPU results](cpu.json) preserve
all paired times; [frame equivalence](verify.json) records the comparison scope.
No main merge, commit or push was performed. Earlier instrumentation and metadata
work remains intact in the working tree.
