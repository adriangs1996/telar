# Performance gates

Performance decisions use native Ubuntu 24.04 x86_64 runners and Zig 0.16.0.
Results from different CPUs, targets, optimization modes, screen sizes, sample
counts, or sample durations are not comparable.

Pull requests run the short correctness, portability, and absolute p99 budget
gate. The nightly workflow runs five repetitions of 200 samples. Architecture
comparisons use `tools/perf_gate.py` over five baseline and five candidate
runs; regressions above 5% at p50, 8% at p95, or 10% at p99 fail. Any wire
payload change fails by default. If run-to-run spread exceeds the same bounds,
the result is `no verdict` and must be repeated on a quiet host.

A release candidate needs three consecutive green nightly reports in addition
to the release workflow. This makes the release gate span multiple days without
keeping a CI worker asleep. The release workflow repeats the 200-sample suite
with one-second sample targets and runs the backend proxy and historical proxy
example separately.

The terminal-browser check and the graphics throughput gate measured the
terminal client inside Ghostty and retired with it. The window's replacement
is `tools/gui_graphics_gate.py` (macOS; build with
`-Doptimize=ReleaseFast -Ddiagnostics=true`). It runs the key-to-GPU-completion
probe (`gui_latency.py`) against an idle pane, a pane redrawing a text counter
at 120 Hz (the control) and a pane streaming synthetic 3840x2160 RGBA images
over shared memory at 120 Hz (`tools/kitty_stream.py`), three runs of 100
samples each. A pane that redraws continuously makes every key wait for the
next frame, so the image stream is judged against the text control and the
idle run is context. It passes when image-stream latency stays within 5%
at p50, 8% at p95 and 10% at p99 of the control and its p99 under an absolute
16 ms, the window presents at least 50 distinct generations a second (a
generation counts the first frame that draws it) and no run stalls under
half of that, the runtime neither resets nor drops media, the client asks for
no graphics resync, and idle and stream runs start from the same scene. It
reports upload and prepare percentiles and the GPU bytes the textures hold.

Result on an M3 MacBook (2026-09-30, medians of three runs of 100 samples):

| Pane | p50 | p95 | p99 |
| --- | --- | --- | --- |
| idle | 3.4 ms | 9.3 ms | 12.6 ms |
| text control, 120 Hz | 10.3 ms | 25.6 ms | 29.1 ms |
| 4K image stream, 120 Hz | 4.5 ms | 9.5 ms | 12.2 ms |

The window presented 56.8 distinct generations a second with no reset, drop
or resync; uploads took 4.8 ms at p50 and 14.7 ms at p99, `prepare` 0.17 ms
at p50 and 0.40 ms at p99, and the textures held at most 99.5 MB. That run
predates folding wrapped frames; afterwards the same probe presented 55.6
to 57.7 generations a second in each of three runs, where the build without
the fold stalled at about one a second in two of three. The gate needs a
machine that is not paging: runs on the same host under heavy swap, the
text control included, came out two to five times slower and failed.

Linux has no GPU-completion probe. `tools/vm/gui-graphics-latency-test.py`
measures key-to-PTY latency in the test machine (llvmpipe, four vCPUs) idle
and while the same pane streams 1920x1080 frames at 60 Hz: 300 samples gave
p50 3.7 ms and p99 24.0 ms idle, p50 2.0 ms and p99 8.9 ms streaming, with
about 47 generations a second presented; an earlier run of 100 gave p50 2.4
and 3.2 ms. The spread is the host's noise, not the stream: uploads run
on their own thread, drawing and its fence waits on the frame worker, and
`queue_lock` covers only queue submission.
The CPU cost of
drawing images is measured by `telar-dod-probe` (`DOD_MODE=images`): 256
placements add 2-4 µs to a pane frame and resolving them takes 10.5 µs, with
no allocation.
