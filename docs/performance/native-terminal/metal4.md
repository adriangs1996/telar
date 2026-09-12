# Metal 4 and display-clock pacing

Measured on 2026-09-12, Apple M3, macOS 26.6.2, Zig 0.16.0. This is a
maintenance migration with measured latency checks, not a claim of superiority
over Ghostty or a guarantee of lower display latency.

The final implementation uses Metal 4 command submission, a reusable allocator
and argument table, explicit residency, and a view-bound `CADisplayLink`.
Presentation remains synchronized by `CAMetalLayer.displaySyncEnabled`.
After idle, rendering can begin immediately; pending continuous work uses the
display clock and the 60 Hz frame budget. The shaping and retained cell caches
are unchanged.

## Same-size comparison

Each ReleaseFast row contains three runs of 100 measured responses, with 20
warmup responses discarded per run. Both versions use the same single-cell
PTY response and pixel verification probe. At 1900 × 2112, both pane grids are
211 × 105 cells at scale 1. The probe fixes the content view size independently
of the tiling window manager. Both client and runtime are ReleaseFast and have
phase/CPU tracing enabled.

| Version | Samples | p50 ms | p95 ms | p99 ms | Maximum ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Previous renderer and dispatch timer, repeated | 300 | 5.63 | 9.62 | 10.44 | 12.66 |
| Metal 4 and final display-clock pacing | 300 | 4.22 | 9.82 | 11.00 | 28.25 |

The final Debug build (`just app`) measured **6.86 ms median, 12.76 ms p95,
16.18 ms p99 and 16.20 ms maximum** over 100 responses at the same fixed
1900 × 2112 viewport. Its client and runtime both use Debug.

The median remains in the few-millisecond range. The new version has a slightly
higher p95/p99 and a larger observed maximum; these measurements do not support
an across-the-board latency improvement. GPU execution itself has a median of
0.47 ms before and 0.44 ms after, including the diagnostic pixel copy.

The earlier historical reference was 3.77 ms median / 8.77 ms p95. Its repeated
baseline here is 5.63 / 9.62 ms, which illustrates sensitivity to desktop and
refresh scheduling. The current comparison changes both the submission API and
pacing; it does not isolate the cost of Metal 4 alone. Runs are sequential,
not a randomized experiment: the final fixed-size version ran three times,
then the previous version ran three times.

A separate larger-window control used 3770 × 2112 pixels, 418 × 105 cells and
300 samples per version. The previous version measured 6.67 ms median / 13.98 ms
p95; the final version measured 6.79 / 15.01 ms. Do not compare those values
directly with the smaller viewport. This control ran the previous version first.

## Why the final scheduler uses CADisplayLink

An intermediate Metal 4 implementation used `CAMetalDisplayLink`, paused after
each callback, at 60 Hz with preferred frame latency 1. It measured 17.41 ms
median / 28.02 ms p95 over 300 responses at 1900 × 2112. Its median GPU execution
was only 0.49 ms. That implementation was not retained because its end-to-end
GPU-completion latency regressed substantially.

The final view-bound `CADisplayLink` paces pending frames while allowing an
immediate drawable request after idle. Both implementations keep VSync enabled.
The experiment identifies a problem with the tested scheduling strategy, not a
general performance limit of `CAMetalDisplayLink`.

## Instrument and scope

The probe records native key dispatch to successful GPU completion of a frame
containing the expected alternating marker color. For classic Metal it appends
a blit before commit. For Metal 4 it appends a compute-encoder copy before ending
the command buffer, with a render-to-copy barrier and explicit residency.
Both copy a single pixel into a 256-byte readback buffer during measurement.
Startup performs a larger readback to locate the marker. The probe makes the
drawable readable with `framebufferOnly=false`; production uses `true`.

Completion timestamps are captured before dispatching verification to the main
queue. Metal 4 commit feedback replaces classic command-buffer completion. GPU
execution durations use the API's start/end timestamps. Neither timing measures
physical keyboard acquisition, compositor presentation, scanout or photons.
No visual smoothness improvement is claimed from this latency experiment.

All samples, GPU durations and executable hashes are retained in
[metal4.json](metal4.json). These measurements do not count whole-process
allocations, IPC bytes or internal driver memory. The adapter has one submission
slot, two buffer bindings, one texture binding and at most four resident resource
allocations; the command allocator's driver-managed byte footprint was not
profiled. No additional queue or renderer worker was introduced.

## Reproduce and verify

```sh
zig build -Doptimize=ReleaseFast -Decho-trace=true -Decho-trace-cpu=true --prefix /tmp/telar-metal4
python3 tools/gui_tui_latency.py /tmp/telar-metal4/bin/telar /tmp/telar-m4-run --mode gui --rounds 3 --samples 100 --viewport 1900 2112
MTL_DEBUG_LAYER=1 zig build test-gui-window
zig build test-gui
python3 tools/gui_lifecycle.py /tmp/telar-metal4/bin/telar /tmp/telar-m4-lifecycle
```

Use fresh short result paths. `--viewport` fixes only the GUI render target;
it does not resize Ghostty in a TUI run. Existing comparison modes remain
available, and the probe supports both classic Metal and Metal 4.

Native validation passed with ordered delivery, 100 coalesced requests, idle
stability and close during an in-flight frame (7 painted, 6 delivered, 4 inputs,
zero failures; the closing frame intentionally receives no client delivery).
The real-shell lifecycle test observed `stty size` changing from `105 418` to
`18 71`, verified command input, and found the shell alive after the window
closed. Its isolated runtime was stopped only after this check. The GUI unit
suite and code-style checks also passed.

See [the renderer walkthrough](../../flows/metal4-renderer.md) for ownership,
Objective-C syntax and the step 9 integration boundary.
