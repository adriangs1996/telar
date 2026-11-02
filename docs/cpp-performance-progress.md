# Complete-stack performance progress

This is the current work log for [F01–F16](cpp-performance-flows.md), starting
from `6152393b18f8b3e7ae1a1322eca6c8f1eb718bbd` on 2026-11-02. The persistent
objective is active and unbounded. No flow has complete-stack performance
acceptance yet. Conditional cursor invalidation is accepted for the measured
warm-typing layouts against the frozen C++ baseline; complete-flow and Zig-stack
acceptance remain open.

## Fresh environment

Personal reports Apple M1 Pro, MacBookPro18,3, 32 GiB, ten CPU cores, 128-byte
cache lines, macOS 26.6.2 / 25G83 and AC power. The native probe identifies
display 1 and a maximum of 120 Hz. Active sustained presentation cadence is
still unqualified; the maximum is not a measurement of actual refresh.
The new `gui-display-probe` reports Qt 6.12.0/Cocoa, DPR 2 and 120 Hz on the
built-in screen. The suspected Qt-reports-60-Hz cap is not present in this run.

All generated artifacts are under ignored `out-perf/` or private
`/tmp/telar-perf-*` directories. No installed application or user configuration
is replaced. `out-perf/baseline/conditions.json` records machine, source,
dependency, executable hash, dynamic linkage and Mach-O SDK evidence.

- Fresh C++ runtime and GUI Release builds use LLVM 23.1.4, CMake 4.4.5,
  SDK 26.5 and the installed Qt packages recorded by CMake. Runtime and GUI
  are copied together to `out-perf/baseline/stage-cpp/bin`, with the C++ runtime
  named `telar` for GUI discovery and plugin helpers.
- Ghostty `df1c99c8…` plus the checked-in state patch was freshly compiled
  with Zig 0.17 into `out-perf/dependencies/ghostty`.
- The reference source requires Zig 0.16. Zig 0.17 rejects its build APIs.
  Official Zig 0.16.0 was downloaded into `out-perf/toolchains` and checked
  against the SHA-256 in the official download index.
- Native automatic SDK selection failed in libc++ and translated Mach
  structures. The reference uses the existing `sdk-libc.sh`, CLT SDK 26.5,
  `-Dtarget=aarch64-macos.26.0 -Dcpu=apple_m1` and `--libc`. The clipboard
  import now names the four CoreFoundation headers actually used, avoiding
  unrelated Mach structures in the umbrella header. This is a build repair,
  not a performance optimization. The resulting Zig Release build passes.
- The first C++ runtime build accidentally found nghttp2 in the general
  Homebrew include directory, which shadowed OpenSSL 3 headers with OpenSSL 4.
  Explicit `NGHTTP2_ROOT/INCLUDE_DIR/LIBRARY` pointing to `libnghttp2` corrected
  the build. The OpenSSL 3 ownership assertion remains intact.

## Measurement controls

`gui_tui_latency.py` now requires `--cpp-runtime` for C++ GUI runs. It starts
and stops that runtime, checks the staged GUI helper's hash, and records actual
GUI process and connected socket-peer executable identities. A selected Zig
runtime remains explicitly labelled a same-runtime diagnostic. Runtime readiness
is bounded; background launch completion does not imply socket readiness.
The aggregate uses medians of run quantiles, rather than pooled samples.

Focused Python identity/report tests and the native readiness join pass.
The latter rejects missing/zero/stale presentation evidence. Full-client
negative controls and helper-process resource accounting remain pending.

Qualification 01 exposed the asynchronous runtime-start race. Qualification 02
verified both C++ executable identities, but failed viewport negotiation before
input because the window manager controlled its size. Both owned runtimes and
children were cleaned up. Qualification 03 uses the existing `--float-windows`
control, which affects only probe windows. It reaches setup readiness, then
times out on the first input despite the fixture receiving `x`. A second pair
qualification repeats that C++ failure while Zig completes. C++ qualification
04 with capture and a diagnostic run with GPU pixel logging both pass; the
intermittent failure remains unresolved. These are setup/diagnostic attempts,
not accepted paired performance measurements.

