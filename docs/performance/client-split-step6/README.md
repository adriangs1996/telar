# Client split — phase 6 evidence

Implementation and functional validation are recorded here. **Performance is not
accepted.** Both repeated local microbenchmark comparisons returned exit 2:
`no verdict: benchmark host is noisy`. The browser exterior verifier also fails
two checks on both the pre-split binary and the candidate. Phase 6 remains open
for acceptance; this report does not replace the Ubuntu release gates.

## Changes and functional proof

- Common-client source and build-module boundaries are executable checks.
  Cross-capability imports now use public roots. The common module imports only
  core; native headers are rejected except the guarded `sys/stat.h` media use.
- Window-title formatting/cache uses a synchronous host port. TUI hostname
  lookup and OSC output remain outside the client. Complete UTF-8 is preserved
  on truncation; controls are removed. Failed sinks do not advance the cache.
- Removed the transitional `input.host` alias. Terminal-parser encoding tests
  remain in frontend `host_tests.zig`; semantic encoding is shared.
- Benchmark fixtures follow the extracted `.delivery` state without changing
  their measured operations.
- The two-client pointer-shape test had a child-readiness race: an initial
  snapshot could precede `stty raw -echo`, allowing PTY echo to satisfy its text
  wait before OSC pointer output. A delayed `stty` reproduced the failure. The
  fixture now waits for `OBSERVER_READY` and accumulates snapshot receipt.
  The fixed test and seeds 11, 12 and 13 passed. Runtime behavior is unchanged.
- Updated capability/flow documentation, terminology and accepted ADR 0012.

Final validation:

| Check | Result |
| --- | --- |
| Full `zig build test -Doptimize=ReleaseSafe -j4 --summary all` | 3696 passed, 2 skipped; 119/119 build steps |
| Shared client within that suite | 776 passed |
| TUI within that suite | 712 passed |
| Shared client Debug | 776 passed |
| Python boundary tests | 8 passed |
| Common client semantic analysis, x86_64 Linux GNU | Passed; not execution on Linux |
| ReleaseSafe `check`, diagnostics ReleaseFast build, Zig formatting, common codestyle | Passed |
| Shared-client test linkage | Only `/usr/lib/libSystem.B.dylib`; no font/window/GPU libraries |

See `tests.log`, `debug.log`, `linux-client.log`, `client-link.log` and the
[phase-5 contract tests](../client-split-step5/README.md). Headless exercises real
shared handlers and its supported entrypoints; it is not a full GUI or CLI.
Frontend capability facades still re-export shared types used by TUI consumers;
they do not retain a second implementation.

## Measurement identity

Apple M3, macOS 26.6.2 arm64, Zig 0.16.0, ReleaseFast with diagnostics.
The baseline is `beab209f` plus the preserved pre-existing working tree, as in
[phase 0](../client-split-baseline/README.md). Native SDK, Ghostty-fork and
execution-model experiments are not part of the extraction.

- Baseline binary SHA-256:
  `0e649afca986fd21b93cf01aa0bc03e33956aa437500a1789ee55f00c315ebfd`.
- Measured candidate SHA-256:
  `5560e8c08bc6515c5101ffa417bb50e4c4efc1209d64eac79fbaed95ff3a7641`.
- Final functional-build SHA-256:
  `27e2bf46292d54cee9bccaa8e44793986beab2f9ee582b32f1f4b3680bf2b6e2`.
  Comments, title assertions and the build-only Linux analysis step were added
  after the measurements; no production behavior changed after them. A final
  one-pair E2E smoke (`final-e2e.json`, 20 echo/load samples) passed all eight
  runs with no latency timeout and clean shutdowns. It is not merged into the
  repeated statistics below.

`metadata.json` records the initial suite invocation. `micro/` retains both
repeated series. `e2e.json` contains raw latency samples and each shutdown.
`telemetry.json.gz` contains the corresponding runtime/client diagnostics.
Run `python3 docs/performance/client-split-step6/analyze.py` to regenerate
`summary.json` (Python 3.10+ for the imported performance tooling).

## Repeated microbenchmarks

Each series alternated baseline/candidate order over five pairs, at 154×37,
with 20 samples per benchmark. There are 34 benchmarks per run.

| Series | Sample target | Comparator |
| --- | --- | --- |
| Initial | 40 ms | No verdict: excessive run-to-run spread |
| Repeat, without concurrent test/build jobs | 100 ms | No verdict: excessive run-to-run spread |

Thresholds remained 5% p50, 8% p95 and 10% p99. For example, initial baseline
one-cell damage spread was 21.04%/23.18%/29.82%; the repeat still had
9.09%/34.60%/34.24%. Raw comparator output is in `40ms-gate.txt` and
`100ms-gate.txt`. No `--allow-noisy` override was used.

