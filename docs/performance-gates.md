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
terminal client inside Ghostty and retired with it. No window-side
replacement exists yet: the window's frame rate under a 4K KGP stream and the
exterior behavioural checks (no PTY response, delivery or media drops, no
resyncs, isolated history) need a new verifier that drives `telar gui`.
Until it exists, those properties are covered only by the runtime's own
tests and `zig build test-isolation`.
