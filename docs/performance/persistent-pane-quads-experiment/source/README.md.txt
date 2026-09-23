# Pane cache lab

Run the isolated native widget, with no runtime or child processes:

```sh
zig build run-widget -Doptimize=ReleaseFast -- --cache
```

`zig build run-widget` still opens the change review experiment. Use ReleaseFast
for timing comparisons; Debug is useful for correctness checks.

The lab runs four instances of Telar's real terminal renderer on the same pair
of 80 × 20 cell buffers:

| Policy | Admission |
| --- | --- |
| Cells only | Existing retained cell meshes; no pane quad storage allocated. |
| Always store pane | Current experimental pane cache on every eligible draw. |
| Store after repeat | Store only when the pane's content revision matches its preceding draw. The renderer still validates its full visual key. |
| Keep pane quads | Draw directly into a persistent buffer per pane, retain it on hits, and append one copy to the native scene. |

Click a workload or use `1`–`5`: unchanged panes, one changing cell in pane A,
one changing cell in both panes, full replacement of both panes, or bursts of
five changing frames followed by fifteen unchanged frames in pane A.

- `Space` plays or pauses at ten simulation steps per second.
- `N` or `Right` advances one frame and pauses.
- `R` resets the selected workload and timing history.
- Workload changes reset the experiment and retain play/pause state.
- Hover, resize and other UI redraws do not advance a paused experiment.

Every simulation step rotates measurement order, runs each policy, then compares
quad bytes and atlas pixels outside the timing window. A mismatch pauses play.
The preview uses a separate renderer and crops the shared inputs to the window;
resizing does not change the measured geometry.

Mean microseconds cover `begin`, both pane draws and `seal`. The first eight
frames after reset are excluded. Hits and copied bytes describe the last step.
Cells visited is derived from cache misses × 80 × 20: it counts input cells in
the first traversal, not both renderer passes or hardware memory reads. Cache
KiB counts allocated pane-quad capacity, excluding metadata and other renderer
resources. Reset clears retained-cell validity and pane admission history but
keeps allocated storage and loaded glyphs.

These are exploratory CPU measurements on dense ASCII input. UI drawing, byte
comparison and GPU submission are outside the timer. The lab does not measure
end-to-end latency, hardware cache misses or real idle scheduling. It deliberately
requests draws of unchanged panes to show their reuse cost; it does not imply
that production should render continuously while idle.

To iterate, change admission in `Trial.draw`, or mutations in `Lab.advance`. Policy
names live in `policy.zig` and `Widget.zig`. The admission experiment does not
change production renderer policy. Geometry, theme, cursor and resources are
fixed here; extending admission beyond this fixture needs invalidation coverage.

```sh
zig build test-widget
```

Tests cover equivalent output across all workloads, zero Zig allocator calls
after warmup, reduced copying during continuous changes, delivered mouse controls,
keyboard controls, pause/redraw isolation and the runner's single-frame ownership.

## Batch admission measurements

Build once, then run the campaign without compiling during measurement:

```sh
zig build build-widget -Doptimize=ReleaseFast
python3 tools/cache_admission_experiment.py --output /tmp/telar-cache-admission
```

The driver runs each policy in its own process, in all six policy orders. Each
round shuffles the 36 cases with a recorded seed. Cases combine pane sizes
40 × 10, 80 × 20 and 160 × 40, one or two changing panes, and 0, 1, 2, 5, 20 or
100 unchanged draws after each changed draw. A change replaces one cell per
active pane. With one active pane, the other remains unchanged throughout.

Each process warms at least 256 frames and three full cycles, then measures at
least 4096 frames, rounded to whole cycles. Mutation, counters, sorting and
output are outside the timer. The selected renderer runs alone; the shared lab
still allocates all four renderers, so process RSS is not a per-policy memory
comparison. The reported cache capacity belongs only to the selected renderer.

A separate pass compares every quad byte and all atlas pixels across all
policies for three complete cycles of each case. Measured runs check zero
allocator calls and the expected number of cache hits. Results retain every
run, including outliers, with per-run p50/p95/p99, paired mean changes, raw CSV,
commands, exit statuses, source snapshots and the executable SHA-256.

One case can also be run directly:

```sh
TELAR_CACHE_COLS=80 TELAR_CACHE_ROWS=20 TELAR_CACHE_QUIET=1 \
TELAR_CACHE_ACTIVE=2 TELAR_CACHE_POLICY=stable \
zig-out/bin/run-widget --cache-bench
```

Set `TELAR_CACHE_VERIFY=1` for the comparison pass. Batch mode opens no window,
starts no runtime and ignores the live change-review connection.

## Persistent pane output

The fourth policy owns two bounded `PersistentPane` buffers in the lab. A miss
renders directly into that pane's buffer; a hit leaves it unchanged. Both append
one copy to the renderer's ordinary contiguous scene. This removes the cache
refresh copy on hits without delaying their admission. It is not zero-copy:
scene composition still copies, and native Metal/Vulkan uploads are unchanged.

The existing renderer supplies the full `paneKey`, so content, visual state,
attachment identity and resource epochs use the same invalidation rules. A
pane-local capacity failure invalidates the entry and falls back to ordinary
cell drawing. The native frame never points into persistent pane storage.
Normal single-flight submission still prevents drawing or resizing resources
while the GPU owns a frame.

The experiment reserves two quads per cell per pane. That is half the previous
cache's quad capacity, which kept two complete preparations. This fixed two-pane
experiment does not implement a production-wide allocator or eviction policy.

Compare persistent storage with cell-only and immediate admission:

```sh
zig build build-widget -Doptimize=ReleaseFast
python3 tools/cache_admission_experiment.py --candidate retained --output /tmp/persistent-quads
```

The default campaign still compares `cells`, `always`, and `stable`. The selected
candidate is recorded in metadata. Verification compares all four policies.