The comparator stops at noise before checking wire sizes. Independent inspection
of all 20 runs found identical `payload_bytes_per_op` for every benchmark. The
paired 4K graphics probe also returned identical 4,004,011-byte compressed
payloads and pixel hashes in every run. These checks do not cover every possible
message size or authorize a latency verdict.

## Paired end-to-end probes

Five repetitions per version/case; echo and load have 200 samples per repetition.
Geometry is 240×70; load/slow-host use two flooding panes. There are 40 runs in
all. The values below are medians of the five run percentiles, not pooled-sample
percentiles or a physical input-to-photon measurement.

| Case | Version | p50 µs | p95 µs | p99 µs |
| --- | --- | ---: | ---: | ---: |
| Echo | Baseline | 396.08 | 598.12 | 750.18 |
| Echo | Candidate | 408.79 | 640.21 | 761.76 |
| Load | Baseline | 683.27 | 1124.85 | 1355.56 |
| Load | Candidate | 681.71 | 1147.25 | 1434.49 |

- Zero echo/load timeouts across 4000 samples.
- Every slow-host run delivered all 32 inputs while host output was blocked.
- Every graphics run recovered all 33,177,600 pixel bytes with the same SHA-256.
- All 40 runtimes exited, their children exited and their sockets were removed.
- Recorded drop and resync counters stayed zero. Maximum observed client outbox
  depth was 5 in both versions; runtime media queue high water was 9 events in
  both, with 35,672 bytes baseline versus 23,552 candidate across these probes.
- After the first six seconds, every echo/load/slow-host diagnostics window had
  zero additional interactive allocations in both processes and versions.
  Pane creation before that window allocates. Short graphics probes do not
  provide a comparable six-second steady window. Headless failing-allocator
  tests separately cover repeated patch, preparation, completion and input.

## Memory and CPU

Medians of maximum sampled client RSS across five E2E runs, in MiB:

| Case | Baseline | Candidate |
| --- | ---: | ---: |
| Echo | 26.44 | 26.80 |
| Load | 27.88 | 28.61 |
| Slow host | 28.45 | 28.62 |
| Graphics | 66.67 | 66.91 |

These are one-second diagnostics samples, not operating-system peak RSS or a
long-term leak proof. Sampled maximum live client heap medians were 15.28→15.32
MiB for echo, 18.73→18.77 MiB under load and 23.06→23.09 MiB for graphics.
Lease/quota tests, rather than these process totals, verify retired resources
remain charged until release.

`cpu.json` records a separate five-pair idle/load probe at 240×70. It reuses the
isolated runtime, two-flood setup and shutdown helpers. After startup and a
four-second warmup, it drains the host for ten one-second intervals. CPU is the
process `ps TIME` delta divided by wall time, excluding child-shell CPU; one
fully occupied core is 100%. This is not GPU time.

| Case/process | Baseline median CPU | Candidate median CPU |
| --- | ---: | ---: |
| Idle runtime | 0.00% | 0.10% |
| Idle client | 0.00% | 0.00% |
| Load runtime | 172.93% | 170.16% |
| Load client | 1.53% | 1.52% |

Idle runtime samples were 0–0.10% in both versions, near `ps` time quantization.
All 20 CPU-probe shutdowns were clean. `cpu_probe.py` reproduces the method with
explicit binary/output arguments. None of these summaries overrides the noisy
microbenchmark result.

## Exterior graphics

Ghostty 1.3.1, candidate diagnostics binary, 15-second synthetic
`3840x2160@120` runs, floor 58, with both `shm` and `file` transport:

| Transport | Verifier | Reported client transfers/s | Unavailable frames | Obsolete frames discarded |
| --- | --- | ---: | ---: | ---: |
| shm | Passed | 87.43 | 1 | 586 |
| file | Passed | 82.56 | 0 | 627 |

These rates count client image transfers, not distinct visible monitor frames.
PTY/response/media queue drop checks, resync/reset checks and history isolation
passed; shared expiries were zero. Obsolete work is folded, not replayed. The
single unavailable `shm` frame is retained in the evidence, not relabeled zero.
See `graphics-shm.log` and `graphics-file.log`.

The pinned Chromium/browser verifier failed `mouse_reached_chromium` and
`hybrid_sidebar_emitted` on both baseline and candidate. Page completion,
keyboard delivery, pane graphics, queue safety and history isolation passed.
Repeating both with `--no-config` and mouse coordinates `(600, 250)` produced the
same failures. Their cause remains unresolved; the browser gate is **not green**.
Logs and the controlled probe wrapper are retained. This is evidence of failure
on the baseline too, not permission to waive the gate.

## Remaining acceptance work

Run the prescribed native Ubuntu 24.04 x86_64 repeated/nightly/release gates on
a quiet host, and resolve the exterior browser checks before claiming complete
acceptance. Do not lower thresholds or infer physical graphics correctness from
transfer counters. No native renderer, second VT or event-loop rewrite was added.
