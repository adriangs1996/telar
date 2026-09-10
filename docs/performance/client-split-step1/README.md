# Client pane extraction, step 1

The TUI now uses `telar-client` for pane storage, frame application, damage,
presentation completion values and semantic key/mouse values. The workspace
model delegates frame admission and retirement to `Pane`; it no longer implements
those operations itself. Terminal composition and parsing remain in the frontend.
The full client model, application, graphics and replaceable presentation have
not been extracted yet.

## Validation

- `zig build test-client`: 14 tests passed in Debug and ReleaseSafe.
- `zig build test-frontend -Doptimize=ReleaseSafe`: 1427 tests passed. Three
  former frontend tests moved with cwd handling and damage into the client suite.
- Schema, transport and isolation targets: 228 tests passed, including cached
  unchanged suites.
- `zig build check -Doptimize=ReleaseSafe`: succeeded.
- `zig build -Doptimize=ReleaseFast -Ddiagnostics=true`: succeeded.
- `zig build codestyle -- src/client`: succeeded.
- The headless test binary's `otool -L` lists only `libSystem.B.dylib`, with no
  FreeType, AppKit or GPU frameworks.

The pane tests cover receive-buffer reuse, canonical input modes, broken bases,
foreign pane identity, resize restrictions, stale completion, same-size storage
reuse and every allocator failure in initialization, resize and metadata update.

## Local measurements, not a performance gate verdict

`bench.jsonl` uses the baseline's 20 samples and 40 ms targets. `comparison.txt`
compares it to the initial run. All reported wire payload sizes are unchanged.
Some medians exceed the documented regression thresholds; a single unpaired
before/after run cannot distinguish a code regression from host variation.
Performance acceptance remains pending repeated paired measurements.

`e2e.json` is one paired smoke run from `tools/perf_e2e.py`, with 20 echo samples:

- Baseline echo p50/p95/p99: 387.8/723.5/857.0 microseconds.
- Candidate echo p50/p95/p99: 395.8/501.0/519.1 microseconds.
- Neither echo run timed out.
- Both slow-host runs delivered all 32 inputs while host output was blocked.
- All four isolated runtime shutdowns exited successfully, removed their socket
  and completed child cleanup.

This is not evidence of a latency improvement, a memory-soak result, or proof
that the complete client is renderer-independent. Steps 2 through 6 remain.

Use `/opt/homebrew/bin/python3` for these tools on this machine. The default
`python3` is 3.9.20 and cannot parse `bench_compare.py`'s match statements.