Further reproduction isolates the failure after rendering: the GPU readback
has the correct green pixel, but the corresponding native presented callback
returns zero. `cpp-readback-02` passed five starts and failed the sixth;
`cpp-readback-03` passed six; `cpp-readback-04` passed two and failed the third.
`cpp-readback-05` confirms zero timestamps with native occlusion-visible true,
window frame `[910,321,800,500]`, display 1 and `presentsWithTransaction=false`.
The cause remains open; GPU completion is not substituted for presentation.
Readback diagnostics are opt-in and labelled in new reports.

`f03-capture-baseline-01` starts a provisional six-pair comparison with identical
capture setup, 20 warmups and 100 measured inputs per run, 1600×1000 pixels,
DPR 2 and an 82×21 grid. It does not close the failure without capture or the
remaining native negative controls. No builds/tests/profiles overlap this run.
The collection stopped on the first Zig run with no completed inputs.
`zig-readback-01` reproduces the same correct-green-pixel/zero-presented-time
failure on Zig, so this is not established as a C++ regression. Apple documents
[zero presentedTime](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime)
as unpresented/dropped; these runs remain invalid. The next qualification
separates warm typing (`--idle-seconds 0`) from input following two seconds of
idle, retaining the same positive-presentation gate for both.
The first warm qualification passes in both complete stacks, with equal grid,
viewport and marker coordinates. A six-pair, 100-input warm baseline follows
under `f03-warm-baseline-01`; full F03 acceptance remains open.

The six warm pairs completed without rejected rows. Medians of run quantiles:

| Metric | Zig stack | C++ stack | C++ wins |
| --- | ---: | ---: | ---: |
| Input to presentation p50 | 24.30 ms | 27.04 ms | 0/6 |
| p95 | 29.02 ms | 37.28 ms | 0/6 |
| p99 | 30.34 ms | 40.53 ms | 0/6 |
| GUI CPU (100% = one core) | 3.30% | 3.95% | — |
| GUI process peak RSS | 124.63 MiB | 199.45 MiB | — |

Median paired p50 ratio is 1.1211, p95 1.2846 and p99 1.3326. Runtime resources
are not yet sampled, so GUI RSS is not a whole-stack total. No input-latency
number here establishes continuous frame cadence. The first separate profile
attempt finished before sampling attached; it provides no CPU profile. The
integrated `cpp-typing-profile-02` collected five-second GUI/runtime `sample`
outputs and Qt scene-graph timing under `out-perf/profiles/`.

Both processes spend most sparse-typing samples waiting for events. The GUI
profile includes `keyPressEvent -> dirty -> maybeUpdate -> requestUpdate` and
`deliverUpdateRequests -> polishAndSync`. Installed Qt Cocoa disassembly
confirms that nonzero swap interval selects native display-link delivery of
update requests. Input-to-GPU time is roughly 8–10 ms in C++ versus 3 ms in Zig
in the first baseline runs, while GPU work is roughly 0.5–1.1 ms. This motivates
an earlier content-triggered frame request, retaining VSync and existing pacing.

The rejected `early-frame` experiment coalesces visible terminal changes
through the existing single-shot deadline timer. It preserves cadence/input
grace checks and cancels delivery if the window becomes hidden. Focused core
and window-pacer tests pass, including coalescence, cadence and cancellation.
The native 30-input qualification passes at the same geometry with positive
drawable presentation and VSync. Its 29.09 ms p95 is preliminary, not acceptance.
Six alternating pairs against frozen C++ A follow. Source patch, executable
hashes and ARM64 disassembly are under `out-perf/early-frame/`; no baseline
executable is replaced. Disassembly shows a bounded 2 KiB pane scratch array
and an existing timer dispatch, without a new per-change heap event allocation.

