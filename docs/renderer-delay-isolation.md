# Renderer delay isolation, 2026-11-05

## Decision

Keep Qt for now. Do not replace the renderer on the strength of these results.
The measured warm-typing difference is mostly **before command submission**.
GPU execution and GPU-end-to-presentation are effectively alike in this workload.
An additional drawable-encoder diagnostic locates its difference before opening
the target render encoder, not in encoding that pass or executing it on the GPU.

Qt can still contribute CPU work and scheduling overhead. This pass does not
establish an unavoidable Qt latency floor, nor does it prove that all of the
pre-encoder difference belongs to Qt rather than our application/runtime.
The next target is pre-encoder delivery, invalidation and synchronization.
A direct-Metal rewrite has not been measured as a counterfactual.

This is not complete F03/F08 acceptance or a claim that C++ beats Zig generally.

## Frozen conditions

- Source: `6994769261a02c10faf4f443b258aead1bb6db83`, independent complete stacks.
- Host: Personal, MacBookPro18,3 / M1 Pro, macOS 26.6.2 / 25G83, AC power.
  The local development Mac was rejected for concurrent compilation/load.
- New C++ Release builds, LLVM 23.1.4; new Zig 0.16.0 ReleaseFast build,
  `aarch64-macos.26.0`, `apple_m1`, explicit CLT SDK 26.5 libc description.
- Qt 6.12.0 comes from an explicitly frozen managed installation copied from the
  development machine, not Homebrew/system Qt. Its framework bytes are verified
  against every C++ process's loaded-image receipt. A scratch CMake provisioning
  shim reuses that installation; it changes no application/rendering source.
  This is not a qualification of subsequent uncommitted toolchain changes.
- Matching Lua configuration, JetBrains Mono 15 with thickening enabled, opaque
  window, no cursor blink, 1600×1000 drawable pixels, DPR 2, 82×21 terminal cells.
- Six alternating pairs per workload, 100 measured actions after 20 warmups.
  The typing series also runs the traced C++ GUI in each round.
- Each accepted frame requires matching marker pixels, foreground/key window,
  VSync and a positive native drawable presentation timestamp. GPU completion is
  not substituted for presentation. Actual sustained 120 Hz is not established;
  the screen reports a 120 Hz maximum.
- Host gates retain their default 5 / 7.5 one-/five-minute load limits for this
  ten-core host. No application builds, tests or profilers overlap native timing.
  All accepted runs have successful owned-runtime/child/socket cleanup.

| Executable | SHA-256 |
| --- | --- |
| Zig GUI/runtime | `28544646196685b7fa2ff12383f062d624e4a88774331580334744c82890378b` |
| C++ GUI | `f540411fcf9c1e5fa9a62d5f0815ad6b32bc29de4e27117b36fc3158cbe8a970` |
| C++ runtime | `83220b9817b343bc258e8796cb893603869d500836af336698919eefc070e838` |
| C++ CLI | `92ac8c3c9fe897e10e613974d0b0649b72484298277fa7b777540d1c31115dd4` |
| Traced C++ GUI | `6100ed148724c711cfab2a41866cc3e6a9894ebf8e2be6a186befcad6d5d4efc` |

The current C++ CLI and server are different executables. The private runner
freezes both, verifies the adjacent GUI CLI helper, and checks the actual socket
peer against `telar-runtime`. It does not disable peer identity verification or
silently select the installed application.

## Warm typing

Values are medians of per-run statistics. GUI CPU is measured user+system CPU
per measured input, excluding warmup. It is not whole-stack CPU.

| Metric | Zig | C++ without GUI phase tracing | C++ lower pairs |
| --- | ---: | ---: | ---: |
| Input to presentation p50 | 25.933 ms | 27.201 ms | 0/6 |
| p95 | 29.518 ms | 30.494 ms | 0/6 |
| p99 | 31.359 ms | 32.603 ms | 2/6 |
| Maximum | 32.882 ms | 41.450 ms | 2/6 |
| GUI CPU/input | 4.602 ms | 5.937 ms | 0/6 |

The following table uses arithmetic means across the six equal-sized measured
runs. These additive intervals reproduce the mean total; they are not quantiles.
Both stacks use the native pixel/readback observer, without GUI phase tracing.

| Elapsed interval | Zig | C++ |
| --- | ---: | ---: |
| Input to command-buffer commit | 3.018 ms | 3.817 ms |
| Commit to GPU start | 0.996 ms | 1.109 ms |
| GPU execution, including readback | 0.232 ms | 0.223 ms |
| GPU end to positive presentation | 21.647 ms | 21.628 ms |
| Total mean | 25.893 ms | 26.777 ms |

