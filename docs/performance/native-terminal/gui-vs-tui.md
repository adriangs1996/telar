# GUI versus TUI inside Ghostty

Measured on 2026-09-12 on Apple M3, macOS 26.6.2. Ghostty 1.3.1 stable uses
its shipped ReleaseFast build. Telar uses Zig 0.16.0 and the retained-preparation
implementation in this working tree. Executable hashes, every individual
sample, per-run statistics and viewport dimensions are retained in
[gui-vs-tui.json](gui-vs-tui.json).

## Results at a common GPU completion boundary

| Telar build | Client | Samples | p50 ms | p95 ms | p99 ms |
| --- | --- | ---: | ---: | ---: | ---: |
| ReleaseFast | GUI | 300 | 3.77 | 8.77 | 9.93 |
| ReleaseFast | TUI + Ghostty | 300 | 9.03 | 14.69 | 17.29 |
| Debug | GUI | 100 | 7.00 | 11.17 | 16.65 |
| Debug | TUI + Ghostty | 100 | 12.42 | 18.93 | 19.10 |

Use these measurements as a reference for latency ranges and future regressions,
including new GUI features and the step 9 execution-model migration. The GUI
reference is roughly **3–4 ms median / 9 ms p95 in ReleaseFast**, and
**7 ms median / 11 ms p95 with `just app` (Debug)**. TUI + Ghostty provides
context at roughly **9 ms median / 15 ms p95 in ReleaseFast**, and
**12 ms median / 19 ms p95 in Debug** under the conditions below.

These are workload-specific reference values, not performance targets or a
claim that Telar is faster than Ghostty. Compare future runs using the same
fixture, viewport, build mode, synchronization settings and measurement boundary.
Both the Telar client and its isolated runtime use the listed build mode.
Ghostty remains ReleaseFast in both cases.

ReleaseFast has three rounds per client, with execution order GUI/TUI,
TUI/GUI, GUI/TUI. Debug has one round per client. Each run discards 20 warmup
responses, then records 100 responses. Inputs are separated by a deterministic
25–74 ms varying pause after verified completion, avoiding a fixed interval
that repeatedly lands on the same display-refresh phase.

A separate 100-sample ReleaseFast control with Ghostty's `window-vsync=false`
gave TUI + Ghostty **5.60 ms p50, 10.13 ms p95, 10.88 ms p99**. The main table
uses `window-vsync=true`, the installed version's default. Synchronization
configuration affects this comparison; it does not measure only transport or
CPU rendering throughput.

The earlier 3.1 ms GUI number used the cat echo/glyph-count probe. This table
remeasures the GUI with the exact same pixel-based instrument used for Ghostty,
rather than comparing that earlier number with a different TUI endpoint.

## What is timed

The shared test-only probe starts its clock immediately before dispatching a
native `keyDown` event to the test window's actual first responder. A raw PTY
fixture receives `x` and changes the background color of one cell. The probe
accepts only successful completion of a render command buffer whose output
pixel contains the expected alternating color.

The TUI measurement therefore includes native Ghostty key handling, Ghostty's
outer PTY, Telar input/runtime/child/VT/output, Ghostty parsing and rendering,
and the final Ghostty GPU work. It does not stop at Telar's host write.
The GUI measurement includes its native key handling, shared runtime/child/VT
path, native preparation and final GPU work.

Ghostty 1.3.1 renders to IOSurface-backed textures and publishes those surfaces
to Core Animation after GPU completion. The probe wraps Metal render-pass
creation and command-buffer commit in both applications, so the same final
render-target boundary is observed despite the different presentation APIs.
See the pinned upstream [Metal renderer](https://github.com/ghostty-org/ghostty/blob/v1.3.1/src/renderer/Metal.zig)
and [frame completion](https://github.com/ghostty-org/ghostty/blob/v1.3.1/src/renderer/metal/Frame.zig).

This is **key dispatch to verified GPU command completion**, not physical key
acquisition, compositor presentation, display scanout or photon latency.
Attempts to collect `MTLDrawable.presentedTime` returned zero in the GUI on
this setup; Ghostty's IOSurface path does not use that drawable interface.
No screen-presentation numbers are inferred from these GPU measurements.

## Controls and limitations

- Every reported run used a 1900 × 2112 pixel render target at scale 1. The
  same JetBrains Mono family and nominal size 15 were selected. Both rendered
  the same one-cell response. GUI geometry was 211 × 105 cells; TUI pane
  geometry was 211 × 103 because its two chrome rows remain. These are equal
  pixel viewports, not identical pane dimensions or font rasterizers.
- Telar used an isolated minimal configuration: sidebar hidden, cell sidebar
  renderer, pane gaps disabled, static blank bar segments plus the mandatory
  tabs segment. No user configuration, plugins or foreground shell prompts
  were loaded. This is a single-pane comparison, not a benchmark of the user's
  complete customized TUI.
- Each runtime was started before injection, without the diagnostic library.
  Ghostty's wrapper removes injection variables before starting Telar TUI.
  The installed Ghostty application and existing sessions were untouched.
  A private copied bundle was ad-hoc signed solely to load the instrument.
- During warmup the probe locates the marker in a full-texture readback. During
  measurement it appends a single-pixel blit into 256 bytes to the same render
  command buffer. Verification is therefore tied to that frame, not a later
  reuse of the texture. Both paths include this instrumentation cost. The GUI
  drawable is made readable with `framebufferOnly=false` for the probe.
- The clock is read in the GPU completion callback, before dispatching pixel
  validation back to the window thread. Main-loop delivery of the measurement
  does not extend its end timestamp. Runtime protocol and production
  scheduling code are unchanged.
- The fixture hides the cursor and performs filesystem writes only when its
  terminal dimensions change. Wrong-color and unsuccessful GPU frames do not
  count. A resize during measurement or missing responses fails the run.
- The application response uses a controlled one-cell color change, not shell
  readline echo. Desktop scheduling and refresh configuration still affect
  tails. These observed samples are not a latency guarantee or proof that the
  GUI's pixels reach the physical display sooner.

## Reproduce

```sh
zig build -Doptimize=ReleaseFast -Decho-trace=true -Decho-trace-cpu=true --prefix /tmp/telar-profile
python3 tools/gui_tui_latency.py /tmp/telar-profile/bin/telar /tmp/telar-compare --rounds 3 --samples 100
```

Use a fresh, short result path. The tool copies/signs Ghostty, creates isolated
runtimes, closes its own test windows and stops those runtimes. It preserves
raw results and a `comparison.json` report. The test requires a macOS graphical
login session; leave the test windows untouched while it runs.

For Debug, omit `-Doptimize=ReleaseFast`. For the VSync control, use a new
result directory and add `--vsync false --mode tui --rounds 1`.