`f03-early-frame-pairs-01` completed all six pairs without rejected rows:

| Metric | Frozen C++ A | Early-frame B | B wins |
| --- | ---: | ---: | ---: |
| p50 | 25.69 ms | 24.36 ms | 6/6 |
| p95 | 37.29 ms | 32.79 ms | 5/6 |
| p99 | 37.38 ms | 37.42 ms | 3/6 |
| GUI CPU | 4.06% | 5.84% | 0/6 |
| GUI peak RSS | 201.45 MiB | 200.90 MiB | — |

B is rejected for its consistent CPU regression. Separate Qt render-timing
diagnostics with 120 inputs including warmup count 183 rendered frames in A
versus 301 in B, including startup. These instrumented counts are not timing
acceptance. Qt's [platform update delivery](https://github.com/qt/qtbase/blob/v6.12.0/src/gui/kernel/qplatformwindow.cpp#L777)
clears its pending request before sending the event; B's direct event did not.
The [Cocoa display link](https://github.com/qt/qtbase/blob/v6.12.0/src/plugins/platforms/cocoa/qcocoascreen.mm#L405)
checks that pending state before delivering again.

The follow-up `early-platform` experiment consumes the pending Cocoa
update through Qt's virtual platform delivery, preserving its resize lock and
DPR handling. An already delivered request is not repeated; a held pacing event
retains its existing delivery. Non-Cocoa platforms retain the original schedule.
A dedicated native test checks consumption, coalescence and requests made during
delivery. This is a separate variant with fresh build/stage paths; B remains
frozen with its source patch and rejected results.

The core, window-pacer and native Cocoa update suites pass. A separate
120-input instrumented run counts 189 rendered frames, close to A's 183 rather
than B's 301. The six uninstrumented pairs in `f03-early-platform-pairs-01`
nevertheless reject this revision too:

| Metric | Frozen C++ A | Early-platform revision | Revision wins |
| --- | ---: | ---: | ---: |
| p50 | 29.03 ms | 25.29 ms | 6/6 |
| p95 | 40.21 ms | 41.88 ms | 2/6 |
| p99 | 45.82 ms | 46.31 ms | 0/6 |
| GUI CPU | 5.36% | 5.43% | 3/6 |

The median paired CPU ratio is 0.9920, but the p95 ratio is 1.0839 and p99 loses
all six pairs. Earlier rendering alone is not a sufficient whole-flow win.
The rejected source and native oracle are preserved under
`out-perf/early-platform/source/`; production pacing is restored before the next
experiment. Its target is the unconditional terminal `update()` after a key,
even when the local cursor is already visible and no PTY output has arrived.

The `cursor-invalidation` candidate starts from original production pacing.
Its oracle captures the cursor cell with the local blink phase visible/hidden,
then checks that a key restores the visible pixels from either phase without
moving the terminal cursor. This runs against the original handler before
conditional invalidation is introduced. Existing input-to-cell integration and
the native presented-marker gate remain required.

The cursor oracle and input-to-cell integration pass before the change, then
pass after it with the software renderer and native Cocoa/Metal. Targeted copy,
link-hover and Kitty key press/release checks also pass after the change. ARM64
output adds a byte load and conditional branch around `QQuickItem::update()`;
the visible-cursor path avoids scene-graph invalidation. The separate native
render-timing diagnostic counts 159 frames including startup for 120 inputs,
versus 183 in A's diagnostic. Six uninstrumented pairs against frozen A complete
under `f03-cursor-invalidation-pairs-01`:

| Metric | Frozen C++ A | Conditional cursor invalidation | Candidate wins |
| --- | ---: | ---: | ---: |
| p50 | 31.15 ms | 29.55 ms | 5/6 |
| p95 | 41.48 ms | 37.65 ms | 6/6 |
| p99 | 45.97 ms | 39.79 ms | 6/6 |
| Maximum | 49.70 ms | 43.29 ms | 6/6 |
| GUI CPU | 5.76% | 5.49% | 4/6 |
| GUI peak RSS | 201.11 MiB | 198.93 MiB | — |

Median paired ratios are 0.9518 / 0.9057 / 0.8491 for p50/p95/p99 and 0.9520
for GUI CPU. This clears the targeted warm single-pane timing gate, without a
consistent resource regression. The clean four-split/four-tab comparison follows
below; the independent Zig-stack comparison is recorded next. These
layout cases measure typing with other panes present, not actual tab switching
or sustained 120 Hz motion. No whole F03/F07/F08 flow is closed by this result.

`cursor-layout-pairs-01` is excluded from acceptance: a source-format comparison
ran during collection, violating the separation from checks. Its full rows and
an explicit invalid-collection receipt are retained. `cursor-layout-pairs-02`
repeats the entire six-pair split/tab collection without concurrent checks.

The clean repeat completes with no rejected rows:

| Layout / metric | Frozen C++ A | Conditional cursor invalidation | Candidate wins |
| --- | ---: | ---: | ---: |
| Four splits p50 | 31.06 ms | 30.31 ms | 5/6 |
| Four splits p95 | 45.26 ms | 37.83 ms | 5/6 |
| Four splits p99 | 48.07 ms | 40.79 ms | 6/6 |
| Four tabs p50 | 30.51 ms | 29.57 ms | 5/6 |
| Four tabs p95 | 43.42 ms | 37.43 ms | 6/6 |
| Four tabs p99 | 46.83 ms | 41.28 ms | 6/6 |

GUI CPU medians are 6.24% -> 5.67% for splits (6/6 wins), and 5.82% -> 5.70%
for tabs (4/6). GUI peak RSS medians are 206.95 -> 199.20 MiB for splits and
199.39 -> 199.70 MiB for tabs. The change is accepted against frozen C++ A for
these measured warm-input workloads, with no consistently regressing layout.
The frozen GUI SHA-256 is
`7f59fab433392828a94e5acbbce2766e4af1b1706bf84ce5c6761cb6ea5a4aaa`;
the runtime remains the baseline C++ executable. These results are not a win
over Zig, a whole-flow acceptance, or a 120 Hz cadence measurement.

`idle-recheck-zig-01` and `idle-recheck-cpp-01` separately repeat the two-second
idle setup with labelled readback diagnostics. Both complete 26 inputs including
warmup. A delayed read of the same zero-timestamp drawable still returns zero
100 ms later; these are not timestamps that simply become positive shortly
after the native callback. This does not resolve the intermittent idle failure.
The delayed reread is diagnostic-only and never admits an otherwise invalid
frame. The uninstrumented path does not retain the drawable for this check;
native readiness negative controls still pass.

The attempted C++ GUI + Zig runtime diagnostic cannot connect: current C++
uses schema `cqp00001`, while Zig uses `886b480d`. Shared component probes also
need schema-appropriate drivers before cross-runtime timing. Do not bypass
the handshake or decode the new input-mode fields with the old frame layout.

## Fresh Zig comparison and allocation hypothesis

`cursor-zig-layout-pairs-01` completes six alternating pairs per layout, with
100 measured inputs after 20 warmups, independent matching runtimes, equal
viewport/grid and positive native presentation. All 36 runs are retained and
valid. Medians of run quantiles show that the accepted C++ improvement still
loses to Zig:

| Layout / metric | Zig stack | Accepted C++ stack | C++ wins |
| --- | ---: | ---: | ---: |
| Single p50 | 25.76 ms | 29.37 ms | 0/6 |
| Single p95 | 33.11 ms | 37.67 ms | 0/6 |
| Single p99 | 37.12 ms | 40.17 ms | 1/6 |
| Four splits p50 | 26.30 ms | 31.21 ms | 0/6 |
| Four splits p95 | 33.11 ms | 38.29 ms | 0/6 |
| Four splits p99 | 35.05 ms | 41.52 ms | 0/6 |
| Four tabs p50 | 26.14 ms | 29.65 ms | 0/6 |
| Four tabs p95 | 33.18 ms | 38.11 ms | 0/6 |
| Four tabs p99 | 38.78 ms | 42.18 ms | 1/6 |

GUI CPU medians are Zig/C++ 4.54/5.42%, 4.69/6.10% and 4.43/5.90%
for single/splits/tabs. GUI peak RSS medians are 124.33/199.80 MiB,
129.82/200.55 MiB and 130.19/199.76 MiB. These are GUI resources, not
whole-stack totals. The Zig tab outlier remains in the raw results.

The standalone `tools/display_link_probe.m` records Core Video callback and
scheduled output ticks for an explicit display. Its six-second idle diagnostic
on display 1 observes callback gaps near 8.33 ms (p50), with a nominal period
of 199999/24000000 seconds. This rules out a fixed 60 Hz callback cadence in
that observer; it does not measure Qt's delivery or actual drawable presentation.
Raw samples, identity, timebase and duration are retained under
`out-perf/cursor-invalidation/display-link-idle-01.json`. Compilation and argument,
identity, completeness and callback-monotonicity checks pass. The legacy API
is deliberately the one used by the Qt Cocoa path under investigation.

The coordinator's allocation/copy/Qt-conversion hypothesis was read and verified
against this branch. It is additional investigation, not a demonstrated cause.
RAII does not imply allocation. `TextScene` reuses its previous node and
`FrameStream` retains vector capacity, although payload insertion still copies.
`GraphicsStore::Image` owns a new pixel allocation per image/generation;
that must not be counted as a fresh allocation on every rendered frame.

For Kitty uploads, `WindowImages::upload` wraps borrowed RGB888/RGBA8888 bytes.
`ImageResource::upload` converts them to RGBA8888 premultiplied before its
same-size GPU-texture reuse branch and detaches existing draw nodes. The
`pixels.copy()` fallback is a separate no-RHI path, not the measured Metal path.
Qt/framework allocation, conversion and buffer lifetime therefore need separate
measurement from the project's allocator counters. The Zig image path borrows
through bounded leases, but `PremultipliedImage` allocates, initializes and
securely erases memory; the full Zig application is not allocation-free.

`alloc-cpp-typing-01` attempted an Allocations attachment after warmup. The native
probe lost its active/key window after 56 responses; the recorder remained
waiting after the target exited and was stopped. Export failed with a missing
template error. The receipt marks this diagnostic invalid; it supplies no
allocation counts or acceptance timing. No cause for focus loss is established.
Follow-up diagnostics must count Qt work as well as application work, distinguish
logical allocator operations from system allocations, and preserve alpha,
source ownership, generation/cancellation, secure erasure and recovery rules.

The isolated Qt conversion census under `out-perf/allocations/qt-conversion/`
wraps `malloc`, `calloc` and `free` in an owned diagnostic process, including
calls inside Qt. It does not cover every allocation API, VM operation or the
whole application. After a warm conversion, eight conversions give:

| Source | Dimensions | Observed allocations / image | Requested bytes / image |
| --- | --- | ---: | ---: |
| RGB888 | 1024×1024 | 2 | 4,194,464 |
| RGBA8888 | 1024×1024 | 35 | 4,197,424 |
| RGB888 | 3840×2160 | 2 | 33,177,760 |
| RGBA8888 | 3840×2160 | 255 | 33,186,880 |

Observed free counts match allocations. A separate backtrace-enabled census
reproduces these totals: small RGBA allocations originate in `convert_generic`,
which [partitions conversion into thread-pool segments](https://github.com/qt/qtbase/blob/v6.12.0/src/gui/image/qimage_conversions.cpp#L198).
Every conversion also owns a new output pixel buffer. The test verifies source
immutability, independent destination storage and the generated pattern's pixels.
These are component allocation counts, not steady-state whole-GUI counts or
native frame timing. Peak live bytes and complete upload lifetime remain open.

An exhaustive channel/alpha oracle rejects substituting the existing
`ArtworkResize::premultiply`: its rounding differs from Qt, for example 229
with alpha 152 produces 137 versus Qt's 136. That existing helper is unchanged.
The first timing collection was mistakenly started before checking this failed
oracle; `candidate-pairs-01-invalid.json` excludes it from acceptance.

Revised scratch candidates reproduce Qt's arithmetic. Their oracle covers all
65,536 channel/alpha combinations, odd widths, padded rows and source ownership.
Seven alternating component pairs in `candidate-pairs-exact-01.jsonl` compare
Qt with a single-pass byte conversion and a packed-word alternative. The byte
conversion wins 7/7 at both sizes: median per-image time 0.292 -> 0.204 ms at
1024×1024 and 1.833 -> 1.629 ms at 3840×2160. Packed conversion loses 0/7
at both sizes and is rejected. ARM64 disassembly shows automatic NEON
`ld4`/`umull`/`usra`/`raddhn`/`st4` conversion with a scalar remainder.
No handwritten architecture-specific intrinsics are needed. The byte candidate
is not integrated or accepted for production: other architectures, native F10
image presentation, source lifetimes and complete-stack regressions still need
validation. Scratch source, oracle, binaries, allocation logs and disassembly
are retained together; instrumentation is excluded from these timing pairs.

## Coverage and next experiments

Every row below remains open. Existing component/functional probes do not prove
the visible endpoint or a full-flow win. Six valid alternating full-client pairs
and the existing seven-pair component contracts remain mandatory.

| Flow | Reusable support | Missing acceptance work |
| --- | --- | --- |
| F01 | Isolated launch and initial marker readiness | Launch timing, restore, surviving children |
| F02 | Native GUI idle getrusage | Separate runtime/wakeup/settled memory, hidden/disconnected |
| F03 | Native keyDown to verified presented marker | Full-stack pairs; Unicode/combining/cursor/paste variants |
| F04 | Fixed-rate fixture, ASCII/ANSI DSR and runtime probes | Unicode, final-content oracle, concurrent input and resource evidence |
| F05 | TUI/terminal fixtures | Deterministic full TUI trace and presentation cadence |
| F06 | Native wheel injection, terminal scroll probes | Continuous scrollback/selection/live-return content and cadence |
| F07 | Four splits and fixed-rate background load | All producers active, fairness and cadence |
| F08 | Four tabs and background output | Repeated tab/workspace switching to verified target content |
| F09 | Native resize and blur controls | Continuous window/divider motion, clipping, matched backgrounds |
| F10 | Kitty producer and image marker tooling | Integrated 1K/4K receipts, alpha/generations, image latency plus UI cadence |
| F11 | Private clipboard/shelf/modal captures | Independent runtimes, actual image endpoint, bounded multi-attachment cases |
| F12 | History/query probes and GUI captures | Independent runtimes, cold/warm queries to presented results |
| F13 | Agent/report/sidebar fixtures | Report-to-presentation under streaming load, service overhead |
| F14 | Configuration/plugin/path/suggestion probes | Complete configured interactions, worker cost and cadence |
| F15 | Local reconnect and SSH configuration fixtures | Owned real SSH, controlled backpressure, continuity and presentation |
| F16 | Proxy, CONNECT, HTTP/1, HTTP/2 and capture oracles | Equal-feature service load concurrent with GUI, resources/queue bounds |

First profiling candidates are the refresh value sent by each GUI, GUI pacing
phase versus VSync, and whole-viewport repaint during subcell resizing. Further
leads are repeated font coverage lookup, per-cell row-revision division, runtime
scrollback projection and history-query scratch/statement reuse. Each needs a
fresh profile, equivalence oracle, disassembly and paired acceptance before it
can be retained as an optimization. Historical rejected batching, relay-buffer,
prefault, render-loop and update-idle variants remain documented in the existing
GUI/runtime performance reports.
