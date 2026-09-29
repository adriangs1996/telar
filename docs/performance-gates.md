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
at p50, 8% at p95 and 10% at p99 of the control, the window turns at least 58
generations a second into textures, and the runtime neither resets nor drops
media.

Result on an M3 MacBook (2026-09-29, medians of three runs):

| Pane | p50 | p95 | p99 |
| --- | --- | --- | --- |
| idle | 2.9 ms | 11.9 ms | 17.7 ms |
| text control, 120 Hz | 9.2 ms | 21.6 ms | 30.0 ms |
| 4K image stream, 120 Hz | 5.1 ms | 9.7 ms | 12.5 ms |

The runtime forwarded all 120 generations a second with no reset or drop,
uploads took 5.1 ms on average, and the window turned 58.2 generations a
second into textures (runs: 59.8, 57.0, 58.2): the gate passes, with little
margin on throughput. Three changes got it there from 26: textures are
recycled by size and stay in their own residency set (re-adding a 4K texture
to the frame's set every frame cost the driver more than drawing it), and a
placement shows the newest complete generation of its image, which a stream
delivers before the placement that names it. The CPU cost of
drawing images is measured by `telar-dod-probe` (`DOD_MODE=images`): 256
placements add 2-4 µs to a pane frame and resolving them takes 10.5 µs, with
no allocation.
