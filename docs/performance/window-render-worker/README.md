# Window render worker

An experiment on the macOS window: move what blocks the window thread per
frame onto a persistent worker per window, keep the UI thread the only writer
of the client model, and measure key-to-GPU latency under load. Measured on
2026-10-03 on the machine Personal.

**Result: unfavorable; the approach was not applied.** Step 1 showed that
scene preparation costs 0.08 to 0.2 ms of the window thread per frame and
never reaches 1 ms at p99 even with four times the cells, so a worker that
prepares scenes off the UI thread has nothing measurable to win; it was not
prototyped. What does block the window thread under load is
`CAMetalLayer.nextDrawable`, 3 ms at the median and 12 ms at p99 per frame
with four panes flooding, so the prototype moved that wait and the GPU
submission to a persistent render queue per window, prepared scenes on the
main thread with the drawable in hand, and kept the Zig client untouched.
Paired against the base it did not change the target metric, typing while
three panes flood (p95 better in 2 of 7 pairs, p99 in 4 of 7), lost `dense`
p99 in 7 of 7 pairs and presented 1.5% fewer frames a second under the
flood. Nothing was integrated into `main` or installed on Personal. The
branch keeps this report, the samples, the measurement scripts, the
candidate as a patch, the libproc declarations the build needs on this host
(`42fe1a90`, `149f8b32`) and a diagnostic improvement to the window test
(`9c668f35`).

## Host, builds and endpoint