The approximately 0.80 ms pre-commit difference accounts for most of the
approximately 0.88 ms mean total difference. There is no observed typing GPU
execution penalty that would explain the slower C++ result.
The roughly 21.6 ms presentation interval occurs in both stacks; it is not a
measured Qt-specific penalty or a physical scanout measurement.

### Inside the C++ GUI

A private Clang VFS overlay recompiles three translation units without editing
production files or changing their types. It reuses the bounded runtime scope
recorder, with a separate GUI prefix. Startup/shutdown brackets establish the
same clock epoch as the native observer. All 120 actions in each of six traced
runs correlate the actual pane/frame ID, PaneFrame payload, scene update and
qualified drawable commit. Overflow, missing clocks and ambiguous matches reject
the report.

These are mean elapsed durations across the six traced runs, **not CPU
attribution**. Input-to-payload includes runtime/PTY/transport and GUI event
queueing, which this GUI-only trace does not separate.

| Traced interval | Mean |
| --- | ---: |
| Input to frame payload dispatch | 1.772 ms |
| Payload dispatch to decoded frame | 0.014 ms |
| Synchronous application subscribers | 0.273 ms |
| Subscribers complete to Qt synchronization | 0.446 ms |
| Sync start to terminal paint | 0.023 ms |
| Terminal scene synchronization | 0.125 ms |
| Terminal paint end to sync end | 0.006 ms |
| Sync end to Qt beforeRendering | 0.017 ms |
| Qt beforeRendering to afterRendering | 0.997 ms |
| Qt afterRendering to native commit | 0.239 ms |
| Total input to commit | 3.911 ms |

No explicit application frame-pacer hold occurs between matching frame delivery
and synchronization in any of the 600 measured traced typing actions.
The 0.446 ms interval must not therefore be labelled a measured pacer sleep.
Likewise, Qt rendering signals bracket elapsed renderer work, not exclusively
our terminal or exclusively runnable CPU.

Tracing perturbs tails: traced p95 is 31.013 ms versus 30.494 ms without GUI
tracing, with the traced variant lower in only 1/6 pairs. Mean pre-commit time
increases from 3.817 to 3.911 ms. Internal traces are diagnostic, not a replacement
for the untraced C++ results above or proof about sub-millisecond optimizations.

### Independent encoder-entry control

One additional diagnostic pair records entry into the target drawable's actual
Metal render encoder, supporting both legacy Metal and Metal4 without relying
on Zig's window class names. Each of 100 measured actions per stack has exactly
one target encoder, one commit and ordered native clocks, qualified pixels and
positive presentation. This is not a new six-pair performance comparison.
C++ uses the traced GUI in this control.

| Mean elapsed interval | Zig | Traced C++ |
| --- | ---: | ---: |
| Input to target encoder entry | 2.447 ms | 3.243 ms |
| Target encoder entry to commit | 0.780 ms | 0.709 ms |

The difference is already present before the target encoder opens. The
encoder-to-commit interval includes observer/readback preparation and is not a
pure renderer CPU measurement. It does not support blaming slower Metal drawing
or command encoding in Qt for this typing result.

## Discrete tab switching

Four independent 30 Hz producers, verified target tab/generation/checksum,
unchanged 5% offered-rate checks over 500 ms checkpoints. Six complete pairs
qualify. These are discrete switches, not continuous-motion/cadence acceptance.

| Metric | Zig | C++ | C++ lower pairs |
| --- | ---: | ---: | ---: |
| Presentation p50 | 40.060 ms | 37.168 ms | 4/6 |
| p95 | 47.399 ms | 43.697 ms | 5/6 |
| p99 | 48.822 ms | 48.538 ms | 3/6 |
| Maximum | 50.881 ms | 52.203 ms | 2/6 |
| GUI CPU/action | 29.441 ms | 44.203 ms | 0/6 |

Medians of per-run mean native intervals are input-to-commit 10.917/13.026 ms,
GPU execution 0.415/1.923 ms and GPU-end-to-presentation 28.208/21.879 ms for
Zig/C++. These row medians must not be added. Unlike typing, this workload has a
larger measured C++ GPU interval. The lower total p50 median does not pass the
5/6 paired win gate, and CPU consistently loses. Neither a universal Qt
presentation penalty nor a complete C++ performance win follows from this table.

## Interpretation and limits

