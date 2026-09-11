# Zig source-layout migration validation

The source migration is implemented on `refactor/zig-source-layout`, based on
`3b801c85`. Executable probes used Zig source at `4d8c9024`. This report's commit
also fixes progress-dot handling in the test-inventory tool.

The functional checks pass. Performance acceptance remains open.

## Scope

- 3273 maintained Zig files and 119 generic constructors.
- No `root.zig` files or ordinary top-level struct declarations remain.
  The linter also checks conditional and parenthesized type initializers.
- Two packed and five extern layouts retain their field layouts. Explicit
  package entrypoints replace the old roots; they were not removed as barrels.
- The client policy admits 401 public files and 86 assembly-only imports across
  29 capabilities. Assembly permission does not grant cross-capability access.
- Import targets and Git's index have matching filename case, with no
  case-insensitive collisions.

`source-audit.json` records the inventory. The
[source convention](../../zig-source-layout.md) describes the resulting layout.
The migration does not change the execution model, transport, ownership of
sessions, or the presentation completion protocol.

## Checks

Host: Apple M3, 16 GiB, macOS 26.6.2, Zig 0.16.0. Binary hashes, build options
and host details are in `metadata.json`. Plaintext build logs normalize trailing
whitespace; compressed telemetry and trace files retain their recorded bytes.

| Check | Result | Evidence |
| --- | --- | --- |
| ReleaseSafe aggregate tests | 3300 passed, 2 skipped; 123/123 steps | `tests.log` |
| ReleaseSafe tests with tracing | Same totals | `trace-tests.log` |
| ReleaseSafe tests with diagnostics, tracing and CPU tracing | Same totals | `trace-cpu-tests.log` |
| ReleaseSafe aggregate analysis | 90/90 steps | `check.log` |
| Nine executable entrypoints, including optional examples | 54/54 steps | `programs.log` |
| Debug common-client and frontend tests | 751 + 690 passed | `debug.log` |
| Linux x86_64 common-client analysis | 17/17 steps | `linux-client.log` |
| Existing cross-target declaration checks | 12/12 steps | `cross.log` |
| AST linter tests | 49 passed | `linter-tests.log` |
| Client boundary policy tests | 19 passed | `tests.log` |
| Test-inventory tool tests | 7 passed | `tests.log` |
| ReleaseFast diagnostics build | 51/51 steps | `build.log` |
| ReleaseFast CPU-trace build | 51/51 steps | `trace-build.log` |
| Echo oracle and proxy executable builds | 47/47 steps | `aux-build.log` |
| Optional proxy example tests | 34 passed | `proxy-tests.log` |
| Fuzz adapters and corpus replay | 22/22 steps | `fuzz.log` |

The history-preview example also emitted parseable SVG with `--inspect`.
Benchmark smoke executed 34 cases. Every reported payload size matched the
baseline. The three samples per case do not support a timing verdict.
The common-client test executable links only libSystem, as shown in
`client-link.log`.

## Test discovery

The comparison queried 31 native test executables from each checkout using
Zig's metadata protocol. It did not rerun those application tests.

All 2795 baseline named tests remain present. The candidate advertises 2814
unique names. `test-discovery.json` lists the 19 additions and the empty missing
set. `test-inventory.json.gz` contains the full comparison, including reduced
duplicate executions. Anonymous discovery blocks are not named tests.

The baseline executed 3684 passing tests and two skips. Its higher execution
count includes duplicate reachability through barrels. Matching names is a
discovery check, not a claim of line coverage or a proof of behavior equivalence.

## Reflective contracts

Alias cleanup removed the executable's three root opt-ins. As a result, an
optimized build ignored `-Ddiagnostics=true` and the trace options. The repair
restores `telar_diagnostics`, `telar_echo_trace` and `telar_echo_trace_cpu`.

The main-module regression test now checks public declaration metadata and
configured values. Zig's test runner is the root during unit tests, so those
tests cannot stand in for the executable's root lookup. The live probes check
the actual effects instead.

The audit also checked platform declarations, optional input-handler methods,
wire validation, the search probe and asynchronous metrics sampling.
`TextSearch`, `sampleOwned` and generic delivery namespace contracts remain
available. See `reflection-audit.txt`.

An earlier E2E attempt used an uncontrolled installed binary. Another had no
candidate telemetry because of the missing root declarations. Neither attempt
is acceptance evidence. Zero observed inputs in that second attempt did not
establish input loss.

## Optimized executable probes

Baseline and candidate were copied outside `zig-out`. Their hashes were checked
before and after the measurements.