| | |
| --- | --- |
| Hardware | Apple M1 Pro, 32 GB, built-in 3024x1964 display, 120 Hz, mains power |
| System | macOS 26.6.2 (25G83), Zig 0.16.0 (Homebrew), Command Line Tools 26.5 SDK (`DEVELOPER_DIR=/Library/Developer/CommandLineTools`; the Xcode 27.0 beta SDK on this host breaks `translate-c` and libcxx) |
| Base | `3aadb40e` "Fix some issues with the proxy", the coordinator's source base |
| A | `42fe1a90`: the base plus the libproc calls declared by hand, which the macOS 26 SDK needs to build at all (`lib/proclineage/darwin.zig`, `src/backend/process/darwin.zig`); `149f8b32` later moved each struct into its own file for the code style, with the same layouts and assertions |
| B | A plus the render worker in `TelarMetalRenderer.m` and `TelarView.m`, kept as [candidate.patch](candidate.patch) |
| Flags | both `-Doptimize=ReleaseFast -Ddiagnostics=true -Decho-trace=true -Decho-trace-cpu=true`; the probes need the diagnostics telemetry |
| Endpoint | native key event to successful GPU completion of the frame that shows it (`tools/gui_latency.py`: the frame's glyph count; `tools/gui_tui_latency.py`: a verified marker pixel). Neither measures scanout or photons. |

Every measurement ran from an SSH session into Personal with
`SSH_CONNECTION` unset so the window opens, on the console display, with the
screen unlocked (behind the lock screen the window is occluded and draws
nothing) and with no build or test suite running. AeroSpace tiles the probe
windows: `gui_latency.py` records the viewport it got, and the pairs below
only compare runs with the same viewport; `gui_tui_latency.py` fixes the
render target at 1900x1100 and floats its windows.

## Step 1: where the window thread's time goes on A

`tools/gui_latency.py` with the graphics gate configuration (no sidebar,
raw echo, 100 samples after a 3 s settle). `prepare` is the render callback:
projection, scene composition, shaping, retained cell meshes and the
presentation token, measured by the probe around the callback. The default
font gives 18x40 px cells, about 98x50 cells in this viewport; the 8 pt font
gives 10x21 px cells, about 177x95.

| Scene | Viewport | key -> GPU p50 ms | p95 | p99 | prepare p50 ms | p99 | max |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| idle | 1770x2100 @2x | 2.69 | 5.17 | 10.52 | 0.18 | 0.46 | 0.54 |
| dense, 20 rows | 1770x2100 @2x | 2.62 | 4.42 | 6.31 | 0.17 | 0.58 | 1.39 |
| text counter at 120 Hz | 1770x2100 @2x | 9.05 | 26.30 | 27.54 | 0.15 | 0.49 | 0.65 |
| 4K images at 120 Hz | 1770x2100 @2x | 6.99 | 18.13 | 25.52 | 0.07 | 0.13 | 0.95 |
| idle, 8 pt font | 1770x2100 @2x | 2.97 | 4.52 | 10.03 | 0.40 | 0.90 | 2.15 |
| dense, 8 pt font | 1770x2100 @2x | 3.07 | 4.00 | 5.69 | 0.56 | 0.90 | 1.47 |
| text counter at 120 Hz, 8 pt font | 1770x2100 @2x | 8.64 | 27.31 | 33.98 | 0.44 | 0.90 | 1.80 |

Scene preparation never reaches a millisecond at the median and stays under
a millisecond at p99 even with four times the cells. The client applies a
cell frame in 5 to 8 µs and decodes it in 2 µs (client telemetry). None of
that explains 9 ms medians and 26 ms tails under continuous output.

`tools/gui_tui_latency.py --mode gui` with `TGB_DRAW_DIAGNOSTICS=1` names
the stages of the submission that carried each sample, one round of 100
samples after 20 warmups, render target 1900x1100 at scale 1 (98x24 cells
alone, 47x22 per pane with four panes). In `splits-load` three panes run
`tools/terminal_bench_fixture.py` flooding output without a rate limit
(the runtime read 71 to 75 MiB/s from the three flooding PTYs over each run, from its telemetry) while the fourth is typed into.

| Stage of the sample's submission | single p50 ms | p95 | p99 | splits-load p50 ms | p95 | p99 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| input -> draw attempt | 1.26 | 2.94 | 5.15 | 0.55 | 2.42 | 3.00 |
| drawable wait (`nextDrawable`) | 0.10 | 0.26 | 1.13 | 3.01 | 7.33 | 11.72 |
| prepare (render callback) | 0.20 | 0.35 | 0.43 | 0.08 | 0.12 | 0.15 |
| submit (`renderFrame` to commit) | 0.53 | 1.23 | 1.65 | 0.16 | 0.20 | 0.22 |
| GPU (commit to feedback) | 0.89 | 1.54 | 2.06 | 0.84 | 1.32 | 2.49 |
| feedback -> main thread | 0.09 | 0.38 | 0.84 | 0.04 | 7.39 | 7.45 |
| **key -> GPU completion** | 3.18 | 5.93 | 8.44 | 5.05 | 9.72 | 13.34 |

Under load the window thread spends its time inside `CAMetalLayer
nextDrawable`: 3.0 ms at the median and 11.7 ms at p99 of the sample's own
submission, because at 120 Hz with one frame in flight the layer's drawable
pool is empty until the display recycles one. While it waits, the thread
cannot route input, apply runtime frames or take GPU completions: the
completion of the frame that carried a sample waited 7.4 ms (p95) for the
main queue. Preparing the scene costs 0.08 ms and handing it to Metal 0.16
ms. A worker that prepares scenes would move at most a tenth of a
millisecond per frame off the window thread; the drawable wait is what to
move.

## The candidate

`TelarMetalRenderer` owns one serial dispatch queue per window at
user-interactive QoS, its render worker. The view asks it for a drawable
(`acquireDrawable:completion:`); the worker blocks in `nextDrawable` and
hands the drawable to the main thread, where the view prepares the scene as
before, with the drawable in hand, so the frame is as fresh as it was when
the main thread waited itself. `renderFrame:drawable:` admits the frame on
the main thread (marks it in flight, resolves the image textures its draws
sample) and the worker uploads the pages, encodes and commits. Completion
still arrives on the main thread through the commit feedback.

Ownership and lifecycle:

- The client model, the Zig preparation and the presentation lifecycle are
  untouched: no Zig file changes. The frame's borrowed quads, pages and
  diagram pixels are read by the worker until the completion the lifecycle
  already waits for before preparing again.
- `in_flight` is set on the main thread before the hand-off and cleared by
  the completion, so the main thread never touches the command buffer, the
  allocator, the argument table, the pages or the quad buffer while the
  worker encodes. Image bookkeeping (`acceptImages`, upload completions)
  stays on the main thread between frames; the worker binds `draw_textures`
  resolved at admission, never `images` itself.
- A drawable acquired before a resize has the old size; the view asks for
  another instead of preparing a frame it would only retire. A nil drawable
  resumes the display link so the next tick asks again.
- A frame the worker cannot encode completes as failed on the main thread,
  which closes the client the way a refused submission did.
- `shutdown` drains the render queue (a pending drawable wait or encode ends
  first), then waits for submitted GPU work and uploads, as before; the view
  closes after it, so nothing reaches a released context.
- Linux is unchanged: its frame worker already draws off the window thread.

Pacing, coalescing, tokens and the cell ACK keep their contracts; the Zig
side does not know the worker exists.

## Step 4: paired A/B

Seven pairs per case, order alternated every pair (A then B, then B then
A), the same viewport, font, display, build mode and endpoint within a case,
no build or suite running. Per run the probe's p50, p95 and p99 of key to
GPU completion; "B wins" counts the pairs where B's value is lower. The
acceptance rule (`.agents/skills/perf-pass/measurement.md`) asks for 6 of 7
in the target case and no consistent loss elsewhere.

### Four panes, three flooding (`gui_tui_latency.py --mode gui --cases single splits-load --panes 4`)

| Case | Metric | A median ms | B median ms | paired change | B wins | A range | B range |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| single | p50 | 2.17 | 2.07 | +6.4% | 2/7 | 1.70..2.27 | 1.72..2.54 |
| single | p95 | 5.21 | 5.37 | -7.3% | 5/7 | 4.86..6.45 | 4.36..5.60 |
| single | p99 | 6.97 | 6.31 | -25.7% | 5/7 | 5.42..10.12 | 4.70..11.47 |
| splits-load | p50 | 6.00 | 6.02 | -1.1% | 4/7 | 5.85..6.09 | 5.50..6.12 |
| splits-load | p95 | 9.78 | 9.80 | +0.3% | 2/7 | 9.72..9.84 | 9.72..9.95 |
| splits-load | p99 | 10.10 | 9.99 | -0.2% | 4/7 | 9.76..10.47 | 9.78..11.44 |

Viewports: [1900, 1100]. GUI process usage over each run (ps):

| Build | peak RSS MiB (median of runs) | CPU time s (median of runs) |
| --- | ---: | ---: |
| A | 163 | 1.94 |
| B | 142 | 1.90 |

### One pane (`gui_latency.py`, graphics gate configuration)

| Case | Metric | A median ms | B median ms | paired change | B wins | A range | B range |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| dense | p50 | 2.56 | 2.66 | +2.5% | 3/7 | 2.54..2.69 | 1.99..2.91 |
| dense | p95 | 5.76 | 6.00 | +5.8% | 2/7 | 4.82..6.70 | 4.66..6.79 |
| dense | p99 | 8.41 | 9.39 | +8.1% | 0/7 | 6.34..10.49 | 8.90..11.32 |
| idle | p50 | 2.29 | 2.34 | -2.6% | 4/7 | 2.00..2.55 | 1.95..2.51 |
| idle | p95 | 5.51 | 5.12 | -4.0% | 5/7 | 4.98..7.43 | 4.57..6.73 |
| idle | p99 | 8.36 | 8.43 | +9.0% | 3/7 | 6.59..10.17 | 5.48..12.61 |
| image120 | p50 | 3.07 | 2.36 | -14.4% | 5/7 | 2.04..8.22 | 2.06..4.15 |
| image120 | p95 | 9.36 | 9.44 | -2.6% | 4/7 | 7.35..17.79 | 8.31..19.87 |
| image120 | p99 | 11.36 | 11.54 | -11.2% | 4/7 | 9.05..22.63 | 9.70..23.95 |
| text120 | p50 | 6.06 | 6.05 | +1.2% | 3/7 | 3.21..8.84 | 1.85..9.60 |
| text120 | p95 | 16.53 | 10.97 | -10.4% | 6/7 | 8.72..22.23 | 9.33..18.62 |
| text120 | p99 | 17.36 | 17.80 | -5.2% | 5/7 | 11.23..25.55 | 10.86..26.08 |

Viewports seen: (3560, 2100, 2.0).

| Build | peak RSS MiB (median of runs) | CPU time s (median of runs) |
| --- | ---: | ---: |
| A | 121 | 0.78 |
| B | 121 | 0.83 |


Throughput under the flood, from the client's telemetry: A presented 98.7
to 100.9 frames a second (median 100.1), B 98.4 to 99.5 (median 98.6), B
lower in every pair; the runtime read 71 to 75 MiB/s from the PTYs in both.
Under the flood the GUI process's peak RSS varied between 146 and 175 MiB
for A and stayed at 145 to 147 MiB for B, a difference this experiment did
not explain; in the one-pane scenes both peaked at 121 MiB. B's GUI process
used about 6% more CPU time over the one-pane scenes (0.83 s against 0.78
s, median of 28 runs each) and the same under load.

The target case, typing while three panes flood, does not move: p50 4/7,
p95 2/7 and p99 4/7, with medians within 0.2 ms and the p95 of every run of
both builds between 9.7 and 10.0 ms. The one-pane scenes split by noise
except `dense` p99, which B loses in all 7 pairs (+8% at the median), and
`text120` p95, which B wins in 6 of 7; neither is the target. The candidate
fails the rule in the target case and shows a consistent loss in another
mode, so it is rejected.

Why the window thread's wait did not become latency: under continuous
output the layer hands out a drawable once per display interval, whichever
thread asks. Moving the wait off the window thread frees it to route input
and apply frames meanwhile, but the frame that carries the key still waits
for the same drawable slot, and under the flood every slot is taken. The
cadence, not the CPU, sets the 9.7 ms p95. The probe's stage attribution
assumes the synchronous order (`drawIfReady` acquiring on the main thread),
so B's stages are not attributable with it; the endpoint is unaffected by
that and is what the pairs compare. The two dispatch hops the candidate adds
to every frame after idle are the likely cost behind `dense` p99 and the
lower frame rate; that cause was not measured in isolation.

Raw per-run summaries and per-sample latencies: [pairs-load.json](samples/pairs-load.json)
(with the client and runtime counters each run ended with),
[pairs-scenes.json](samples/pairs-scenes.json), [pairs-report.md](samples/pairs-report.md).
The candidate itself is [candidate.patch](candidate.patch), against `42fe1a90`;
it is not on this branch.

## Checks

On the final branch (`149f8b32`), with `DEVELOPER_DIR` set to the Command
Line Tools:

| Step | Result |
| --- | --- |
| `zig build codestyle check-client-boundaries check-model-boundaries check-programs check-library-reexports` | passed |
| `zig build cross` | passed (type-checks the Linux and Windows binaries, which include the new layout files) |
| `zig build test-libraries` | passed, 694 tests, 1 skipped (`lib/proclineage` among them) |
| `zig build test-runtime` | passed (the backend's `cwd` and process tests among them) |
| `zig build test-gui` | passed |
| `zig build test-gui-window` | 5 failures, all the clipboard-image checks of `macos_host_input.m`; the same five fail on the base native code on this host, see below. Every window, Metal, input, pointer and fullscreen check passed. |
| `zig fmt --check` on the changed files | passed |

For the candidate (B), run before it was discarded: `test-gui-window` with
the render worker passed every window, Metal, resize, close-in-flight and
fullscreen check once a drawable acquired before a resize was dropped
instead of prepared for (the first prototype failed the render callback's
viewport check three times there); its five clipboard-image failures are
the host's. `test-gui`, `cross` and the style checks do not reach the
Objective-C files and passed unchanged. The `telar-benchmarks` binary of B
is byte-identical to A's and `telar-dod-probe` differs only by the
Objective-C objects it links, so the CPU-side kernels and digests are A's
by construction; the paired dod-probe timings were not run. No oracle
beyond the window test and the paired endpoint was built for the
candidate, since it changed no frame data, only which thread submits it.

## Risks and gates not verified

- Linux was not measured; the final branch changes no Linux code, and the
  candidate did not touch it either.
- The Ubuntu nightly gate (`docs/performance-gates.md`) and `zig build test`
  as a whole were not run; the checks above are the steps the changes reach.
- `test-gui-window` fails five clipboard-image checks on this host for A and
  for B alike (`image clipboard capture failed at line 248` and the
  following ones), from this SSH session and from an execution under the
  live runtime; they are not caused by either build and were not
  investigated further. One viewport check (`macos_window.m` line 263, the
  render callback's viewport against the layer's size) failed once on A: the
  window resized between the drawable and the callback, which the view
  retires as a resize.
- The libproc declarations were checked against the Command Line Tools 26.5
  SDK with the system compiler (`sizeof` and `offsetof` of every struct) and
  are asserted at comptime; they were compiled on arm64 only.
- The experiment ran at 120 Hz on the built-in display. A display at 60 Hz
  halves the drawable cadence that bounds the flood case; the conclusion
  about where the window thread's time goes should hold, the numbers will
  not.

## Rejected: a Zig preparation worker

The brief's first hypothesis, preparing the scene on a worker from an owned
snapshot of the visible cells, was not prototyped: step 1 bounds its gain at
the preparation cost, 0.08 to 0.2 ms per frame in the measured scenes and
under 1 ms at p99 with an 8 pt font, below the run-to-run spread of the
endpoint (the idle p50 of one build spanned 2.0 to 2.6 ms over seven runs). It
would also need a worker-owned copy of every visible pane's cells per frame
and an exclusive hand-off of the glyph atlas, which the chrome composition
shares, for a gain the measurement cannot see. The numbers that would
justify it are in [samples/A-profile](samples/A-profile).

## Reproduction

```sh
export DEVELOPER_DIR=/Library/Developer/CommandLineTools   # on a host whose default SDK is a beta
zig build -Doptimize=ReleaseFast -Ddiagnostics=true -Decho-trace=true -Decho-trace-cpu=true --prefix /tmp/trw/A   # at 42fe1a90
zig build -Doptimize=ReleaseFast -Ddiagnostics=true -Decho-trace=true -Decho-trace-cpu=true --prefix /tmp/trw/B   # at the render worker commit
docs/performance/window-render-worker/scripts/profile.sh /tmp/trw/A/bin/telar /tmp/trw/profA
docs/performance/window-render-worker/scripts/profile_small.sh /tmp/trw/A/bin/telar /tmp/trw/profA-small
python3 docs/performance/window-render-worker/scripts/pair_load.py /tmp/trw/A/bin/telar /tmp/trw/B/bin/telar /tmp/trw/pairs-load 7
python3 docs/performance/window-render-worker/scripts/pair_gui.py /tmp/trw/A/bin/telar /tmp/trw/B/bin/telar /tmp/trw/pairs-gui 7 idle dense text120 image120
```

The probes need macOS, a graphical login with the screen unlocked, the
`aerospace` CLI for `--float-windows`, Ghostty under `/Applications` (the
load probe copies it even in GUI mode) and no `SSH_CONNECTION` in the
environment. Socket paths must stay short: use `/tmp`.