- Keep the current Qt integration while targeting work before the target render
  encoder. Faster scene synchronization alone cannot remove transport/event
  queueing, synchronization or other window/chrome work.
- Do not attribute the entire difference to QML, allocations, IPC, the runtime
  or Qt scheduling. The present observations locate intervals, not a unique
  cause. Runtime service and GUI dispatch waits need distinct timestamps before
  assigning the 1.772 ms input-to-payload interval.
- The native observer inserts pixel readback and hooks different Metal APIs.
  Absolute GPU/encoder durations include that work. The extra GUI observer has
  its separately measured perturbation above.
- Marker pixels, pane/frame identities, geometry and workload receipts are
  verified. This pass does not establish full-viewport visual equivalence for
  every frame, Unicode/paste behavior, images, history, resize or sustained120.
- Ordinary typing fixtures can terminate before publishing a final receipt.
  Initial receipts qualify geometry, not final input counts. Native acceptance
  still verifies every alternating marker. When a final fixture receipt exists,
  its count must agree; reports explicitly distinguish these cases.
- The existing history debounce remains 60 ms in `qt/application.cpp`. It was
  not benchmarked or changed here; a renderer replacement would not remove that
  application policy. The earlier rejected debounce experiments remain rejected.

## Failed attempts retained

1. The first qualification inherited SSH environment variables and the Zig CLI
   correctly refused a graphical launch. No inputs completed; owned cleanup
   passed. The runner then used the active graphical login environment, as the
   existing native capture tools do.
2. Initial tab trace analysis treated graphics `Change::terminal` notifications
   as frame delivery. The corrected analyzer requires the enclosing actual
   PaneFrame tag as well as pane/frame IDs. Positive traces and a dedicated
   graphics-notification negative test cover this distinction.
3. The first 100-input tab series failed the existing offered-rate gate in C++.
   That entire pair is excluded, including its successful Zig partner. A new
   collection then obtained six complete alternating pairs without rejection;
   no latency/CPU/tail value selected which pairs entered the report.
4. Initial typing postprocessing incorrectly required a final fixture count even
   for an initial `ready` receipt. Reporting now distinguishes initial and final
   receipts without weakening native pixel/presentation guards. Timing was not
   rerun or selected on this correction.
5. The old Zig view-method diagnostic rejected the current pure-Zig window ABI
   before any input. Its checks were not bypassed. The subsequent native
   encoder-entry control uses the already supported Metal hooks instead.
6. The first diagnostic C++ compilation rejected a narrowing conversion in the
   observer; an explicit uint64 conversion fixed it in a new private build.

## Artifacts and reuse

Ignored local artifacts are under `out-perf/renderer-isolation-20261105/`:
`tab-summary.json`, `typing-summary.json`, qualification/typing/encoder raw
results and the baseline collection. Private native originals remain on Personal:
`/tmp/tlr-ri-base-02` through `-07`, `/tmp/tlr-ri-typing-01`,
`/tmp/tlr-ri-encoder-control-01` and the named rejected attempts.
The isolated source/build checkout is
`~/sandbox/telar-worktrees/renderer-isolation-20261105`; installed applications,
configuration and user runtimes were not replaced.

Reusable tools:

```sh
python3 tools/build_tab_switch_timeline.py NEW_PROBE --workload typing
python3 tools/build_gui_phase_probe.py --build-directory RELEASE_GUI_BUILD NEW_TRACED_GUI
python3 tools/gui_phase_report.py RUN --host-load SERIES/host-load.json \
  --trace RUN/gui-phase.PID.jsonl --output NEW_REPORT.json
```

Use the generated harness's `measure()` with `timeline-probe.dylib`; invoking
its ordinary `main()` rebuilds the ordinary probe instead. Explicitly supply and
freeze the CLI, actual runtime, GUI, command helper, Qt prefix and source identity.
The private runners/provisioning receipts retain this pass's exact commands and
hashes. Do not time while rebuilding a probe, application or dependency.

Focused validation covers native clock ordering, encoder ambiguity, peer identity,
overflow, missing/mismatched frame IDs, stale geometry/presentation, foreground,
workload/cleanup gates, initial-versus-final receipts and changed source anchors.
All 49 focused tests pass; the final generator reproduces the measured native
encoder observer source byte-for-byte. Final reanalysis accepts all 18 typing
runs and both encoder controls. The process audit finds no remaining owned
benchmark GUI/runtime. `git diff --check` passes.

There are no production performance changes in this pass and no new architecture
or all-flow performance acceptance.