The final echo/load/slow-host/graphics smoke had eight clean shutdowns, no echo
or load timeouts, and runtime/client telemetry for every run. Both versions
observed 32 of 32 inputs while host output was blocked. The graphics fixture
recovered 33,177,600 pixel bytes with the same SHA-256 and the same 4,004,011-byte
image wire payload. Total host-terminal stream lengths differed; this is not a
claim that every output stream was byte-identical.

`e2e-results.json` contains the samples. `telemetry.json` indexes the compressed
runtime/client logs and records shutdown results.

The CPU-trace build produced two trace files, 2533 events and 20 complete echo
chains. Every event had CPU-time and thread fields, with no dropped records.
The client exited successfully and the runtime removed its socket and children.
See `trace-summary.json`, `trace-chain.json` and the two `.echo.jsonl` files.

### Performance is not accepted

The candidate was slower in the final one-pair, 20-sample latency smoke:

| Case | Baseline p50/p95/p99, microseconds | Candidate p50/p95/p99, microseconds |
| --- | --- | --- |
| Echo | 641.96 / 955.03 / 1032.77 | 741.73 / 1789.16 / 2476.83 |
| Load | 510.67 / 780.24 / 796.62 | 563.08 / 971.01 / 1244.07 |

These observations exceed the 5%/8%/10% budgets. This small smoke does not
establish a stable regression or satisfy the performance gates. It cannot be
reinterpreted as a pass. Controlled paired runs and native Ubuntu acceptance
are still required. The earlier
[client-split performance and browser acceptance](../../performance/client-split-step6/README.md)
also remains open.

## Windows limitations

The Windows console ABI assertions pass, including the 22-byte screen-buffer
info layout and its field offsets. The general `cross` step checks declarations;
it does not establish that every Windows method compiles or runs.

Full Windows analysis remains blocked by cross-target sqlite3. Common-client
analysis exposes the same `std.c.socketpair` and `std.c.O` errors on baseline
and candidate. Explicit TTY method analysis exposes the same Windows BOOL and
`CreateFileW` errors on both. The paired `windows-*` logs record those failures.
This migration does not claim Windows runtime support or fix unrelated APIs.

## Reproduction

Run from the migration checkout with Zig 0.16.0 and the project's native build
dependencies installed:

```sh
zig build codestyle
zig build check -Doptimize=ReleaseSafe
zig build test -Doptimize=ReleaseSafe -j4 --verbose --summary all > candidate-tests.log 2>&1
zig build test -Doptimize=ReleaseSafe -Decho-trace=true -j4
zig build test -Doptimize=ReleaseSafe -Ddiagnostics=true -Decho-trace=true -Decho-trace-cpu=true -j4
zig build test-client test-frontend
zig build check-client -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu
zig build cross
zig build -Doptimize=ReleaseFast -Ddiagnostics=true
zig build echo-probe proxy -Doptimize=ReleaseFast
zig build test-proxy-example -Doptimize=ReleaseSafe
zig build history-preview -Doptimize=ReleaseSafe -- --inspect > /tmp/history-preview.svg
zig build bench -- --samples 3 --sample-ms 5 --json
(cd test/fuzz && zig build check -Doptimize=ReleaseSafe)
```

Build the baseline tests with `--verbose` in a detached `3b801c85` checkout.
Its test executables must still exist in that checkout's cache:

```sh
python3 tools/compare_zig_tests.py \
  --baseline-root /tmp/telar-layout-reference \
  --baseline-log /tmp/telar-layout-reference-tests.log \
  --candidate-root "$PWD" \
  --candidate-log candidate-tests.log \
  --output /tmp/layout-test-inventory.json
```

Copy and hash the diagnostics-enabled ReleaseFast binaries before probing:

```sh
python3 tools/perf_e2e.py \
  --baseline /tmp/layout-binaries/baseline \
  --candidate /tmp/layout-binaries/candidate \
  --samples 20 --repetitions 1 --cases echo load slow-host graphics \
  --output /tmp/layout-e2e
```

For the trace check, build with all three diagnostic/trace options, copy that
binary separately, and pass it to the existing echo fixture:

```sh
python3 tools/echo_path.py --probe /tmp/layout-binaries/echo-probe \
  --candidate /tmp/layout-binaries/trace-cpu --samples 20 --repetitions 1 \
  --controls --trace --output /tmp/layout-trace
python3 tools/echo_trace.py /tmp/layout-trace/candidate-0
```

The original checkout and the native experiments were not incorporated into
this branch. The saved config and Asteroids hashes still match. The original
geometry file has a new trailing `// bench-marker-2`; without that suffix its
hash matches the saved contents. The suffix was left in place. Preservation
hashes are recorded in `metadata.json`.
