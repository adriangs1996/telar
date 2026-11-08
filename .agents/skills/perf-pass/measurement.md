# Measurement

## Builds

One build directory per variant; never overwrite a measured one. Release
builds keep the probes (`BUILD_TESTING` stays on):

```sh
tools/cpp configure runtime -B $SCRATCH/A/runtime --config Release
tools/cpp build runtime -B $SCRATCH/A/runtime
tools/cpp configure gui -B $SCRATCH/A/gui --config Release -- -DTELAR_GUI_QT_BUILD_DIR="$PWD/.qt-cache"
tools/cpp build gui -B $SCRATCH/A/gui
```

`-DTELAR_DIAGNOSTICS=ON` adds the allocation and timing counters of Debug to
an optimized build; use them for work census, never for timing.

## Paired tools

Each takes a baseline and a candidate and alternates them; `--help` lists the
inputs.

| Workload | Tool | Probe |
| --- | --- | --- |
| GUI text scene construction | `services/gui-cpp/tools/compare_text_scene.py` | `gui-text-scene-probe` |
| GUI terminal scene | `services/gui-cpp/tools/compare_terminal_scene.py` | `gui-terminal-scene-probe` |
| Runtime PTY round trips | `services/runtime-cpp/tools/bench_control_pty.py` | `control-pty-latency-probe` |
| Runtime control queries | `services/runtime-cpp/tools/bench_control_queries.py` | its own fixtures |
| Complete GUI against Ghostty | `tools/gui_tui_latency.py` | the GUI and runtime |

A workload with no tool gets a probe beside the existing ones (a target in the
project's CMake under `BUILD_TESTING`) and a driver that alternates the two
builds.

## Oracles

- GUI scenes: `compare_text_scene.py` checks ordered vertex values, matrices,
  material colors and blend modes; `compare_terminal_scene.py` checks the
  final rendered pixels.
- Everything else: a test that runs the old and the new path on the same
  inputs (exhaustive where the domain is small, seeded random otherwise).

## Timing

The host is shared and noisy (20-40% swings between unpaired runs). Only
paired, alternated runs count: A then B, then B then A. Check `uptime` first;
do not measure while builds or test suites run. Compare against the previous
accepted build, then re-measure the final build against `A`.

## Acceptance rule

Accept when the target case wins at least 6 of 7 pairs and no other workload
regresses consistently. A consistent loss in any workload (0-1 wins) rejects
the variant unless the loss is proven to be code placement: identical
normalized disassembly of the affected function in both builds (see
[assembly.md](assembly.md)). Report such cases as placement, not as a cost of
the change.

For cost of a single system call or library routine, measure it directly with
a small C++ loop (e.g. `tcgetpgrp` on a `forkpty` session).
