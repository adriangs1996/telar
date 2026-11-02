# Animation cadence correction

## Changes

`TabStripLayout` now queues its active motion sample from `afterAnimating`, before
Qt's polish pass, and requests the next window frame while a transition remains
active. Previously the next sample depended on a deadline timer rounded up to
milliseconds. The adapter could miss the next display refresh even though its
reported interval was 8.33 ms. The 180 ms interpolation and drag/drop semantics
are unchanged. Window changes and destruction disconnect the frame callback;
hidden or settled strips do not continue requesting animation frames.

`ComponentPanel.qml` previously had no entrance transition. Provider panels now
reuse `ModalRevealLayout`: the existing 220 ms fade and a bounded 12-unit entrance
offset. The panel identity, not its content revision, starts a new entrance, so
command output and periodic refreshes do not restart it. Final placement, focus,
keyboard handling and close policy are unchanged.

## Native measurement

Source base: `6152393b18f8b3e7ae1a1322eca6c8f1eb718bbd`, including the existing
uncommitted managed-Qt migration. The executable hashes identify the measured
snapshots; these were not clean-commit builds.

- Apple M3, arm64, macOS 26.6.2, Cocoa/Metal, Qt 6.12.0, LLVM 23.1.2.
- Both Release builds use `-O3 -DNDEBUG`; both Mach-O files report SDK 26.5.
- Internal display: native and Qt report 120 Hz, DPR 2, display synchronization on.
- Isolated 800×240 logical-pixel scene, production tab/modal adapters and
  application window pacer, four native rectangles for tabs.
- Twelve 400 ms cycles per run, after one second of startup and two warmup cycles.
- Seven A/B pairs per mode, alternating variant order. No builds or test suites
  ran during the paired collection.

| Snapshot | Probe SHA256 |
| --- | --- |
| A, previous scheduling | `cf1a4f765b912f33e171a502105027dea2b476954af8d8eb8afbfeca15fa13f8` |
| B, corrected scheduling | `2dacd16e12f56ce61a6a706818fa46dd9da6adfee1e19a1fa286f205572ce012` |

The observer tags the synchronized rectangle position and collects
`MTLDrawable.presentedTime`. These are presented state changes, not just timer
firings or `frameSwapped` counts. It does not verify framebuffer pixels or physical
scanout. Repeated positions are collapsed before calculating intervals. Zero native
timestamps denote unpresented drawables: they do not count as presentations, and
the gap across their loss remains in the results. Warmup and shutdown cycles are
outside the measurement.

Medians of per-run quantiles, not pooled samples:

| Mode | A p50 | B p50 | A p95 | B p95 | B p50 wins / ties / losses |
| --- | ---: | ---: | ---: | ---: | ---: |
| Tab reorder | 16.667 ms | 8.333 ms | 33.333 ms | 25.000 ms | 7 / 0 / 0 |
| Existing modal reveal | 8.333 ms | 8.333 ms | 25.000 ms | 25.000 ms | 0 / 7 / 0 |
| Continuous-motion control | 8.333 ms | 8.333 ms | 25.000 ms | 25.000 ms | 0 / 7 / 0 |

Pair comparisons round to one microsecond. Tab p95 improves in five pairs and
ties in two. Modal p95 loses three and ties four; continuous-control p95 wins two,
loses four and ties one. There is no claim that the remaining presentation stalls
are fixed or that their cause has been established.

A separate native `max_fps = 30` check reports a 33.333 ms p50 with the application
pacer enabled. A single external-display diagnostic at 100 Hz changes tab p50
from 20 to 10 ms, but p95 regresses from 20 to 30 ms; cause not established. Its
continuous control also has a 30 ms p95. That single pair is not smoothness
qualification for the external display.

Raw collection: `out-animation-results/paired-120hz-qualified/`. The original
collector incorrectly rejected zero timestamps in shutdown cycle 13. The complete
42-run collection was reprocessed uniformly into `report-measured-window.json`:
measured cycles only, discarded drawables counted separately, and repeated states
collapsed before interval calculation. No runs were dropped. The accounting has
seven Python regression tests.

## Checks and limits

- The frame-preparation regression fails when the new callback is disabled and
  passes when restored. The complete chrome test passed five consecutive repeats.
- Focused CTests pass: chrome, modal reveal, window frame pacer and cadence tools.
- Nine integration cases pass with both offscreen/software and Cocoa rendering:
  panel rendering, panel/group/overflow keyboard handling, tab drag/drop,
  escape, captured-source deletion, viewport cancellation and configuration reload.
- A separate `QSG_INFO=1` run confirms QRhi Metal on Apple M3 for the actual main
  window while opening the configured panel.
- A baseline `sample` capture mostly shows main-loop waits; tab rebuild and caption
  measurement also appear. Native arm64 disassembly of the callback shows the
  eligibility/deadline guards and queued polish. No interpolation arithmetic or
  ISA-specific kernel was changed.

An early variant that only sampled from the frame callback, without requesting
its successor, did not remove the half-rate cadence. Calling `ensurePolished()`
as well as scheduling polish could rebuild twice; the final adapter uses the
regular polish pass instead. Disabling the entire application pacer was only a
diagnostic and was not adopted.

These measurements qualify the isolated adapter correction, not full-client
120 FPS, input latency, terminal throughput or all provider-panel content. The
provider entrance has functional/native integration coverage, not a seven-pair
full-panel presentation benchmark. Linux and x86-64 were not run in this pass.

## Reproduction

Freeze each variant's Release probe before changing source, then run:

```sh
cmake --build services/gui-cpp/out --target gui-animation-probe
python3 services/gui-cpp/tools/check_animation_cadence.py \
  /path/to/A/gui-animation-probe /path/to/B/gui-animation-probe \
  services/gui-cpp/out-animation-results/new-comparison \
  --screen 1 --expected-fps 120 --pairs 7
```

The result directory must be new. Select the actual screen and its supported rate;
the continuous-motion control must qualify that cadence. A window manager may
ignore Qt's requested screen: `--aerospace-monitor '<monitor name>'` optionally
floats/moves only the owned probe window, and the native display is checked after
each run. AeroSpace is not otherwise required. The probe also supports
`--config /path/to/config.lua` for configured caps and `--pacer off` for diagnostics.
