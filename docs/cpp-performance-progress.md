# Complete-stack performance progress

This is the current work log for [F01–F16](cpp-performance-flows.md), starting
from `6152393b18f8b3e7ae1a1322eca6c8f1eb718bbd` on 2026-11-02. The persistent
objective is active and unbounded. No flow has complete-stack performance
acceptance yet. Conditional cursor invalidation is accepted for the measured
warm-typing layouts against the frozen C++ baseline; complete-flow and Zig-stack
acceptance remain open.

## Shared-library base, 2026-11-03

Work has moved to `cpp-stack-perf-dlls-20261103`, initially at
`b8be74a45cf85d01db4998b3cf94fe7f4c975bbe`, following Adrian's local handoff.
The preceding branch is obsolete. Its commits and C++ working changes were
already integrated, so only the subsequent report and capture-oracle files were
carried over. A binary patch, exact snapshot-to-current tree delta and backup
stash are retained; the delta was verified byte-for-byte after switching.
The actual shared-library extraction commit in this history is `282d1a727`.
The integrated key-repeat fix and shared-memory include moves are preserved.
Neither removed measurement directory has tracked files.

New build directories are under `out-perf/dlls-handoff-20261103`. The first
runtime attempt exposed generic Homebrew include paths selecting OpenSSL 4
headers despite linking OpenSSL 3. Explicit nghttp2/Brotli/Zstd prefixes avoid
that include collision. The resulting Release runtime has SHA-256
`fa894913f47514fc4246876e0f79d773fef1467876d395b89e87963af8eb7c36`.
Thirty-five CTest entries pass initially. `runtime-tests` stops at the inherited
descriptor test because its process limit is 2560 but it requests descriptor
4096. With a limit of 8192 confined to the owned test controller and children,
that same test binary passes, including the atomic-runtime checks. All 36 entries
are therefore verified; the initial failure is retained, not relabeled successful.

The GUI now builds successfully with the repository's managed Qt recipe and
pinned patch in a new private cache. The complete suite passes 128/131 entries;
the two known stale fixtures and the Quick suite's CTest timeout remain in the
initial log. The handshake fixture now expects the actual schema identifier in
the exact refusal text. The activity fixture supplies materialized workspace
entries and refreshed connection metadata, checks canonical OpenPane navigation,
and completes a denied request before checking detached-worktree rejection.
The first fixture revision used a missing-pane failure, which correctly triggered
the existing fallback and left a request pending; that failed trial is retained.
Activity, handshake and workspace-navigation checks now all pass. Production
behavior was not changed. The first direct Quick invocation omitted its runtime
environment and failed initialization; that controller error is retained. With
the environment supplied, the unrestricted offscreen run finishes in 130.481 s:
125 passed, five failed and one skipped. Two failures expect hiding a window to
remove its active state; two subsequent history checks fail synchronization.
All four pass in a focused Cocoa/Metal rerun without production or test changes.
The skipped native-minimization case also passes in a separate Cocoa run.

The fifth failure exposes a separate complete-stack gap. The first test PATH
contained `telar-runtime`, while helper discovery searches for `telar`; its
identity assertion correctly rejected the installed executable before invoking
the plugin. With the new C++ runtime staged as `telar` and used for both discovery
and the test server, the native test reaches invocation but reports
`PluginWorkerFailed`. The C++ CLI has `tap-worker` but no `plugin-worker` dispatch.
A direct empty-environment control returns `Unknown server option`. F14 plugin
action parity therefore remains open; substituting the Zig helper would not
validate the complete C++ stack. All failures and focused results are preserved
under the new build prefix.

The new staged GUI has SHA-256
`01c6ebc2c0bc28d210b458be09150b6f9b366fa0c5706eb022ce5017f051324e`.
Its runtime, command helper, dynamic linkage and matching benchmark configuration
are frozen alongside it. The first fresh native qualification completes in both
stacks with twenty measured inputs after twenty warmups, a 1600×1000 viewport,
82×21 grid, identical marker coordinates, VSync, positive drawable presentation
and verified GUI/runtime identities (`/tmp/telar-perf-dlls-native-qual-01`).
Single-run p50 is 26.965 ms for Zig and 25.781 ms for C++; this is qualification,
not a six-pair performance acceptance or a sustained-refresh result.

A fresh instrumented tab-layout census on this base reproduces the repeated
work: reorder and Escape cancellation pass with 37/58 rebuilds and 100/162
caption measurements. Caption work accounts for about 8.0%/9.6% of their
instrumented rebuild time. The hidden-counter case first fails visibility under
the window manager; floating only its owned window reaches the counter but fails
the destination-in-viewport assertion. Both failed runs remain excluded. The
viewport-change cancellation passes in a separate floating-window run. Artifacts
are under `out-perf/dlls-tab-layout-census`. No production cache change has been
made.

Phase instrumentation in `out-perf/dlls-tab-layout-phases` then separates
measurement, positioned-record construction and model reconciliation. Reorder,
Escape cancellation and viewport cancellation all pass. Measurement accounts
for 10.6–13.1% of instrumented rebuild time; reconciliation, including synchronous
Qt/QML subscribers, accounts for 76.2–80.2%. These are diagnostic, unpaired
durations. Rebuilding captions or measured records alone would leave most of
that observed work intact.

The provisional `dlls-tab-field-roles` experiment retains complete records for
existing consumers but exposes separate tab content and geometry roles to QML.
Moving a tab then notifies bounds without rebinding its content, icons and
activity. A reference-model oracle passes 2,048 deterministic insert/remove/
reorder sequences and verifies selective notifications; chrome and activity scene
tests pass. All three instrumented native gestures pass as well. Their model
update durations decrease, but instrumentation and nonpaired runs prevent a
performance acceptance claim. The candidate's single-layout native qualification
also passes, with a byte-identical full-viewport PNG against the new C++ baseline
(SHA-256 `5ef2102300977afa1170013c15ce79664d5dacce5f0816862062f8ab0a6f3eed`).
That static equality does not establish animated pixel parity. A separate v2
build incorporates lint cleanup and passes the model oracle, chrome/activity
tests and six uninstrumented native reorder/cancellation gestures. Its native
single-layout capture also has the same PNG digest. Targeted model/test lint
passes; linting the unchanged layout translation unit reports its existing
101-line `rebuild` against the 100-line threshold.

Six alternating pairs per settled typing layout finish successfully in
`/tmp/telar-perf-tab-fields-v2-regression-01`. These are regressions against the
new C++ baseline, not a Zig comparison or actual F08 switching acceptance.
Values below are medians of run statistics; CPU is GUI CPU milliseconds per
measured input. Runtime resources remain outside this series.

| Layout / metric | New C++ baseline | Field-role v2 | Candidate wins |
| --- | ---: | ---: | ---: |
| Single p50 ms | 25.101 | 24.921 | 3/6 |
| Single p95 ms | 32.112 | 30.616 | 4/6 |
| Single p99 ms | 35.121 | 34.345 | 4/6 |
| Single maximum ms | 37.640 | 35.769 | 5/6 |
| Single GUI CPU ms/input | 4.081 | 4.066 | 3/6 |
| Four tabs p50 ms | 25.020 | 24.978 | 2/6 |
| Four tabs p95 ms | 32.668 | 31.556 | 5/6 |
| Four tabs p99 ms | 34.443 | 35.306 | 3/6 |
| Four tabs maximum ms | 37.671 | 35.979 | 4/6 |
| Four tabs GUI CPU ms/input | 4.175 | 4.261 | 2/6 |
| Four splits p50 ms | 25.264 | 25.758 | 2/6 |
| Four splits p95 ms | 31.697 | 32.976 | 1/6 |
| Four splits p99 ms | 34.660 | 35.531 | 3/6 |
| Four splits maximum ms | 36.629 | 37.780 | 1/6 |
| Four splits GUI CPU ms/input | 4.178 | 4.357 | 1/6 |

The four-split p95, maximum and CPU regressions reject v2. Cause is not
established; no code-placement exemption is demonstrated. Median lifetime GUI
peak RSS is approximately 205–206 MiB in both variants and is not the rejection
criterion. ARM64 inspection shows the bounded per-field comparisons and selective
role-list construction; fewer downstream QML evaluations do not prove a complete
application win. Source copies, executables, oracles, profiles and the decision
remain in the isolated prefixes. All candidate production/test/CMake changes
were verified against their preserved copies and withdrawn from the working
tree. Actual tab/workspace switching and continuous presentation remain open.

A fresh original-Zig ReleaseFast reference also builds from this branch with the
new font/theme assets, SHA-256
`6ccf79485c5ca8baaa2d69d2590abb49d23c808891c04fe6e70f5602713a1d5e`.
Earlier installed-Qt measurements below are historical evidence, not performance
qualification of this new dependency/base.
The rejected image prototypes remain isolated artifacts and were not promoted
into the production working tree during the migration.

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

## Native image qualification

The marker fixture now supports explicit `--image-size WIDTH HEIGHT` for a
single Telar pane. Each input replaces a Kitty RGBA image through shared memory;
its pixels supply the marker, so text output cannot satisfy the image endpoint.
The fixture records dimensions, actual payload byte counts and hashes, publication
sequence and source timestamps. It precomputes source pixels, retains bounded
publication records in memory and writes the final receipt after measurement.
The runner then finishes only the verified child of its owned runtime and checks
shared-memory cleanup before stopping that runtime. This is a closed-loop image
replacement test, not a fixed-rate stream or a 120 Hz smoothness qualification.

`image-1k-qualification-01` is invalid: native Zig presentation completed, but
runtime shutdown killed the fixture before its final receipt. The revised owned
fixture shutdown completes both stacks in `image-1k-qualification-02` and
`image-4k-qualification-01`, with 20 warmups and six measured inputs each.
Both stack pairs match the 1600×1000 viewport, DPR 2, 82×21 grid, image marker
location, source payloads and positive presentation gate. The image receipts
verify 1024×1024 / 4,194,304 bytes and 3840×2160 / 33,177,600 bytes respectively.
Focused checks cover shared-memory pixel contents, publication independence,
cleanup, corrupted/missing receipts, source bounds and refusal to signal an
unrelated child. Existing fixture and GUI comparison tests pass.

These short qualifications are not acceptance pairs. Their Zig/C++ p50 values
are 42.62/46.42 ms for 1K and 45.70/139.45 ms for 4K. The 4K gap is much larger
than isolated Qt conversion cost. The separate `image-4k-profile-01` completes
200 measured inputs and captures five-second GUI/runtime samples after warmup;
both sampled process identities match the frozen accepted stack. Instrumented
results are excluded from timing acceptance. Runtime samples include socket
writes and image chunk serialization; GUI samples include input draining, copies
and Qt's conversion workers. Most sampled thread time is waiting. Further
transport/queue phase measurement is needed before attributing the large gap.

The single-pass conversion also wins all seven component pairs on an opaque
input pattern: Qt/fused medians 0.273/0.203 ms at 1K and 1.693/1.633 ms at 4K.
The packed alternative loses all seven at both sizes. These additional component
results do not close native-image or cross-architecture acceptance.

## Native image baseline pairs and transport candidate

`image-1k-baseline-pairs-01` completes five pairs, then its last Zig run fails
on input 11 during warmup: the image was published, the window remained active
and key, but no qualifying presentation arrived within two seconds. The cause
is not established. All raw observations and the unmatched C++ run remain.
`image-1k-baseline-supplement-01` adds two fresh alternating complete pairs.
The seven complete 1K pairs below exclude the unmatched pair, not any sample
within a valid run; all maxima and outliers are retained. The series does not
resolve the invalid launch. A later cleanup diagnostic records which shared
objects the fixture itself must unlink, to distinguish unadopted input from
presentation failure on future attempts; that field was added after timing.

`image-4k-baseline-pairs-01` completes all six pairs without rejected rows.
Both sizes use 100 measured inputs after 20 warmups with the same frozen stacks
and qualified native endpoint. Medians of run quantiles:

| Image / metric | Zig stack | Accepted C++ stack | C++ wins |
| --- | ---: | ---: | ---: |
| 1024×1024 p50 | 41.38 ms | 45.38 ms | 0/7 |
| 1024×1024 p95 | 52.74 ms | 58.61 ms | 0/7 |
| 1024×1024 p99 | 56.61 ms | 61.69 ms | 0/7 |
| 3840×2160 p50 | 52.60 ms | 137.42 ms | 0/6 |
| 3840×2160 p95 | 66.59 ms | 147.82 ms | 0/6 |
| 3840×2160 p99 | 74.84 ms | 152.25 ms | 0/6 |

GUI CPU counters start at input 20 and cover the 100 measured inputs, excluding
warmup; CPU 100% means one core. CPU per input divides that user+system time by
100. The earlier report incorrectly divided by 120; corrected derived values
are in `out-perf/allocations/image-baseline-summary-02.json`, with the original
raw runs and erroneous summary retained. Presentation timings and CPU percentages
are unchanged. RSS is the lifetime process peak, not a whole-stack sum.

| Image / GUI resource | Zig | C++ |
| --- | ---: | ---: |
| 1K CPU | 7.48% | 18.27% |
| 1K CPU per input | 7.01 ms | 17.64 ms |
| 1K peak RSS | 141.75 MiB | 203.19 MiB |
| 4K CPU | 9.71% | 47.09% |
| 4K CPU per input | 10.03 ms | 89.37 ms |
| 4K peak RSS | 251.98 MiB | 331.44 MiB |

Source review confirms the transport difference already noted in `PARITY.md`:
C++ `Session::connected` always sends `ConfigureGraphics{false}` and has no
`GraphicsSharedImage` dispatch. Zig enables shared transport when available.
The C++ runtime already supports either route. Its inline route serializes up
to 1 MiB image chunks and writes batches up to 256 KiB; the GUI assembles and
copies those pixels before Qt conversion. The profile contains that inline
serialization/write path. This is a concrete optimization target, not proof
that it explains every millisecond of the measured gap.

The next isolated candidate is local shared-image delivery with owned client
pixels, using bounded validated reads and retaining inline delivery for remote
connections. It must preserve names/descriptor cleanup, permissions, byte and
image quotas, generations, source immutability, credits, failure recovery and
rendered output. Merely flipping the capability without receiving the message
is invalid. Qt conversion remains a separate candidate after transport; neither
candidate is integrated or accepted by this baseline. Full F10 alpha, continuous
streaming and presentation cadence acceptance remain open.

## Local shared-image experiment: latency win, memory unresolved

The frozen experiment in `out-perf/shared-image` implements local shared-image
negotiation and dispatch, retaining bounded owned pixels and inline remote
delivery. It validates names, private permissions, owner, storage type and extent,
unlinks accepted objects, and uses kernel-mediated reads to avoid dereferencing
peer-controlled mappings. Missing storage requests a graphics snapshot; quotas,
generation retirement and credits retain the existing store behavior. Qt's
conversion remains unchanged. Its GUI SHA-256 is
`d4526b445e33f360a09fd725cca7b6a28128eb28402e38f3c176928668a848ee`;
the runtime is the same frozen C++ runtime as the accepted cursor variant.
Sources, binaries and build hashes are retained in that experiment directory.

The shared/inline oracle compares RGB/RGBA bytes, partial alpha, generations,
credits, quotas, missing/truncated storage, permission/name rejection, ignored-pane
cleanup and remote rejection. It passes natively and under x86-64 Rosetta.
Native Metal image rendering and keyboard controls pass, as do graphics retention,
recovery and their scene tests. The remote connection test passes after replacing
its obsolete hardcoded schema expectation with the compiled schema. The new reader
compiles to Linux AArch64 and x86-64 objects; Linux execution remains unavailable.
An initial Linux syntax attempt exposed a missing `cerrno` include in the reused
reader and the existing test fixture's musl `arc4random_buf` limitation. Neither
failed attempt counts as Linux execution or a passing full Linux test suite.

`/tmp/telar-perf-shared-image-{1k,4k}-pairs-01` each contains six complete
alternating pairs, 100 measured inputs after 20 warmups, positive native
presentation timestamps and verified image pixels. A is the accepted cursor
build; B is this experiment. Medians of run quantiles/resources:

| Size / metric | A | B | B wins |
| --- | ---: | ---: | ---: |
| 1K p50 | 43.94 ms | 37.26 ms | 6/6 |
| 1K p95 | 58.60 ms | 45.22 ms | 6/6 |
| 1K p99 | 63.81 ms | 48.52 ms | 6/6 |
| 1K GUI CPU / measured input | 17.35 ms | 9.33 ms | 6/6 |
| 1K GUI peak RSS | 206.20 MiB | 215.88 MiB | 1/6 |
| 4K p50 | 137.40 ms | 48.49 ms | 6/6 |
| 4K p95 | 145.77 ms | 58.60 ms | 6/6 |
| 4K p99 | 152.90 ms | 62.50 ms | 6/6 |
| 4K GUI CPU / measured input | 89.33 ms | 31.47 ms | 6/6 |
| 4K GUI peak RSS | 331.35 MiB | 362.10 MiB | 3/6 |

This variant was **rejected and restored out of production source** under the
original resource gate: the 1K peak-RSS regression was consistent and its cause
was not established. Adrian subsequently authorized bounded memory increases
when measured work and latency savings justify them; memory growth alone is no
longer a rejection criterion. The separate typing regression below still requires
qualification of a fresh production candidate. Fresh paired
Zig comparisons have not been run for this rejected build. A separate seven-pair
component diagnostic compares a full
kernel copy with 1 MiB mapping windows and verifies every output byte. Both have
the same median process peak (5.36 MiB at 1K and 33.00 MiB at 4K); windowing does
not demonstrate a memory reduction and has not been integrated. The diagnostic
is under `out-perf/shared-image/memory-probe`, separate from headline timings.
The corrected candidate summary is `out-perf/shared-image/summary-02.json`.

The six complete no-image typing pairs in
`/tmp/telar-perf-shared-image-text-pairs-01` also reject the variant:
p50 29.37 -> 30.73 ms (1/6 wins), p95 37.75 -> 37.73 ms (4/6),
p99 39.39 -> 42.17 ms (2/6), GUI CPU per measured input 4.49 -> 4.83 ms
(1/6). Peak RSS improves slightly, 201.63 -> 199.74 MiB (6/6).
The object disassembly, including relocation targets, of `keyPressEvent` is
identical in A and B. This alone does not establish that the entire typing
regression is code placement: dispatch/render paths still need comparison.

The separate `out-perf/shared-image/memory-profile-02` diagnostic captures
`vmmap -summary` for each identified GUI/runtime during 200-input runs. Both GUI
snapshots show 150.1 MiB physical footprint and 14.2 MiB resident `MALLOC_LARGE`;
their footprint peaks are 222.5/213.1 MiB. Runtime snapshots are 31.1/22.0 MiB,
with peaks 31.1/26.0 MiB. These single asynchronous snapshots neither explain
the uninstrumented lifetime-RSS regression nor prove a settled-memory reduction.
The first diagnostic tried 520 total inputs, exceeded the native probe's 512
capacity and aborted before measurement; it is retained as invalid.

Frozen experiment sources and the oracle remain available under
`out-perf/shared-image/source`; accepted cursor production behavior is intact.

### Same-binary transport diagnostic and memory tradeoff

`out-perf/shared-image-toggle` isolates the shared-image capability using a flag
read once at construction in one diagnostic binary. Its SHA-256 is
`bc5877b5ae229d75f837bd6e217562daecd92adfc4c80e44edf1c587dc2aa90e`.
The flag is explicitly passed by a scratch harness and its selected value is
checked in each process receipt. It is not a production environment option.
Native input/rendering oracles pass with either value. Each row below summarizes
six complete alternating pairs of 100 measured inputs after 20 warmups:

| Workload / metric | Inline | Shared | Shared wins |
| --- | ---: | ---: | ---: |
| Text p50 | 29.614 ms | 29.419 ms | 5/6 |
| Text p95 | 37.687 ms | 37.593 ms | 4/6 |
| Text p99 | 42.106 ms | 41.237 ms | 5/6 |
| Text GUI CPU/input | 4.377 ms | 4.366 ms | 3/6 |
| Text GUI peak RSS | 199.50 MiB | 201.33 MiB | 1/6 |
| 1K p50 | 43.489 ms | 37.227 ms | 6/6 |
| 1K p95 | 58.129 ms | 45.070 ms | 6/6 |
| 1K p99 | 63.032 ms | 50.128 ms | 6/6 |
| 1K GUI CPU/input | 17.521 ms | 9.567 ms | 6/6 |
| 1K GUI peak RSS | 210.22 MiB | 213.34 MiB | 2/6 |
| 4K p50 | 137.493 ms | 48.079 ms | 6/6 |
| 4K p95 | 148.554 ms | 59.698 ms | 6/6 |
| 4K p99 | 153.222 ms | 66.220 ms | 6/6 |
| 4K GUI CPU/input | 89.453 ms | 31.578 ms | 6/6 |
| 4K GUI peak RSS | 362.73 MiB | 362.04 MiB | 4/6 |

Raw receipts are `/tmp/telar-perf-shared-image-toggle-text-pairs-03`,
`...-1k-pairs-01`, `...-4k-pairs-01` and `...-4k-supplement-01`;
`out-perf/shared-image-toggle/summary-01.json` combines only complete pairs.
The first text attempt did not forward the flag and is invalid; the second
stopped on the new receipt assertion. In the first 4K series one shared run
failed initial readiness with zero inputs and no initial presentation. Its
unmatched inline run is excluded; two fresh complete pairs supplement the four
completed pairs. The readiness failure's cause is not established.

This diagnostic does not reproduce the earlier no-image latency/CPU regression
when changing only the capability. It does not prove code placement caused the
earlier result or qualify a new production build. Common input and normal-frame
dispatch instructions match after normalizing relocations, but the complete
dispatch function differs. A fresh production candidate still needs its controls
and independent Zig comparison on the merged renderer base.

### Qt conversion CPU diagnostic

The allocation/copy hypothesis remains scoped to measured paths. Seven alternating
component pairs in `out-perf/allocations/qt-conversion/` compare Qt's RGBA conversion
with a single-pass exact premultiplication loop. The oracle covers every channel
and alpha combination, odd widths, padded rows and unchanged source bytes. On
opaque fixtures, median Qt wall/aggregate CPU time per image is 0.271/1.067 ms at
1K and 1.693/8.184 ms at 4K; the fused loop is 0.204/0.204 ms and 1.633/1.633 ms,
winning all seven pairs for both metrics. Qt parallelizes the conversion, so
wall time alone hides most of the CPU difference. Results and raw samples are
`candidate-cpu-summary-opaque-01.json` and `candidate-cpu-pairs-opaque-01.jsonl`.
The loop is not yet a production optimization or a full-client result. Prioritize
eliminating repeated work and conversion passes, then measure bounded reuse or
precomputation against its memory cost.

## Integrated optical glyph cache on Personal

Merge `2beb08bf0e2048e70334fe3a066189de4980d61d` includes coordinator commit
`62a45e2405462e6868341b5f1806436924f2b764` and retains the accepted cursor change
and all earlier work. The persistent F01–F16 goal remains active. The new
`out-perf/optical-integration` Release build uses LLVM 23.1.4 and Qt 6.12 on this
M1 Pro. Frozen GUI SHA-256:
`19f2916e762f0a7e2ce441f6a8ae00ca502fe585afff24c66dfec03b88320881`.
The frozen runtime remains
`64222e2f2e07c12a4de9f380c60e8db57266f29f8beb43c9118e50602ae44d91`.

Four focused CTest entries pass, including 432 optical cases. The independent
original-Zig row oracle passes all 7,494 cases. Its first build failed due to SDK
selection; the successful second run records explicit macOS 26 libc/target flags.
Native Cocoa/Metal text mask/position tests and runtime-backed terminal input,
frame synchronization and cursor phase tests also pass. Logs and build identities
are retained in the same experiment directory.

An independent scene oracle uses the unmodified original Zig `RowRuns`,
`GlyphAtlas`, `TextRun` and original macOS C rasterizer. It exports the alpha atlas
and positioned quads for CPU composition in draw order. Bundled JetBrains Mono,
19 pixels at scale 2, line height 1.3, letter spacing -0.5 and optical strength
250 produce a 5,632 × 3,380 image. A native Metal item capture of the **entire**
new C++ scene matches exactly: zero differing pixels/channels. The initial native
window capture was clipped to 3,600 × 2,198; that cropped region also matches the
original Zig exactly, while the old C++ scene differs in 651,294 pixels. Neither
comparison silently accepts an old C++ rendering defect as the oracle.

Oracle source, build command, atlas, quads and images are under
`zig-visual-reference`; the full Metal capture and exact comparison are under
`full-capture` (`comparison-02.json`). The first item-capture attempt doubled DPR
and is retained as invalid. Capturing the full item separately avoids mistaking
the window manager's size limit for whole-scene coverage.

Seven alternating component pairs in `scene-pairs-01` measure production scene
synchronization for 256 × 52 changing ASCII cells with warm optical caches:
**108.965 -> 6.975 ms/repaint, 7/7 wins**. The final native-window capture matches
the independent reference crop exactly; the separate full-item capture above
verifies the rest. These are CPU synchronization results with identical current
dependencies and historical scene implementations. They do not establish
full-stack latency against Zig, sustained FPS, or native 120 Hz cadence.

Six complete alternating full-client pairs per layout in
`/tmp/telar-perf-optical-integration-text-pairs-01` compare the accepted cursor
build with the merged optical build, explicitly setting `font.thicken=true`.
Each run has 100 measured inputs after 20 warmups, matching grids and positive
native presentation timestamps with verified marker pixels. Medians of run
quantiles/resources follow; win counts compare paired runs, not the medians:

| Layout / metric | Previous C++ | Merged optical C++ | Optical wins |
| --- | ---: | ---: | ---: |
| Single p50 | 31.258 ms | 30.363 ms | 3/6 |
| Single p95 | 38.604 ms | 38.400 ms | 3/6 |
| Single p99 | 41.617 ms | 42.015 ms | 2/6 |
| Single GUI CPU/input | 4.902 ms | 4.451 ms | 4/6 |
| Single GUI peak RSS | 203.48 MiB | 206.00 MiB | 1/6 |
| Splits p50 | 33.141 ms | 30.474 ms | 6/6 |
| Splits p95 | 39.119 ms | 38.417 ms | 5/6 |
| Splits p99 | 41.817 ms | 41.008 ms | 4/6 |
| Splits GUI CPU/input | 5.747 ms | 4.517 ms | 6/6 |
| Splits GUI peak RSS | 203.49 MiB | 204.92 MiB | 2/6 |
| Tabs p50 | 32.241 ms | 30.309 ms | 5/6 |
| Tabs p95 | 39.292 ms | 39.071 ms | 3/6 |
| Tabs p99 | 42.915 ms | 43.327 ms | 3/6 |
| Tabs GUI CPU/input | 5.293 ms | 4.514 ms | 6/6 |
| Tabs GUI peak RSS | 203.46 MiB | 204.92 MiB | 1/6 |

Single-pane latency is inconclusive; its median paired p50 ratio is 1.0068
despite the lower median of quantiles. Splits and tabs meet the p50 win-count
gate, and no layout has a consistent latency/CPU regression by the paired rule.
The small RSS increase is retained under Adrian's explicit memory/performance
tradeoff policy. These controls support keeping the requested merge, not closing
F03/F07/F08: they do not provide a fresh Zig comparison, Unicode/TUI coverage or
sustained native cadence. Resource calculations are recorded in
`out-perf/optical-integration/client-text-resources-01.json`.

### Shared-image candidate rebuilt on the optical base

`out-perf/shared-image-optical` restores the seven-file local transport candidate
on the merged source, without the diagnostic toggle. The frozen GUI SHA-256 is
`c695b51d7d611b57452fd64b845e02ae24b32dd1cbbc5928d1ab8862fea2eba6`;
its C++ runtime is unchanged. The build receipt records all candidate source
hashes, and copies are retained under `source/`. Six focused CTest entries pass,
including remote connection and shared/inline pixel, generation, quota, cleanup
and recovery oracles. Native Metal runtime-backed Kitty/input tests pass, as do
seven image-scene cases for RGB, straight alpha, clipping, incomplete replacement,
retained geometry, shared views and texture reuse.

Initial 1K and 4K end-to-end qualification pairs pass their native pixel and
presentation checks. Six complete alternating 4K pairs, 100 measured image
replacements after 20 warmups, are recorded in
`/tmp/telar-perf-shared-image-optical-4k-pairs-01`. Both variants explicitly use
`font.thicken=true`. Against the merged optical build, the candidate produces:

| 4K metric | Optical inline | Optical shared | Shared wins |
| --- | ---: | ---: | ---: |
| p50 | 137.421 ms | 48.582 ms | 6/6 |
| p95 | 146.965 ms | 58.695 ms | 6/6 |
| p99 | 152.967 ms | 62.681 ms | 6/6 |
| GUI CPU/measured input | 89.366 ms | 31.054 ms | 6/6 |
| GUI peak RSS | 367.77 MiB | 366.88 MiB | 4/6 |

Six complete 1K pairs under the same contract are recorded in
`/tmp/telar-perf-shared-image-optical-1k-pairs-01`:

| 1K metric | Optical inline | Optical shared | Shared wins |
| --- | ---: | ---: | ---: |
| p50 | 44.534 ms | 37.178 ms | 6/6 |
| p95 | 58.267 ms | 45.540 ms | 6/6 |
| p99 | 63.607 ms | 51.024 ms | 6/6 |
| GUI CPU/measured input | 17.483 ms | 9.240 ms | 6/6 |
| GUI peak RSS | 206.26 MiB | 216.33 MiB | 1/6 |

The roughly 10 MiB 1K peak increase is recorded as a memory/performance tradeoff,
not an automatic rejection. Existing quotas and owned-buffer lifetimes remain
intact. Resource summaries are `4k-resources-01.json` and `1k-resources-01.json`
under the experiment prefix.

The six fresh no-image pairs per layout completed in
`/tmp/telar-perf-shared-image-optical-text-pairs-01`:

| Layout / metric | Optical inline | Optical shared | Shared wins |
| --- | ---: | ---: | ---: |
| Single p50 | 29.267 ms | 29.270 ms | 4/6 |
| Single p95 | 37.345 ms | 37.271 ms | 4/6 |
| Single p99 | 39.278 ms | 39.934 ms | 4/6 |
| Splits p50 | 30.302 ms | 30.611 ms | 2/6 |
| Splits p95 | 37.439 ms | 38.160 ms | 1/6 |
| Splits p99 | 39.574 ms | 42.800 ms | 0/6 |
| Tabs p50 | 29.577 ms | 30.326 ms | 1/6 |
| Tabs p95 | 37.751 ms | 37.784 ms | 2/6 |
| Tabs p99 | 41.740 ms | 40.360 ms | 5/6 |

GUI CPU/input is 4.310 -> 4.250 ms in single (4/6), 4.610 -> 4.486 ms in
splits (2/6) and 4.426 -> 4.490 ms in tabs (3/6). No-image peak RSS remains
around 205–206 MiB. `text-resources-01.json` records the complete resources.
The isolated candidate is **rejected for consistent interaction regressions**,
particularly splits p99 and tabs p50, not for the allowed image-memory tradeoff.
The cause is not established. The frozen candidate, source and raw data remain
available; no fresh Zig comparison is claimed for it.

The next experiment combines this saved transport candidate with native pending
update delivery on the current cursor/optical base. The earlier `early-platform`
variant was tested before conditional cursor invalidation, so the combination
tests a different amount of unnecessary rendering. It must pass the native
pending-update, cadence, visibility and input oracles, then fresh control/image
pairs against the accepted optical build. Neither earlier latency win excuses
the current tails, and the combination is not an accepted production change.

### Combined pending-update experiment

`out-perf/shared-image-optical-early` freezes that combined candidate separately.
GUI SHA-256:
`c2c737ab39caae68e7dc0c4fdee0b3037afc43e2e0dacd1725ee5ae34361e319`.
The runtime remains the same C++ binary; the previous shared-only stage is intact.
Nine focused CTest entries pass, including native Cocoa pending-update consumption,
coalescence and requests made during delivery, frame pacing/cancellation, shared
images, remote connections and graphics retention/recovery. Native Metal Kitty,
terminal input, synchronization and cursor-phase checks also pass.

A separate `QSG_RENDER_TIMING=1` diagnostic in
`/tmp/telar-perf-shared-image-optical-early-render-01`, with 100 measured inputs
after 20 warmups, counts 166 rendered frames for the accepted optical baseline
and 162 for the combination, including startup. This does not reproduce the
duplicate-render explosion of the old direct-event variant. These instrumented
durations are not timing acceptance; the counts do not measure native cadence.
The uninstrumented six-pair single/splits/tabs control series in
`/tmp/telar-perf-shared-image-optical-early-text-pairs-01` has completed,
with 100 measured inputs after 20 warmups in each
run. Against the accepted optical baseline, the combined candidate wins all six
pairs for p50, p95 and p99 in each layout:

| Layout | Median p50 A → B (ms) | Median p95 A → B (ms) | Median p99 A → B (ms) | GUI CPU/input A → B (ms), wins |
| --- | --- | --- | --- | --- |
| Single | 29.022 → 25.324 | 37.988 → 32.172 | 41.093 → 35.124 | 4.122 → 4.107, 4/6 |
| Splits | 30.299 → 25.407 | 37.640 → 32.708 | 41.350 → 34.498 | 4.718 → 4.357, 6/6 |
| Tabs | 30.167 → 25.263 | 37.744 → 31.553 | 41.325 → 34.164 | 4.727 → 4.130, 5/6 |

GUI peak RSS medians are respectively 204.211 → 204.438, 205.313 → 204.555
and 210.758 → 205.758 MiB; pair wins are mixed. The resource calculation uses
the 100 measured inputs, excluding warmup CPU. Raw runs and `summary.json` are
in the directory above; resource results are frozen in
`out-perf/shared-image-optical-early/text-resources-01.json`.
This qualifies the isolated-input controls only. The candidate remains
uncommitted pending fixed-rate background-load controls, new 1K/4K image pairs
and a fresh independent Zig-stack comparison. The load fixture checks every
periodic producer checkpoint against the requested rate with 5% tolerance;
those checkpoints are not synchronized to individual input samples. These
latencies do not establish sustained native 120 Hz.

The first 1 MiB/s-per-producer load qualification stopped in the accepted optical
baseline, before a candidate run: one periodic checkpoint delivered
0.948003493 MiB/s, below the unchanged 0.95 minimum. All six requested native
input samples completed, but the workload gate failed, so this is not a valid
latency pair. All receipts remain in
`/tmp/telar-perf-shared-image-optical-early-load-qualification-01`. The cause of
the rate miss is not established. New single-pair, six-sample native image
qualifications for both 1024×1024 and 3840×2160 passed. No old shared-only image
timing is reused to qualify this binary.

The new six-pair 1K series completed in
`/tmp/telar-perf-shared-image-optical-early-1k-pairs-01`. With the same
100 measured inputs, 20 warmups, native presentation endpoint and optical text
configuration, A → B medians are p50 45.589 → 29.579 ms, p95
59.108 → 38.202 ms, p99 62.839 → 42.048 ms and maximum 70.027 → 45.910 ms.
Every latency metric wins 6/6. GUI CPU per measured input falls from 17.873
to 9.242 ms, also 6/6. GUI peak RSS rises from 204.039 to 228.328 MiB,
with no memory wins. This is an allowed memory-for-performance tradeoff,
not a reason to reject the candidate. These are whole-run peak RSS values,
not settled-memory or allocation-lifetime attribution. Resource results are in
`out-perf/shared-image-optical-early/1k-resources-01.json`.
The six-pair 4K series also completed in
`/tmp/telar-perf-shared-image-optical-early-4k-pairs-01`. Its A → B medians are
p50 137.404 → 45.746 ms, p95 147.469 → 53.782 ms, p99 153.881 → 56.494 ms
and maximum 156.804 → 58.256 ms, all winning 6/6. GUI CPU per measured input
falls from 89.165 to 31.110 ms, also 6/6. GUI peak RSS medians are
351.805 → 366.969 MiB, with 3/6 pair wins; the raw resource summary is
`out-perf/shared-image-optical-early/4k-resources-01.json`.

A separate `load-diagnostic.py` controller is prepared to retain both variants'
observations even if a producer misses its offered rate. It preserves the same
5% gate and emits no paired timing summary for a case containing an invalid run.
The one-pair-per-layout load diagnostic with 100 measured inputs completed; the
failed qualification above remains part of the record. The tabs pair satisfies every periodic producer
rate check and has p50 30.404 → 25.013 ms and p99 38.301 → 35.772 ms. It is
one pair, not acceptance. In splits, A misses the rate gate again (minimum
0.939829 MiB/s), while B meets it (minimum 0.953377 MiB/s). Their observed p50
values are 31.864 and 45.743 ms respectively, but unequal qualified work prevents
a valid latency comparison. This is a warning to investigate, not proof of the
regression's cause. A separate `QSG_RENDER_TIMING=1` split-load diagnostic in
`/tmp/telar-perf-shared-image-optical-early-load-render-01` also misses rate gates.
It counts 1535 → 1787 frames including startup, with different measurement
durations (8.238 → 9.500 seconds); those totals alone do not prove excess frame
rate. Both diagnostics show larger input-to-GPU and GPU-to-presentation intervals
for B. Raw work/phase summaries are in
`out-perf/shared-image-optical-early/load-work-counts-01.json`. The candidate is
not accepted.

`out-perf/shared-image-optical-input` starts a separate experiment that requests
early native delivery only for a newer frame from the visible pane/attachment
with active input grace. Other output retains the original platform scheduling;
an already deferred frame still considers the full visible set. This removes the
new all-pane snapshot from the ordinary nonpending output path. Tests cover old
frames, another pane, attachment generations, detachment, expiration, visibility,
coalescence and native requests made during delivery. Its fresh build completed;
all nine focused CTest entries pass, as do native Metal Kitty, input,
synchronization and cursor-phase checks. An initial compile failure caught stale
test calls to the superseded adapter method; the native oracle now supplies a
matching newer input frame and still checks pending-request consumption,
coalescence and reentrant platform requests. The earlier binaries and source
snapshots remain frozen.

The new GUI SHA-256 is
`3cf83d33cf2643e8d3826963197fb17df16c25de223fabed5687f24a3b9cb2b6`;
runtime/helper identities are unchanged. ARM64 `requestTerminalFrame` now uses
a 64-byte stack frame instead of the previous 2 KiB pane snapshot. Its
nonpending path checks the changed pane and input-grace eligibility; this is
work avoidance, not evidence about heap allocations.

The first new load diagnostic in
`/tmp/telar-perf-shared-image-optical-input-load-diagnostic-01` passes the offered
rate gate for all four runs. Splits p50 is 32.699 → 32.757 ms, p95
37.380 → 44.004 ms, p99 40.892 → 45.736 ms and GUI CPU/input
16.652 → 18.379 ms. Tabs p50 is 29.068 → 24.827 ms, p99
41.560 → 35.127 ms and CPU/input 4.538 → 3.729 ms. These are one-pair
observations; they do not establish consistent gains or losses. A six-pair
alternating load series completed in
`/tmp/telar-perf-shared-image-optical-input-load-pairs-01` to resolve the split
tail warning. Only round 0 in splits and rounds 1–4 in tabs satisfy the offered
rate gate for both variants. The split pair loses p50/p95/p99 (30.608 → 32.700,
35.656 → 38.589 and 38.329 → 41.097 ms). Among the four valid tabs pairs,
p50 and p95 win 4/4, but p99 wins only 2/4. GUI CPU/input wins 1/1 in splits
and 4/4 in tabs; these insufficient subsets do not qualify acceptance. Exact
valid rounds, excluded rows and resources are retained in
`load-qualified-subset-01.json` and `load-qualified-resources-01.json` under the
experiment prefix. Invalid rate runs remain visible and cannot qualify timing.

`out-perf/background-rate-diagnostic` instruments the producer's existing
dropped-slot policy without changing deadlines or rates. Twenty-one exact
old/new policy checks pass. The one-pair splits/tabs diagnostic records both
pre-write scheduling lateness and elapsed PTY-write durations that consume a
slot. Across its four runs it records 57, 88, 51 and 34 missed slots; most need
the combined pre-write and write time to exceed the slot. Maximum elapsed writes
range from 6.878 to 10.664 ms. These are instrumented observations, and elapsed
time inside `write` cannot distinguish kernel blocking from descheduling.

A separate five-second GUI/runtime sample during 200-input split load completed
with both process identities checked. The runtime main thread appears in
`kevent` in 3415 of 3731 samples; this does not support CPU saturation as the
explanation for the rate failures. It also does not exclude intermittent stalls.
The profiles and receipt are in `out-perf/background-rate-diagnostic`. A direct
PTY-sink control using the same three producers, matched grids and unchanged
1 MiB/s rate passes all periodic gates over twelve seconds, with per-producer
minimum rates 0.976, 0.971 and 0.969 MiB/s. This single control localizes further
investigation but does not establish a production bottleneck or performance win.

### First continuous native cadence diagnostic

`out-perf/native-cadence-prototype` reuses a frozen copy of the existing native
setup, queue filtering, Metal/Metal 4 pixel readback and presentation observation.
After 20 qualified input warmups, a separate fixture emits a 12-bit sequence in
one cell's exact truecolor background at 240 updates/s. A one-second stream
warmup precedes a six-second observation window. Only exact decoded sequence
pixels on drawables with positive `MTLDrawable.presentedTime` contribute. This
tests a minimal continuous terminal update, not scroll, resize or a full TUI.

The first diagnostic (`/tmp/telar-perf-native-cadence-prototype-01`) observes
671 changed frames for accepted optical C++, 691 for the combined candidate and
658 for the independent original Zig stack. Rates between the first and last
changed frames are 111.823, 115.161 and 109.806 changes/s. Each has an 8.333 ms
median native interval; p99 intervals are approximately 16.667 ms. Longest gaps
are 16.667, 25.000 and 16.668 ms. There is one repeated-content drawable in the
candidate. These are single diagnostic runs, not paired timing acceptance or
proof of sustained 120 Hz across the requested flows.

Offline analysis verifies producer receipts cover each observation window and
every half-second contains 119–121 accepted updates (120 expected), within the
unchanged 5% tolerance. Presented sequence writes precede their native timestamps.
Eleven offline negative controls reject zero/stale presentation, invalid pixels,
unknown sequences, duplicate drawables/producer entries, incomplete receipts,
wrong offered rate, overflow, disabled VSync and missing initial presentation.
Their receipt is `out-perf/native-cadence-prototype/negative-controls-01.json`.
Live fault injection, contemporaneous display-reference qualification, frozen
missed-refresh classification, overhead and representative motion remain open.

`out-perf/native-cadence-display` adds a simultaneous Core Video reference for
the window's actual display. Four classifier checks cover 120 Hz, 60 Hz on a
120 Hz reference, multi-period stalls and invalid/unaligned intervals. The
0.25 ms interval residual tolerance was fixed before its first native run.
All four runs in `/tmp/telar-perf-native-cadence-display-01` have verified native
sequence pixels, valid producer rates and a same-display reference containing
720 opportunities in six seconds at approximately 120 Hz. Changed-frame rates
over the full window are 112.667/s for accepted optical C++, 115.333/s for the
unscoped early-delivery candidate, 111.333/s for input-scoped delivery and
111.500/s for Zig. Each has roughly 16.667 ms p99 intervals.

The unscoped candidate and Zig classify 28 and 51 missing refresh opportunities
between content changes respectively. Accepted optical C++ and the input-scoped
candidate include an interval that does not align with whole reference periods;
one is 20.833 ms. Their missed-opportunity classification remains unresolved,
with the original tolerance intact. `reanalysis-02.json` separates valid native
content/reference observations from that classification failure; the initial
summary had combined the two statuses. No row establishes overall 120 Hz
acceptance. Live negative controls, instrument overhead, repeated pairs and
representative motion still need qualification.

### Drawable-depth diagnostic

The split-load phase observations motivate checking queued drawable depth.
`out-perf/drawable-depth` freezes a separate probe comparing the same accepted
optical C++ GUI/runtime binary with its existing layer policy versus a two-drawable
pool. The short native qualification observes three drawables in the default
policy and exactly two after the requested override; both complete their
initial-content and presented-pixel checks. This is an instrumented policy
experiment, not a production change. A 100-input diagnostic pair for single,
split-load and tab-load cases completed in
`/tmp/telar-perf-drawable-depth-load-diagnostic-01`. Single p50/p99 worsen from
29.085/39.564 to 30.215/41.347 ms and CPU/input from 4.431 to 4.741 ms. The
valid split-load pair improves p50/p99 from 30.529/42.247 to 29.050/37.378 ms,
but CPU/input rises from 16.258 to 18.291 ms. The tab-load pair is invalid
because the two-drawable run misses the rate gate. One mixed diagnostic pair
does not justify a production drawable-depth change; the hypothesis is left
unaccepted and the default policy is preserved in all production candidates.

The next isolated source experiment is `out-perf/shared-image-optical-idle`.
It retains the shared-image path and input/attachment eligibility, but allows
early native delivery only after two frame intervals without an actual prepared
frame. The ordinary pacing anchor and input-grace behavior are unchanged;
a separate optional preparation timestamp prevents the ideal cadence anchor
from masquerading as idle time. Tests add a busy-window case that must still
receive the original platform event and an exact idle-threshold boundary.
The fresh Release build completed. All nine focused CTest entries passed in
23.97 seconds, including the idle threshold and continuous-rendering cases.
The four native Quick cases for images, input, scene synchronization and cursor
restoration also passed. Staged GUI SHA-256 is
`995aae4b038695f98d7b96612b1e358da59ee3f823f7079e1bb49707ead5c34c`;
runtime and command helper remain identical to the accepted optical build.
The source, binary and validation receipts are frozen in that prefix.

The first diagnostic invocation completed single-A natively, then its
load-only reporting code raised `KeyError: background_load` on that non-load
row. Its controller, manifest, native result and failure log are retained in
`/tmp/telar-perf-shared-image-optical-idle-load-diagnostic-01`; it is not a pair.
The subsequent load-only invocation completed all four planned runs in
`/tmp/telar-perf-shared-image-optical-idle-load-diagnostic-02`. Split-load A
missed the unchanged rate gate (minimum 0.949573 MiB/s), while B passed
(0.956081). Tab-load A and B both missed it (0.931434 and 0.947318).
Neither load comparison qualifies for timing acceptance. Six alternating
no-load text pairs per case completed separately with the normal controller in
`/tmp/telar-perf-shared-image-optical-idle-text-pairs-01`:

| No-load case | p50 A → B, ms | p95 A → B, ms | p99 A → B, ms | B wins, p50/p95/p99 |
| --- | ---: | ---: | ---: | ---: |
| Single | 29.276 → 25.036 | 38.166 → 33.102 | 41.282 → 36.639 | 6/6, 6/6, 5/6 |
| Splits | 31.610 → 26.315 | 39.024 → 32.342 | 41.485 → 36.382 | 6/6, 6/6, 6/6 |
| Tabs | 30.352 → 25.404 | 38.922 → 33.032 | 42.708 → 36.178 | 6/6, 6/6, 6/6 |

GUI CPU per measured input falls from 4.545 to 3.966 ms in single (6/6),
4.766 to 4.567 ms in splits (5/6), and 4.593 to 4.174 ms in tabs (5/6).
Median peak GUI RSS is 205.766 → 204.664 MiB, 204.156 → 206.258 MiB,
and 204.977 → 204.820 MiB respectively; pairwise RSS wins are mixed.
The 100-input CPU denominator excludes the 20 warmup inputs. These results
support the no-load text controls but do not accept the full candidate:
fixed-load controls, fresh image pairs, independent Zig-stack comparisons and
the full native cadence contract remain open. Memory growth alone is not a veto.

The earlier unscoped build's ARM64 disassembly verifies the pending-state
predicate followed by virtual platform delivery. It also exposes a repeated
2 KiB default initialization of 64 pane records in `requestTerminalFrame`.
That is bounded stack work, not a demonstrated heap allocation. The later
input-scoped and idle-gated variants separate changed-pane eligibility from
pending-deadline snapshots; both retain a 64-byte stack frame in that path.
The frozen assemblies identify each version separately.

### Repeated font coverage and shaping work

Source inspection confirms that `RowTextLayout::appendAlone` asks
`FontCoverage::covers` before checking its existing ASCII glyph cache.
That check reaches `FT_Get_Char_Index` even for a glyph already proven present
in the same face and pixel height. `out-perf/ascii-coverage-cache` prepares a
separate component candidate that checks the existing glyph first. It adds no
storage and retains the existing face, height and explicit reset invalidation.
After the full-client series finished, both component variants built and passed
the focused row tests. The 256-row warm-output oracle matches glyphs, spans and
cell ranges exactly through font, size, cursor and selection changes. The new
probe also matches all 7,494 frozen original-Zig cases across three bundled
faces byte for byte. The initial scratch benchmark compile failure was limited
to missing namespace qualification; its source and log are retained separately.

Seven alternating component pairs use 256 warmup rows followed by 20,000
measured rows of 256 cells. Full source, binary identities and results are in
`out-perf/ascii-coverage-cache`; no full-client timing ran concurrently:

| Row workload | Wall A → B, ms | CPU A → B, ms | B wins, wall/CPU |
| --- | ---: | ---: | ---: |
| ASCII | 225.886 → 84.411 | 225.844 → 84.369 | 7/7, 7/7 |
| Ligatures | 3964.280 → 3965.610 | 3960.080 → 3958.640 | 4/7, 4/7 |
| Mixed ASCII and combining marks | 756.974 → 716.196 | 756.593 → 715.982 | 7/7, 7/7 |
| Font and height changes | 271.460 → 198.959 | 271.384 → 198.902 | 7/7, 7/7 |

The target component wins without a consistent loss in the ligature control.
ARM64 disassembly shows the cached-presence load and branch before the coverage
call; a hit appends the stored glyph directly. The A/B x86-64 and x86-64-v3
objects also compile and their lowering is retained. Those objects do not prove
Rosetta or Linux execution. The existing cache stores the proof of coverage;
this is removed repeated work, not fewer allocations or a new cache budget.

The small source change is now included in the separate integrated candidate
`out-perf/shared-image-optical-coverage`, on top of shared images and idle-gated
native delivery. Seventeen source files and the component receipts are frozen.
Its fresh GUI build completed with SHA-256
`6ce2ae46f435ef93ecfc72f7ef65a126b6ff37a426e5bc445f34317deaecb8f8`;
runtime and helper hashes remain unchanged. All twelve focused CTest entries
passed in 25.24 seconds, the four native Quick cases passed, and the new
integrated row probe matches all 7,494 original-Zig cases. Fresh independent
Zig-stack comparisons are next. The component result is not yet an integrated
latency, cadence or full-flow acceptance result.

A larger algorithmic lead is shaping-result reuse. Original Zig's
`ShapingCache` owns bounded short-run results keyed by text, face and height;
the uncached C++ `Face::shape` validates UTF-8, resets the HarfBuzz buffer and
calls `hb_shape` on every call. The row layer already caches individual ASCII
glyphs, so that existing reuse must not be counted as repeated shaping work.
Short ligature runs, fallback text and chrome are candidates for a separate
work census and bounded cache experiment. Additional memory is allowed when
it saves measured work; the oracle must retain clusters, direction, positions,
face/height identity and borrowed-result lifetime.

### Fresh coverage candidate versus original Zig

Six alternating pairs per no-load text case completed in
`/tmp/telar-perf-shared-image-optical-coverage-zig-text-pairs-01`. A is original
Zig GUI plus its own Zig runtime; B is the integrated coverage candidate GUI
`6ce2ae46f435ef93ecfc72f7ef65a126b6ff37a426e5bc445f34317deaecb8f8`
plus the unchanged accepted C++ runtime. Both have matched grids, thicken=true,
100 measured inputs after 20 warmups and verified positive native presentations.

| Case | p50 Zig → C++, ms | p95 Zig → C++, ms | p99 Zig → C++, ms | C++ wins, p50/p95/p99 |
| --- | ---: | ---: | ---: | ---: |
| Single | 25.990 → 25.030 | 33.613 → 32.336 | 39.087 → 34.606 | 5/6, 6/6, 5/6 |
| Splits | 26.065 → 25.822 | 33.398 → 32.304 | 37.318 → 34.650 | 3/6, 4/6, 6/6 |
| Tabs | 26.304 → 26.175 | 33.328 → 32.376 | 36.816 → 34.673 | 3/6, 5/6, 4/6 |

Single-window latency meets the paired win rule, but splits/tabs do not win
their medians consistently. GUI CPU/input is higher in all six pairs of each
case: 3.582 → 4.079 ms in single, 3.712 → 4.403 ms in splits and
3.616 → 4.172 ms in tabs. Median peak GUI RSS is 124.367 → 204.953 MiB,
124.367 → 205.406 MiB and 131.188 → 204.109 MiB respectively. These are
separate GUI process measurements; they do not establish runtime CPU parity.
Memory growth is recorded as an allowed tradeoff, not a standalone rejection.
F03/F07/F08 and the full matrix remain open, including their other variants and
cadence requirements. The full raw series and resource summary are retained.

### Bounded shaping-result reuse

`out-perf/shaping-result-cache` freezes an initial optional per-face cache for
short shaping results. It preserves exact UTF-8 bytes, pixel height, glyph
clusters/positions and direction, uses four-way bounded replacement, and falls
back to ordinary shaping if its optional allocation fails. Long text and
oversized results bypass insertion. The first new oracle attempt incorrectly
expected `std::invalid_argument` for invalid UTF-8; the unchanged baseline
instead throws `EncodingError`. That harness error and its partial output are
preserved; the corrected oracle passes for A and B.

This first cache wins all seven target component pairs but loses six of seven
in the nonrepeating short-label control (402.106 → 405.525 ms for 50,000
requests). It is rejected for that consistent timing loss. The source adds
lookup and insertion work on misses; its exact contribution versus code/layout
effects is not established. The rejection is not because of additional memory.

`out-perf/shaping-result-cache-tags` keeps full fingerprints in compact metadata
and reuses the computed key, reading large entry payloads only after a key
match. A full text/height comparison still decides a hit. A forced-collision
build maps every key to one fingerprint and one four-way set; its 5,366,254-byte
output remains identical to the uncached reference. Warm/cold outputs, eviction,
font/height changes, RTL direction, long-input bypass, invalid requests and
optional-allocation failure all pass, as do the existing 7,494 original-Zig
row cases. The reusable `gui-shaping-cache-test` independently compares results
against newly constructed faces across three bundled fonts and verifies that
a failed optional allocation is not retried on every request.

Seven uninstrumented alternating pairs compare this revised cache with the
uncached coverage candidate. Row cases measure 20,000 256-cell rows after 256
warmups; direct shaping cases measure 50,000 calls after 1,024 warmups:

| Component | Wall A → B, ms | CPU A → B, ms | B wins, wall/CPU |
| --- | ---: | ---: | ---: |
| ASCII rows | 84.190 → 84.244 | 84.163 → 84.223 | 2/7, 2/7 |
| Ligature rows | 3960.390 → 583.448 | 3954.520 → 583.218 | 7/7, 7/7 |
| Mixed ASCII/combining rows | 715.227 → 145.315 | 714.935 → 145.293 | 7/7, 7/7 |
| Font/height-changing rows | 200.102 → 92.768 | 200.011 → 92.760 | 7/7, 7/7 |
| Repeated short labels | 368.910 → 0.836 | 368.837 → 0.840 | 7/7, 7/7 |
| Labels at four heights | 370.730 → 0.938 | 370.594 → 0.943 | 7/7, 7/7 |
| Nonrepeating short labels | 401.683 → 402.655 | 401.545 → 402.499 | 3/7, 3/7 |
| Long text bypass | 243.562 → 243.430 | 243.451 → 243.323 | 4/7, 4/7 |

The target cases pass the component rule, with no 0–1/7 timing control loss.
The first variant's nonrepeating-control warning is retained rather than hidden
by the revised measurements. In a separate instrumented census, including
warmup and 2,000 measured requests/rows, repeated labels reduce Face-owned
`hb_shape` calls from 3,024 to 8, four-height labels to 32, ligature rows from
19,960 to 3,480, combining rows from 144,385 to 2, and font-changing rows from
36,096 to 96. ASCII rows retain 63 calls; nonrepeating and long-label cases
retain 3,024. These counts establish work removal, not native frame latency.

ARM64 lowering allocates 675,904 bytes lazily per participating face, initializes
only 2,112 metadata bytes and publishes entry keys after copying valid payload
prefixes. Peak process RSS increases by 112 KiB for repeated labels, 400 KiB for
four-height labels and 624 KiB for the churn control. Those standalone process
differences are not an estimate of aggregate GUI memory. A/B x86-64 and x86-64-v3
objects compile; Rosetta and Linux native execution remain unqualified.

The revised cache is now part of the separate integrated candidate
`out-perf/shared-image-optical-shaping`, preserving shared images, idle-gated
native delivery and the ASCII coverage fast path. Twenty source files are
frozen. The fresh GUI has SHA-256
`d7f7086b0846601c6dcb2f5a078ab81797970335cffccc1bb898b0b4ee4b3aca`;
runtime and helper hashes are unchanged. All thirteen focused CTest entries
pass in 26.08 seconds, the four native Quick cases pass, and the integrated row
probe matches all 7,494 original-Zig cases. Fresh native latency, resources and
cadence still require evidence; no flow is closed by the component result.

A fresh final-source repeat after lint cleanup is retained separately at
`out-perf/shaping-result-cache-clean`. Its exact-output, forced-collision and
allocation-failure checks pass, as do targeted clang-tidy and x86-64/v3 object
compilation. However, the churn control loses all seven wall and CPU pairs:
401.538 → 403.272 ms wall and 401.353 → 403.102 ms CPU. This variant is rejected
under the existing rule; the earlier tag-cache series does not override that
result. The integrated `d7f7086…` binary contains the earlier source and has not
been measured as if it contained the lint-clean revision.

The successor experiment, `out-perf/shaping-result-cache-adaptive`, suppresses
lookup and insertion after 64 consecutive misses and probes every 32nd eligible
request until a hit restores normal caching. It adds distinct-text and
unique-to-repeated phase controls, so a cyclic working set larger than capacity
is no longer described as fully nonrepeating. Before timing, all existing
oracles and 7,494 original-Zig cases pass, including forced hash collisions and
optional allocation failure. A separate census preserves all 3,024 HarfBuzz
calls for genuinely unique input and reduces 1,000 recovery-phase requests to
62 HarfBuzz calls. These are work counts, not native presentation measurements.

The adaptive component completes seven alternating pairs with no consistent
wall or CPU control regression. Medians below exclude setup and warmup; row
cases use 20,000 iterations and direct cases use 50,000 requests.

| Case | Wall ms A → B | CPU ms A → B | Wall / CPU wins |
| --- | ---: | ---: | ---: |
| row-bench/ascii | 84.266 → 84.340 | 84.262 → 84.323 | 4/7 / 2/7 |
| row-bench/ligatures | 3958.160 → 586.398 | 3954.560 → 586.050 | 7/7 / 7/7 |
| row-bench/unicode | 715.864 → 145.870 | 715.528 → 145.828 | 7/7 / 7/7 |
| row-bench/font-change | 199.333 → 92.839 | 199.253 → 92.813 | 7/7 / 7/7 |
| shape-bench/repeated | 368.201 → 0.844 | 368.081 → 0.851 | 7/7 / 7/7 |
| shape-bench/heights | 370.877 → 0.970 | 370.701 → 0.976 | 7/7 / 7/7 |
| shape-bench/churn | 402.151 → 385.472 | 401.964 → 385.091 | 6/7 / 6/7 |
| shape-bench/long | 242.394 → 241.953 | 242.316 → 241.886 | 5/7 / 5/7 |
| shape-bench/unique | 423.903 → 423.477 | 423.786 → 423.207 | 3/7 / 4/7 |
| shape-bench/phase-switch | 444.335 → 212.309 | 444.142 → 212.236 | 7/7 / 7/7 |

Median standalone peak RSS increases by 144 KiB for repeated labels, 432 KiB
for four-height labels, 672 KiB for genuinely unique text and 688 KiB for the
phase switch. Long-input bypass has equal median RSS. These bounded memory
costs are accepted for the work saved; native GUI/runtime resources remain a
separate measurement. ARM64 disassembly shows a 675,912-byte optional allocation,
2,115 metadata bytes cleared, a 144-byte shape stack frame and a skip-byte
load/decrement/store that bypasses hashing and cache copies in the sampled mode.
A cache hit returns borrowed glyph/position prefixes without payload copies or
HarfBuzz. Both x86-64 baseline and v3 objects compile; those objects are not a
Rosetta or Linux runtime qualification. The source passes targeted clang-tidy.
The successor
integrated build is frozen under `out-perf/shared-image-optical-adaptive`; it
adds a reusable phase-transition equivalence test. Its GUI SHA-256 is
`cff34db828bb3cca2627e4b8785ba5262563adeb74a9c2f69497ce404bda290e`;
the runtime and helper hashes remain unchanged. Thirteen focused CTest entries
pass in 26.43 seconds, all four native Metal Quick cases pass in 1.568 seconds,
and the fresh integrated probe matches all 7,494 original-Zig cases. The Face
object is byte-identical to the measured adaptive component object (SHA-256
`5971e6ffae7b64306b527d0890759133a33804ba3bc011cd07c5156ee243fdc6`).
Six alternating native text pairs against the preceding coverage candidate are
running under `/tmp/telar-perf-shared-image-optical-adaptive-coverage-text-pairs-01`.
No F01–F16 flow is closed by these component or correctness results.

The six-pair native adaptive series subsequently completes and **rejects the
integrated shaping-cache candidate**. Against the preceding coverage build,
median p50 is 24.871 → 25.063 ms for one panel (1/6 wins), 25.981 → 25.475 ms
for splits (4/6), and 25.407 → 25.798 ms for tabs (2/6). The corresponding
p95 win counts are 3/6, 2/6 and 4/6; p99 wins 4/6 in all three. GUI CPU/input
changes from 3.789 → 4.005 ms for one panel (1/6), 4.395 → 4.007 ms for splits
(4/6), and 3.983 → 4.119 ms for tabs (1/6). Peak GUI RSS medians are
205.563 → 206.773, 204.398 → 213.172 and 203.836 → 206.641 MiB respectively.
Memory is reported as an allowed tradeoff, not the rejection reason. The latency
and CPU controls fail the unchanged rule; their cause is not established.
The general Face cache and its registered test are withdrawn from active source,
while the independently validated ASCII coverage fast path remains. Commit
`e2a9dbc02d13b97e79d98537b7e270c6fb0812f5` and all frozen variants preserve the
experiment. Future cache work should avoid duplicating the existing single-ASCII
glyph cache and measure native shaping workloads before reconsideration.

### Image conversion profile and BGRA candidate

`out-perf/image-upload-profile` freezes matched, independent C++ and Zig stacks
for 200 measured 4K image replacements plus 20 warmups. The image supplies the
verified marker, with positive native presentation timestamps. Five-second,
1 ms sampling profiles attach only after verifying each owned process identity.
Both diagnostic runs and all four samplers finish successfully. Their latency
numbers are profiling diagnostics, not paired acceptance evidence.

In the C++ GUI sample, 154 render-thread observations reach
`ImageResource::upload → QImage::convertToFormat_helper → convert_generic` and
wait for Qt's conversion workers. Across five pooled workers, 488 leaf samples
are in `fetchRGBA8888ToARGB32PM_neon` and 272 in
`storeRGBA8888PMFromARGB32PM`; another observation is worker setup. An additional
125 render-thread samples reach a memory copy inside
`QRhiMetal::enqueueSubresUpload`. These counts identify conversion and staging
work, not allocation counts or percentages of frame latency. The C++ runtime
media worker has 54 observations in its checked shared-image kernel copy; its
main thread spends 3,730/3,734 observations in `kevent`. The independent Zig GUI
has 190 upload-worker observations under native Metal texture replacement.

The next candidate converts directly to Qt's native ARGB32 premultiplied image
and uses a BGRA8 texture on little-endian targets only when the backend reports
support. Other targets retain the RGBA8 path; the software fallback remains
unchanged. Texture reuse checks size and format. This removes an avoidable
channel reordering while retaining Qt's alpha conversion and owned pixel lifetime.
`out-perf/image-bgra-conversion` first verifies all 65,536 alpha/channel
combinations plus twelve odd-stride RGB/RGBA images, with exact channel equality
and unchanged input. Seven alternating pairs then produce these per-conversion
medians (1K uses 128 iterations and 4K uses 32; eight warmups excluded):

| Input / size | Wall ms A → B | CPU ms A → B | Wall / CPU wins |
| --- | ---: | ---: | ---: |
| opaque/1024x1024 | 0.270 → 0.094 | 1.061 → 0.317 | 7/7 / 7/7 |
| opaque/3840x2160 | 1.691 → 0.680 | 8.181 → 3.200 | 7/7 / 7/7 |
| alpha/1024x1024 | 0.291 → 0.115 | 1.144 → 0.398 | 7/7 / 7/7 |
| alpha/3840x2160 | 1.832 → 0.732 | 8.868 → 3.454 | 7/7 / 7/7 |
| rgb/1024x1024 | 0.253 → 0.075 | 0.253 → 0.075 | 7/7 / 7/7 |
| rgb/3840x2160 | 1.974 → 0.952 | 1.974 → 0.952 | 7/7 / 7/7 |

The fresh integrated BGRA candidate is frozen under
`out-perf/shared-image-optical-bgra` from the preceding coverage objects, with
only `image_resource.cpp.o` replaced in a copied archive and dependent binaries
relinked. Its recipe records every reused link input and command. The GUI SHA-256
is `07acd71ebd4b469b4564496fcf4f54d7a4ecb2782ad7c18c814cc405ecdd47d6`;
runtime and helper hashes are unchanged. Targeted clang-tidy and x86-64/v3 object
compilation pass; native Linux and Rosetta execution remain unqualified.

All twelve focused CTest cases pass. The initial isolated prefix omitted the
unchanged SSH fixture executable, causing the remote-connection test to time out;
that first failure is retained, the dependency is staged and only the failed test
is rerun. Four native Metal Quick cases pass, and the row probe still matches all
7,494 original-Zig cases. Eleven additional native image cases pass on both the
coverage and BGRA binaries, with every distinct captured RGBA image identical.
They cover RGB, straight alpha, incomplete/replaced generations, retained geometry,
placeholders, catalog lifetimes, shared textures, spare reuse and clipping. Logs
confirm the actual Metal backend on Apple M1 Pro. Static captures do not prove
presentation latency or cadence.

Six alternating 4K full-client pairs are running under
`/tmp/telar-perf-shared-image-optical-bgra-coverage-4k-pairs-01`. Further 1K,
non-image controls, independent Zig comparison, fixed-load and cadence evidence
remain open; no F01–F16 flow is closed by this candidate yet.

The BGRA native series completes and **rejects this variant**. Median 4K p50
changes 48.298 → 47.187 ms (4/6 wins), but p95 worsens 59.028 → 62.093 ms
(1/6) and p99 62.553 → 69.218 ms (0/6); the maximum also loses all six pairs.
GUI CPU/input improves 31.323 → 28.202 ms (6/6), while median peak GUI RSS is
366.758 → 367.195 MiB. The rejection is the consistent visible-tail regression,
not the allowed memory tradeoff. Source is withdrawn and frozen evidence remains.

`coverage-4k-decomposition-01.json` separates the endpoints. Median per-run p99
GPU execution is almost equal (9.121 → 9.126 ms), while p99 from input to the
verified GPU completion callback worsens 38.766 → 45.612 ms. The median per-run
p99 of presentedTime minus callback time is 28.126 → 27.079 ms. The tail is
already present before that callback; these observations do not establish whether
conversion scheduling, CPU work or another wait caused it, and do not prove a
BGRA GPU execution problem.

### Native premultiplication with RGBA textures retained

The successor `out-perf/image-native-premultiply` keeps the original RGBA8 GPU
texture format. On little-endian targets RGBA8888 and native ARGB32 place alpha in
the same byte, and channelwise premultiplication commutes with swapping red/blue.
A temporary read-only ARGB-labelled view selects Qt's native premultiplication
path; only the newly owned result is relabelled RGBA8888 premultiplied. No input
bytes are changed and no channel-reordering pass is required. Other input formats
and big-endian targets keep the original conversion path.

The component matches all 65,536 alpha/channel combinations and twelve odd-stride
RGB/RGBA images. A separate ownership oracle verifies twenty-four format/alpha
cases: output never aliases the input allocation and survives direct overwriting
of the original buffer. Seven alternating pairs give these per-conversion medians:

| Input / size | Wall ms A → B | CPU ms A → B | Wall / CPU wins |
| --- | ---: | ---: | ---: |
| opaque/1024x1024 | 0.271 → 0.080 | 1.060 → 0.249 | 7/7 / 7/7 |
| opaque/3840x2160 | 1.699 → 0.643 | 8.191 → 3.004 | 7/7 / 7/7 |
| alpha/1024x1024 | 0.291 → 0.108 | 1.141 → 0.381 | 7/7 / 7/7 |
| alpha/3840x2160 | 1.829 → 0.735 | 8.866 → 3.471 | 7/7 / 7/7 |
| rgb/1024x1024 | 0.253 → 0.253 | 0.253 → 0.253 | 4/7 / 4/7 |
| rgb/3840x2160 | 1.980 → 1.975 | 1.979 → 1.975 | 4/7 / 4/7 |

The integrated candidate `out-perf/shared-image-optical-native-premultiply`
replaces only the image-resource object in a copied coverage archive and relinks
its dependent executables. GUI SHA-256 is
`26767f531b227ed8e5110731b399a3cc9e178e75ad0df3d87ef5a69124474536`;
runtime and helper hashes are unchanged. Twelve focused tests pass in 25.25 s,
four native Quick cases in 1.595 s, all 7,494 original-Zig row cases match and the
eleven native image cases again produce exactly matching distinct captured RGBA
images. Targeted clang-tidy and x86-64/v3 object compilation pass. Rosetta and
Linux native execution remain unqualified.

Six fresh native 4K pairs complete in `/tmp/telar-perf-native-pm-4k-pairs-01`
and **reject this variant**. Median p50 changes 47.798 → 47.967 ms (3/6 wins),
p95 59.639 → 62.369 ms (0/6), p99 64.834 → 71.266 ms (0/6), and maximum
68.314 → 78.212 ms (1/6). GUI CPU/input improves 31.963 → 28.247 ms (6/6).
Median peak GUI RSS is 367.070 → 367.203 MiB (3/6); memory is not the rejection
criterion. The helper is withdrawn from the working tree, with source, binaries
and receipts retained in the frozen prefix. Keeping RGBA8 textures did not remove
the visible-tail regression, so changing to BGRA was not a necessary condition.

The first attempted directory name exceeded the UNIX socket path limit and was
rejected before runtime launch; that failure is retained separately. The new
short directory changes no workload or gate. Non-image controls, independent Zig,
fixed-load and sustained 120 Hz remain open.

Follow-up diagnostic profiles in `out-perf/image-native-premultiply-profile`
compare this candidate with the frozen coverage baseline on the same native 4K
workload. Both runners and all four owned-process samples complete successfully.
Both GUI profiles contain five Qt conversion workers, so they do not support the
hypothesis that the new path introduces more conversion threads. The baseline has
517 leaf samples in RGBA fetch/premultiplication and 242 in the channel store pass;
the candidate has 689 in native fetch/premultiplication and no channel store pass.
Render-thread observations in upload conversion change 155 → 138, and Metal
staging memmove observations 124 → 117. The profiles contain 3,744 and 3,752 samples
per persistent thread respectively. These are sampled stacks, not an allocation
census, exact durations, or paired latency acceptance. The tail's cause remains
unestablished. The next isolated diagnostic records input, image arrival,
conversion and frame preparation to test the graphics-only input-grace lead.

### Graphics-only input-grace diagnostic

`out-perf/image-pacing-trace` builds two isolated diagnostic GUIs from the frozen
coverage archive, replacing only three translation units and adding a bounded
event logger. It records input, requests, graphics revisions, preparation,
conversion, and deferral to 65,536 pre-faulted 64-byte slots in a private mapping.
Logging performs no per-event allocation or explicit file syscall. The original
build failure from a Qt `emit` macro/name collision is retained; the corrected
logger uses `logEvent`. No diagnostic code is added to the product sources.

Both native 4K runs complete 100 measured inputs after warmup with the original
pixel/presentation endpoint. The baseline and native-premultiply traces contain
1,704 and 1,729 complete events, without capacity exhaustion. Each of the last
100 input intervals contains exactly one upload and one conversion. Screen frame
ID stays at 7 while graphics revisions advance. In each variant, 99/100 inputs
have a changed graphics revision within the 30 ms input grace, at least two
display intervals since preparation, and no pending delivery, yet no new text
frame to satisfy `InputGrace::includes`. This identifies a missed eligibility
case; it does not establish the cause of the rejected conversion's tail.

| Diagnostic interval | Coverage p50 / p95 ms | Native premultiply p50 / p95 ms |
| --- | ---: | ---: |
| Input → first changed graphics request | 14.115 / 19.903 | 13.753 / 21.219 |
| First changed graphics request → upload | 4.848 / 8.271 | 4.140 / 7.711 |
| Upload entry → conversion return | 4.629 / 6.282 | 3.742 / 5.997 |

There are zero and one held UpdateRequest events in those input intervals;
ordinary platform delivery, rather than repeated explicit pacer deferral, is the
remaining scheduling lead. These are single diagnostic runs, not paired
acceptance or trace-overhead qualification, and the analysis joins no timestamps
across different clocks.

The next candidate `out-perf/shared-image-optical-graphics-grace` starts from
coverage, keeping the original Qt conversion. It extends the existing input
identity with the graphics revision, propagates it through input and prepared
frames, and requires a new non-regressing text/graphics state from the same
attachment. Idle, expiry, budget and native pending-event delivery limits remain
in place. Focused tests cover graphics-only wakeup, stale/detached output, expiry,
and budget exhaustion. A fresh complete GUI build passes; the changed public pane
layout is not linked with old objects. GUI SHA-256 is
`83d3898cf73bea55e9dc66be7a4329e5e4da0915cc89523848f96d7ee3258a12`, with
runtime and helper unchanged. Thirteen focused tests pass in 25.76 s, four native
Quick cases in 1.510 s, all 7,494 original-Zig row cases match, and eleven native
image cases produce matching distinct RGBA captures. ARM64, x86-64 and x86-64-v3
code generation compiles; inspected `canAdvance` is a leaf without stack storage
on all three. Native x86/Linux execution remains unqualified.

Touched-translation-unit clang-tidy is **not green**. The unchecked optional access
in `Application::requestTerminalFrame` and missing arithmetic parentheses in the
existing idle-test constant reproduce against baseline source with baseline Qt
generated files. The other diagnostics concern special members/nodiscard in
`login_shell.hpp`, special members in `shared_image_source.hpp`, and nesting in
`window_frame_pacer.hpp`; all three headers are byte-identical to the baseline.
The new session input-observation test passes lint. Counterfactual setup failures
(mixed include trees, a relocated vendor include, and mismatched generated test
slots) are retained separately; only corrected, parse-clean reproductions support
this classification. These existing diagnostics remain cleanup work, not a green
lint claim.

Six uninstrumented native 4K pairs complete in
`/tmp/telar-perf-graphics-grace-4k-01`, with no concurrent builds, tests or
profilers. The graphics-grace candidate wins all six pairs in p50, p95, p99 and
maximum: median per-run values change 48.672 → 45.749, 59.153 → 53.646,
62.848 → 57.527, and 65.292 → 61.761 ms respectively. GUI CPU/input changes
31.462 → 31.050 ms (4/6 wins); median peak GUI RSS is 367.086 → 367.133 MiB
(2/6). This is a successful 4K target measurement against coverage, with the
original Qt conversion retained, not full-flow or independent-Zig acceptance.

Six alternating pairs for each of single-pane input, four splits and four tabs
complete in `/tmp/telar-perf-graphics-grace-text-01`. These are the existing native
marker controls, not complete ASCII/Unicode/combining typing coverage for F03.

| Control | p50 ms A → B / wins | p95 ms A → B / wins | p99 ms A → B / wins | GUI CPU/input ms A → B / wins |
| --- | ---: | ---: | ---: | ---: |
| Single | 24.986 → 25.197 / 3/6 | 32.651 → 32.050 / 5/6 | 36.553 → 33.880 / 5/6 | 4.009 → 4.100 / 2/6 |
| Splits | 25.818 → 25.763 / 2/6 | 33.040 → 32.734 / 4/6 | 36.005 → 36.701 / 2/6 | 4.254 → 4.205 / 3/6 |
| Tabs | 25.587 → 25.997 / 3/6 | 32.678 → 32.989 / 2/6 | 36.788 → 35.975 / 4/6 | 4.363 → 4.288 / 5/6 |

No timing or CPU control has the 0–1 wins that rejects a candidate. Maximum-latency
wins are 5/6, 2/6 and 4/6 respectively. Median peak GUI RSS is 203.531 → 205.430,
206.727 → 204.711 and 205.063 → 205.367 MiB; the single-pane memory metric loses
all six pairs. That approximately 1.9 MiB increase is an allowed memory tradeoff,
not a timing acceptance waiver.

`out-perf/shared-image-optical-graphics-final` now rebuilds the final source after
lint cleanup. `login_shell::Command` explicitly remains noncopyable/nonmovable;
the shared image source retains its move-only descriptor ownership. The timeout
handler is flattened and the optional pacer is checked again at its use after
visibility queries. Existing arithmetic grouping is made explicit. The original
Qt image conversion remains unchanged. The final GUI SHA-256 is
`eb900cdecaabdde19110639367599449f5243caeb9f48cf26311030943c53c55`.
Thirteen focused tests pass in 25.37 s, four native Quick cases in 1.546 s, all
7,494 original-Zig row cases match, all eleven native image cases have identical
distinct RGBA captures, and all four touched translation units pass clang-tidy.
ARM64/x86-64/v3 code-generation checks also pass; native x86/Linux qualification
remains open.

`measure-final.py` now runs fresh 4K, 1K and three marker-layout controls against
coverage, then the same cases against the independent original Zig stack. Each
case requires six alternating pairs. The sequence stops for review on a consistent
timing/CPU regression against C++ coverage or an image target with fewer than 5/6
p50 wins; memory is reported separately. Earlier binary timings are not transferred
to this final binary. The paths start `/tmp/telar-perf-gfinal-`, and state/results
remain under the final prefix. Independent Zig, fixed-load and native 120 Hz gates
remain open. No F01–F16 flow is closed by this result.

The final binary completes its coverage image targets successfully:

| Image target | p50 ms A → B / wins | p95 ms A → B / wins | p99 ms A → B / wins | GUI CPU/input ms A → B / wins |
| --- | ---: | ---: | ---: | ---: |
| 4K | 47.622 → 45.740 / 6/6 | 58.811 → 53.008 / 6/6 | 62.637 → 57.268 / 6/6 | 31.405 → 30.911 / 5/6 |
| 1K | 37.223 → 29.973 / 6/6 | 45.887 → 40.380 / 6/6 | 49.757 → 43.604 / 6/6 | 9.548 → 9.457 / 6/6 |

Maximum latency also wins all six pairs at both sizes: 66.374 → 58.088 ms at 4K
and 54.378 → 46.797 ms at 1K. Median peak GUI RSS is 367.109 → 367.156 MiB and
218.891 → 222.203 MiB respectively; the approximately 3.3 MiB 1K increase is an
allowed memory tradeoff. These are complete C++ stacks against the coverage C++
stack. The retained-conversion prototype is absent from this binary.

The final-source marker controls have now completed and **reject this binary**:
the tabs control loses all six p99 pairs, five maximum-latency pairs and five GUI
CPU pairs. The sequence stopped with exit 2 before starting the independent Zig
comparisons. Raw evidence remains in `/tmp/telar-perf-gfinal-coverage-text-01` and
the final prefix's `measurement-state.json`; no earlier favorable run overrides
this final-build failure.

| Marker layout | p50 ms A → B / wins | p95 ms A → B / wins | p99 ms A → B / wins | GUI CPU/input ms A → B / wins |
| --- | ---: | ---: | ---: | ---: |
| Single | 25.366 → 25.590 / 3/6 | 32.906 → 32.658 / 3/6 | 36.451 → 36.619 / 3/6 | 4.146 → 3.890 / 4/6 |
| Splits | 25.678 → 26.098 / 2/6 | 33.163 → 33.068 / 3/6 | 37.040 → 37.223 / 2/6 | 4.286 → 4.331 / 4/6 |
| Tabs | 25.392 → 25.935 / 2/6 | 32.678 → 33.052 / 2/6 | 33.829 → 36.721 / 0/6 | 4.050 → 4.183 / 1/6 |

Tabs maximum latency is 35.316 → 37.869 ms, 1/6 wins. Peak RSS improves from
211.820 to 205.969 MiB, 5/6 wins; memory is not the rejection reason. The latency
decomposition gives tabs p99 input-to-GPU-completion callback 7.566 → 7.695 ms and
GPU work 2.916 → 3.059 ms, both 4/6 wins. These do not establish the cause of the
presentation-tail loss or justify a code-placement exception.

`out-perf/graphics-tabs-profile` retains two separate diagnostic executions and
four successful process samples, with exact GUI/runtime identities. Sampling
starts seven seconds after process availability, rather than a verified postwarmup
signal; the baseline sample includes QML object construction. Treat these as
mixed-phase leads, not a steady-state cost comparison or an allocation census.
Both show native input delivery, Qt update scheduling and rendering; the candidate
also samples ICC profile conversion below `QCocoaWindow::requestUpdate`. None of
this establishes that allocations or the pacer cause the regression.

### Bounded input-grace scan experiments

The pacer scans 64 optional entries even when only one has received input.
`out-perf/frame-pacer-active-prefix` limits scans to the initialized prefix while
preserving capacity, first-vacancy insertion and oldest-entry eviction. A frozen
reference comparison checks 1,920,000 decisions, including graphics/text revisions,
attachment generations, detached panes, capacity overflow, changing caps, clock
regression and unsigned timestamp boundaries: all outputs match exactly. Storage
changes from 4,136 to 4,144 bytes per pacer.

Seven alternating component pairs show wall ms 56.312 → 17.674 with one entry and
98.791 → 56.730 with four, both 7/7 wins. Empty controls win 3/7 and churn 7/7.
However, the full 64-entry case regresses 208.731 → 224.715 ms, 0/7 wall/CPU wins:
**this variant is rejected**, despite its smaller-case gains. One/four/empty/churn
use two million iterations; full uses 100,000, so these are not cross-case totals.
The next isolated `out-perf/frame-pacer-dense` variant removes optional-entry tests
inside the proven initialized prefix as well. It also passes the same oracle but
loses full-capacity wall/CPU timing 0/7, 207.464 → 224.557 ms: rejected.

`out-perf/frame-pacer-indexed` adds a bounded pane-id bucket index to the dense
prefix for large visible sets. This cuts the large `record` search from repeated
full scans to short bucket chains. All initial cases win 7/7, including full
209.461 → 100.139 ms. A deliberately colliding identity control then regresses
225.344 → 359.276 ms, 0/7 wall/CPU wins: this variant is also rejected. Its extra
collision oracle still matches; the problem is cost, not functional output.

`out-perf/frame-pacer-ordered` instead retains ordered indices and identity keys.
It verifies keys/order on each indexed record and sorts only when they change.
Binary search finds each input's candidates; an original-index tie-break preserves
the first qualifying duplicate. Frame, generation and graphics revision values
are read fresh. Small visible sets and spans larger than capacity use the linear
path. Fixed storage grows from 4,136 to 4,216 bytes per pacer (+80 bytes), without
heap allocation. The added sorting state is an explicit memory-for-work tradeoff.

Three separate reference corpora each check 1,920,000 exact decisions: ordinary
identities, deliberately colliding identities, and spans up to 72 entries (over
the 64-entry index bound). The last runs under AddressSanitizer and UBSan without
diagnostics. Seven alternating component pairs give:

| Case | Wall ms A → B | Wall/CPU wins |
| --- | ---: | ---: |
| Empty | 8.865 → 8.474 | 7/7, 7/7 |
| One initialized entry | 56.158 → 17.555 | 7/7, 7/7 |
| Four initialized entries | 98.807 → 56.743 | 7/7, 7/7 |
| Full | 223.037 → 127.533 | 7/7, 7/7 |
| Full with changing identities | 224.985 → 162.460 | 7/7, 7/7 |
| One visible, evicting old identities | 325.485 → 286.201 | 7/7, 7/7 |
| Full, colliding identities | 227.752 → 127.350 | 7/7, 7/7 |

Full and full-churn cases use 100,000 iterations; the small cases use two million.
The one-entry saving is approximately 19 ns per benchmark iteration. This does
not explain the millisecond native presentation-tail regression. ARM64 assembly
shows an identity-validation loop that bypasses sorting when unchanged and a
halving binary-search loop for matches. ARM64, x86-64 and x86-64-v3 compilation
passes; native x86/Linux execution remains unqualified. This is a component
candidate only; none is accepted as a complete-client optimization. After these
component checks and the cadence diagnostics, the ordered header was staged
in the worktree for a fresh integrated build under
`out-perf/shared-image-optical-ordered`. The preceding header and measured final
binary are preserved. Focused tests, pixel/row oracles, lint and native paired
controls were then required, with the tabs regression tested first after build
qualification. That variant preserved the original Qt image conversion.

That first integrated build completes all 477 steps, thirteen focused tests in
25.49 s, the four native Quick cases, 7,494 original-Zig rows and eleven native
image-capture comparisons. Clang-tidy then requires `std::ranges` versions of the
two new algorithms, so no headline timing starts. Its source, binary and failed
lint output remain frozen. The corrected source uses a pane-id projection with
`std::ranges::lower_bound` and `std::ranges::sort`.

`out-perf/frame-pacer-ordered-ranges` rechecks that final component source: all
three 1,920,000-decision corpora pass, including the oversized-span ASan/UBSan
corpus. All six ordinary/churn cases and the separate collision control win 7/7
for wall and CPU. Representative wall totals are one entry 56.164 → 17.488 ms,
full 224.245 → 127.469 ms, full churn 225.496 → 162.537 ms, and collision
227.471 → 127.106 ms, with the same iteration counts as above. Three-target
code generation compiles again. The fresh full application build in
`out-perf/shared-image-optical-ordered-final` passes thirteen focused tests in
25.70 s, four native Quick cases in 1.615 s, 7,494 original-Zig row comparisons,
eleven native image comparisons and all four touched-unit lint checks.

The final GUI SHA-256 is
`6d50486990077ce67dee60e9d05c1f64c771af2aee8f7b9af7cee5f7fe5f7153`.
Its six alternating tabs pairs against coverage reject the integrated variant:
GUI CPU/input rises 4.227190 → 4.253515 ms with only 1/6 wins. Presentation p50
is 25.541437 → 26.065812 ms (2/6), p95 33.256270 → 33.108103 (4/6), p99
35.387584 → 35.359052 (2/6), and maximum 37.721104 → 37.782250 (3/6).
RSS is 203.90625 → 203.9375 MiB (3/6), not the rejection reason. Raw evidence is
`/tmp/telar-perf-gordered-coverage-tabs-01` and the prefix's
`measurement-state.json`. The sequence exits 2 before image or independent-Zig
stages. No code-placement exception is established. The ordered header has been
withdrawn byte-for-byte to the preceding graphics-final version; all frozen
component and integrated evidence remains available.

`out-perf/graphics-tabs-warm-profile` then samples both GUI and runtime in two
separate diagnostic runs, using explicit native postwarmup and measurement-end
markers. Both receipts confirm the five-second samples fall inside measurement,
after warmup; all four samples and both controllers exit successfully. These use
the coverage and rejected ordered GUI identities above, with the same runtime.
Main and render threads mostly wait. Both show ColorSync/ICC work below Qt native
update scheduling; the candidate also samples a QML Repeater/delegate creation
cascade after warmup. Neither establishes a dominant pacer or allocation cause.
The `sample` observations include sleeping/preempted threads and must not be read
as CPU-time percentages or allocation counts. These profiles improve phase
qualification over the earlier mixed-phase samples, not performance acceptance.

### Retained destination conversion component

The separate `out-perf/image-retained-premultiply` prototype uses only public
QImage APIs. On little-endian RGBA input it copies rows into a retained native
ARGB-labelled destination, calls in-place premultiplication and relabels the
result as RGBA premultiplied. A destination still shared with an earlier output
is replaced before writing. Other input formats retain the original conversion.
The exact oracle covers all 65,536 alpha/channel combinations, twelve odd-stride
RGB/RGBA images, source overwrite, retained old outputs, and unshared buffer reuse.

Seven alternating pairs pass for opaque, alpha, near-opaque, queued-opaque and
queued-alpha input at both 1K and 4K: every RGBA wall/CPU case wins 7/7. RGB controls
win 3/7 at both sizes, without a consistent loss. Representative per-conversion
results are:

| Input | Wall ms A → B | CPU ms A → B |
| --- | ---: | ---: |
| 1K opaque | 0.271 → 0.175 | 1.061 → 0.350 |
| 4K opaque | 1.697 → 1.279 | 8.184 → 2.730 |
| 1K alpha | 0.292 → 0.271 | 1.146 → 0.617 |
| 4K alpha | 1.838 → 1.528 | 8.896 → 3.920 |
| 4K queued opaque | 1.701 → 1.195 | 8.200 → 2.644 |
| 4K queued alpha | 1.839 → 1.459 | 8.881 → 3.826 |

After warmup the unshared RGBA path has zero explicit destination creations and
zero pointer changes during conversion. Keeping the previous output alive forces
one fresh destination per call, preserving its contents. These counters describe
destination creation/address reuse; they are **not** a census of allocations
inside Qt or proof of zero framework allocations. Native integration, RSS impact,
tail latency and all-flow controls remain unqualified. The two earlier conversion
variants passed component timing but failed native tails, so this component win
does not authorize retaining the change in production.

The integrated candidate is frozen at
`out-perf/shared-image-optical-retained-final`, GUI SHA-256
`7fd7b6f5f3cb89a905fca07b9c747f018da19b94be52ede685d3faa4628db37b`.
It copies and replaces only the image-resource object in the frozen graphics-final
archive, then relinks dependent executables; all other source hashes and committed
service files match that base. Exact archive/object/binary identities are recorded.
The first prefix, `shared-image-optical-retained-premultiply`, stops on the lint
requirement to use an anonymous namespace; its failed receipt is preserved.

A private retained QImage now belongs to each native upload texture. Replacing a
pending upload first drops the obsolete local reference; an image still held by a
Qt update batch forces a new destination. Clear/eviction/recovery releases the
cache with its texture. This can add one RGBA buffer per resident texture: about
31.64 MiB for 3840×2160, 4 MiB for 1024×1024, bounded by the existing 512 MiB
resident-image budget per window (excluding Qt's transient queued uploads).
This is an allowed memory tradeoff to measure, not zero-copy or a new admission
limit. RGB and big-endian conversion, GPU RGBA8 format and draw-node behavior stay
as before.

The actual production helper, extracted unchanged, passes the exhaustive
65,536 alpha/channel and twelve odd-stride/source-overwrite/held-output cases.
Thirteen focused tests pass in 25.43 s, four native Quick cases in 1.469 s,
7,494 original-Zig row cases match, and all eleven native image captures match
coverage exactly. Image-resource clang-tidy passes. Integrated ARM64, x86-64 and
x86-64-v3 assembly compiles; ARM64 calls the row-copy loop and in-place native
conversion, with the generic RGBA conversion confined to fallback. This does not
qualify x86 Qt execution. Six native tabs pairs now reject this combined binary:
p50 is 25.368990 → 25.631260 ms (2/6 wins), p95 32.795209 → 33.113134 (2/6),
p99 34.457947 → 35.931213 (1/6), maximum 36.881208 → 37.356042 (1/6).
CPU/input is 4.337445 → 4.322860 ms (2/6), RSS 210.742 → 206.359 MiB (4/6).
The sequence exits 2 before image or independent-Zig timing; evidence is in
`/tmp/telar-perf-retained-coverage-tabs-01` and `measurement-state.json`.

This rejects the combined package, not a demonstrated conversion mechanism:
the marker control has no image uploads, and the graphics-final base already
failed tabs without the conversion. The next experiment isolates the same image
source on coverage's archives. Compiler-generated dependencies must match every
local services header to coverage's commit plus frozen overlay before linking;
this avoids mixing the graphics-grace ABI into the old objects. A first isolated
build stops because coverage lacks the unrelated session-effects test object;
the failure is preserved. `out-perf/shared-image-optical-retained-isolated-final`
selects coverage's twelve existing focused tests, which pass in 25.27 s. All
26 local services dependencies match coverage. Four native Quick cases pass in
1.517 s, all 7,494 original-Zig rows match and all eleven native graphics cases
match coverage pixel-for-pixel. The isolated GUI SHA-256 is
`dad2ce88f795889196930f6f3327f683047620f7f2f07c31a9251890f3090fc2`;
runtime and helper remain unchanged. Six tabs pairs initially stop this isolated
sequence too: p50 25.617250 → 25.827531 ms (2/6), p95 32.683566 → 33.064984
(1/6), p99 35.255964 → 35.565902 (2/6), maximum 36.788292 → 40.530729 (0/6).
CPU/input is 4.262575 → 4.338330 ms (3/6), RSS 206.141 → 203.977 MiB (5/6).
Raw results and the original failed state remain unchanged.

A subsequent placement check establishes byte-identical input objects for
Application, TerminalItem and TerminalScene. It compares linked ARM64 instructions
for eleven text-path functions, masking only relocation immediate fields from
those identical objects and preserving other opcodes/registers/constants plus
relocation symbol identities. All eleven normalized streams match, including
consume, presentChange, input-frame scheduling, prepared-frame recording and
terminal scene synchronization. All move by 960 bytes. `placement/result.json`,
the comparison script and normalized listings preserve the proof.

Under perf-pass's explicit identical-normalized-disassembly rule, the unchanged
text control is classified as placement, with its losses still reported. This
exception does not cover the changed image path or establish a complete-stack
win. `measure-after-placement.py` starts the remaining image/text/Zig stages,
recording to a separate `placement-qualified-measurement-state.json`. The original
sequence is not overwritten.

The six-pair 4K target then rejects the isolated image variant on changed-path
latency: p50 47.418917 → 47.178302 ms (3/6 wins), p95 58.766621 → 58.789570
(3/6), p99 62.427293 → 63.308232 (2/6), maximum 63.713188 → 64.699500 (1/6).
GUI CPU/input falls 31.225410 → 14.956875 ms, winning all six pairs. Peak RSS
rises 367.226563 → 398.828125 MiB, approximately one retained 4K RGBA destination.
This is a favorable memory-for-CPU tradeoff under Adrian's instruction; memory
is not the rejection reason. The target lacks the required p50 win count and
has a consistent maximum-latency loss. The unchanged-text placement exception
does not cover the modified image path. No framework allocation census or causal
explanation of the remaining presentation delay is established by these numbers.

Evidence is `/tmp/telar-perf-retiso-coverage-4k-01` and the separate placement-
qualified state file. The controller exits 2 before 1K, other text controls or
independent-Zig stages. Root `image_resource.cpp` has been restored exactly to its
preceding source; all candidate binaries, source, pixel proof, assembly and paired
receipts are preserved. The >50% CPU reduction is a useful measured component
for a future distinct scheduling experiment, not permission to retain this
failed complete-client variant. All F01–F16 and representative native 120 Hz
requirements remain open.

### Retained-image timeline and fused conversion experiments

`out-perf/image-retained-timeline` joins bounded C++ pacing/upload events with
per-input native Metal submission, GPU timestamps and verified drawable
presentation. Both C++ variants reuse the same frozen coverage tracing objects;
only the image resource differs. The native probe retains the existing readiness,
focus, geometry and pixel gates. Each of the base, retained and independent Zig
runs has 120 sequential, unique, pixel-verified native presentations, with 20
warmups excluded. Native `CACurrentMediaTime` and `CLOCK_UPTIME_RAW` are bracketed
in each run; local Python monotonic-clock calibration also passes. Phase sums
reproduce each original presentation sample. These are diagnostic runs, not
alternating acceptance pairs or sustained-cadence qualification.

| Median phase, ms | Coverage C++ | Retained C++ |
| --- | ---: | ---: |
| Input to first graphics-change request | 14.278 | 13.994 |
| First graphics-change request to upload | 4.042 | 4.329 |
| Conversion | 4.588 | 3.955 |
| Conversion to Metal commit | 3.507 | 3.556 |
| Commit to GPU start | 0.757 | 0.706 |
| GPU work | 0.728 | 0.731 |
| GPU end to native presentation | 18.998 | 19.605 |
| Drawable acquisition | 0.047 | 0.048 |

The retained path records zero explicit destination creations and zero conversion
pointer relocations across its 100 measured uploads. The baseline does not
instrument these counters; neither path has a framework allocation census.
Separate phase medians do not add to the median total. The independent Zig run
also has a large GPU-end-to-presentation median, 24.944 ms, so that wait is not
established as a Qt-specific cause. Producer publication takes median 3.397,
3.303 and 4.043 ms for base C++, retained C++ and Zig; publication-to-commit is
22.996, 22.690 and 17.510 ms respectively. The fixture is unchanged.

The original six-pair 4K results were also decomposed after excluding warmup and
asserting that all presentation quantiles reproduce the recorded summaries.
GPU-completion callback p50 is 28.639 → 28.135 ms (5/6 wins), p99
38.558 → 39.655 (2/6), and maximum 39.626 → 45.683 (0/6). GPU work p50 is
0.724 → 0.711 ms (5/6). The first analysis accidentally included warmup; it is
preserved with an invalid-warmup name and is not used for these numbers.

The next component family fuses source copying and premultiplication into one
pass over a retained destination. Opaque blocks copy directly; other blocks use
exact Qt rounding. All versions preserve the original RGB and big-endian path.
The ARM SIMD versions also preserve the original conversion on non-AArch64.
`out-perf/image-fused-premultiply` passes the exhaustive/ownership oracle but
loses 4K opaque wall time 1/7 and alpha wall time 0/7: rejected. Its 32-bit packed
arithmetic saves CPU but is slower in wall time than Qt's parallel conversion.
`out-perf/image-fused-neon` uses byte-wide multiplication/narrowing and 32-pixel
blocks. Opaque, near-opaque and queued-opaque cases win 7/7 at both sizes, but
alpha 4K loses 0/7: also rejected.

`out-perf/image-fused-parallel` divides rows between the caller and one private
worker. Additional large odd-stride RGB/RGBA and held-output oracles pass. Its
4K RGB control loses 1/7 for wall and CPU, and queued-alpha timing is unstable;
it is unaccepted. `out-perf/image-fused-worker` instead bounds workers per calling
thread, avoiding a pool per texture, and requests high worker service quality on
supported Qt versions. Every RGBA CPU case wins 7/7, with all RGBA wall cases
winning 6–7/7 except alpha 4K (5/7). RGB controls have no consistent loss. This
remains a component candidate. `out-perf/image-fused-three` partitions rows across
the caller and at most two extra workers: all ten RGBA cases win 7/7 for wall
and CPU time, while both RGB controls win 4/7. Per-conversion opaque 4K time is
1.695→1.091 ms and alpha 4K is 1.829→1.142 ms. These are component results.

The production candidate in `out-perf/shared-image-optical-fused-final` replaces
only the image-resource TU in frozen coverage archives. Every local compiler
header dependency is audited against that baseline. It retains destinations only
for little-endian ARM64 RGBA, keeps queued outputs immutable, and joins workers
with scope guards even if a subsequent task launch throws. RGB and other targets
retain Qt's conversion. The final source extracts a row helper to pass complexity
limits; its exact helper is independently rechecked in
`out-perf/image-fused-source-final`, without fictional allocation counters.

The integrated build and clang-tidy pass. Twelve focused tests (25.28 s), four
native Quick cases (1.651 s), 7494 independent original-Zig row cases, and eleven
native Metal image cases pass; every distinct captured RGBA image matches
coverage exactly. The exhaustive conversion/ownership oracle also passes under
ASan/UBSan. The actual production TU compiles for ARM64, x86 baseline and x86-v3;
x86 uses the original Qt fallback. Installed Qt frameworks are ARM64-only, so
x86 Qt execution remains unqualified. ARM assembly uses an AND/UMIN reduction
and exact integer multiply/narrowing without per-pixel calls, but materializes
a 128-byte temporary on the stack and reloads the source for the reduction.
That remaining work is a separate possible experiment, not an assumed win.

Candidate GUI SHA-256:
`10e3533e9ec6de37e59c934de4e153870281adb75a94e383c3f081b86891c62e`.
The working image resource contains this unaccepted candidate. Exact final-helper
component timing passes: all ten RGBA cases win 7/7 for wall and CPU; RGB 1K wins
3/7 for both and RGB 4K wins 5/7 wall, 4/7 CPU. Opaque 4K conversion is
1.696→1.087 ms, alpha 4K 1.833→1.109 ms; corresponding total CPU per conversion
is 8.185→3.139 ms and 8.872→3.221 ms. Component runs contain 128 conversions for
1K and 32 for 4K after eight warmups. The six-pair tab control completes with p50 25.597→25.785 ms (2/6),
p95 32.989→32.989 ms (4/6), p99 36.152→36.646 ms (2/6) and maximum
37.215→40.861 ms (1/6). GUI CPU/input is 4.336→4.457 ms (3/6), peak RSS
204.141→204.930 MiB (3/6). The consistent maximum loss stops the controller.

The independent placement audit proves all eleven affected linked text/pacing
functions identical after masking only instruction relocation immediate fields;
input objects are byte-identical and relocation targets remain part of the
comparison. Their addresses shift 7168 bytes. Under the perf-pass exception the
text maximum loss is classified as placement, with the raw result preserved in
`measurement-state.json`. The separate
`placement-qualified-measurement-state.json` continues with 4K images; the
changed image path receives no placement exception.

The six native 4K pairs pass this stage: p50 48.035→47.327 ms (6/6),
p95 58.325→58.025 ms (4/6), p99 63.607→63.465 ms (3/6), maximum
66.703→65.783 ms (3/6). GUI CPU/input falls 31.473→15.615 ms (6/6).
Peak GUI RSS increases 367.008→398.898 MiB (+31.891 MiB); that bounded
memory tradeoff is explicitly allowed and is not the rejection criterion.
The six native 1K pairs also pass: p50 37.225→35.531 ms (6/6),
p95 43.821→43.485 ms (4/6), p99 47.624→47.507 ms (3/6), maximum
56.289→50.798 ms (4/6). GUI CPU/input falls 9.689→6.510 ms (6/6),
with peak RSS 218.383→226.125 MiB (+7.742 MiB). The sequence now checks
single/split text controls before independent Zig. Native cadence remains open.
Raw data: `/tmp/telar-perf-fused-coverage-{4k,1k}-01`.

The single/split text controls also finish without consistent losses. Single
p50/p95/p99/max wins are 2/3/5/6 out of six; split wins are 3/2/4/4. GUI CPU/input
is 4.134→4.155 ms (2/6) single and 4.511→4.403 ms (5/6) split. These controls do
not establish F06/F08/F09 continuous interaction. Raw data:
`/tmp/telar-perf-fused-coverage-text-01`.

Independent Zig GUI + runtime versus candidate C++ GUI + runtime now yields:

| Native image input | Zig → C++ median ms | p50 / p95 / p99 / max C++ wins | GUI CPU/input ms, wins | GUI peak RSS MiB |
| --- | --- | --- | --- | --- |
| 4K opaque replacement | 52.573 → 47.178 | 6/6 / 6/6 / 6/6 / 6/6 | 10.497 → 15.960, 0/6 | 252.055 → 398.977 |
| 1K opaque replacement | 41.405 → 35.427 | 6/6 / 6/6 / 6/6 / 6/6 | 6.957 → 6.444, 6/6 | 140.492 → 225.180 |

Raw data: `/tmp/telar-perf-fused-zig-{4k,1k}-01`. The 4K GUI CPU deficit remains
real even though every latency percentile wins; more retained memory is allowed,
not evidence that the CPU gap is solved. Both rows are uniform opaque image
replacement, not arbitrary-alpha images or continuous 120 Hz. Independent Zig
text controls have completed. Runtime CPU was not captured in these intervals;
these GUI CPU figures must not be presented as whole-stack CPU.

The independent single/split/tab text controls retain GUI CPU deficits: Zig → C++
CPU/input is 3.640→4.242, 3.673→4.527 and 3.552→4.368 ms respectively, each
0/6 C++ wins. Presentation p50/p95/p99/maximum win counts are 4/5/6/5,
6/4/4/3 and 5/4/2/2 respectively. No complete text-flow acceptance follows.
Raw data: `/tmp/telar-perf-fused-zig-text-01`. The full frozen fused-image
sequence is now terminal; its initial placement failure and proof remain intact.

`out-perf/native-runtime-resources` prepares an SDK-based `proc_pid_rusage`
collector for explicit GUI/runtime intervals, with PID/start-time/UUID and
counter monotonicity checks. Its owned-child test will compare counter deltas
against `getrusage`, verify the time units and confirm child CPU is excluded from
the parent. This is prepared source, not yet compiled or qualified; it will run
after headline timings. Memory snapshots and lifetime physical-footprint peaks
are explicitly separate from interval RSS peaks, and shared RSS is never summed.

A further source review finds an important original-Zig parity question. The
original Metal image backend uploads RGBA bytes unchanged in
`lib/window/metal/Images.zig`; `lib/window/shaders/quad.metal` samples them linearly
and uses straight-alpha blending configured in `lib/window/metal/Scene.zig`.
C++ premultiplies before QSGImageNode linear sampling. Those operations need not
commute across neighboring pixels with different alpha. The existing
`straightAlphaIsBlendedOnce` test is uniform translucent red, and the eleven
native captures compare C++ variants; neither proves that boundary against Zig.

`out-perf/image-alpha-edge-oracle` prepares native captures from all three frozen
stacks using a 16×16 image magnified to eight columns by four rows. It has an
opaque border, an independently changing center marker, and a boundary between
opaque reddish and transparent bluish pixels. Payload identity, native readiness,
capture witness, geometry and independent runtimes remain checked. This probe
has not run yet. If it confirms a mismatch, aligning filtering/blending with Zig
may eliminate CPU premultiplication work entirely; no shader or production
conversion change is made on that unverified inference. Current image timings
and the fused candidate remain preserved.

The next F08 investigation was prepared under `out-perf/tab-layout-work-census`.
It instruments actual native tab reorder/cancel/reveal/viewport gestures to count
layout rebuilds, caption measurements, native shaping and fallback work. It also
separates animation-requested rebuilds from other updates. The diagnostic will
run after headline timing; instrumented durations are not acceptance evidence.
The hypotheses are bounded caption reuse and reusing measured model records/target
geometry across animation-only frames. No cache change has been implemented.

A read-only follow-up distinguishes GUI generation allocation from rendering:
`GraphicsStore::Image` owns a byte buffer per admitted image generation, and
`SharedImageSource` fills it through a protected kernel-mediated read. The runtime
atomic path already adopts a protected mapping and exports its prepared shared
name, so a second `freezeShared` memcpy must not be assumed there. A separate
diagnostic should time GUI construction/allocation, shared read and retirement,
joined by image key/generation to native input. These project events would not
be a Qt/framework allocation census. The lead and required lifetime/recovery
oracles are recorded in
`out-perf/graphics-tabs-warm-profile/image-store-copy-lead.json`.

### Straight-alpha parity and reducing upload work

The prepared alpha-edge experiment has now run. Initial zero-idle captures failed
because the asynchronous capture had not arrived when collection ended; these
failures are retained under `image-alpha-edge-oracle` and its debug variant.
The `image-alpha-edge-oracle-ready` controller allows the existing two-second
capture interval. Original Zig and coverage both then qualify native readiness
and the capture witness. The generic cross-stack marker-centroid gate fails at
[188,163] versus [189,163]; it remains unchanged for headline comparisons.
An independent opaque-border audit establishes identical image bounds
[120,84,264,244], source payloads, grid, viewport and DPR. Within that 144×160
image footprint, 3860 pixels differ, with maximum channel difference 40.
This proves a varying-alpha filtering difference, rather than an image-size
or position mismatch. Raw data: `/tmp/telar-perf-alpha-edge-ready-01`.

The scratch `out-perf/image-straight-shader` prototype uploads straight RGBA and
uses the original Zig blend factors after linear sampling. Its actual native
edge capture matches original Zig exactly: zero pixel/channel differences,
RGBA SHA-256 `bb3028162627b8c348c59f06f6d4bec44f4989d9cab17b8fed7ee8a0ab1dd3eb`.
All eleven native graphics cases also pass and match the preceding C++ captures
exactly, including replacement, clipping, shared views, generation recovery and
texture reuse. The actual raw-copy helper passes Release and ASan/UBSan checks
for all alpha/channel combinations, alternate formats, odd strides, source
overwrite and retained queued outputs. Qt frameworks are not instrumented.
This prototype removes CPU premultiplication but still makes an owned upload
copy. The subsequent six alternating 4K pairs against coverage reject this
variant: p50 47.807→47.508 ms (4/6 wins), p95 60.528→60.658 (2/6),
p99 64.076→68.866 (2/6), maximum 67.207→77.280 (0/6). GUI CPU/input
does improve 31.290→11.946 ms (6/6), with peak RSS 367.117→399.180 MiB.
The explicit memory allowance does not excuse the consistent maximum-latency
loss. No placement exemption is established for the changed image path.
Raw data: `/tmp/telar-perf-straight-coverage-4k-01`; the pixel-parity finding
remains valid independently of the rejected performance result.

A separate `out-perf/image-straight-qimage` diagnostic uploads an owned straight
RGBA QImage through QRhi. Its native image footprint also matches original Zig
exactly (`/tmp/telar-perf-alpha-qimage-01`). This verifies the relevant Metal
upload behavior without assuming Qt converts these bytes. It deliberately makes
a fresh copy and is not a performance candidate. A future immutable pixel lease
could avoid that copy, but must preserve allocator lifetime/thread ownership,
generation cancellation, global bounds and teardown. GraphicsBudget currently
belongs to the session, while queued upload objects can outlive a catalog; a
raw borrowed pointer alone cannot establish safe ownership. The protected
kernel-mediated shared-memory read remains required. Original Zig's mapping
explicitly accepts same-user truncation SIGBUS, which is not a suitable C++
optimization to copy.

The next isolated variant, `out-perf/image-pixel-lease`, shares the immutable
pixel allocation of a completed generation with the upload QImage. A cleanup
owner retains the bytes until Qt releases its last image reference. This avoids
the post-read RGBA copy and premultiplication; RGB still requires expansion.
Catalog credits retain their previous semantics, and queued ownership replaces
the former owned upload copy rather than adding an unbounded retention cache.
Leases are available only for thread-safe allocators; other allocators use an
owned copy. The allocator must outlive both the model and renderer, as in the
application's existing destruction order. No delayed deleter accesses the
session-owned GraphicsBudget. The component oracle passes native ARM64,
ASan/UBSan and x86-64 via Rosetta, covering incomplete images, failed pixel/control
allocations, immutable publication, retirement, catalog deletion/credits and last
release on another thread. The complete isolated GUI build now succeeds, with
GUI SHA-256 `512f4bc7285d01203f735211385a783d54d6099a42d8a21724c10911fa490a7a`.
The actual Qt helper oracle passes Release and ASan/UBSan: RGBA pointer identity
survives the model's destruction and last-reference release on another thread;
copy-on-write mutation preserves the source; borrowed and non-thread-safe paths
own their copies; RGB expands correctly. Seven focused session/graphics/shared
memory/recovery tests and all eleven native pixel cases pass. The original alpha
edge and a new varying-alpha gradient/checkerboard capture both match original
Zig exactly. The latter image-footprint digest is
`1a8c60569009571f946f4ff59cb9ce4786798f880719f8a8bd842c2e93f849c1`.
Payloads, native geometry and actual PNG hashes are audited separately for both
comparisons under `/tmp/telar-perf-alpha-{lease,gradient-lease}-01`.

The ARM64 linked path takes a shared-owner atomic reference, constructs the
external-buffer QImage and passes retained ownership. Relocations verify that
the retained RGBA branch invokes QImage's sharing constructor; conversion and
deep-copy calls remain on the other branches. No pixel loop remains in that
branch. This removes post-read CPU work, not the protected shared-memory read or
Qt/driver staging. The six alternating native 4K pairs are now complete and reject
this variant too: p50 47.303→47.130 ms (3/6 wins), p95 59.007→63.425 (0/6),
p99 63.320→73.516 (0/6), maximum 67.203→79.580 (0/6). GUI CPU/input
falls 31.412→11.099 ms (6/6), and peak RSS falls 367.031→335.406 MiB (6/6).
Those resource gains do not excuse the consistent tail losses. Their cause is
not established; a native upload/presentation timeline is the next diagnostic,
rather than assuming that fewer copied bytes guarantees lower visible latency.
Raw data: `/tmp/telar-perf-lease-coverage-4k-01`. The root production candidate
remains preserved separately from this rejected isolated source tree.

Reusable source tooling now covers both alpha patterns. The native runner accepts
`--image-size 16 16 --image-pattern alpha-edge` or `alpha-gradient`, with
`--capture --idle-seconds 2` for the static oracle. The fixture reports the pattern
and eight-column/four-row placement, and the runner verifies them. The ordinary
opaque workload retains its original payload and wire placement. All six alpha
payload digests match the original diagnostic fixtures exactly.
`tools/image_capture_oracle.py REFERENCE_RESULT CANDIDATE_RESULT --output REPORT`
checks native readiness/VSync/focus, source payloads, capture-file hashes and
geometry before comparing the connected opaque-bordered footprint. It permits
a color-derived marker-centroid difference only in this static comparison;
the headline runner's geometry gate is unchanged. Fifteen image-tool tests and
nineteen existing latency-runner tests pass. Replaying five actual native pairs
retains the original 3860-pixel mismatch and all four exact prototype results.

### Qualified process counters and remaining diagnostic limits

The first `proc_pid_rusage` unit test failed because CPU values are Mach ticks,
not nanoseconds on this host. The failure and raw counters are retained.
`out-perf/native-runtime-resources-clock` applies the recorded 125/3 timebase.
Its self/owned-child controls pass against getrusage: self 199.996 versus
199.990 ms; child 199.848 versus 199.717 ms, while parent CPU is 0.0127 ms.
PID/start-time/UUID, counter-regression and invalid-PID controls also pass.
The native collector verifies the isolated runtime PID against the socket owner
and brackets each process sample. Runtime and GUI CPU remain separate.

One diagnostic sequence with twenty measured 4K inputs reports GUI/runtime CPU
per input in ms: Zig 10.298/9.709, coverage 30.928/7.914, fused 14.508/7.890
(`/tmp/telar-perf-proc-resource-01`). The straight-shader prototype later records
11.866/7.908 (`/tmp/telar-perf-proc-straight-01`). GUI counters agree with native
getrusage, and paired process-sample midpoint skew is 6–22 microseconds in the
three-stack sequence. These are separate, unpaired diagnostics, not acceptance
comparisons or retroactive runtime measurements for earlier headline pairs.
Collector overhead still needs paired qualification. Memory snapshots and
lifetime physical-footprint peaks are retained with their actual meaning;
shared RSS is not summed and lifetime peaks are not interval peaks.

The tab-work census also completed its first two gestures: reorder after release
and Escape cancellation pass, with 23 and 35 rebuilds. Caption measurement is
about 8.9% and 8.5% of instrumented rebuild time respectively, so caption caching
alone cannot remove most observed rebuild work. The third gesture fails its
hidden-counter visibility/width setup assertion; the viewport-change case did
not run. Both outcomes are preserved in `qualified-summary.json`, and neither
is counted as a passing flow. No caption or layout cache was implemented.

### Display-reference phase audit

Read-only reanalysis of the original cadence runs finds a phase discontinuity in
both traces that had a 20.833 ms native interval. Around those events, Core Video
output-host timestamp intervals include approximately 6.239, 7.281 and 7.806 ms,
while the reported video period remains 8.333 ms. The existing reference check
examines median host spacing and the longest gap; it does not reject these shorter
phase-adjustment intervals. A fixed median is insufficient evidence of a fixed
phase reference. See `phase-diagnostic-03.json` and `reference-phase-04.json` under
`out-perf/native-cadence-display`.

This does not establish a renderer or hardware cause. The original 0.25 ms
classification tolerance remains unchanged, and the affected runs remain
unqualified. The next reference diagnostic must retain callback input timestamps
as well as output timestamps and distinguish reference phase changes from actual
drawable intervals before counting missed opportunities. No 120 Hz acceptance is
inferred from these records.

`out-perf/native-cadence-phase` prepares a separate diagnostic probe for that
follow-up. It retains Core Video callback input and output timestamps, rejects
every output-host interval outside the existing 5% reference tolerance instead of
checking only its median, and leaves the native residual tolerance at 0.25 ms.
It adds an explicit timed GUI CPU observation interval and a census of successful
probe readback-buffer requests/bytes. Those buffer counters do not describe Qt,
driver-internal or application allocation totals.

Prepared fault controls alter cadence records only after real native readiness:
zero/missing presentation, regressing sequence and failed pixel verification.
Pre-fault native timestamps and sequences are retained. Setup failures cannot
count as successful negative controls. After the final-source sequence stopped,
the probe compiled and all ten model/clock-validity tests passed. Invalid clock
data now produces a diagnostic error rather than a division exception aborting
the content analysis. All five owned live positive/fault controls now behave as
expected: native content passes with no fault; zero timestamps, absent records,
regressing sequences and failed pixel checks are rejected after successful native
setup and twenty qualified warmup inputs. Receipts are under the phase prefix and
`/tmp/telar-perf-phase-fault-{0..4}-01`. The missing-record runner exits nonzero;
its raw result still proves successful setup and actual rendering, rather than
counting a setup failure as a passing fault control.

The positive control contains 671 distinct visible content frames over six
seconds (111.823 changes/s by the first/last changed timestamps). Its longest gap
is 29.166 ms. The reference has phase changes, so active-refresh and missed-refresh
classification remain unqualified. In that run, 719 valid Core Video input
timestamps have median spacing 8.332 ms; output-minus-input median is 10.912 ms,
and callback-minus-input median 0.00225 ms. These are timestamp relationships,
not a physical display latency measurement.

The explicit GUI CPU interval lasts 6.156 s, with 0.746 s user plus 0.598 s system
CPU. It contains 688 successful probe readback-buffer creations requesting
176,128 bytes. Its actual boundaries differ from the six-second content window;
these counts are not an application/framework allocation census. Probe overhead
still needs qualification. The separate diagnostic sequence for coverage, the
rejected final-source candidate and independent original Zig has completed with
this same probe (`/tmp/telar-perf-phase-stacks-01`). Coverage/final content qualifies
at 111.912/112.156 changes/s, but both references change phase; neither qualifies
active refresh. Zig's producer receipt ends 0.994 ms before the native window and
fails the unchanged coverage gate, so this sequence cannot compare all three.

The controller shut down the owned runtime immediately after GUI exit. Producer
receipts are published every half second, so a fast GUI exit could leave the last
published checkpoint just short of the observation boundary. The isolated
`out-perf/native-cadence-phase-complete` controller waits up to three seconds for
a checkpoint covering the native window before runtime cleanup. It does not
change the producer, offered-rate tolerances, native probe binary or presentation
criteria. A delayed-checkpoint test proves the wait occurs; a timeout test proves
an incomplete receipt still fails. All twelve completion/clock/model tests pass.

The separate corrected Zig diagnostic in `/tmp/telar-perf-phase-complete-zig-01`
qualifies its producer, pixels and fixed 120.0006 Hz reference. It observes 694
content changes, 115.661 changes/s by first/last timestamps, and 26 intervals that
span two refresh opportunities; maximum gap is 16.667 ms. This does not meet a
sustained 120-content-FPS objective. It is a single diagnostic run with probe
overhead still open, not a paired C++/Zig acceptance result. The original failed
run is retained and is not relabeled successful.

The reusable analyzer, clock classifier and owned-producer completion helper now
live in `tools/native_cadence_report.py`, `tools/native_display_reference.py` and
`tools/native_cadence_completion.py`. Eighteen unit tests pass, covering native
faults, 60-on-120 cadence, producer coverage/rate failures, delayed checkpoints,
timeouts, phase changes and invalid numerical/clock metadata. Replaying seven
native receipts preserves all expected content classifications, including the
failed original Zig receipt and all four live injected faults. Five reference-only
replays also preserve their exact clock classification. Reference qualification
alone deliberately does not override a failed producer/content gate.

The legacy `gui_frame_rate` tool's documentation now explicitly identifies its
historically named presentation counters as frame-completion callbacks. Those
counters cannot qualify visible 120 Hz; native positive presentation timestamps
and a content oracle remain required.

### Process-resource probe rebuilt on the DLL base

The SDK `proc_pid_rusage(RUSAGE_INFO_V4)` prototype was rebuilt from current
native-harness sources in `out-perf/dlls-runtime-resources`; the preserved
`125/3` Mach timebase conversion remains necessary. Fresh self/child CPU controls
and invalid identity/counter controls pass. The native qualification run
`/tmp/telar-perf-dlls-resources-qual-01` verifies the GUI and socket-peer runtime
identities for both complete stacks. Its 20-input CPU readings are diagnostic,
not paired application results: Zig GUI getrusage/process counters are
3.701300/3.700538 ms per input and runtime 0.841794; C++ GUI
4.182150/4.186038 and runtime 0.570227. Memory counters remain separate snapshots
and a process-lifetime footprint maximum, not interval peaks or additive RSS.

The first probe-overhead comparison is **rejected**. Six alternating pairs per
stack, 100 inputs after 20 warmups, native positive presentation timestamps,
1600×1000 at DPR 2 and 82×21 cells are preserved in
`/tmp/telar-perf-dlls-resources-overhead-01`. Application binaries are identical
between variants; A uses the original probe and B the rebuilt resource probe.
C++ p50 moves 25.019750 → 25.135417 ms and GUI CPU 3.948820 → 4.111330 ms/input,
both winning only 1/6. C++ p95 wins 4/6, p99 and maximum 3/6; Zig has no metric
at 0–1/6 but worse median tails. No cause or code-placement exemption is
established. All outliers remain in the receipts. This does not qualify the
collector for historical-probe comparisons.

A follow-up uses **one identical probe binary** with collection disabled/enabled
to separate collection cost from the rebuild. Its first attempt,
`/tmp/telar-perf-dlls-resources-toggle-01`, is invalid: Python used `is False`
against the probe's numeric JSON zero. Disabled start/end PIDs and counters were
all zero. The corrected controller accepts numeric zero and still verifies the
absent intervals and zero PIDs. The corrected complete series in
`/tmp/telar-perf-dlls-resources-toggle-02` also **fails qualification**: C++ GUI
CPU is 3.992750 → 4.106245 ms/input, winning only 1/6. C++ p50/p95/p99/maximum
win 4/5/3/3 pairs; Zig 4/3/2/4 and CPU 4/6. This isolates an enabled/disabled
collector comparison with identical machine code, but does not establish the
cause of the CPU difference. The collector remains a separate diagnostic tool;
there is no promotion into headline measurements or claim of negligible cost.

### Client plugin-worker parity prerequisite

The fresh-base F14 failure is a missing C++ CLI dispatch for `plugin-worker`, not
a timing regression or permission failure. The isolated subprocess oracle
`services/runtime-cpp/tools/compare_action_workers.py` checks exit status and
exact protocol bytes with an empty environment and no server/GUI launch. The
initial 66-case reference run in `out-perf/dlls-action-worker-oracle-02` passes
66/66 against Zig. The frozen C++ runtime passes only the 23 negative cases;
all 43 valid cases fail because the command is absent. The earlier reference
run is retained: its sole fixture error put `config.helper` at the wrong path.

The C++ implementation now dispatches the existing seven-argument command,
reuses the shared bounded VM, configuration bootstrap, local-module sandbox and
action/binding validators, and encodes the complete result before writing stdout.
It loads only the worker binding rather than a full GUI/runtime configuration.
The 16 MiB VM quota, load/callback instruction and deadline budgets, immutable
context, first-16-effects truncation and unsupported-effect rejection remain.
Callback context/invocation and protocol tags are shared with the GUI. Its parent
still owns the immutable package snapshot, timeout, generation/cancellation and
whole-batch capability checks; there is no fallback to a Zig executable.

The first direct-entry prototype passed 118 functional cases and seven component
pairs on four workloads, but review found a lexical-scope difference. Zig's wrapper
captures a local `telar` and invokes the mutable `telar.bind_global` factory after
loading the entry. Bypassing that wrapper changes valid programs that replace the
global or factory. Four new controls reproduce those mismatches against the old
C++ prototype while all 122 pass against Zig. The prototype and its favorable
component timings in `out-perf/dlls-plugin-action-worker/pairs-01` are therefore
**rejected for equivalence**, with the exact executable preserved there.

The corrected worker preserves the lexical wrapper and binding-factory call,
including its validation, while still avoiding the unrelated configuration
snapshot. This intentionally retains a bounded source copy. Both binaries pass
122/122 exact-result cases in `out-perf/dlls-action-worker-oracle-05`. A new
`plugin-action-worker` CTest runs the same expected-byte/error oracle without a
Zig dependency and passes. The existing `gui-config`, `gui-plugin-packages` and
`gui-plugin-worker` tests pass; `QuickTest::routedPluginWorker` passes natively on
Cocoa/Metal with the corrected C++ runtime, exercising command and keyboard
execution, whole-batch permission refusal and stale-generation cancellation.
No all-flow or 120 Hz acceptance follows from these checks. Linux and x86-64
execution remain unqualified for this new worker.

The corrected binary is measured separately in
`out-perf/dlls-plugin-action-worker/pairs-02`: seven alternating pairs, 30 fresh
worker launches per variant/case after three warmups. Every invocation checks
exact stdout bytes and successful exit. Wall time includes spawning through
reaping; `wait4` supplies that child's CPU and maximum RSS. These are one-shot
component measurements, excluding package copying, GUI authorization/routing and
presentation. Medians of paired summaries (A original Zig → B corrected C++):

| Case | p50 ms (wins) | p95 ms (wins) | p99 / max wins | CPU ms (wins) | Child max RSS MiB (wins) |
| --- | --- | --- | --- | --- | --- |
| Sidebar | 11.099 → 9.374 (7/7) | 12.283 → 10.265 (7/7) | 5/7 / 5/7 | 8.7165 → 7.4425 (7/7) | 12.547 → 7.602 (7/7) |
| Sixteen effects | 10.949 → 9.254 (7/7) | 12.301 → 10.071 (7/7) | 7/7 / 7/7 | 8.6600 → 7.3255 (7/7) | 12.547 → 7.602 (7/7) |
| Local module | 10.929 → 9.414 (7/7) | 12.111 → 10.212 (7/7) | 6/7 / 6/7 | 8.6290 → 7.4085 (7/7) | 12.555 → 7.609 (7/7) |
| Targeted notification | 10.885 → 9.367 (7/7) | 11.904 → 10.289 (7/7) | 7/7 / 7/7 | 8.6560 → 7.3920 (7/7) | 12.578 → 7.641 (7/7) |

This meets the component criterion for p50/p95 and CPU; sidebar p99/max do not
meet the 6/7 target. The functional implementation is retained, without closing
F14 or attributing the entire C++/Zig difference to one optimization. The corrected
C++ SHA is `a0b8b9d5826cf80c135cc113a1587a552c054e4d733942ab34e98157a1717645`;
the Zig SHA remains `6ccf79485c5ca8baaa2d69d2590abb49d23c808891c04fe6e70f5602713a1d5e`.
Sources, receipts, binary and selected ARM64 assembly are preserved privately.
Assembly confirms the 16-effect bound and direct encoding without a full
configuration-generation call. It also shows a roughly 164 KiB worker stack
frame: retained command-validation storage is still initialized even though
command-tab effects cannot be emitted by this protocol. Removing that work is a
candidate, not an accepted change. Linked stub labels are not used as evidence
of the underlying library function.

Standalone new runtime headers compile. The focused clang-tidy translation unit
finishes without compiler errors but emits style/advisory warnings, including
repository-style pragma guards, checked span indexing, structure padding and
intentional uninitialized output storage. This is not a clean lint claim.
A focused worker build with ASan/UBSan also passes all 122 oracle cases without
sanitizer diagnostics (`out-perf/dlls-action-worker-sanitizers-01`). The C++ VM
adapter and encoder are instrumented; the existing Lua static library is not.
Negative cases must exit normally with a nonzero status and empty stdout; crashes
and timeouts do not count as successful rejection.


## Native tab-switch endpoint and initial DLL baseline, 2026-11-03

`tools/bench_tab_switch.py` now exercises actual native Ctrl+B,p actions against
four independently updating PTYs, instead of typing in an already selected tab.
Each producer publishes a tab identity, 16-bit generation and CRC8 packet in
opaque terminal cells at 30 Hz. Receipts bind producer identities to the runtime's
actual pane, tab and workspace IDs. Native readback requires the requested tab
and a generation at least as new as the receipt at input time and newer than its
last accepted presentation. The endpoint remains a positive
`MTLDrawable.presentedTime`; focus, initial readiness, matching grids and VSync
checks come from the ordinary harness, whose typing probe is unchanged.

The isolated builder preserves generated sources, helper binaries, commands and
hashes. Publication events bracket PTY writes with `CACurrentMediaTime`, allowing
the report to reject unproduced generations and check all four producers during
the observation window. It conservatively retains the 5% offered-rate gate in
every complete 500 ms window: at this rate, integer counts require exactly 15.
This is a method limitation near a window boundary, not permission to silently
accept a failed run. Runtime resource separation, probe overhead, entire terminal
content equivalence, workspace switching and continuous 120 Hz cadence remain
open. A display reporting a 120 Hz maximum does not close those requirements.

Twelve focused tests pass, covering packet corruption/truncation, generation and
native-clock provenance, a producer stall, and four real PTYs surviving marker
withdrawal/restoration, resize and termination. Native wrong-tab, stale-generation
and bad-checksum controls pass in both complete stacks: all six qualify initial
presentation and then reject the first incorrect target with input timeout and
zero accepted responses. They are reproducible with `--negative-controls` and
were re-run through the final CLI in `/tmp/telar-perf-tab-switch-negative-03`.
The controls exercise the target oracle, not all possible presentation faults.

Producer qualification initially failed with select, Python sleep and
`mach_wait_until`; changing QoS and adding a Foundation activity did not solve it
and were removed. An isolated 180-tick comparison found median/max wake lateness
of 7.603/16.450 ms for Mach wait versus 0.053/2.794 ms for an absolute Mach-clock
kqueue timer with `NOTE_CRITICAL`. The final small C helper uses that timer only
in the owned benchmark producers, with no busy wait or system configuration
change. The native qualification then passed both stacks, 40 switches each.
These are generator diagnostics, not Telar improvements. Failed attempts remain
under `/tmp/telar-perf-tab-switch-qual-01` through `-07`; successful final
qualification is `-08` and generator evidence is in
`out-perf/dlls-tab-switch-qual`.

The initial baseline uses source HEAD `3da9ec736`, GUI SHA
`5a639c5f26f67892698088cd95e31555212e6508dae2e45a441dc58e641caef5`,
C++ runtime SHA `a0b8b9d5826cf80c135cc113a1587a552c054e4d733942ab34e98157a1717645`
and the same frozen original Zig SHA `6ccf79485c5ca8baaa2d69d2590abb49d23c808891c04fe6e70f5602713a1d5e`.
Both stacks use JetBrains Mono 15, optical thickening, opaque background, no
sidebar, four tabs, 1600×1000 backing pixels and an 82×21 grid. Six valid
alternating pairs contain 100 measured switches after 20 warmups per run.

`/tmp/telar-perf-tab-switch-pairs-01` completed five valid pairs; its sixth C++
attempt failed the predeclared rate gate and remains excluded. That producer's
observed rate was 30.00085 Hz, with 31.625–34.879 ms gaps, but publications near
500 ms boundaries produced counts of 14/16. A fresh complete sixth pair in
`/tmp/telar-perf-tab-switch-pairs-02` passed without changing that gate or the
workload, starting C++ first to retain the AB/BA order. All invalid artifacts are
retained; the combined receipt is `out-perf/dlls-tab-switch-qual/paired-summary.json`.
Medians of the six paired summaries, scoped to this instrumented discrete-switch
workload. Visible run-directory labels differed between stacks; the later working-
directory correction is required before matched-content acceptance:

| Metric | Zig | C++ | C++ wins |
| --- | --- | --- | --- |
| p50 latency ms | 38.370 | 43.100 | 1/6 |
| p95 latency ms | 43.425 | 49.151 | 0/6 |
| p99 latency ms | 47.546 | 49.285 | 2/6 |
| Maximum latency ms | 50.749 | 49.808 | 3/6 |
| GUI CPU ms/action | 17.217 | 29.741 | 0/6 |

This is a baseline regression, not an accepted optimization or F08 completion.
Separate native stack sampling in `/tmp/telar-perf-tab-switch-profile-01` overlaps
102 Zig and 91 C++ switches; its timings are excluded from the pairs. C++ samples
show QML delegate construction/destruction, hidden pane-header layout and binding
work, and new optical glyph rasterization after switching. Large sampled Metal
`nextDrawable` waits are waits, not equivalent CPU-work percentages. Source
inspection confirms keyed pane-model reconciliation replaces delegates when pane
identity changes, and `PaneArea.qml` constructs its header even for an unframed
single pane. Avoiding that unused header work is the next isolated candidate;
retaining glyphs across delegate lifetimes is another unaccepted memory/work
tradeoff. Neither follows merely from a general allocation hypothesis.

## Unframed pane-header experiment rejected, 2026-11-03

The first isolated candidate following that profile put `PaneHeader` behind a
synchronous Loader whose `active` condition was the pane's existing `framed`
flag. This avoids creating and updating unused header objects for a single
unframed pane, while preserving the existing framed and fullscreen behavior.
The source and candidate executable are preserved privately in
`out-perf/dlls-pane-header-lazy-01`; they are **withdrawn from production source**.
A is the frozen GUI SHA `5a639c5f26f67892698088cd95e31555212e6508dae2e45a441dc58e641caef5`;
B is `94c7bcf912d8e828f105ef677c095a842b299ffca4d1dac51d08199f0fc007b4`.
Both use the identical C++ runtime and command helper. Generated QML C++ and
ARM64 assembly are retained; the active binding reads the framed boolean. The
native structural test verifies that an unframed pane has no header instance.
No architecture-specific application kernel was introduced.

Functional checks passed: a new native test covers no unframed header, two
visible headers after splitting, click-to-focus on the correct pane and removal
after closing the split. Its first version incorrectly assumed traversal order
identified the original pane; it was corrected to find the header through that
pane's retained TerminalItem. Existing native split/tab, nested-grid recovery,
fullscreen-strip and configured-group keyboard tests pass, as does `gui-chrome`.
Full viewport PNGs are byte-identical between A/B for a single pane and four
splits, including the visible headers, in `/tmp/telar-perf-pane-header-pixels-02`.

The first capture attempt differed because the two run-directory names were
visible workspace labels. The corrected comparison uses a shared private working
directory, with no pixel masking or tolerance. `bench_tab_switch.py` now uses
that same policy for both stacks, including negative controls. The final CLI
qualification in `/tmp/telar-perf-tab-switch-cwd-qual-01` passes both complete
stacks with 20 warmup and 20 measured switches each, without claiming timing
acceptance from one pair. All 12 focused tests pass again; stricter input-source
anchor checks in the builder preserve the measured native probe and producer
sources byte for byte. Earlier six-pair
Zig/C++ figures above used different run-directory labels and are therefore
initial diagnostic data, not final matched-content acceptance; repeat that
comparison with the corrected working directory before any full-flow claim.

All subsequent candidate pairs use the same working directory, four 30 Hz
producers, strict target/generation and offered-rate gates, 100 measured switches
and 20 warmups. There were no invalid rows in either candidate switch series.
The initial hypothesis specified at least 5/6 GUI-CPU wins, without a consistent
latency regression. It failed that criterion despite a promising latency result.
An independent six-pair confirmation was then declared for p50 and p95 latency,
each requiring 5/6 wins, with the exact same candidate and reversed initial order.
It failed p50. Do not merge the exploratory and confirmatory samples to bypass
that result.

| Switch metric | Exploratory A → B (wins) | Independent A → B (wins) |
| --- | --- | --- |
| p50 ms | 45.190 → 40.518 (6/6) | 42.929 → 40.626 (4/6) |
| p95 ms | 49.255 → 45.599 (6/6) | 48.743 → 45.603 (6/6) |
| p99 ms | 49.398 → 47.101 (5/6) | 49.469 → 47.278 (4/6) |
| Maximum ms | 49.826 → 47.675 (5/6) | 49.727 → 48.903 (4/6) |
| GUI CPU ms/action | 29.947 → 29.269 (4/6) | 29.136 → 29.367 (4/6) |
| GUI lifetime peak RSS MiB | 207.352 → 205.523 (4/6) | 204.414 → 205.469 (3/6) |

The already-started settled-input regression series was allowed to finish.
Single-pane p95 loses consistently, giving an additional rejection under the
existing rule; the cause is not established and code placement is not proven.
These are six alternating pairs per layout, also with identical working labels:

| Settled input metric | Single A → B (wins) | Four splits A → B (wins) |
| --- | --- | --- |
| p50 ms | 24.966 → 24.995 (4/6) | 25.160 → 25.233 (2/6) |
| p95 ms | 31.999 → 32.219 (1/6) | 33.065 → 32.663 (4/6) |
| p99 ms | 33.684 → 34.264 (4/6) | 37.047 → 34.345 (4/6) |
| Maximum ms | 39.646 → 37.108 (6/6) | 37.262 → 38.150 (3/6) |
| GUI CPU ms/input | 4.048 → 4.060 (2/6) | 4.338 → 4.368 (3/6) |

Raw series are `/tmp/telar-perf-pane-header-pairs-01`,
`/tmp/telar-perf-pane-header-confirm-01` and
`/tmp/telar-perf-pane-header-regressions-01`. Their favorable p95 and maximum
latencies are retained as observations, not selected for promotion. No Zig or
120 Hz victory follows, and all F01–F16 remain open. The next diagnostic separates
continuous producer/drawing cost from switching cost on the frozen original C++
GUI, before choosing a larger work-reduction or bounded-retention change.

## Switching versus continuous background work census, 2026-11-03

A separate diagnostic on the frozen original C++ GUI compares three alternating
pairs with identical working labels and four 30 Hz producers. The normal variant
performs previous-tab actions. The control leaves tab zero selected and observes
fresh, CRC-verified generations on positive native presentations without injecting
an action. Its reported observation waits are explicitly **not input latency**.
Both retain the publication provenance and all four offered-rate checks; all six
runs pass. Sources, native probes and receipts are in
`out-perf/dlls-tab-switch-work-census` and
`/tmp/telar-perf-tab-switch-work-census-01`.

GUI CPU divided by its measured wall interval is 9.16%, 10.11%, 9.81% of one
core without switching, versus 33.28%, 31.87%, 31.64% with switching. Medians are
9.81% and 31.87%. These observations prioritize switching-related work, but do not
identify one cause or prove a 22-point optimization opportunity: runtime work is
not included, the response-driven observation cadence differs, and probe overhead
remains unqualified. In particular, this does not turn a wait into CPU work or
make the rejected header candidate acceptable.

The next candidate should investigate bounded retention of the complete pane
presentation and its glyph resources across tab changes, rather than assume that
one hidden header dominates. Preserve pane/generation identity, focus and held
input release, IME/copy/scroll state, image budgets, close/invalidation behavior
and renderer-thread resource destruction. Hidden panes must not acquire extra
rendering work merely because their disposable client objects are retained.
This is a hypothesis supported by the profile and control, not an implemented or
accepted cache. The allocation/copy/Qt-conversion brief and Adrian's allowance for
bounded memory in exchange for less work remain part of the investigation.

The rejected QML and test changes are removed and the original source rebuilt.
The rebuilt GUI hash is `24236ffa9b107578541847d52bf528704a47cec3b05d1e44fd48bdd16bb6226f`;
its 6,850,340-byte `__TEXT/__text` section is byte-identical to the frozen original,
as are the other inspected text sections except `__const`. This is a restoration
check, not a new performance result. Continue using the immutable original A
executable for comparisons until qualifying any newly rebuilt binary.

## Bounded pane-presentation retention: rejected, 2026-11-03

The whole-pane cache experiment retains at most eight hidden client presentations
beside the active layout, keyed by machine/client/runtime epoch and pane generation.
It preserves active-pane API semantics through a separate presentation model,
reuses QML delegates, skips hidden preparation/resizing, and retires held input,
IME, wheel and link state on hiding. Closed, replaced and evicted views are removed;
existing global image/glyph budgets and render-thread destruction remain intact.
This is an archived experiment, **not an accepted production change**.

The frozen baseline remains GUI `5a639c5f26f67892698088cd95e31555212e6508dae2e45a441dc58e641caef5`.
The candidate is `77e003f3fb056189a9eff31147f0642efd64af390d499c962b8ea53b98a23bd3`,
both using runtime `a0b8b9d5826cf80c135cc113a1587a552c054e4d733942ab34e98157a1717645`.
Sources, binaries, acceptance criteria, generated ARM64 disassembly and the exact
withdrawn patch are in `out-perf/dlls-pane-surface-cache-01`. The patch SHA-256 is
`be446956adc49caf5f231c010426fb9f7ff1db151aca4fdd5d0367e531a7e95a`.

The model passes persistent-index, generation/epoch, close/eviction, invalid-input
and 2,000-operation reference checks. Fifteen selected Cocoa/Metal Quick cases
pass, including actual delegate reuse, the retention bound, close, viewport,
fullscreen/splits, held mouse, keyboard/copy, configuration reload and window
replacement/reopening. Machine-window and graphics retention/recovery suites
pass; the graphics retention suite also passes all 22 entries with Metal.
Settled full-viewport PNGs are byte-identical for single, four-split and four-tab
layouts (`/tmp/telar-perf-pane-surface-pixels-01`). These are not a complete animated
content oracle or continuous-refresh qualification.

Six valid alternating 100-input pairs with four 30 Hz producers meet the declared
CPU and p95 targets. Complete pairs are rounds 0–1 of
`/tmp/telar-perf-pane-surface-pairs-03`, round 0 of `...-pairs-04`, and rounds 0–2
of `...-pairs-05`, in continuous A/B, B/A alternation. Median per-run results:

| Metric | Original A | Retained B | B wins |
| --- | ---: | ---: | ---: |
| p50, ms | 43.074 | 38.341 | 6/6 |
| p95, ms | 49.256 | 42.671 | 6/6 |
| p99, ms | 49.308 | 44.579 | 6/6 |
| Maximum, ms | 49.639 | 45.184 | 6/6 |
| GUI CPU, ms/input | 29.578 | 28.213 | 6/6 |
| GUI lifetime peak RSS, MiB | 204.664 | 217.766 | 1/6 |

The roughly 13.1 MiB higher peak RSS is the measured memory tradeoff; it is not a
measurement of exact live cache bytes. However, the independent six-pair typing
regression series (`/tmp/telar-perf-pane-surface-regressions-01`) **rejects** the
candidate. Four-split p99 rises from 33.973 to 37.258 ms and maximum from 37.124 to
40.369 ms, both with **0/6 wins**. Its p95 is 32.023 → 33.184 ms (2/6), CPU
4.168 → 4.296 ms/input (3/6). Single-pane p95 is 31.809 → 31.850 ms (3/6), CPU
3.992 → 4.014 ms/input (3/6); other single-pane latency wins range from 2/6 to 4/6.
The regression's cause is **not established**; no code-placement exemption is
claimed. Target gains and functional parity do not override that rejection.

Separate eight-second profiles overlap 97 original and 100 retained tab switches
(`/tmp/telar-perf-pane-surface-profile-01`). Non-overlapping inclusive stack
observations for QML construction fall 115 → 2, pane refresh 142 → 30, and native
glyph rasterization 34 → 0; QML variable writes remain 191 → 191. These support
reduced reconstruction work but are neither CPU-time attribution nor exact
allocation/conversion counters. Separate four-split profiles do not identify the
tail cause and must not replace the uninstrumented regression pairs. The working
C++/QML and cache tests have been restored after byte-exact archive verification;
all F01–F16 remain open. The restored GUI and Quick target build successfully.
The GUI SHA-256 is `747d48fac2a08d45e3b79848a2e3226a70a3abce0a0ff5e95b2f6e2edf763de7`;
its 6,850,340-byte `__TEXT/__text` section is byte-identical to frozen A. Of the
inspected text sections, only `__const` differs. Continue measuring immutable A;
this restoration check is not a code-placement explanation for B's regression.

The remaining variable-write samples are primarily downstream of
`TabStripLayout::rebuild` and `ListModel::reconcile`, where geometry updates notify
whole QVariant records and nested QML consumers. The earlier field-role candidate
also failed its regression gate and must not be silently reinstated. A next
experiment should isolate layout motion from semantic record updates with a
behavior/notification oracle, while independently investigating the four-split
tail. Neither the source reading nor the samples establish a new accepted fix.

### Producer shutdown receipt correction

The first attempt fails the unchanged offered-rate gate: a 500 ms bucket contains
16 publications even though overall rate is about 30 Hz. That run remains invalid.
Another attempt exposes a distinct shutdown race: the signal handler raises
`SystemExit` after incrementing the generation but before recording its publication.
A deterministic PTY test sends SIGTERM immediately after the third payload: the
old fixture records generation 3 with only two publications, while the corrected
fixture finishes all three and then exits. Shutdown now requests loop termination
rather than interrupting the publication transaction. All 13 fixture/packet/report
tests pass, and a fresh 20-input native A/B qualification passes before timing.

The failed runs and incomplete pairs remain archived and excluded; their valid
halves are not paired with unrelated executions. The 5% rate, identity, generation,
CRC, focus, geometry and positive-presentation checks were not relaxed. Integer
bucket quantization remains a documented harness limitation for separate work.
The receipt fix is retained independently of the rejected GUI experiment.

## Scalar tab presentation roles — rejected

On DLL base `d2ae9b30e`, this experiment replaced nested tab records in the
TerminalTabs delegate with sixteen independent model roles. The full-record API
remained available. An oracle compared 2,048 seeded insert/remove/reorder cases
with ListModel; role-specific notification checks and an actual QML selection test
verified that unchanged application marks and activity records were not rebound.
The model, activity and chrome suites passed, as did nine native Cocoa/Metal tab,
drag, focus and layout cases. Settled single/split/tab captures were byte-exact;
this does not qualify animated content.

Frozen evidence is under ignored `out-perf/dlls-tab-value-roles-01`: A GUI
`5a639c5f26f67892698088cd95e31555212e6508dae2e45a441dc58e641caef5`, B GUI
`e1379cf358c584ece3bc148e0c17a0f7f0dee1962294344cc802245b90b458f9`, source patch
`21c2ddd85c88d292485a0473407abdc550b525c654e2d3ab0410ee2cb4eaadcf`.
Six valid alternating target pairs are rounds 0–4 of
`/tmp/telar-perf-tab-value-pairs-01` and round 0 of `...-pairs-02` (B first).
Incomplete pair 5 of the first series failed the unchanged offered-rate gate and
was excluded in full. Median per-run results:

| Metric | Original A | Scalar-role B | B wins |
| --- | ---: | ---: | ---: |
| p50, ms | 43.069 | 44.533 | 3/6 |
| p95, ms | 47.882 | 49.214 | 1/6 |
| p99, ms | 49.295 | 49.333 | 0/6 |
| Maximum, ms | 49.624 | 49.707 | 3/6 |
| GUI CPU, ms/input | 29.900 | 28.757 | 5/6 |
| GUI lifetime peak RSS, MiB | 205.805 | 206.531 | 3/6 |

The declared target required CPU **and p95** wins in at least five pairs. CPU gains
do not override the latency rejection; its cause is not established. Independent
six-pair single-pane and four-split typing series (`...-tab-value-regressions-01`)
had no latency/CPU metric with 0–1 wins. That does not override the target failure.
Separate eight-second profiles overlap 94 A and 89 B switches. Non-overlapping
inclusive QML variable-write stack observations fall 249 → 31, while construction
remains 99 → 104 and pane refresh 124 → 130. These support reduced binding work,
not precise CPU or allocation attribution, and instrumented timings are excluded.
The candidate source and tests were withdrawn after exact archive verification.

Before candidate timings, an identical-binary A/A four-split control ran six
alternating pairs (`/tmp/telar-perf-split-identical-control-01`). Median p95 was
31.953 → 30.713 ms (4/6), p99 34.594 → 33.119 ms (4/6), CPU 4.156 → 4.279 ms/input
(2/6). No latency/CPU metric showed a consistent 0–1 directional loss. This records
host variability; it neither excuses the earlier pane-retention regression nor
establishes its cause. All F01–F16 remain open.

## Snapshot row retention and staged decoding — investigation open

On `0fcfdc42a`, the first experiment preserves cell rows and their presentation
revisions for same-pane, same-grid snapshots whose semantic cell contents match.
Delta invalidation remains unchanged; cursor, links, modes and frame identity
still advance. A 2,048-case seeded cell/row oracle exercises text, width, style,
pane identity, grid changes, detach, metadata and malformed late input. It fails
on the original implementation's unconditional row invalidation and passes the
candidate, including under Rosetta and ASan/UBSan. All 38 native Metal scene tests
pass, including retained-row cursor movement against forced reconstruction.

The probe now separates Screen application from TerminalScene synchronization and
supports full, one-row and unchanged snapshots. Seven alternating pairs for each
text policy are in `/tmp/telar-perf-snapshot-rows-components-01`; source and frozen
binaries are under ignored `out-perf/dlls-snapshot-row-retention-01`. Median combined
apply-plus-paint CPU times in milliseconds:

| Snapshot changes | Optical A → B | Wins | Standard A → B | Wins |
| --- | ---: | ---: | ---: | ---: |
| None | 6.653 → 0.274 | 7/7 | 7.073 → 0.276 | 7/7 |
| One row | 6.602 → 0.393 | 7/7 | 7.097 → 0.412 | 7/7 |
| All cells | 6.743 → 6.814 | 2/7 | 7.176 → 7.177 | 2/7 |

All six final visible captures match exactly. These component numbers exclude
encoding and do not measure input latency, native frame cadence or hidden-pane
scene retention. Application alone is consistently slower: the optical unchanged
case rises from 0.257 to 0.273 ms, the full case from 0.260 to 0.295 ms, both 0/7.
The benefit comes from avoiding downstream work; this is **not an accepted
full-flow optimization**. Arm64 assembly retains both decoder traversals and adds
semantic-style comparison and memcmp on the retention path; unchanged cells skip
stores and row-revision division. No vector or architecture-specific shortcut is
used.

The follow-up experiment stages decoded cells in a retained vector and commits
only after all spans validate, eliminating the second decoder traversal while
keeping malformed-frame atomicity. At the protocol maximum, its extra cell storage
is 130,359 × 32 bytes (about 3.98 MiB per Screen on this host); typical grids need
less. This is an explicit bounded-memory tradeoff, not a zero-memory claim. Added
checks cover a malformed later delta span, recovery, gaps, and no further injected
Screen allocations after capacity warmup. The source remains experimental under
`out-perf/dlls-staged-screen-decode-01`; native latency, resource and regression
acceptance are still required. No pane-retention cache has been reinstated, and
all F01–F16 remain open.

The staged variant passes the same 2,048-case oracle under native arm64, Rosetta
x86-64 and ASan/UBSan, all 38 native Metal scene cases, core/session/runtime-link
checks, four native tab/layout cases, and byte-exact settled single/split/tab
captures. Seven alternating component pairs per case are recorded in
`/tmp/telar-perf-staged-screen-components-01`:

| Snapshot changes | Optical A → B, ms | Wins | Standard A → B, ms | Wins |
| --- | ---: | ---: | ---: | ---: |
| None | 6.619 → 0.199 | 7/7 | 7.089 → 0.201 | 7/7 |
| One row | 6.636 → 0.333 | 7/7 | 7.108 → 0.331 | 7/7 |
| All cells | 6.720 → 6.684 | 6/7 | 7.114 → 7.087 | 3/7 |

Application-only CPU wins all seven pairs in every case; the optical full case
falls 0.256 → 0.187 ms. Arm64 assembly has one CellReader traversal followed by a
commit traversal over decoded cells; the two decoder call sites are the entry and
backedge of that single traversal. No native-latency conclusion follows from these
component results. GUI A is
`5a639c5f26f67892698088cd95e31555212e6508dae2e45a441dc58e641caef5`, staged GUI B is
`d63ca3a96192f551bfad6fe1dfdc7138d8e5c612ef6ef15b8857755d3d1064aa`; both use runtime
`a0b8b9d5826cf80c135cc113a1587a552c054e4d733942ab34e98157a1717645`.
Native qualification passes. Six alternating tab-switch pairs
(`/tmp/telar-perf-staged-screen-pairs-01`) finish without rejected runs: median
p50 44.326 → 44.075 ms (4/6), p95 49.239 → 49.066 ms (4/6), p99 49.304 → 49.301 ms
(4/6), maximum 49.966 → 49.416 ms (3/6), GUI CPU 30.471 → 29.718 ms/input (5/6).
The latency counts do not establish an F08 win. GUI peak RSS is 212.625 → 211.672
MiB (4/6); this is not the staging buffer's exact allocation size.

Six independent typing-control pairs per layout
(`/tmp/telar-perf-staged-screen-regressions-01`) have no consistent latency/CPU
loss. Single-pane p95 is 33.069 → 33.118 ms (3/6), CPU 4.260 → 4.089 ms/input
(4/6); its latency wins range from 2/6 to 3/6. Four-split p50/p95/p99 win 5/6 each,
p95 32.806 → 31.969 ms; CPU is 4.225 → 4.182 ms/input (4/6).

A separate direct Screen audit checks empty, one-cell, one-row and full-grid deltas,
plus full snapshots, using the same 82×21 grid. The first short batches expose a
fixed empty-delta cost: 13.175 → 17.950 ns, 0/7, while deltas with cells win 7/7.
These small durations motivate longer batches before final acceptance. Injected
allocator accounting reports 55,293 live bytes for original A and 110,397 for B:
exactly one additional 55,104-byte cell buffer, with no warm allocation churn.
The staged binary remains **unaccepted** while this empty-message path is repaired.

The follow-up in `out-perf/dlls-staged-screen-fast-empty-01` keeps validation and
metadata application in the common path and moves nonempty cell decoding/commit
into a separate helper. Empty deltas avoid staging-vector setup entirely. Added
functional checks require cursor, input modes, scroll and row metadata to advance
without invalidating cell rows. Final-source functional checks pass: core/session/runtime-link, the expanded
2,048-case oracle under Rosetta and ASan/UBSan, 38 native Metal scene cases and four
native tab/layout cases. The fresh GUI is
`d6dc9a4930ba8260020ddf6a050e9386d646368d2dc9912a29760eb8c280d66a`;
its source patch is `06ca097c76f666de8025c57911cce589b4c7de34a3905e1ab608488116d43009`.

Longer direct-kernel batches use 10 million measured empty deltas, 3 million
one-cell deltas, 200,000 row deltas and 10,000 full frames, after half as many
warmups in each process. Seven alternating pairs report:

| Frame case | Original A, ns | Separated-path B, ns | B wins |
| --- | ---: | ---: | ---: |
| Empty delta | 10.069 | 9.618 | 7/7 |
| One-cell delta | 43.130 | 31.074 | 7/7 |
| One-row delta | 783.203 | 471.355 | 7/7 |
| Full-grid delta | 15,788.996 | 11,356.992 | 7/7 |
| Full snapshot | 15,792.733 | 15,729.533 | 5/7 |

The direct fixture uses plain ASCII at 82×21; it is not the richer 256×52 scene
probe or a whole-client benchmark. Its allocator evidence remains 55,104 extra
live bytes and one additional allocation on cold initialization, with no warm
allocations. Arm64 production symbols confirm a separate nonempty helper.
The final separated-path variant is **rejected**. Six independent native typing
pairs (`/tmp/telar-perf-staged-fast-empty-regressions-01`) give single-pane GUI CPU
3.902805 → 4.017025 ms/input, only 1/6 wins. Its p95 is 32.794 → 32.657 ms, 2/6;
four-split CPU is 4.183 → 4.204 ms/input, 3/6. The cause is not established and no
code-placement exemption is claimed. The target tab-switch attempt fails the
unchanged offered-rate gate before completion; it supplies no acceptance evidence.
Component wins cannot override this independent native regression.

Final component pairs (`/tmp/telar-perf-staged-fast-empty-components-01`) still
show retained/sparse combined application-plus-paint wins in all seven pairs:
optical 6.594 → 0.197 ms and 6.539 → 0.328 ms; standard 7.105 → 0.200 ms and
7.060 → 0.333 ms. Full optical is 6.675 → 6.647 ms (3/7); full standard is
7.153 → 7.060 ms (6/7). All six final visible component captures are pixel-exact.

The new joint experiment, `out-perf/dlls-pane-row-reuse-01`, combines bounded
pane retention with staged decoding and unchanged snapshot row revisions. Its
contract explicitly retains the original frozen C++ baseline: neither rejected
parent is accepted. The intended saving is reuse of both QML delegates and
unchanged terminal rows when revisiting tabs. Extra bounded storage is allowed;
six fresh target pairs must win CPU and p95 at least 5/6, and a consistent
latency/CPU loss in independent single/split controls rejects it.

An initial native oracle catches two fullscreen-strip objects after changing
panes: the hidden cached delegate keeps its old strip. Requiring the pane to be
visible before loading fullscreen/attention chrome fixes the failure without
weakening the oracle. The corrected candidate passes 17 native cases, 38 Metal
scene cases and core/session/runtime-link/cache-model tests. The refactored
2,048-case Screen oracle also passes Rosetta and ASan/UBSan; pinned Zig 0.16 checks,
cross-compilation, style and module-boundary checks pass. A later final-binary repetition catches another correctness issue: opening a
split reports generation zero before a later snapshot resolves it. Cache identity
replacement destroys the terminal during mouse capture; a QPointer diagnostic
records generation 0 → 3. A new model oracle fails deterministically before the
fix. Only visible unresolved entries may retain their token when the generation
resolves; hidden unresolved entries are never cached, while known-generation and
runtime-context changes still replace tokens. The corrected candidate passes the
model oracle, 20 native cases, 38 Metal cases and six additional repetitions of
each previously failing mouse case. Modified-code static analysis passes; the
unchanged redundant-alias diagnostic in `config/callback.hpp` remains recorded.

The **joint candidate is rejected and withdrawn**. Final GUI B is
`713aefd658db8ed23149b72da7f82fb97e92378ac7118a695c878df72965eee0`,
source patch `6cb76158567333f90f0fc6aac008277fd71be5ac153af3512026443e7a45b346`.
Settled full-window PNGs match exactly for single, split and tab layouts.
Six alternating native typing pairs per layout
(`/tmp/telar-perf-pane-row-reuse-regressions-01`) report:

| Control | Metric | Original A | Joint B | B wins |
| --- | --- | ---: | ---: | ---: |
| Single | p95, ms | 32.609 | 31.595 | 2/6 |
| Single | p99, ms | 36.095 | 34.222 | 5/6 |
| Single | GUI CPU, ms/input | 4.004 | 4.027 | 3/6 |
| Four splits | p95, ms | 32.721 | 32.665 | 3/6 |
| Four splits | p99, ms | 34.247 | 35.212 | 1/6 |
| Four splits | GUI CPU, ms/input | 4.221 | 4.493 | 0/6 |

The split p99 and CPU losses reject the candidate. Peak GUI RSS is
205.063 → 206.906 MiB for single-pane and 204.914 → 204.430 MiB for splits;
extra bounded memory is allowed and is not the rejection reason. No target-switch
or final component acceptance batch runs after this independent rejection.
A separate eight-second sample of each frozen binary during four-split typing
(`/tmp/telar-perf-pane-row-reuse-split-profile-01`) is too sparse in application
code to establish the CPU cause. GPU-work medians and observed drawable-ID spans
do not show an obvious directional change. No code-placement exemption is claimed.

The reusable Screen probe completes seven pairs per case in
`screen-pairs-final`: empty delta 10.308 → 9.381 ns (7/7), one cell
42.704 → 31.194 ns (7/7), one row 784.999 → 473.190 ns (7/7), full delta
15,721.825 → 11,278.800 ns (7/7), changing snapshot 15,746.308 → 15,737.475 ns
(4/7), retained snapshot 15,806.979 → 15,630.496 ns (7/7). Each uses 55,104 extra
Screen-owned bytes at 82×21 and no warm allocation churn. These component wins
cannot override the native rejection. ARM64 inspection confirms the empty-span
branch and single decoding traversal. It also finds 512 bytes of temporary cache
identity initialization per validation; retaining that scratch is an unmeasured
follow-up, not an explanation for the measured regression.

The complete rejected source, generation and visibility oracles, binaries and
receipts remain in the ignored experiment prefix. Production changes are removed;
only generic Screen checks for atomic rejection, recovery, span gaps and
metadata-only deltas remain in the active source. The accepted baseline and all
F01–F16 acceptance requirements remain unchanged.

A follow-up allocation census (`out-perf/dlls-allocation-census-01`) remains a
private diagnostic prototype. Instruments' Allocations attachment invoked
SecurityAgent and invalidated focus after 59 responses; its incomplete trace is
not used. The alternative interposes six dynamic heap APIs in the owned GUI:
`malloc`, `calloc`, `realloc`, `free`, `aligned_alloc` and `posix_memalign`.
A known five-operation sequence verifies 344 requested bytes, four frees and one
realloc, both standalone and linked into the presentation probe. Overflowing
calloc, invalid alignment and absent-instrument negative controls also pass.
QtCore and the measured GUI import the covered classic allocation symbols.

Three alternating diagnostic four-split pairs, 100 inputs each
(`/tmp/telar-perf-allocation-census-splits-01`), count successful calls as
A/B 88,298/79,506; 83,346/83,317; 87,574/87,589. Requested bytes are respectively
11,776,269/10,839,052; 11,221,016/11,212,180; 11,656,520/11,672,380. These counts do
not show a consistent increase in B and do not explain the rejected CPU result.
The broad per-input medians are 875.74/833.17 calls and 116,565/112,122 requested
bytes, but the paired rows show why those medians must not be presented as a
repeatable allocation reduction. Instrumented latency is excluded from acceptance.

The census takes fieldwise atomic snapshots around the measured-input phase,
before result construction and cleanup. It includes framework and probe-induced
work outside the interposer image, excludes uncovered APIs/direct zone calls,
and neither attributes sites nor measures live/peak heap bytes. Returned usable
bytes are cumulative API results, including realloc, not net memory growth.
The next allocation investigation needs site attribution and a control for
probe-induced work; allocator lifetime or Qt conversion is not yet a demonstrated
cause of the native regression.

`gui-screen-probe` and `tools/compare_screen.py` now provide the direct Screen
workloads as reusable source. They verify final cells, reject warm allocation
churn, retain binary hashes and raw paired results, and report Screen-owned bytes.
They exclude encoding, Qt allocations, process RSS and native presentation timing.

The reusable `compare_terminal_scene.py` controller now supports
`--snapshot-workload full|sparse|retained` and
`--metric elapsed_ns|apply_and_paint_ns`. The default remains scene-only timing;
the combined metric requires a positive application duration and exact accounting
of application plus painting. Two native smoke invocations cover the legacy
arguments and retained/combined mode with exact visible pixels. Their one-pair
numbers are functional checks, not acceptance evidence.

## Sampled allocation sites and draw batches, 2026-11-03

A private bounded stack sampler extends the six-API census in
`out-perf/dlls-allocation-sites-01`. It samples approximately one in 64 successful
calls into a fixed 4,096-site table with 20-frame stacks and thread identities.
Contention, capacity overflow and truncated stacks are reported. A known control,
both standalone and linked into the native probe, records exactly five allocations
and 344 requested bytes at sampling period one. Storage does not allocate, but
backtrace and presentation-probe work remain part of the diagnostic environment.
This is neither allocation CPU attribution nor a live/peak heap measurement.

The native four-split qualification contains 20 inputs per variant in
`/tmp/telar-perf-allocation-sites-qual-01`. Original A records 289 samples from
18,326 observed successful API calls; rejected joint B records 280 from 17,678.
Neither run drops samples through contention or capacity. Respectively 59 and 54
stacks reach the depth limit. A/B render-thread samples are 228/222, main-thread
samples 51/46, and explicit probe-containing stacks 25/17. Do not extrapolate this
short qualification into a full-flow distribution or compare its instrumented
latencies for acceptance.

The dominant resolved stacks pass through `QArrayData::allocate`,
`QRhiBatchedBindings::Batch` growth, `QRhiMetal::enqueueShaderResourceBindings`
and `QSGBatchRenderer::Renderer::renderMergedBatch`. Source inspection confirms
that Metal constructs temporary binding batches for each call before comparing
them with the previous binding state. Project-containing stacks also include
`AncestorGeometry::observe`: it reconnects every ancestor on parent changes,
including during QML Repeater construction. Neither finding establishes the
cause of the earlier native CPU regression. Large sampled probe allocations
also prevent attributing all requested bytes to production code.

A separate original-A run with `QSG_RENDERER_DEBUG=render`,
`/tmp/telar-perf-baseline-render-batches-01`, consistently ends with 26 opaque nodes
in 12 batches and 83 alpha nodes in 28 batches. Inactive terminal glyph rows
already merge into one text batch per pane; a per-glyph draw-call explanation
would be incorrect. Most batches are retained but still submitted. This motivates
an isolated header-layer experiment: retain unchanged header pixels in small
textures, require exact visible output first, and then test whether fewer batches
outweigh offscreen rendering and texture storage. No optimization is accepted by
these diagnostics, and all flows remain open.

## Pane-header layers rejected by visual equivalence, 2026-11-03

The isolated `PaneArea.qml` candidate enables a layer only for visible headers
on known GPU backends. It trades header-sized texture storage for retained chrome
pixels, with original accepted A as the baseline. Neither variant is retained in
production source. No native acceptance timing was run after the visual rejection.

The RGBA8 candidate in `out-perf/dlls-pane-header-layer-01`, GUI SHA
`c788df0ca63bc4dfe14c1c76693453b3ccb0b83ce1e30b320525681acd0e0900`,
passes the unframed single-pane capture but changes 1,131 four-split header pixels
by one channel level. The full capture receipts and difference bounds are in
`/tmp/telar-perf-pane-header-layer-pixels-01`. The oracle is not relaxed.

An independently frozen RGBA32F refinement in
`out-perf/dlls-pane-header-float-layer-01`, GUI SHA
`114b4edaadcd9342eadcfbe378a00edf18abbebba2de6313e0055999f263fe69`,
passes exact settled single/splits/tabs captures in
`/tmp/telar-perf-pane-header-float-layer-pixels-02`. Nine selected native cases
pass, covering split/close/tab changes, pane focus and child mouse ownership,
fullscreen, attention, sidebar resize, configured bars and configuration reload.
A separate debug-render run in `/tmp/telar-perf-header-float-render-batches-01`
reduces the settled scene from 40 to 36 batches: opaque batches remain 12 and
alpha batches fall from 28 to 24. This is work-count evidence, not a latency win.
RGBA32F also requires 16 bytes per texture pixel before backend overhead;
allocation dimensions and residency were not qualified for acceptance.

The expanded Metal oracle compares a header containing blocked status, paused
progress and the images-paused label with its layer disabled, enabled, then
disabled again. At the first integer-aligned 460×30 logical header, 281 pixels
change by one channel level. The 980×180 backing-window captures are saved as
`/tmp/telar-perf-pane-header-float-oracle-fixed-{reference,layer}.png`.
Disabling the layer restores the original image exactly, ruling out a persistent
content change in that fixture. The first attempted restoration control was
invalidated by the window manager resizing the window; the corrected fixed-size
tool-window control removes that confound. Fractional-position and narrower-header
iterations are not reached after the first exact comparison fails.

Both QML variants and the experimental oracle are withdrawn. Their source patches,
frozen binaries, build/test logs, difference receipts and withdrawal decision
remain in the ignored experiment prefixes. The small pixel discrepancy is still
a visual regression; the reduced batch count does not justify accepting it.
Further draw-work experiments should avoid introducing this intermediate color
composition, for example by investigating batch compatibility of existing glyph
geometry. That is a source lead, not an accepted optimization.

## Per-vertex mask colors rejected by component controls, 2026-11-03

The isolated experiment in `out-perf/dlls-mask-vertex-color-01` moves mask color
from material uniforms into float vertex attributes. Compatible text/icon masks
can then batch across colors without offscreen composition. It preserves separate
sampling and blend material types, premultiplication and shader coverage formulas.
Vertex stride increases from 20 to 36 bytes, or 96 additional bytes per six-vertex
glyph quad. The candidate is **withdrawn from production source**.

Original accepted A remains GUI SHA
`5a639c5f26f67892698088cd95e31555212e6508dae2e45a441dc58e641caef5`;
B is `ffa1df64b2ce0dd3a310de26d83f5983093cbf036ad83a8c02e46b38f9369138`,
with the identical runtime, command helper and Qt installation. The frozen patch
SHA is `3c1ef558bd18c6d9d9f4545050dedf1fa5979e30c7296d610def267d22aafb73`.
Native single/splits/tabs captures remain byte-exact in
`/tmp/telar-perf-mask-vertex-color-pixels-01`. Existing Metal text, icon and scene
suites pass. A separate four-split debug run reduces alpha batches from 28 to 24,
with 12 opaque batches unchanged. No native latency/CPU acceptance follows from
that count or from diagnostic presentation samples.

The new generic icon oracle renders two semitransparent colored icons separately,
then together, and compares both image regions exactly before and after recoloring
at fractional positions. It passes with the candidate on Metal, actual OpenGL 2.1
and software. It is preserved independently of the rejected representation.
Generated shader inspection verifies a flat color input on Metal/HLSL/modern GLSL
and the existing legacy-GLSL qualifier fallback. The CPU text-scene probe's
experimental adaptation checks uniform opaque vertex ink before emitting its
existing single-ink digest; that adaptation is withdrawn with the candidate.

Seven alternating pairs for each optical/standard and retained/sparse/full mode
complete in `/tmp/telar-perf-mask-vertex-color-components-01`, without simultaneous
builds, tests or profiling. All six final 3600×2198 captures have zero channel
difference. Median CPU milliseconds per snapshot application plus scene update:

| Mode | A ms | B ms | B wins |
| --- | --- | --- | --- |
| retained-optical | 6.619460 | 6.729761 | 2/7 |
| sparse-optical | 6.587403 | 6.679302 | 1/7 |
| full-optical | 6.628179 | 6.814280 | 1/7 |
| retained-standard | 7.027967 | 7.096267 | 2/7 |
| sparse-standard | 7.105088 | 7.122310 | 3/7 |
| full-standard | 7.091248 | 7.148828 | 2/7 |

Sparse and full optical modes each win only 1/7, rejecting the predeclared component
control contract. Native timing pairs are not run for this rejected variant.
The retained color oracle and original icon suite pass on Metal, OpenGL and
software after withdrawal, and the offscreen CTest target and modified-file
clang-tidy pass. The test uses the repository component-window helper to prevent
a Cocoa tool window from disappearing on deactivation; an earlier OpenGL run
timed out while unexposed and is retained as a harness failure.
Address-bounded ARM64 disassembly shows shorter material comparison and uniform
update functions but additional color stores in `GlyphMesh::paint`. The paint
function changes, so this is not an established code-placement exception. More
vertex traffic is a plausible cost; the entire timing difference is not causally
attributed to it. The shader/geometry changes, frozen binaries, generated shaders,
assembly and withdrawal decision remain in ignored artifacts. All full-flow
acceptance requirements remain open.

The next isolated lead is Metal binding-batch storage. Qt already uses small
inline arrays for the initial buffer/texture/sampler lists, but each stage then
constructs four `QRhiBatchedBindings` containers backed by implicitly shared
vectors. The private `dlls-metal-bindings-inline-01` contract first requires an
equivalence oracle against the actual Qt container before any dependency change.
The original Qt installation remains unchanged; any eventual native experiment
requires separate immutable dependency prefixes.

## Metal inline binding storage, 2026-11-03

The isolated experiment in `out-perf/dlls-metal-bindings-inline-01` is not retained.
Its native timing series is discarded for elevated shared-host load following
Adrian's coordinator notice. The initial CPU rejection was based on that series
and is superseded: native CPU impact is inconclusive pending a qualified rerun.
The container oracle and diagnostic allocation census remain useful, but do not
establish a native performance gain or disprove the broader allocation/copy or
Qt conversion hypotheses.

The container oracle compares the actual Qt private template with four inline
resources and two inline batches. All 4,123 cases pass in Release and with
ASan/UBSan: exhaustive subsets of twelve bindings, empty and large streams,
gaps, repeated finish, copy/assignment, clear and reuse. Repeated finish preserves
Qt's existing duplicate-final-batch behavior. The standalone source tool
`services/gui-cpp/tools/check_qt_binding_storage.py` reproduces these checks with
a supplied managed Qt prefix and matching header. It generates the experimental
header only in ignored output and preserves Qt's copyright/license identifiers.
The final oracle also passes the repository clang-tidy profile.

Storage grows from 64 to 224 bytes per container, or 1,280 to 4,480 bytes in the
five-stage/four-type model. Seven alternating uninstrumented pairs exercise
construction, feed, finish, copying previous state and destruction. Median
nanoseconds per model frame are:

| Resources / binding stride | Original | Inline | Inline wins |
| --- | --- | --- | --- |
| Empty | 66.670 | 109.091 | 0/7 |
| 1 / 1 | 596.697 | 229.320 | 7/7 |
| 4 / 1 | 960.503 | 313.005 | 7/7 |
| 8 / 1 | 1372.197 | 729.363 | 7/7 |
| 4 / 2 | 1765.938 | 720.280 | 7/7 |
| 16 / 2 | 5487.367 | 2360.550 | 7/7 |
| 257 / 1 | 10799.400 | 5526.829 | 7/7 |

This is not a universal container win: empty construction regresses. A separate
instrumented census records zero allocations for the inline one/four-resource
contiguous cases, versus 160,000/240,000 calls over 10,000 original model frames.
Large fallback also has a tradeoff: the 257-resource case requests 979,216,448
bytes versus 656,640,000 cumulatively. These are requested bytes across repeated
allocations, not live or peak memory. No container timing includes Metal dispatch.

The native candidate changes only shader-resource binding storage in a private
copy of Qt's Metal backend. Vertex-input batches and the generic shared Qt
container remain unchanged. Baseline QtGui SHA256 is
`abd4bdf7f5042bc0cbae3f3dfdfbfa378deeea7a9fdc5a436dc83bf592d455a7`;
candidate is `34fa13cf15f18d19b7796ad82d7a51e43793e9fe5466a30aea3d079465002b55`.
The GUI, runtime and helper bytes are identical between A/B; other Qt framework
binaries are also identical. Qualification verifies the actual loaded QtGui and
byte-exact native single/splits/tabs captures. Seven graphics suites and ten
native cases pass. An initial preparation run could not find the Cocoa plugin
after framework relocation; explicit original plugin/QML paths fix this before
qualification and timing. The original installation is untouched.

ARM64 disassembly of `QRhiMetal::enqueueShaderResourceBindings` shows stack
reservation growing from 4,048 to 7,264 bytes, plus the same 96 bytes of saved
registers. The address span to the next symbol grows from 6,152 to 6,864 bytes;
static call sites grow from 89 to 95, including dynamic fallback paths. These
are not executed-instruction counts or evidence of a placement-only difference.

Six alternating native pairs in
`/tmp/telar-perf-metal-bindings-inline-regressions-01` use 100 measured inputs
after 20 warmups, identical 1600×1000 viewports and strict native marker,
geometry, focus, presentation and offered-rate checks. This agent ran no builds,
tests or profilers during timing, but later learned of concurrent CLI-port work.
The series ran 10:36:47–10:42:57 local time, overlapping the five agents active
since 10:40. Its initial load averages were already 7.05 / 9.92 / 7.01 on ten
logical CPUs. The following numbers are retained as discarded observations,
not acceptance evidence:

| Case / metric | Original | Inline | Inline wins |
| --- | --- | --- | --- |
| Single GUI CPU ms/input | 4.048870 | 4.091645 | 4/6 |
| Single presented p50 ms | 24.886990 | 24.911885 | 2/6 |
| Single presented p95 ms | 32.793789 | 31.717501 | 6/6 |
| Single presented p99 ms | 35.340820 | 35.576264 | 3/6 |
| Single peak RSS MiB | 204.406250 | 205.109375 | 3/6 |
| Four splits GUI CPU ms/input | 4.322370 | 4.336195 | 3/6 |
| Four splits presented p50 ms | 25.615646 | 25.832708 | 3/6 |
| Four splits presented p95 ms | 32.733261 | 32.896727 | 2/6 |
| Four splits presented p99 ms | 35.717754 | 35.046910 | 3/6 |
| Four splits peak RSS MiB | 211.578125 | 204.570313 | 4/6 |

The primary four-split CPU target requires at least 5/6 wins; the discarded
series obtains 3/6. Neither that count nor the single-pane p95 count can support
acceptance or rejection of CPU impact. The frozen CPU target is unchanged.
Tabs and fixed-rate load timing controls were not run after the initial decision.
Runtime resources, complete C++/Zig flow comparisons and 120 Hz cadence remain
unqualified. Any rerun requires a fresh low-load window and recorded load/process
checks before each A/B series; discard or repeat series affected by high load.

A separate three-pair native heap census in
`/tmp/telar-perf-metal-bindings-inline-census-01` confirms the intended reduction.
Median successful allocation calls per input fall from 839.38 to 508.76 (39.4%);
requested bytes fall from 112,733.61 to 101,571.05 (9.9%). Instrumented timings are
excluded. These six-API counters include framework/probe work and are neither
precise allocation-site CPU attribution nor live/peak heap measurement. They also
do not normalize the amount of rendering work under shared-host load. Fewer
observed allocations do not establish a native CPU gain in this experiment.

Only the reusable oracle and this report are retained. The private dependency
patch, binaries, raw measurements and decision remain ignored; no production
renderer or Qt recipe change is applied. All F01–F16 acceptance rows remain open.

A subsequent baseline variable-output profile attempted three background panes
at 0.125 MiB/s each plus interactive input in the fourth. The first launch stopped
at manifest preparation because the helper filename was wrong. After correcting
it, the native run lost foreground/key-window ownership after 115 responses and
was invalidated; both samplers were still waiting for a readiness file that this
non-throughput fixture does not emit. No useful stacks were collected. The owned
runtime/children exited and cleanup completed. Artifacts are under
`out-perf/dlls-variable-work-profile-01` and
`/tmp/telar-perf-variable-work-profile-02`. A post-run load receipt records
7.51 / 11.88 / 10.04. Other agents' worktrees/processes were not modified.

## Immutable ASCII font coverage candidate, 2026-11-03

The next isolated candidate is prepared in `out-perf/dlls-ascii-coverage-01`;
production `Face` remains unchanged. `TerminalItem::updatePolish` visits changed
rows and `requestRowFonts` checks each nonempty, non-continuation cell through
`FontCoverage::covers`. Every relevant scalar reaches `Face::covers`, which calls
FreeType's charmap lookup. The existing tab-switch profiles contain this path,
but only a few samples; they do not establish a dominant CPU cost. Row revision
filtering and the existing shaped-glyph cache already avoid some other work.

The candidate stores 128 immutable coverage bits after selecting the font and
applying its variation. ASCII queries read those bits; all other inputs retain
the original lookup. The selected charmap is not changed by later size/shaping
operations. This adds 16 bytes per `Face` (336 → 352 on ARM64), no cache heap
allocation, and 128 additional charmap queries per construction. Cold creation
is an explicit control, not a free precomputation assumption.

The source baseline is `65c69967d3bd679fe3a1fea475f973a7d3bb496c`, compiled with
LLVM 23.1.4 and the current managed FreeType/HarfBuzz archives. The frozen original
coverage probe SHA256 is
`0f33592bbb8a79749ec7a0cac09fbf199c85d30e14319bf68b5b7d8808e780cd`;
the Release candidate is
`62afde0ba7e28d8d50571f9ea245662af88a97a823e087f9d21cba3423ca0a14`.
Dependency/source hashes and commands are in the private build/oracle manifests.

The reusable `gui-font-coverage-probe` and `check_font_coverage.py` compare exact
coverage bitmaps for every value through U+10FFFF, including surrogates, plus
U+110000, 0x1FFFFF and 0xFFFFFFFF. They check coverage again after metrics,
shaping and rasterization at heights 9, 13 and 31. Four bundled fonts and the
variable fixture at default/wide coordinates pass: 26,738,760 queries per probe
in both Release and ASan/UBSan candidate runs. FreeType/HarfBuzz dependency
archives are not sanitizer-instrumented. The corpus includes zero ASCII coverage
in the symbol font, partial coverage in the variable fixture, and distinct text
font coverage. Wrong-bit, truncated and trailing-output negative controls fail
as required. The source probe passes clang-tidy and clang-format.

A separate counted-call build confirms work removal without timing:

| Model operation | Original charmap calls | Candidate charmap calls |
| --- | --- | --- |
| Construct one face | 0 | 128 |
| 128,000 ASCII coverage queries | 128,000 | 0 |
| 8,000 non-ASCII/out-of-range queries | 8,000 | 8,000 |
| 62,000 one-byte cell coverage checks | 62,000 | 0 |

Results/checksums match. These counters wrap calls made by `Face`, not all
FreeType/HarfBuzz internal work or a native GUI workload. ARM64 disassembly
shows the ASCII bounds check and bit load/shift; the non-ASCII branch still calls
`FT_Get_Char_Index`. Actual `Face` source also compiles to x86-64 baseline and v3
assembly; the cached branch uses a bit test. This is codegen inspection, not an
x86 runtime or Linux qualification, and does not establish a speedup.

Four private benchmark modes (ASCII, Unicode, row preparation and cold creation)
have matching short-run checksums. No timing run has started. The load guard
captured 29.82 / 28.73 / 20.05 at 11:07 on ten logical CPUs and deferred the entire
series. It records `uptime` and active processes before each series/pair and after
each member; elevated load discards the complete series. The current conservative
limits are 5 at one minute and 7.5 at five minutes, with an additional check for
active compilers. Other agents and their worktrees are untouched.

The frozen contract requires 6/7 warm component wins without consistent cold or
Unicode losses, followed by 5/6 native four-split variable-output GUI CPU wins,
exact output/visual qualification and single/tabs/load regression controls. Native
and component timing, cold-cost assessment, complete GUI qualification, x86/Linux
execution and all F01–F16 acceptance remain open. Only reusable oracle sources,
their build target and documentation are retained in the branch.

The next qualification pass builds and freezes the complete reference/candidate
GUI and focused test executables, then restores both production `Face` files to
their committed contents. GUI SHA256 values are
`0d5ec9b958573ae7ee7a606a08e9d5537cc88606cca45467e2da8c27bd247f79`
(rebuilt reference) and
`999d09c4c9fe6b00020bbb40a77ac9910814411c8ad1104734642c6333d4b197`
(candidate). Runtime/helper binaries and managed Qt remain unchanged. The frozen
directories are `gui-A` and `gui-B`; the mutable GUI build currently contains
candidate artifacts despite restored source and must be rebuilt before reuse
as a reference. The private `gui-build.json` records targets, source patch and
all frozen hashes.

Font cascade, row text, optical text, font resolver and scene suites pass on both
versions with the offscreen/software test configuration. These include 432
byte-exact CoreText raster cases, 15 font-resolver QtTest entries and 37 scene
entries. The integrated coverage probes also pass all six font variants. Six
native Metal component captures (retained/sparse/full, optical/standard) match
at 3600×2198 with zero channel difference in
`/tmp/telar-perf-ascii-coverage-pixels-01`. Their probe-generated timing fields
are explicitly excluded under shared-host load. This establishes scoped visual
equivalence, not complete GUI input or 120 Hz cadence acceptance.

Full-window qualification against the previously accepted GUI stops during the
rebuilt reference's setup: the key-window/foreground control fails before any
responses, and the candidate is not reached. The recorded frontmost `telar`
process is PID 51675, distinct from owned GUI PID 51410. Both owned runtimes and
children are confirmed cleaned up. This attempt in
`/tmp/telar-perf-ascii-coverage-native-qual-01` remains invalid; no focus check is
relaxed and no native timing conclusion is drawn.

The rebuilt reference's different hash is explained independently: comparison
with accepted GUI `5a639c5f26f67892698088cd95e31555212e6508dae2e45a441dc58e641caef5`
finds identical executable code and every other file-backed Mach-O section except
32 bytes in `__TEXT,__const`. All differences are the low four bytes of eight Qt
resource modification timestamps. Their positions match the local RCC writer's
14-byte resource record prefix plus eight-byte timestamp; resource contents are
unchanged. This is recorded in `reference-sections.json` and
`reference-data-differences.json`, and does not substitute for native qualification.
Load remained elevated (15.32 / 19.54 / 19.23 at 11:21); component and native
acceptance timing have still not started.

At 11:31 the host becomes eligible under the frozen limits, with no active
compilers. Seven alternating component pairs complete in `pairs-01`: 56 runs,
85 valid boundary observations, maximum one/five-minute load 4.80 / 6.85 and
no observed active compiler. No builds, tests or profilers run alongside them.
Median CPU nanoseconds per operation:

| Operation | Original | ASCII cache | Cache wins |
| --- | --- | --- | --- |
| One ASCII query | 9.6580 | 1.4506 | 7/7 |
| One non-ASCII/out-of-range query | 16.8971 | 17.2167 | 1/7 |
| 62 one-byte cell coverage checks | 695.275 | 202.650 | 7/7 |
| Construct face, query A and destroy | 8507.000 | 9483.330 | 0/7 |

Wall-time win counts agree. The Unicode and cold controls reject the predeclared
contract despite the warm ASCII/row gains. The actual coverage implementation
changes, so there is no identical-code placement exemption. This candidate is
rejected, not waiting for native timing; production `Face` still equals the
original. Its source, qualified GUI artifacts and rejection are retained privately.
No full-flow speedup or native CPU result is claimed. A possible follow-up is a
cache scoped to main-thread row-font requests, populated only by actual queries;
it must first establish correct font-generation invalidation and its own controls.
The renderer's existing ligature data is not directly reusable by the main-thread
face: `TerminalFrame` passes a font collection and `ResidentFonts` caches per thread.

## Shared-host measurement qualification, 2026-11-03

The native latency CLI previously recorded only its initial process list. It now
uses the reusable `tools/benchmark_host.py` gate before preparation, before the
series, around every attempted variant and after the series. Load limits and
active-compiler checks are frozen in `host-load.json`; high load or a missing
observation irreversibly excludes the entire series. Raw results remain, but no
aggregate is published. The observer source is copied into the measurement's
source manifest. Direct callers of `measure()` must opt into the gate themselves;
functional image oracles are not timing acceptance runs.

Twelve focused tests pass, including real runner control flow with mocked host
observations: high initial load prevents the probe build/workload, and interference
after a second run prevents aggregate generation even though the first run was
clean. Other cases cover capture failure, compiler detection, sticky invalidation,
cleanup ordering, invalid limits and the final checkpoint. The 19 existing native
comparison tests also pass. No GUI/runtime production behavior changes.

A real CLI attempt in `/tmp/telar-perf-host-load-cli-01` exits 2 at `before-setup`
under the observed shared load. Its report is `deferred`, with zero started runs;
no probe library, runtime or GUI was launched. Boundary snapshots have limited
temporal coverage and are not proof of an otherwise idle machine. The ASCII
coverage candidate was subsequently rejected by its component controls; all
full-flow timing/cadence requirements remain open.

## Variable-output sampled work, 2026-11-03

Two fresh diagnostic repetitions in `/tmp/telar-perf-variable-work-profile-03`
use the frozen accepted GUI `5a639c5f26f6`, runtime `a0b8b9d5826c`, and original
QtGui `abd4bdf7f504`. Each qualifies 240 measured inputs, four panes with grids
39×19 (primary), 18×19, 8×19 and 9×19,
and three variable-ASCII producers at 0.125 MiB/s each. Both offered-rate checks
pass, and both owned runtimes report complete cleanup. GUI and runtime are sampled
for eight seconds each, with process-path/hash verification; these instrumented
runs do not qualify latency, CPU, throughput or cadence. The private controller
and manifests retain the source and binary identities.

Inclusive stack occurrences, counting nested matches only once within a group:

| Group | Repetition 1 | Repetition 2 |
| --- | ---: | ---: |
| GUI `requestRowFonts` | 11 | 10 |
| GUI `FontCoverage` | 9 | 9 |
| GUI `updatePaintNode` | 50 | 64 |
| Qt `renderMergedBatch` | 68 | 52 |
| WindowServer `SLSObscureCursor` | 91 | 96 |
| Runtime checkpoint `Snapshot::changed` | 10 | 6 |
| Runtime `PaneObservationService::refresh` | 10 | 20 |
| Runtime `CellProjection` | 6 | 7 |

These groups overlap and must not be summed. Sleeping/waiting threads dominate
the profiles, so counts are not CPU percentages. The cursor path waits in
`mach_msg2_trap`: local Qt Cocoa `qnsview_keys.mm` calls
`NSCursor.setHiddenUntilMouseMoves` before IME processing for non-command/control
keypresses. No cursor/IME behavior is changed, and causality remains unproven.
Exact per-input timestamps were not retained, limiting interval attribution.

Source inspection identifies an independently testable work reduction:
`persistence/snapshot.hpp::changed` visits all 256 pane slots and compares/writes
their stamps on every configured session-store tick, even with four panes.
An isolated experiment under ignored `out-perf/dlls-checkpoint-scan-01` explores
ending after the live pane count and retaining the previous extent to detect
removals. Font coverage remains a small sampled path; its rejected eager cache
is not reinstated.

## Count-limited checkpoint scan rejected, 2026-11-03

The candidate adds one `size_t` of state and stops after finding the current
live pane count. It clears stamps up to the previous extent after removals.
The private component probe extracts the actual A/B `changed()` bodies and
stamp definitions, substitutes lightweight pane/model fixtures, and applies
`noinline` equally. Its timings do not measure the full runtime's object layout.
A deterministic oracle compares 200,513 transitions and settled rechecks,
including sparse/full occupancy, identity, dimensions, close flags and all
three revision sources. Native Release, ASan/UBSan and x86-64 under Rosetta pass.

The committed persistence test now checks the real `Snapshot` with owned PTYs:
directory revision, independent dimension changes, text output without persistent
changes, combined close flags, revisions, a hole before a live pane, removal of
the last pane, re-addition and replacement without an intervening observation.
The focused persistence suite passes against the original and candidate headers,
including a sanitized candidate translation unit. Existing dependency libraries
are not sanitized. Final builds have no compiler warnings; formatting and diff
checks pass. An exploratory full-TU clang-tidy invocation exits zero but emits
repository-style/header warnings; it is not a clean lint result. The normal
runtime lint target excludes tests.

Three combined series were discarded when other compilers appeared at their
boundaries. No partial results were reused. Subsequently each case ran as its
own complete seven-pair alternating series, with separate host qualification.
All eight qualify: 240 boundary observations, maximum one/five-minute loads
4.082/3.753, no active compiler observations. No builds, tests or profilers were
run alongside these timings. Median process CPU nanoseconds per call:

| Pane state | Original | Candidate | Wins |
| --- | ---: | ---: | ---: |
| Empty | 337.725 | 1.971 | 7/7 |
| One low slot | 348.823 | 3.647 | 7/7 |
| Four low slots | 394.560 | 12.416 | 7/7 |
| All 256 occupied | 591.234 | 645.752 | 0/7 |
| Four highest slots | 373.839 | 406.373 | 0/7 |
| Four spaced slots | 411.517 | 333.703 | 7/7 |
| Alternating fourth-pane removal/addition | 370.445 | 12.145 | 7/7 |
| Directory revision on every call | 396.151 | 12.680 | 7/7 |

Wall-time win counts agree. **Rejected** for the two consistent control losses;
no production header was changed or native performance victory claimed. Actual
integration disassembly has different bodies (304 → 472 bytes on AArch64),
including the live-count work and tail cleanup, so no identical-code placement
exception applies. The precise contribution of each added instruction is not
established. x86-64 baseline and v3 lowerings were also generated; Linux runtime
qualification remains open.

The next candidate is maintaining the occupied extent when `SlotStore` changes,
then scanning that prefix without a per-slot live counter. This would move work
from every checkpoint tick to insert/remove operations, at a small bounded memory
cost. It still needs store-lifecycle oracles, dense/mutation controls and whole
runtime measurements before acceptance.

## Maintained checkpoint extent: no native CPU win, 2026-11-03

The follow-up in ignored `out-perf/dlls-checkpoint-extent-01` maintains an occupied
prefix in `SlotStore` on insert/erase and scans that prefix in `Snapshot::changed`.
Previous stamps beyond a shortened prefix are cleared. It adds one `size_t` per
store and one to `Snapshot`, without changing the existing full-span `items()`
API. The runtime uses stores for panes, clients, workspaces, worktrees and
executions; the mutation cost therefore needs controls beyond pane scanning.

The oracle uses actual copied `SlotStore` implementations and extracted snapshot
bodies with lightweight pane fixtures. It checks 201,028 transitions, settled
rechecks, holes, full occupancy, rejected inserts, replacement and stale handles.
Release, ASan/UBSan and Rosetta pass. Broken extent shrinking and lost removal
detection are both rejected by negative controls. The real persistence suite
also passes against A/B and sanitized B through a Clang VFS overlay; production
headers remain unchanged. x86-64 baseline/v3 code was generated. Linux runtime
qualification remains open.

Seven alternating pairs per component case all pass their host gates. Median
process CPU nanoseconds, A → B: empty 337.066 → 2.915, one pane 348.069 → 3.628,
four low slots 395.146 → 12.472, four highest slots 373.687 → 365.275, spaced
slots 398.062 → 315.880, mutation followed by scanning 386.719 → 26.210,
revision changes 388.543 → 13.747, and cold snapshot construction plus scan
551.648 → 178.760; all win 7/7. Dense occupancy is unresolved at component level:
581.093 → 598.526 (2/7), then an independently qualified repetition
594.341 → 584.271 (6/7). Both series are retained. Pure insert/remove, declared
separately before timing, costs 20.099 → 22.211 ns (0/7); moving work to mutation
does not make that work free.

The full candidate runtime is `dfee66b94e26`; GUI `5a639c5f26f6`, helper
`87beebb065f0` and QtGui `abd4bdf7f504` are unchanged. The rebuild of original
runtime source has identical code, data, addresses and file bytes outside its
UUID/signature to the accepted runtime; the native A still uses the original
accepted `a0b8b9d5826c` binary. No production source was installed or replaced.

Real-session A→B→A, B→A→B and B→B→B restore checks pass. The attempted existing
cross-Zig driver fails at its first Zig seed because it uses the C++ `cqp00001`
wire client against Zig's different schema; this is not cross-runtime checkpoint
qualification. Native `/tmp/telar-perf-checkpoint-extent-qual-01` qualifies
single, splits, tabs and variable fixed-rate output, with byte-identical settled
PNGs for the three static cases. All owned runtimes report complete cleanup.

`/tmp/telar-perf-checkpoint-extent-native-01` completes six alternating pairs:
100 measured inputs after 20 warmups, four panes at 1600×1000 with grids 39×19
(primary), 18×19, 8×19 and 9×19, three variable
ASCII producers at 0.125 MiB/s each. Every offered-rate check passes. Its 26 host
observations qualify, with maximum one/five-minute load 4.537/2.964 and no active
compiler observations. No builds, tests or profilers from this task overlapped
the series.

| Native metric | Accepted A | Candidate B | Wins |
| --- | ---: | ---: | ---: |
| Input-to-present p50, ms | 31.103 | 31.365 | 2/6 |
| p95, ms | 36.737 | 35.893 | 5/6 |
| p99, ms | 40.952 | 38.237 | 4/6 |
| GUI measured CPU, ms/input | 13.705 | 13.812 | 3/6 |
| Runtime session CPU, ms | 859.904 | 855.974 | 3/6 |
| Runtime session CPU, ms/second | 53.541 | 53.150 | 3/6 |

The runtime window brackets GUI launch and exit, including setup, warmup and
boundary-observer time. It is not the GUI measured-input window, and their CPU values are not
summed. Produced bytes are retained alongside duration/rate: medians
5,365,760 → 5,386,816 bytes. **Rejected for insufficient native target gain**:
both runtime CPU metrics win 3/6, below the predeclared 5/6 requirement. This is
not a claim of a proven runtime regression. Neither the large component gain
nor p95 improvement overrides the failed target. No further checkpoint variant
is promoted; larger-cost work remains the next profiling priority.

The external observer is retained as `tools/macos_process_resources.h/.c` and
`tools/native_runtime_resources.py`, independently of the rejected optimization.
It queries the verified runtime outside the GUI phase and leaves the native probe
binary unchanged. CPU conversion uses the recorded 125/3 Mach timebase on this
host. Fresh self/child controls agree with `getrusage`; invalid-PID and seven
identity/counter/clock controls reject. Nine Python tests cover representation,
conversion, receipt preservation, PID reuse and cleanup after capture/native
failure. All 20 qualification/timing receipts replay identically through the
source adapter; an owned-child run also verifies actual capture and cleanup.
The helper builds with `-Wall -Wextra -Werror`; it remains a
Darwin-only measurement tool, with explicit window limitations documented in
the flow matrix.

## Attached row text experiment, 2026-11-03

**Rejected for insufficient native CPU gain.** The accepted production scene
sources are restored; the private candidate remains under
`out-perf/dlls-attached-row-text-01`. No flow is closed by this experiment.

`TerminalScene::paintRow` detached its retained text root before every changed-row
update. Local Qt source confirms that removal recursively releases renderer shadow
nodes, and reinsertion creates them again. The candidate borrowed a caller-owned,
attached root in `TextScene`, deleting only its shapes/decorations siblings and
preserving their draw order. It added no cache or persistent storage. A diagnostic
full-scene run counted 364 reused roots and 53,746 descendants across seven updates:
all roots were detached in A and attached in B. These are application node counts,
not measured heap allocations or a count of all renderer work. Geometry/material
updates and chunk replacement still occur.

The existing scene probe performed all updates before its first rendered frame.
It now has `--render-each-frame`, advancing from frame swaps, and
`--floating-window` for tool-window treatment by tiling managers. Synchronization
timing includes immediate renderer dirty notifications but excludes later rendering
and presentation. The comparator passes these options, validates the schedule and
uses the shared host-load gate around every variant. The changing-text/decoration
oracle now explicitly covers standard and optical rendering.

All 38 scene checks pass for A and B with both software and Metal rendering.
Six native full/sparse/retained × standard/optical comparisons have identical RGBA
pixels. Six additional comparisons confirm identical final pixels between the
probe's batch and render-between-updates schedules. The first nonfloating image comparison was invalid: the window manager
resized only A. Both partial ASan/UBSan builds initially reported libc++ container
annotation failures in the unchanged, partly uninstrumented `Screen::reserve` path.
Both pass all 38 checks with container annotations and leak checking disabled;
ordinary address/UB checks remain enabled. Dependencies are not fully instrumented.
This is qualified partial sanitizer coverage, not a clean full-dependency run.

One qualified seven-pair component series measures full optical synchronization at
7.971 → 7.429 ms/update, winning 7/7 with identical pixels. The sparse optical
series is discarded after eight runs when the sampled one-minute load reaches
7.859, above the fixed limit of 5. Remaining component cases are not timed. No
partial aggregate or replacement low-load tail is used.

Native qualification (`/tmp/telar-perf-attached-row-text-qual-01`) passes single,
splits, tabs and variable split load; all three static captures are byte-identical.
The unchanged accepted GUI `5a639c5f…` and runtime `a0b8b9d5…` are the reference;
candidate GUI is `2770f96f…`, using the same runtime/helper/Qt. The rebuilt reference
GUI is the previously characterized `0d5ec9b9…`; native timing uses the accepted
binary directly. AArch64 disassembly is archived; this variant has no new SIMD,
bit manipulation or target-specific kernel. No x86/Linux execution is claimed.

Six alternating native pairs each contain 100 inputs after 20 warmups, four panes
in a 1600×1000 window with grids 39×19 (primary), 18×19, 8×19 and 9×19, and three variable ASCII producers at
0.125 MiB/s each (`/tmp/telar-perf-attached-row-text-native-01`). All rates and owned
process cleanup pass. All 26 host observations qualify, with maximum one/five-minute
loads 3.687/3.567 and no active compiler observations. Boundary checks cannot exclude
every transient source of interference.

| Native metric | Accepted A | Candidate B | Wins |
| --- | ---: | ---: | ---: |
| Input-to-present p50, ms | 31.523 | 31.062 | 5/6 |
| p95, ms | 37.414 | 37.428 | 4/6 |
| p99, ms | 41.113 | 41.090 | 4/6 |
| GUI measured CPU, ms/input | 14.683 | 13.797 | 3/6 |
| Runtime session CPU, ms | 894.937 | 875.075 | 2/6 |
| Runtime session CPU, ms/second | 55.382 | 54.448 | 2/6 |

The runtime observer brackets the whole GUI session, not its measured-input
interval; the CPU windows are not summed. Median background production is
5,395,456 → 5,388,416 bytes. The predeclared target requires GUI CPU wins in at least
5/6 pairs; 3/6 fails even though its median is lower. No consistent native regression
is established. The component gain does not override that failed target, and no
additional native series is run to seek a favorable result. Only the reusable
probe/comparator/oracle changes are retained.

## Lazy TerminalItem ASCII coverage — adoption deferred

Starting from `036d129d1`, `out-perf/dlls-terminal-font-requests-01` tests a
GUI-thread cache of primary-face coverage. Each TerminalItem gains 128 bytes of
unknown/missing/present state, cleared when its FontCollection changes. Repeated
ASCII avoids UTF-8 decoding and FreeType charmap lookup. Missing coverage still
requests fallback on every occurrence; Unicode and invalid-byte normalization
keep their previous path. There is no additional heap allocation count, but the
TerminalItem allocation grows. This differs from the rejected eager per-Face
cache: no constructor precomputation or shared mutable Face state is introduced.

The source-extracted oracle uses actual requestRowFonts and collection-install
bodies with real CellValue, Face, FontCoverage and QString normalization. Five
faces, font changes, repeated missing requests, every one/two-byte string,
Unicode boundaries and seeded cell flags produce 889,336 cells in 8,246 records.
Reference and candidate emit exactly 761,710 fallback requests. The promoted
`check_terminal_font_requests.py` also compares roles; both 10,018,306-byte streams
have SHA-256 `651a95191d7f3db30fca1864e55bc9abde0a90e6e2006e7d0460c12d70970b24`.
A deliberately omitted reset is rejected. Five malformed-record controls reject
truncated header/cell data, oversized text, invalid width and unknown font index.
The private ASan/UBSan oracle also passes; Face/probe code is instrumented, whereas
Qt/FreeType/HarfBuzz dependencies are not. Leak checking is disabled. Native font
discovery, asynchronous completion and rendering are outside this facade.

A separate census over 100,000 warm ASCII rows counts 25.6 million primary Face
coverage calls in A and zero in B. The Unicode control keeps 32 million calls;
128 unique cold ASCII scalars keep 12.8 million calls in both. The catalog facade
does not execute real secondary coverage lookup, so these are primary-method
counts rather than total application calls or allocation counts. No census
instrumentation is used for timings. Seven alternating component pairs give:

| CPU ns/row | Reference | Candidate | Wins |
| --- | ---: | ---: | ---: |
| Warm ASCII | 3356.55 | 401.32 | 7/7 |
| Unicode | 4780.12 | 4827.99 | 3/7 |
| Missing ASCII | 2246.54 | 879.55 | 7/7 |
| Cold 256-cell rows | 3336.75 | 1494.43 | 7/7 |
| Cold 128 unique ASCII cells | 1664.49 | 1323.84 | 7/7 |

All 150 host observations qualify: maximum one/five-minute load 2.069/2.281,
no active compiler observations. Cold unique ASCII benefits from bypassing the
UTF-8 wrapper despite having no coverage-call savings. ARM64, x86-64 and x86-64-v3
assembly compilation succeeds for both variants; only ARM64 runs natively.
The full GUI method grows from 600 to 724 code bytes, using cached byte tests to
skip calls. This is work elimination, not a claim of globally fewer instructions.

Both GUIs pass native input/rendering, cursor blink, split/tab and configuration
reload controls. Single/splits/tabs static PNGs are identical, and variable split
load qualifies. Native timing uses the accepted GUI `5a639c5f…`, candidate
`5c57b1b5…`, unchanged runtime `a0b8b9d5…`, helper `87beebb0…` and QtGui `abd4bdf7…`.
The separately rebuilt reference is `0d5ec9b9…`. All subsequent timings use frozen
stages, not the mutable build directory.

Six alternating loaded pairs contain 100 measured inputs after 20 warmups. The
1600×1000 window has grids 39×19, 18×19, 8×19 and 9×19, with three variable ASCII
producers at 0.125 MiB/s each. All 26 host observations qualify (maximum
one/five-minute load 2.987/2.387, no active compilers). Results:

| Native metric | Accepted A | Candidate B | Wins |
| --- | ---: | ---: | ---: |
| Input-to-present p50, ms | 31.389 | 30.627 | 3/6 |
| p95, ms | 37.325 | 37.380 | 3/6 |
| p99, ms | 38.605 | 40.845 | 2/6 |
| GUI CPU, ms/input | 14.594 | 14.389 | 5/6 |
| Runtime session CPU, ms | 895.038 | 923.614 | 2/6 |
| Runtime session CPU, ms/second | 55.650 | 57.407 | 2/6 |

The CPU target meets the predeclared 5/6 gate; the worse p99 median and runtime
trend are retained. Runtime counters cover the whole GUI session, not the GUI
input interval, and the windows are not summed. Median background bytes are
5,371,328 → 5,371,840. This result alone does not accept the candidate.

The separate single-pane control passes its no-consistent-loss criterion over
six pairs, each with five idle seconds and 100 inputs after 20 warmups. GUI CPU
is 2.452 → 2.467 ms/input (3/6); idle CPU is 3.233 → 4.617 ms/second (3/6).
Input p50/p95/p99 are 24.693 → 24.608, 32.640 → 29.958 and 33.695 → 33.260 ms
(3/6, 5/6, 4/6). All 26 host observations qualify, maximum one/five-minute load
3.268/2.929. The higher idle median is a mixed result, not an established saving.

The first tab-control series is incomplete: the accepted baseline times out on
its first input in round 1. A separate diagnostic reproduces that baseline failure.
The expected cyan pixel reaches GPU readback, but drawable 191 and 192 report
zero presentedTime, including a delayed recheck. Focus and geometry are valid;
all owned processes clean up. The cause of the zero timestamp is not established.
Neither incomplete series contributes timing evidence. The complete replacement
series also stops on its first input, this time in B during round 2. All host
observations pass in both attempts; neither series completes. The second failure
has no diagnostic readback enabled, so its cause is not inferred from the first.
Both incomplete series remain excluded. Positive native presentation remains
mandatory; no further timing retry is used to seek a favorable outcome. Adoption
and independent Zig/cadence comparison remain open. The production source is
still the accepted baseline.

A separate current-stack cadence diagnostic completes for A, B and independent
Zig (`/tmp/telar-perf-terminal-font-requests-cadence-qual-01`). It uses the unchanged,
previously fault-qualified phase probe and a current-driver adaptation with the
owned-producer completion gate. The 240 Hz producer, native pixels, focus, geometry,
positive presentations and cleanup qualify in all three runs. All eight host
observations pass; maximum one/five-minute load is 1.760/2.120. Results are single
observations, not paired acceptance:

| Cadence diagnostic | Accepted A | Candidate B | Independent Zig |
| --- | ---: | ---: | ---: |
| Changed content frames in six seconds | 688 | 683 | 626 |
| Changes/s, first-to-last timestamps | 114.660 | 113.825 | 104.312 |
| Longest changed-content gap, ms | 16.667 | 29.166 | 16.670 |
| Stable native refresh reference | 120.0006 Hz | Unqualified phase change | 120.0006 Hz |
| Two-refresh intervals | 32 | Unqualified | 94 |

B's reference changes phase, so its missed-refresh classification is unavailable;
the 0.25 ms native residual and 5% reference tolerances remain unchanged. A and Zig
both fail to sustain a content change at every qualified refresh. GUI CPU totals
are 0.612/0.692/0.675 seconds over separately bracketed 6.292/6.283/6.018-second
windows; these are unpaired diagnostics with probe overhead still open. The data
does not establish a C++/Zig win or a cache regression. Adoption is deferred because
valid tab controls and paired cadence evidence are missing, not because a
consistent regression has been demonstrated. Only the reusable oracle and report
are retained. The next diagnostic will inspect actual pacing decisions before
changing timers or inferring a scheduling cause.

## Pacing-decision census and fractional deadline prototype

`out-perf/dlls-pacing-decisions-01` instruments only the accepted WindowFramePacer
with a bounded 65,536-event ring, atomic publication and an exit-time dump. It logs
configuration, admitted/deferred requests, timer delivery and prepared frames. The
instrumented GUI is `68ad271c…`; its fixed buffer and logging overhead are diagnostic
only. Production source is restored after building. The first two runs do not
activate logging because the isolated launcher strips inherited TELAR variables.
They retain valid native records but have no pacing trace and cannot support
pacing attribution. The corrected launcher supplies the owned output path directly
and requires its trace artifact.

Two corrected six-second observations (`/tmp/telar-perf-pacing-decisions-02`) record
369 and 287 deferred requests. Their millisecond ceiling adds median 0.650/0.735 ms
and maximum 1.000/0.999 ms to the requested remaining deadline. Both configure an
8,333,334 ns GUI interval. They record 682/676 preparations, and neither ring fills.
Both display references change phase; the second producer also suffers an 86.993 ms
write delay despite passing the existing half-second offered-rate buckets. Thus
these traces establish the extra requested wait, not its share of missed refreshes
or a performance improvement. All six host observations qualify, maximum
one/five-minute load 2.596/2.438. Boundary load checks cannot exclude such transient
stalls.

A twenty-sample clock check compares CLOCK_UPTIME_RAW brackets with
CACurrentMediaTime. Exact integer bracketing initially fails because conversion to
integer nanoseconds truncates fractional Mach ticks; the largest excursion is
0.688 ns. Every sample fits with one nanosecond of integer quantization. The
separate native 0.25 ms residual and 5% display-reference criteria are unchanged.

`out-perf/dlls-precise-frame-deadline-01` then freezes an application-only candidate:
QChronoTimer replaces QTimer for deferred delivery, preserving single-shot/precise
behavior, eligibility, input grace, phase anchoring and the existing INT_MAX
millisecond cap. Stop precedes setInterval/start to avoid Qt restarting an already
active timer twice. This is separate from the deferred font cache and includes no
trace buffer. Candidate GUI SHA-256 is
`adae0eb6af0f1bd87ecd3bdf3803d08f84ff61cff9f47f83ba2cf02cb7fa8686`;
reference GUI remains `5a639c5f…`, runtime/helper/Qt remain unchanged.

All 18 window-adapter tests pass for each build. The unchanged pure FramePacer
corpus has 32,174 operations and byte-identical 434,071-byte outputs, SHA-256
`f2883262f71149bc561dd605286317cbc6caa307a13afb68e457c9482f062b5b`.
Its probe binary is also identical across A/B. Native single/splits/tabs static PNGs
match exactly and variable split load qualifies. These are functional checks, not
accepted latency measurements. ARM64 defer assembly shrinks 484 → 468 bytes;
QChronoTimer stop/setInterval/start replace the old timer call and ceiling
arithmetic. No x86/Linux execution or new sanitizer result is claimed.

The local Qt 6.12 source exposes a further limit: QTimerInfoList::timerWait in
`qtimerinfo_unix.cpp` rounds a positive remaining duration up to milliseconds, and
both the generic Core Foundation dispatcher and the actual Cocoa GUI dispatcher
consume that rounded duration. For this GUI the relevant caller is
QCocoaEventDispatcherPrivate::maybeStartCFRunLoopTimer in
`qcocoaeventdispatcher.mm`, which passes it to CFRunLoopTimer. QChronoTimer preserves its internal deadline,
but changing the application wrapper alone does not guarantee an unrounded native
wake. This additional rounding must not be omitted from the hypothesis.

One fresh diagnostic per stack (`/tmp/telar-perf-precise-frame-deadline-cadence-qual-01`)
qualifies native content and producers. Accepted A records 686 changes in six
seconds (114.326 changes/s), B 684 (114.072), and independent Zig 661 (110.154).
A and Zig have stable 120.0006 Hz references with 34/59 missed opportunities; B's
phase changes, so its missed-refresh classification is unavailable. All eight
host observations pass, maximum one/five-minute load 2.888/2.917. These unpaired
observations establish neither a win nor a regression. The six-pair cadence
acceptance controller is prepared but is not run after the failed reference
qualification. The candidate is not adopted; valid cadence acceptance and all
input/idle regression series remain outstanding. The working production source
is restored to A. The mutable GUI build contains the private candidate and must
be rebuilt before being used as a baseline; frozen accepted stages are unchanged.

## Fractional Cocoa timer wait experiment

`out-perf/dlls-qt-timer-wait-01` isolates the second rounding site in Qt 6.12.
A private QtCore relink returns the positive nanosecond remainder directly on
Darwin; other platforms retain the existing millisecond ceiling. Timer eligibility,
activation deadlines and storage are unchanged. Installed Qt and its source/object
files are untouched. The Cocoa dispatcher already accepts fractional seconds.

Original QtCore SHA-256 is `ab7cec95…`, candidate `5a49ee8a…`. An unchanged control
relink has exactly the original 3,951,112-byte executable text section, SHA-256
`98c46d0e23c0bce0cc9b98f0646271e44ebbaeacbde69c01acfa02d41a71726b`;
all link inputs are fingerprinted. Six full-TU assembly compilations pass for
A/B on ARM64, x86-64 and x86-64-v3. ARM64 timerWait removes the reciprocal multiply,
shift and round-up sequence. This does not establish whole-application CPU savings
or Linux/x86 execution.

The first QCoreApplication probe is unsuitable: it selects QEventDispatcherUNIX.
The corrected QGuiApplication probe creates no window and verifies the actual
QCocoaEventDispatcher, loaded QtCore path/hash, cancellation and no early delivery.
Both libraries pass those checks and all 18 existing window-adapter tests; the
latter use QCoreApplication and therefore are not Cocoa-specific tests.

Seven alternating pairs per case deliver 1,200 measured precise QChronoTimer
callbacks after 60 warmups. Fractional waits are 0.25/0.5/0.75/1.25/1.5/2.25 ms;
integer controls are 1/2/3 ms. Raw samples are retained without trimming.
`paired-01` is entirely discarded when load1 reaches 5.250488. Fresh `paired-02`
passes all 58 host observations, maximum load1/load5 3.620/2.907.

| Timer delivery lateness | A median | B median | B wins |
| --- | ---: | ---: | ---: |
| Fractional p50 | 1,054.500 us | 258.146 us | 7/7 |
| Fractional p95 | 1,568.229 us | 627.133 us | 7/7 |
| Fractional p99 | 1,598.335 us | 648.665 us | 7/7 |
| Integer p50 | 553.584 us | 549.875 us | 6/7 |
| Integer p95 | 827.398 us | 821.052 us | 7/7 |
| Integer p99 | 870.978 us | 854.965 us | 7/7 |

Fractional CPU/event is mixed, 36.378 → 36.188 us, 3/7 wins; integer is
35.963 → 34.932 us, 5/7. Integer maximum lateness worsens from median 1.021 to
1.486 ms, 2/7 wins. This maximum was outside the declared component gate and is
retained as an unresolved tail observation. No callback fires early. These are
component delivery latencies, not input latency or presented content FPS.

Native qualification combines this private library with the preceding QChronoTimer
GUI candidate, against accepted GUI/Qt A, with the same runtime/helper. Actual
loaded QtCore paths are checked from dyld logs. Single/splits/tabs static PNGs match
exactly; variable split load also qualifies. Six-second cadence diagnostics in
`/tmp/telar-perf-qt-timer-wait-cadence-qual-01` verify content and producer coverage:
A records 678 distinct changes (113.227/s), B 684 (114.072/s), independent Zig 701
(116.830/s). A/B display references change phase and cannot qualify missed-refresh
counts; Zig qualifies at 120.0006 Hz with 19 missed opportunities. The diagnostic
launcher enables dyld logging, so these observations are not paired acceptance.
No six-pair native target or input/idle regression series is accepted. This remains
a component gain with deferred adoption; working Qt/application source stays at A.

## Retained runtime cell deadline candidate

`out-perf/dlls-runtime-cadence-deadline-01` isolates a difference from the real Zig
attachment path. Zig saves the deadline when deferring a frame and consumes it on
the next preparation attempt. C++ recomputes `FramePacer::deadline(now)` when it
wakes; once a credit has accrued this returns null, so record() anchors at the late
wake instead of the scheduled cadence slot. With a 10 ms interval and a 3 ms late
wake, accepted C++ waits another 10 ms rather than the remaining 7 ms.

The candidate adds one optional time point to Attachment and exchanges it out at
the start of cell preparation. A pacing deferral stores the deadline; a successful
incremental preparation passes the previous deadline only if it has elapsed.
Early input and output-close bypasses cannot anchor in the future. Snapshot,
outstanding ACK, synchronized-output and burst-credit rules remain intact. This
matches Zig's handling of retained deadlines, including clearing them on an early
return. No timer, polling loop, GUI/Qt change or dynamic allocation is added.

The new `attachment-pacing-tests` target exercises actual AttachmentDelivery with
explicit time points and real decoded/ACKed frames. Ten scenarios cover on-time,
1 ns/3 ms/9 ms late wakes, repeated deferrals, ACK backpressure, early input,
snapshot bypass, interval reconfiguration, output closure, synchronized holds and
bounded catch-up bursts. Accepted source fails the scheduled-wake/reconfiguration
and early-output-close expectations; the candidate passes. An isolated copy of
accepted headers compiled with the same expanded test emits exactly the same
48,921 re-encoded frame-body bytes as the candidate, SHA-256
`af2f511d8be5ba6c402278459e4caa5e289954e351924014888df459831fe500`.
The capture decodes messages then serializes their complete bodies; it is not a raw
socket capture. Existing client-delivery and text test groups pass separately. Fixtures own and
reap their child processes. These deterministic checks prove the scheduling
correction and matched output, not native performance.

A/B assembly compilations cover ARM64, x86-64 and x86-64-v3 on macOS with
both the test allocator and the actual synchronized/budgeted runtime allocator.
Attachment grows from 32,592 to 32,608 bytes on all three, 16 bytes per attachment
and at most 1,024 bytes per client's 64 attachments. The emitted cells function
has 269 → 279 ARM64 instructions and retains its 128-byte stack frame; x86-64 and
v3 have 292 → 302 instructions. The scheduled path now uses the existing cadence
slot division. This is a scheduling correction, not a claim of fewer instructions.
Both touched headers compile independently. Address/undefined sanitizers pass on
the complete pacing test translation unit and preserve the wire digest; runtime-core
and external dependencies are uninstrumented and leak detection is disabled.
Linux or Rosetta execution is not yet established.

Frozen B runtime SHA-256 is
`66675b100049f967b5523ee4a26ff118fd83fc8aab42e1a303b23dbe34d837a6`;
accepted A is `a0b8b9d5…`. Both use accepted GUI `5a639c5f…`, helper `87beebb0…`
and original Qt. Native single/splits/tabs static captures are byte-identical;
variable split load also qualifies. All 18 host observations pass. The initial
cadence diagnostic has content-qualified A/B/Zig rates of 113.079/116.162/113.992
changes/s. A's display reference changes phase; B and Zig qualify at 120.0006 Hz.
B also has a 50 ms presented gap and a 52.561 ms producer delay. These observations
cannot establish a paired win. Two fresh native cadence series remain ineligible: `cadence-pairs-01` reaches
the last A run before its reference changes phase; `cadence-pairs-02` fails the
first A reference. All 25/3 recorded host observations pass (maximum load1
2.815/2.469), but neither controller completes host-series qualification. No
partial performance aggregate is accepted. Input/idle regression controls and
independent Zig/full-flow acceptance remain open.

`single-pairs-01` completes five alternating input pairs, then stops on round 5 B:
the first input after five seconds idle has no qualified presentation within two
seconds. The owned producer received the key and exits cleanly; the runtime and
children are reaped. All 23 recorded host boundaries pass. The entire incomplete
series is ineligible, with no aggregate accepted. Four separate after-idle diagnostic
startups (`idle-diagnostic-01`, A/B twice, 20 warmups and three measured markers)
complete with readback logging. Accepted A also produces verified marker pixels
whose drawable presentedTime remains zero at the 100 ms recheck; later drawables
have positive timestamps. The diagnostic retains those drawable references and
logs on the GUI thread, so its timings are not acceptance evidence. It does not
reproduce the timeout or establish its cause. Zero timestamps remain rejected.

The subsequent `load-pairs-01` series completes eight native runs with valid content
and offered rates, but the host rejects the eighth run's final boundary: load1 is
5.443848 against the limit of 5, with no active compiler observed. The entire series
is discarded; earlier latency/CPU differences are not accepted evidence. The failed
boundary's runtime/children exit and socket cleanup complete normally. The following A/B diagnostic profile also stops after the first A run: both
owned eight-second samplers finish, all 240 inputs and offered-rate checks pass,
but final load1 is 5.047852. Only A is captured, so no A/B profile comparison is
available. Its raw stacks remain diagnostic observations, not a cost attribution.
The third cadence series also fails the first A reference, with all three host
boundaries valid and maximum load1 2.592285. No new native timing series is accepted.

Post-processing the four failed A references finds host-clock phase adjustments
inside the observation windows, at offsets ranging from 0.204 to 5.933 seconds.
Some adjacent reference gaps are about 10.43/9.39/8.86 ms; others about
6.24/7.28/7.81 ms, while the reported nominal period remains 8.33329 ms.
`reference-failures.json` retains the exact timestamps. This is not exclusively
startup behavior and does not justify dropping samples or enlarging tolerances.
It establishes an unstable reference, not the physical display's causal mechanism.
The next investigation is the actual Qt/Cocoa display scheduling policy. The
runtime change remains an unaccepted working-tree candidate; accepted frozen
stages are unchanged. The focused CTest and final source rebuild pass, and the
rebuilt runtime is byte-identical to frozen B. All F01–F16 acceptance remains open.

## Application and independent display-link clock census

`out-perf/dlls-display-link-census-01` adds a private, bounded callback recorder to
the native cadence probe. It wraps Qt's CVDisplayLinkSetOutputCallback and delegates
the original callback with unchanged link, timestamps, flags, output-flags pointer
and context. A 32-link/32,768-sample buffer records callback and input/output host
clock values; no logging or dynamic allocation occurs inside the callback. Image
identity identifies `libqcocoa.dylib`, and the native window/display ID must match.
This changes observer overhead and is diagnostic only. GUI, runtime and installed
Qt binaries remain unchanged.

The first hook uses dlsym(RTLD_NEXT), which resolves back to the interposed setter
and recurses. Its private GUI reaches the harness's 105-second timeout; a one-second
sample proves recursive `qt_set_display_callback` calls. The owned GUI/runtime are
terminated and cleanup completes. That run is invalid and its hook/binary/logs are
preserved. The corrected hook calls the original symbol directly from its own
interposing image. A standalone Core Video test passes with and without the hook;
with it, every recorded callback reaches the delegate with the original context.

`/tmp/telar-perf-display-link-census-qual-02` validates A and B content and producer
coverage with exactly one Qt link on display 1. Each six-second window contains
720 application and 720 independent reference callbacks; both clocks and all native
intervals pass the unchanged 5% reference/0.25 ms interval criteria. Median Qt minus
reference output timestamps are -1.625 us (A) and -20.396 us (B). No phase anomaly
is reproduced. Both stacks use the accepted GUI/Qt; B uses only the retained
runtime deadline candidate. All six host observations pass, maximum load1 3.291.
These instrumented observations are not paired timing acceptance.

A twenty-second extension is invalid because the original producer stops at nine
seconds. Producer completion correctly rejects the uncovered observation window;
the nominal success returned by the native observer is not accepted. The next
private prefix, `out-perf/dlls-display-link-census-12s-01`, uses twelve seconds of
observation and fifteen seconds of the same 240 Hz producer. A preflight verifies
all 3,600 unique reversible color codes fit the existing 12-bit encoding and cover
the complete warmup/observation/drain interval. Pixel decoding and tolerances are
unchanged.

`/tmp/telar-perf-display-link-census-12s-qual-01` then passes content, producer and
clock checks for A/B. Each window has 1,440 callbacks from each clock. Their median
output-time difference is -1.583/-1.271 us, with no phase anomaly or off-grid native
interval. All six host observations pass, maximum load1 2.438. AC power is attached,
and pmset records no thermal/performance warning; these observations do not prove
that every possible scheduling or power limit is absent. The failed references'
cause remains unestablished. After these stable diagnostic windows, the original
uninstrumented six-pair cadence controller, `cadence-pairs-04`, fails on round 4 A
after nine runs: the reference changes phase and the longest native gap is
20.833 ms. All 19 recorded host boundaries pass, maximum load1 4.790; the incomplete
series remains ineligible. No partial timing aggregate is accepted.

A bounded diagnostic reproduction then runs accepted A only, stopping at the first
phase anomaly or six twelve-second windows. It stops on the third window in
`/tmp/telar-perf-display-link-census-reproduce-01`. All eight host observations pass,
maximum load1 3.507. Every window contains 1,440 Qt and 1,440 independent reference
callbacks. The first two windows have no detected phase or native interval anomaly.
In the third, both clocks report three out-of-tolerance gaps around 4.008–4.030 s:
Qt has 6.240375/7.281750/7.806292 ms and the reference has
6.239625/7.281375/7.806125 ms. The native presentation interval starting at 3.966398 s
is 29.166417 ms, outside the unchanged 0.25 ms integer-period criterion.

This reproduces the phase adjustment in the application's actual scheduling clock
as well as the independent observer. It does not establish physical scanout behavior
or the causal mechanism, and the bounded, stop-on-event experiment is not an event
frequency estimate. Both timestamp streams and the native frames are retained in
the raw results; `clock-comparison.json` records their comparison. No tolerance is
relaxed and no measured interval is removed. The retained runtime deadline candidate
still requires valid paired performance and regression evidence.

The following four-static-pane input regression series, `splits-pairs-01`, also
remains ineligible. Eight runs complete their native content checks, but the host
gate rejects the final boundary of round 3 A: load1 is 6.341797, above 5, with no
active compiler observed. The whole series is discarded without an aggregate.
No other worktree or process is attributed as the cause of the host load.

## Presented-frame copy work census

`out-perf/dlls-presented-frame-census-01` compiles a private friend-based type census
against the actual Application header and the GUI's existing Release compile
command. On ARM64, PresentedFrame is 18,312 bytes; its 64 PresentedPane slots are
9,728 bytes (152 each), HistoryHoverFrame is 6,744 bytes and TabDropSurface is
1,616 bytes. Generated assignment, copy construction and move construction each
visit all 64 pane slots. The queued
frameSwapped callback captures the preparation by value regardless of the active
pane count. This identifies capacity-dependent copy work, not a proven bottleneck
or a byte count for every executed copy: optional members have conditional paths.

The previous two qualified variable-output diagnostic profiles have 10 and 11
inclusive samples under the frameSwapped callback. Most sampled descendants are
Qt event posting and CFRunLoop wakeup; only the second profile contains a sampled
memmove below that callback. Counts are not CPU percentages. No production frame
storage, ownership, generation handling or scheduling is changed on this evidence.

## Shared prepared-frame snapshots: component candidate

`out-perf/dlls-frame-snapshot-01` tests retaining the prepared frame in the queued
callback rather than copying and moving its full 18,312-byte value. The candidate
keeps the current preparation in a shared holder. At beforeSynchronizing, it reuses
that preparation only when it has no other owners; otherwise it allocates a fresh
frame with the existing application allocator. Each queued callback retains its
own immutable snapshot. No queued frame is discarded and existing window-generation,
machine-view and pane-generation guards remain. Qt documents that the GUI thread
is blocked during beforeSynchronizing. The production source is restored after
freezing the candidate; this is not an accepted optimization.

The reusable `services/gui-cpp/tools/check_presented_frames.py` extracts only the
actual observeFrames implementation. Its QObject facade uses the current real
PresentedFrame type, QQuickWindow signals and queued callbacks, but simulates
preparation and presentation. It checks active pane identities/revisions, populated
link snapshots, history/tab surfaces, duplicate swaps, queue backlogs, unswapped
preparations, window-generation changes, null windows and receiver destruction.
The expanded corpus delivers 1,172 expected snapshots with the same A/B digest
`10422253783135734446`. A weak-reference check verifies that a replaced link snapshot
survives while queued and expires after its last callback. Removing the reuse guard
fails the oracle. The same positive and negative controls pass with address/undefined
sanitizers on the probe translation unit; Qt dependencies are uninstrumented and
leak detection is disabled. Native scene, weak QObject lifetime and runtime ACK
behavior remain outside this facade.

The earlier private timing probe omits the added weak-reference observation. Seven
alternating pairs in `/tmp/telar-perf-frame-snapshot-component-pairs-01` pass all 170
host boundaries (maximum load1 2.372). Each run measures 50,000 preparation/queue/
delivery cycles after 1,000 warmups, with real Qt events on the offscreen platform.
It includes simulated preparation and presentation, not native rendering:

| Component case | A median us/frame | B median us/frame | B wins |
| --- | ---: | ---: | ---: |
| One pane, drain each frame | 18.511 | 17.244 | 7/7 |
| Four panes, drain each frame | 18.479 | 17.307 | 7/7 |
| 64 panes, drain each frame | 18.539 | 17.306 | 7/7 |
| Four panes, drain every eight | 3.471 | 3.220 | 7/7 |
| Four panes plus history | 18.785 | 17.521 | 7/7 |
| 64 panes plus history, drain every eight | 3.774 | 3.530 | 7/7 |

Rebuilding unmodified GUI source yields SHA-256 `0d5ec9b95857…`, different from
accepted `5a639c5f26f6…`. A complete byte-difference audit accounts for all 207
changed bytes: eight generated Qt RCC node modification timestamps, LC_UUID and
code signature. Executable text is byte-identical (6,850,340 bytes, SHA-256
`78d11211a1dde580a278f9b4aa1ccdb13530a21dc99e1c46f2b2bbd8d89c7659`),
and no payload difference is unexplained. This does not claim identical whole files.
The original accepted frozen GUI remains the native timing baseline.

Frozen candidate GUI SHA-256 is
`2aafe1147befc8de58b03ee65961293dfeb9a2fc14853bf3d9116d9e88d7fa8c`.
It uses accepted runtime `a0b8b9d5826c…`, helper `87beebb065f0…` and original Qt;
the unaccepted runtime deadline candidate is not combined with this experiment.
Both rebuilt control and candidate pass six focused native QuickTest cases:
history footer/row delivery, scene synchronization, queued frames across window
rebinding, hidden terminal frames and resuming a deferred frame. Init/cleanup also
pass (8/8 each). `/tmp/telar-perf-frame-snapshot-native-qual-01` then qualifies
single/splits/tabs with byte-identical PNGs, plus the variable split-load workload.
All 18 host observations pass, maximum load1 2.305.

The source-extracted observer compiles to assembly for macOS ARM64, x86-64 and
x86-64-v3; this is not Linux or Rosetta execution. Inspection of the actual frozen
ARM64 binaries finds the frameSwapped callback shrinks from 198 to 73 emitted
instructions, including its event-dispatch/destruction branches. Its stack frame
shrinks from 18,432 to 112 bytes, and the queued callable's operator-new request
from 18,344 to 48 bytes. These are static code/allocation-request observations,
not sampled instruction counts or total process allocation/memory measurements.
Before-synchronization work now includes the reference-count guard and allocating
a fresh frame when an older snapshot is still held.

`native-contract.json` requires at least five of six GUI CPU/input wins under
variable split output, with no consistent latency or GUI/runtime CPU regression
in single/splits/tabs controls. The original frozen GUI remains A; only the GUI
changes in B. Native paired whole-client evidence is required for adoption; the
component result alone does not establish a full-flow win or 120 Hz acceptance.

`/tmp/telar-perf-frame-snapshot-load-pairs-01` completes six valid native pairs,
100 measured inputs plus 20 warmups per run and a five-second input-free interval.
The three background producers remain active during that interval. All 26 host
observations pass (maximum load1 4.203), with content and offered rates qualified.
GUI CPU/input has only 3/6 wins: median 20.641 → 20.144 ms. This misses the
preregistered target, so the candidate is not adopted as a CPU optimization and
the production source remains restored. The smaller static allocation request and
component win do not override this native result.

Median input-to-positive-presentation latency is 32.676 → 30.810 ms, 6/6 wins;
p95 is 37.419 → 37.391 ms and p99 41.034 → 41.039 ms, both 3/6. Runtime session
CPU/s also has 3/6 wins. The median-latency result is exploratory, not a retroactive
replacement for the primary CPU criterion. Post-processing excluding each run's
20 warmups finds GPU-completion latency and reported GPU-work medians each have
4/6 wins. Absolute input/presentation timestamps were not retained, so these
artifacts cannot establish a phase explanation. The input driver already varies
its inter-sample delay between 25 and 74 ms. A fresh, independently specified latency
experiment would need to distinguish a reproducible delivery gain from sample or
display phase before reconsidering this candidate. No F01–F16 row is closed.

## Independent latency confirmation and drawable timeline

A new contract in `out-perf/dlls-frame-snapshot-01/latency-confirm-contract.json`
separates independent median-latency confirmation from the already failed CPU
target. It requires five of six median-latency wins and no consistent tail-latency
or GUI/runtime CPU regression, followed by single/splits/tabs controls. It retains
the same frozen executables, original probe, offered rate and host gates. Neither
attempt qualifies: `latency-confirm-01` fails the first A producer-rate check;
`latency-confirm-02` completes four valid runs, then fails the round 2 A rate check.
No partial aggregate is accepted. All recorded host boundaries pass (3/11,
maximum load1 1.973/2.757), and owned runtime/children/socket cleanup completes.

The first failure has producer intervals as low as 0.114296 and 0.113107 MiB/s
against 0.125 MiB/s. The second has 0.115548 and 0.117146 MiB/s. The second failure's
intervals occur before the first injected input, during setup; the first failure's
intervals occur after input injection starts. This distinction does not change the
existing whole-run rate gate or make either series eligible. Maximum write duration
alone does not establish why the offered rate fell.

`out-perf/dlls-producer-pacing-diagnostic-01` wraps the original producer pacer
without changing its missed-slot/drop policy. It records return-from-wait lateness,
discarded deadline shifts and corresponding write duration, retaining at most 128
events per producer. A deterministic 2,000-step fake-clock comparison preserves
every original deadline and sleep request; it also exercises recorder saturation.
Two accepted-A diagnostic runs keep all offered rates within tolerance. The first
records maximum return lateness of 6.94–9.88 ms across producers; individual recorded
late returns often accompany writes lasting tens of microseconds. This demonstrates
that a discarded pacing slot need not mean a long blocking write. It does not
reproduce or establish the cause of the earlier rate failures. The second run's
final host boundary reaches load1 5.068848, so the entire diagnostic series is
ineligible for performance conclusions. Additional clocks/logging can perturb pacing.

A separate private observer, `out-perf/dlls-drawable-timeline-01`, retains absolute
input, drawable-acquisition, GPU-completion-callback and positive presentation times.
It also records the actual drawable-pool capacity and presentsWithTransaction flag.
Pixel, focus, geometry, sequence and positive-presentation gates remain unchanged.
`/tmp/telar-perf-drawable-timeline-single-01` qualifies 20 measured inputs plus 20
warmups on accepted A, after five seconds idle; all four host observations pass,
maximum load1 3.674. Every recorded absolute GPU/presentation difference agrees with
the existing relative duration. The observed pool capacity is three and transaction
presentation is false. Separate medians are 0.126 ms acquiring a drawable and
22.307 ms from the completion callback to presentation. These diagnostic medians
must not be added or treated as a measured queue depth or causal attribution.

The first private two-drawable policy experiment is **not an applied policy test**.
The harness removes TELAR_* variables, including the experimental activation flag.
Consequently `drawable-pool-single-01` and its short-idle follow-up keep the default
three-drawable capacity. The purported B run after five seconds idle times out on
its first input; the short-idle run succeeds, but both are baseline behavior. Raw
artifacts and policy-disposition receipts retain this mistake; neither supports a
two-drawable conclusion.

The corrected prefix, `out-perf/dlls-drawable-pool-02`, uses a forwarded private
TGB_DRAWABLE_POOL flag and validates both the requested setting and an acquisition
capacity bitmask, as well as every accepted frame's observed capacity. It changes
only the owned test process's layer policy; GUI/runtime/helper/Qt binaries remain
accepted A. `/tmp/telar-perf-drawable-pool-single-02` completes A/B with 20 measured
inputs each after five seconds idle, six valid host observations, maximum load1
1.712. All A samples observe three drawables and all B samples observe two.
Acquisition medians are 0.0635/0.0637 ms, completion-to-presentation medians
22.590/23.335 ms, and input-latency medians 26.477/26.523 ms. This single diagnostic
pair supplies no performance acceptance and no evidence of the hypothesized large
latency reduction. No production pool policy is changed. The remaining lead is
Qt's drawable presentation scheduling/skipping path; its causal role is unproven.

## Zero presentation timestamps isolated outside Qt, 2026-11-03

Two accepted-A diagnostics retain the default three-drawable policy and all native
input qualification gates. `out-perf/dlls-qt-presentation-skip-01` enables Qt's
`qt.rhi.general` and `qt.gui.metal` logs and records drawable pointers/IDs alongside
acquisition and callback times. Its private observer removes only the optional
100 ms zero-timestamp recheck, avoiding that diagnostic's extra drawable retention.
`/tmp/telar-perf-qt-presentation-skip-01` completes 20 measured inputs plus 20
warmups. A setup drawable explicitly skipped by Qt's display lock has a zero
callback. Three subsequent verified, visible-window zero callbacks have no Qt skip
log; one is the first input after five seconds idle. Another drawable for the same
input presents positively. All four host boundaries pass, maximum load1 4.709.

`out-perf/dlls-qt-presentation-call-01` additionally delegates the concrete
CAMetalDrawable `present` method while logging its actual invocation. The native
run completes all 40 inputs with four valid host boundaries, maximum load1 2.791.
Every acquired drawable has exactly one present request except the single setup
drawable explicitly skipped by Qt. The verified first-input drawable receives an
actual present call from the scheduled-handler thread, then a zero presentation
timestamp; a later drawable serves that input positively. Thus Qt's display-lock
omission does not explain this particular zero. Neither diagnostic reproduces a
timeout or establishes the cause of previous timeout attempts. Both owned runtime
cleanup receipts are complete. Logging/hooking overhead excludes timing acceptance.

The reusable [Metal idle control](../tools/metal_idle_control.py), with its
[native probe](../tools/metal_idle_control.m), removes Telar and Qt from the experiment.
It clears an owned AppKit/CAMetalLayer window to alternating solid colors, submits
20 warmup frames, waits five seconds with two unchanged redraws, then submits 20
resumed frames. The first resumed frame is isolated for at least two seconds before
another submission. It compares two diagnostic policies: present from a command
buffer's scheduled handler, or `presentDrawable` on the command buffer. These are
observations of API behavior, not paired performance comparisons. Default readback
verifies a GPU pixel from each clear; `--no-readback` uses framebuffer-only drawables
and explicitly reports content verification unavailable. Neither mode turns zero
timestamps into eligible latency endpoints.

Run `python3 tools/metal_idle_control.py /tmp/unique-metal-control` or add
`--no-readback`; `--presentation scheduled|command` selects one policy. The driver
builds into that new directory, records source/binary identities and host boundaries,
checks owned process exit, and rejects missing/duplicate/mismatched callbacks,
invalid clocks, foreground loss, wrong geometry, VSync/pool changes, unverified
requested readback, coalesced submissions or overlapping first-resume callbacks.
It neither launches a Telar runtime nor changes installed binaries/configuration.

Private control `metal-idle-control-01` scheduled long-delay timers together and
coalesced resumed submissions; it cannot isolate the first resumed frame. Version
02 corrects this with recursive frame scheduling and the two-second isolation.
Private no-readback version 03 loses foreground in its second policy, excluding that
entire series. Both limitations are retained in disposition receipts. The canonical
driver fails closed on foreground loss instead of accepting that observation.

Fresh canonical runs qualify the standalone experiment:

| Artifact under `/tmp/telar-perf-` | GPU readback | Host boundaries / max load1 | First resumed frame, scheduled / command |
| --- | --- | --- | --- |
| `metal-idle-canonical-01` | Every pixel verified | 6 / 1.654 | Zero / zero |
| `metal-idle-canonical-02` | Disabled; framebuffer-only | 6 / 1.815 | Zero / zero |

Each policy completes all 42 GPU operations and presentation callbacks, with a
1600×1000 drawable on the display advertising 120 Hz. First-resume isolation is
2.022–2.099 seconds; every first-resume zero callback precedes the next submission.
Foreground/visibility observations pass at acquisition and callback processing.
All four owned processes exit successfully. Nine mutations of a qualified native
log reject focus loss, wrong pixels, non-finite time, wrong identity, disabled
VSync, wrong dimensions, duplicate/missing callbacks and first-resume overlap. An
untouched zero trace and a synthetic positive control are accepted only as
diagnostics, always with `performance_eligible=false`.

The zero-after-idle behavior therefore does not require Telar, Qt's presentation
lock, its scheduled-handler policy, or this probe's GPU readback/framebuffer-only
change in these controls. This is not a physical scanout observation, a general
driver diagnosis, or proof that every earlier timeout has the same cause. It does
not justify bypassing Qt's locking, repeating production frames, changing drawable
capacity or weakening the positive-presentation gate. Native latency acceptance
remains open. Production GUI/Qt policy is unchanged; the runtime deadline candidate
remains unaccepted working-tree work.

## Span row-revision marking rejected, 2026-11-03

`out-perf/dlls-span-row-revisions-01` tests marking touched rows once per span in
`Screen::apply`, instead of dividing the cell position and writing its row revision
for every decoded cell. Snapshots already initialize all row revisions, so their
per-cell revision work is redundant. Unlike the earlier row-retention/staged-decode
experiments, this variant preserves exact invalidation semantics, both decoder
traversals and all allocation/storage behavior. Production source is unchanged.

A differential oracle compares public cell bytes/styles, row revisions, metadata,
links, frame/header state and allocation counts after 3,342 operations, including
360 rejected malformed frames whose state remains unchanged. Exhaustive small-grid
span ranges, 2,048 seeded sequences, stale/gap/detach/resize behavior and maximum
dimensions/cell count are covered. Native release, ASan/UBSan and x86-64 execution
agree on digest `8144262334345902512`. A negative variant that omits later touched
rows fails the oracle. Sanitizers instrument the probe/header code, not the system
libraries; leak checking is disabled.

ARM64, x86-64 baseline and x86-64-v3 macOS kernels compile. In the BudgetAllocator
component instantiation, ARM64's inner cell-copy loop falls from 30 to 24 static
instructions, removing its division and row-revision loads/store; both the decoder
and memcpy calls remain. Delta spans do one division for a single cell or two for
longer spans. Snapshots do none in the cell loop. Linux and the native GUI's
SystemAllocator instantiation are not performance-qualified by these probes.

Seven alternating pairs per mode/grid in
`/tmp/telar-perf-span-row-revisions-pairs-01` pass all 394 host boundaries, maximum
load1 1.895. Encoding/rendering/native delivery are excluded. Live/peak memory,
allocation counts and final state digests match in every pair; warmed application
adds no allocations. Median nanoseconds per Screen application:

| Mode | 82×21 A → B | B wins | 240×80 A → B | B wins |
| --- | --- | --- | --- | --- |
| Snapshot | 15,748 → 15,707 | 5/7 | 183,392 → 180,674 | 7/7 |
| Full delta | 15,901 → 15,794 | 5/7 | 180,345 → 178,704 | 7/7 |
| One row | 781.85 → 780.13 | 5/7 | 2,245.34 → 2,237.73 | 6/7 |
| 64 one-cell spans | 1,923.62 → 1,948.81 | 0/7 | 1,918.59 → 1,961.19 | 1/7 |
| Two cells crossing a row | 54.00 → 54.57 | 0/7 | 54.13 → 54.86 | 2/7 |
| One cell | 43.42 → 43.85 | 2/7 | 43.50 → 44.04 | 1/7 |
| Empty delta | 10.93 → 10.96 | 2/7 | 11.02 → 11.01 | 3/7 |

The normal-grid targets miss six wins and several controls lose consistently.
Large-grid gains do not override that rejection; no native candidate build or
full-flow acceptance is attempted. Constructing complete Cell values during the
validation-only first pass motivates the separate experiment below, without
reinstating row retention or its additional staging buffer.

## Validation-only CellReader rejected, 2026-11-03

`out-perf/dlls-validation-only-reader-01` separately tests a shared parser with
materializing and validation-only return policies. `Screen::apply` uses the latter
only for its first traversal; all checks, their order, the second traversal and
original per-cell row marking remain. There is no staging buffer or additional
allocation. The baseline parser is frozen as an independent class in the oracle;
both Screen implementations share the unchanged wire types and support headers.

The same 3,342 Screen operations and 360 malformed-frame atomicity checks pass,
along with 6,276 reader comparisons over partial consumption and mutated/truncated/
trailing input. ARM64 release, ASan/UBSan and executed x86-64 agree on the original
Screen digest and allocation counts. A negative control omitting cell validation
from the discard path is rejected. ARM64's validation helper has 152 static
instructions versus 168 in the materializing helper, both with 80-byte stacks;
these counts include error branches, not estimated cycles. The materializing
instruction stream matches the original after local block-number normalization.
ARM64, x86-64 and x86-64-v3 macOS kernels compile; Linux is not executed.

Seven alternating component pairs per mode/grid in
`/tmp/telar-perf-validation-only-reader-pairs-01` pass all 394 host observations,
maximum load1 1.711. Every paired final digest and live/peak/allocation count agrees;
no warmed application allocates. Median nanoseconds per application:

| Mode | 82×21 A → B | B wins | 240×80 A → B | B wins |
| --- | --- | --- | --- | --- |
| Snapshot | 15,784 → 15,676 | 5/7 | 182,362 → 180,817 | 7/7 |
| Full delta | 15,755 → 15,585 | 6/7 | 180,175 → 179,080 | 6/7 |
| One row | 781.57 → 778.67 | 5/7 | 2,241.99 → 2,226.68 | 7/7 |
| 64 one-cell spans | 1,930.77 → 1,860.32 | 7/7 | 1,927.57 → 1,860.53 | 7/7 |
| Two cells crossing a row | 53.93 → 49.37 | 7/7 | 53.98 → 50.67 | 6/7 |
| One cell | 43.44 → 40.87 | 7/7 | 43.57 → 40.83 | 7/7 |
| Empty delta | 10.99 → 11.21 | 0/7 | 10.97 → 11.24 | 1/7 |

The reusable [Screen application checker](../services/gui-cpp/tools/check_screen_application.py)
and [probe](../services/gui-cpp/tools/screen_application_probe.cpp) accept frozen
`--before-screen`/`--after-screen` headers and optional `--before-reader`/
`--after-reader` headers, a configured GUI `--build`, and a new `--output` directory.
They retain source identities and independently rename the baseline reader;
supporting GUI/core/base headers come from the current build. `--sanitize`,
`--arch x86_64` and `--negative-control` select additional checks. This tool compares
Screen state, exception types/messages and requested reader consumption; it does
not render or establish native presentation behavior. Final release, sanitizer,
x86-64 and row-marking control results are retained in the experiment's `final-*`
directories; the invalid-cell negative control fails as required.

The empty controls consistently regress and the normal snapshot target misses six
wins. This rejects the variant despite useful small-span reductions. The empty
path does not decode cells, but that alone does not prove code-placement causality
or override the gate. No production codec/GUI source is changed and no native
performance acceptance is claimed. The separate experiment below examines the
redundant grid-capacity checks without retaining this parser change.

## Same-grid delta reservation experiment, 2026-11-03

`out-perf/dlls-delta-grid-reserve-01` skips the cell and row-revision vector capacity
checks for a valid delta. `Screen::apply` has already required its base frame and
grid to match the current screen. Snapshot reservations and every metadata
reservation remain unchanged, as do both decoder passes and per-cell revision
marking. There is no additional storage. Production source remains the accepted
baseline while the native candidate is evaluated separately.

The reusable Screen oracle now injects allocation failures at each reservation
boundary for initial snapshots, resized snapshots and metadata-growing deltas.
Its 21 scenarios exercise 12 allocation failures and six allocation-free same-grid
recoveries after a failed resize or metadata update. Public state, exception
type/message, allocator attempts, live bytes and allocation/failure counts agree.
The original 3,342 Screen operations, 360 malformed-frame checks and 6,276 reader
comparisons also pass, retaining digest `8144262334345902512`. Release,
ASan/UBSan and executed x86-64 agree; sanitizer scope excludes system libraries
and leak detection. A negative control omitting only the links reservation fails
with `Allocation-failure differential mismatch`. A broader negative that omitted
all metadata reservations crashed with SIGSEGV; that attempt is retained but is
not evidence of a clean oracle rejection or an established crash cause.

ARM64, x86-64 and x86-64-v3 macOS kernels compile for both BudgetAllocator and
the GUI's SystemAllocator. ARM64's `apply` instruction stream is identical in A/B;
the reserve helper branches around two out-of-line capacity-check calls on deltas.
Its static instruction count grows from 32 to 36, with the same 32-byte stack.
These counts are not cycle estimates. Linux is not executed.

Seven alternating pairs per mode/grid in
`/tmp/telar-perf-delta-grid-reserve-pairs-01` pass all 394 host observations,
maximum load1 2.518. Final digests and live/peak/allocation counts match in every
pair; warmed application allocates nothing. Median nanoseconds per application:

| Mode | 82×21 A → B | B wins | 240×80 A → B | B wins |
| --- | --- | --- | --- | --- |
| Snapshot | 15,849.50 → 15,747.98 | 6/7 | 182,137.54 → 182,371.12 | 5/7 |
| Full delta | 15,750.40 → 15,736.90 | 3/7 | 179,949.17 → 179,953.75 | 4/7 |
| One row | 781.31 → 779.53 | 6/7 | 2,244.72 → 2,241.55 | 6/7 |
| 64 one-cell spans | 1,921.17 → 1,917.71 | 3/7 | 1,921.38 → 1,926.26 | 3/7 |
| Two cells crossing a row | 54.09 → 50.74 | 7/7 | 54.02 → 50.70 | 7/7 |
| One cell | 43.59 → 40.01 | 7/7 | 43.63 → 39.71 | 7/7 |
| Empty delta | 11.00 → 9.38 | 7/7 | 10.93 → 9.39 | 7/7 |

The preregistered empty/one-cell targets pass, with no consistently losing
component control. The absolute saving is only a few nanoseconds per delta and
does not establish an application improvement. Native candidate GUI
`c2b1d0425e73` uses the frozen accepted runtime `a0b8b9d5826c`, helper and Qt;
the pending runtime deadline change is excluded. Rebuilt A's executable code and
payloads match the accepted GUI, with all 207 differing bytes accounted for by
eight generated RCC timestamps, UUID and signature. Native timing uses the original
frozen accepted GUI `5a639c5f26f6` as A.

The core test and six focused native frame-delivery cases pass. Qualification in
`/tmp/telar-perf-delta-grid-reserve-native-qual-01` passes three byte-exact captures
(single, splits, tabs), variable offered load, and all 18 host boundaries, maximum
load1 2.238. Native single-pane series 01 is wholly discarded when load1 reaches
6.235 at `after:3-single-A`, above the limit of 5. All eight owned runtimes and
their children exit with complete cleanup; no partial aggregate is used. A fresh
six-pair series 02 starts after load falls to 3.74, with GUI CPU per input as the
preregistered primary target (at least five wins). Its 19 host boundaries remain
valid, maximum load1 3.601, but baseline A times out on the first warmup input
after idle in round 4. Initial presentation qualifies; zero input responses
complete, before the measured interval. All nine runtimes/children clean up.
The ordinary probe has no readback diagnostics enabled, so this receipt does not
establish whether the marker appeared with a zero timestamp or identify another
cause. Series 02 is also wholly excluded. The candidate is **deferred**, not an
accepted native improvement or a measured native regression. Existing
positive-presentation, focus, geometry, rate and host gates remain unchanged.

## Higher-volume accepted-stack profile, 2026-11-03

`/tmp/telar-perf-variable-work-profile-04` profiles accepted GUI `5a639c5f26f6`
and runtime `a0b8b9d5826c`, keeping their helper, Qt, configuration and original
positive-presentation probe. Three variable-output background producers each
request 0.5 MiB/s, four times the earlier profile's offered rate. Two repetitions
complete 240 inputs each, with 20 warmups and no idle phase. Every producer passes
the unchanged 5% rate gate. Owned identities, geometry and foreground qualify;
both runtime/child cleanup receipts complete. All six host boundaries pass,
maximum load1 1.882. Separate GUI/runtime samplers run for eight seconds at 1 ms.
Source/binary identities, profiles and external runtime counters are retained.
These instrumented runs do not qualify latency, CPU savings or continuous cadence.

| Inclusive sampled stack group | Repetition 1 | Repetition 2 |
| --- | ---: | ---: |
| GUI font requests / coverage | 16 / 16 | 17 / 16 |
| GUI `TerminalItem::updatePaintNode` | 72 | 88 |
| Qt `renderMergedBatch` | 90 | 72 |
| WindowServer `SLSObscureCursor` | 117 | 111 |
| GUI `CellReader::next` | 7 | 11 |
| Runtime checkpoint `Snapshot::changed` | 20 | 15 |
| Runtime `PaneObservationService::refresh` | 30 | 31 |
| Runtime `CellProjection::copyRow` | 4 | 7 |
| Runtime `FrameSync::appendDamage` | 8 | 11 |
| Runtime `wait4` | 34 | 28 |
| Runtime process-info / ioctl calls | 53 / 71 | 48 / 70 |

Groups overlap and must not be summed; waiting threads dominate the full samples.
These are stack observations, not call counts or CPU percentages, and exact
per-input timestamps remain unavailable. Higher offered volume does not make
cell projection the dominant sampled path in these small split grids.

Following the `wait4` stack identifies a distinct work-reduction lead:
`Runtime::publish` calls `PtyProcess::reap` for every live pane on every event-loop
iteration. The server already registers SIGCHLD on both platform loops, but the
runtime merely continues on that event and performs the same unconditional
polling on unrelated events. A signal-driven reap pass with a bounded periodic
fallback could avoid repeated live-child syscalls. It needs exit/status and
output-drain oracles, coalesced/early signal checks, platform qualification and
paired whole-runtime evidence before adoption. The older SIGCHLD change removed
a 100 ms exit delay; this lead must preserve that behavior.

Inspection also confirms that `FixedText` already copies only its used prefix;
its 4 KiB capacity is not evidence of a 4 KiB copy per operation. No observation
worker, process-identity policy or Qt cursor behavior is changed on these profiles.

## Signal-driven child-status polling experiment, 2026-11-03

`out-perf/dlls-child-exit-poll-01` isolates the reap lead above. Its private
`runtime.hpp` candidate requests a live-pane reap pass at startup, on SIGCHLD,
or after a 100 ms fallback deadline. Unrelated event-loop iterations retain the
deadline instead of calling `waitpid(WNOHANG)` for every live pane. The next wait
is bounded by the remaining fallback interval. Pipe-execution handling, process
identity checks, PTY draining, final-frame acknowledgements and exit delivery
conditions are unchanged. The extracted policy has 16 bytes of state and allocates
nothing. Production source remains unchanged pending native acceptance.

The baseline is the accepted runtime `a0b8b9d5826c`. Clang VFS overlays restore
the accepted client/attachment headers in both variants, excluding the pending
cadence candidate. Only `runtime.hpp` varies. The first relink used output name
`telar`, changing the automatic signature identifier from `telar-runtime` and its
length by eight bytes; it was not accepted as an unexplained baseline difference.
Relinking with the original name leaves just 48 differing bytes, all UUID or
signature, with every other byte identical. Candidate runtime is `73a96b8d239a`;
GUI `5a639c5f26f6`, helper and Qt are unchanged. Both builds emit existing header
warnings; these are not claimed as clean lint results.

An extracted-policy oracle checks 100,005 initial/deadline/signal transitions.
Eight real owned-child exits cover observed SIGCHLD and recovery when queued
notifications are deliberately not forwarded to the policy. ARM64 release,
ASan/UBSan and executed x86-64 pass. A mutation ignoring the signal flag fails.
ARM64, x86-64 and x86-64-v3 macOS policy kernels compile; Linux is not executed.
Actual ARM64 `Runtime::publish` grows from 400 to 422 static instructions and
contains a new branch bypassing its single `PtyProcess::reap` call site. This is
syscall avoidance, not an instruction-count reduction or a cycle estimate.

The reusable [child-exit checker](../services/runtime-cpp/tools/check_child_exits.py)
and [probe](../services/runtime-cpp/tools/child_exit_probe.cpp) build from a configured
runtime `--build` and compare `--before`/`--after` binaries in a fresh `--output`.
Six cases cover immediate execution exit, release-triggered exit, a 1,024-line
burst, signal termination, an inherited writer and eight simultaneously released
panes in one tab. Each variant exercises 13 panes. The receiver applies actual
wire frames using the current GUI Screen header without Qt, holds the final ACK
while reading all emitted text, then verifies the terminal exit kind/value.
All six canonical byte streams agree. Release and sanitizer runs at
`/tmp/telar-perf-child-exit-canonical-01` and `-canonical-sanitizer-01` pass; a
corrupted expected transcript is rejected cleanly in each. Dependency/source and
binary identities and owned cleanup receipts are retained. Sanitizers cover the
probe/inline headers, not the runtime or configured dependency libraries; leaks
are disabled. Existing launch-cwd/default/environment and capture/capture-cwd
probes also pass with identical canonical A/B output. Their incidental durations
are not paired performance evidence.

Fixture qualification corrected a ReadPane request above the 2,000-row wire limit
and replaced cross-workspace creation, which intentionally detaches old panes,
with same-tab pane creation. A proposed post-session-leader writer was invalid on
this host: direct OS `forkpty`, independently of Telar, also revokes the terminal
and returns EIO for a later descendant write despite ignoring SIGHUP. The final
inherited-writer case keeps the leader alive until its writer completes. These
fixture corrections and the direct control remain recorded privately.

Seven alternating component pairs in `/tmp/telar-perf-child-exit-component-01`
pass all 30 host boundaries, maximum load1 2.199. Across 200,000 opportunities
with four live blocked children, A calls waitpid 800,000 times and B four times.
Median CPU cost is 600.505 → 16.330 ns/opportunity, wall time 600.695 → 16.311;
both win 7/7. The tiny B loop finishes before its next fallback deadline. This
excludes all other publish work, creation/exit cost and the GUI; it does not imply
the same speedup for a runtime session.

Native qualification `/tmp/telar-perf-child-exit-native-qual-01` passes three
byte-exact captures and 0.5 MiB/s variable offered load per background producer.
All 18 host boundaries pass, maximum load1 1.991. The preregistered primary is
runtime session CPU/s under that load, at least five of six alternating wins,
followed by single/splits/tabs/lower-load controls and separate GUI latency/CPU.
Primary series 01 is wholly discarded when the three producers fall to
0.440–0.450 MiB/s in the same interval in round 1 B, outside the unchanged 5%
tolerance. All seven host boundaries pass, maximum load1 2.845, and all three
owned runtimes/children clean up. That does not establish the rate-loss cause or
permit a partial aggregate. Series 02 is also wholly discarded: baseline A in
round 2 has one producer interval at 0.473985 MiB/s (5.20% below the target),
with maximum write duration 8.755 ms. All 11 host boundaries pass, maximum load1
2.181, and all five owned runtimes/children clean up. The other two producers
pass. This receipt does not identify the cause, establish a candidate regression
or permit a partial aggregate.

Series 03 completes all six alternating pairs and 26 host boundaries, maximum
load1 3.748. Offered rate, positive presentation, geometry, focus and all twelve
owned-runtime/child cleanup receipts pass. Medians across the six runs per variant:

| Native metric | Accepted A | Candidate B | B wins / 6 |
| --- | ---: | ---: | ---: |
| Runtime session CPU, ms/s | 137.235 | 130.839 | 6 |
| GUI CPU per measured input, ms | 19.656 | 18.785 | 5 |
| Presented input p50, ms | 31.987 | 31.953 | 4 |
| Presented input p95, ms | 37.272 | 37.372 | 3 |
| Presented input p99, ms | 39.241 | 39.900 | 1 |

The primary CPU target passes, but the consistent p99 loss **rejects the
candidate**. Its cause is not established, and there is no demonstrated code
placement exception. These p99 values are medians of six run-level p99s, not
pooled percentiles. Runtime CPU includes startup/warmup/idle while GUI CPU covers
the measured input interval, so their numbers must not be added. Remaining
single/splits/tabs/lower-load controls are unnecessary after this rejection. A
separate exit-latency control was prepared privately but not built or executed;
it supplies no evidence. The reusable functional oracle is retained, production
runtime source is unchanged, and every F01–F16 acceptance row remains open.

## History query work profile and ordered-index lead, 2026-11-03

The foreground-query lead was checked against the earlier runtime report before
editing: unrestricted worker-side discovery already lost concurrent tail-latency
controls. It is not repeated without new causal evidence.

`out-perf/dlls-history-work-profile-01` instead exercises F12's runtime path with
the accepted runtime `a0b8b9d5826c`. A private protocol fixture imports 10,000
entries containing 5,000 distinct commands, then checks twenty combinations of
five fuzzy searches, duplicate removal and two page offsets. ASCII case, UTF-8
bytes, no matches, score-derived ordering and ties, snapshot bounds, ids and full command
text are checked against an independent model using repeated string search and
a full sort. The model is built before profiling; every queried page is checked.
This does not cover every history filter, cancellation or GUI presentation.

Fixture attempts 01–03 fail before profiling: admission acknowledgements alone
allow the import queue to fill, and a control connection closes after a history
reply. The final fixture verifies persistence after every 64-entry batch and
registers the same interactive client role used for repeated GUI queries. All
failed-attempt owned-runtime cleanups complete; those attempts supply no timing.

`/tmp/telar-perf-history-work-profile-04` completes two repetitions with identical
canonical output `e8b0e9aa70de9`. Each has ten seconds of queries and a separate
eight-second, 1 ms runtime sample. All six host boundaries pass, maximum load1
1.847, and both owned runtimes clean up. The instrumented query counts, 2,055 and
2,060, are not throughput acceptance. The first profile places 5,297 inclusive
samples in the candidate-row `queryFuzzy` branch, of 5,951 under `query`; 5,293
descend through `Statement::next`. SQLite temporary-tree insertion, balancing
and memory movement dominate this path. These overlapping counts are not CPU
percentages and must not be summed.

The runtime's system SQLite 3.51.0 confirms the plan on its owned database:
`SEARCH command USING INTEGER PRIMARY KEY (rowid<?)` followed by
`USE TEMP B-TREE FOR ORDER BY`. The existing index contains only
`started_at_ms DESC`, while the query additionally orders by `id DESC`.
This identifies repeated sorting as a stronger lead than merely retaining the
ranked-entry reservation or prepared statements.

Private database copies in `out-perf/dlls-history-query-order-01` replace that
index with `(started_at_ms DESC, id DESC)`, or with those columns plus `command`.
Both plans eliminate the temporary sort; the latter is a covering-index scan.
Complete result hashes match for snapshot boundaries 10,000, 5,000 and 100,
and each database passes `integrity_check`. The covering copy occupies 3,948,544
bytes versus the original 3,780,608; these whole-file sizes include differing
free-page counts and do not measure incremental live memory or steady-state
index size. No paired speed, write-cost or migration result is claimed yet.
In particular, an old snapshot may make an ordered scan visit many excluded
rows, so old/selective snapshots, ties, scoped queries, imports and deletions
must be controls. Production schema and queries remain unchanged.

## History ordering experiments and fused-ranking candidate, 2026-11-03

Three isolated alternatives to SQLite's repeated temporary-tree work are rejected
before changing production. Native SQL probes include prepare, row consumption
and finalize, use one binary for both paths and check identical row counts/content.
Their diagnostic SQLite counters are collected outside timing. None qualifies a
GUI or full F12 win.

* **Covering index:** `/tmp/telar-perf-history-query-order-pairs-01` completes
  seven alternating pairs in six cases and 170 valid host boundaries, maximum
  load1 1.167. Current-snapshot CPU drops from 4.327 to 0.691 ms/query, 7/7 wins,
  but old snapshots rise from 29.235 to 191.622 microseconds, 0/7. Old-page and
  empty controls also lose 0/7. The old query's diagnostic VM steps rise from
  1,414 to 30,410 and the candidate visits 9,999 index steps; the empty query rises
  from 14 to 30,010 VM steps. The ordered scan defeats the selective id bound.
  `ANALYZE` on another private copy does not change that choice. Write/migration
  controls are not run after rejection; production indexes are unchanged.
* **Forced existing chronological index:** the private proposal would affect only
  new unfiltered fuzzy searches. It retains the exact ORDER BY/LIMIT while SQLite
  sorts the timestamp ties. An independent timestamp/id model matches 120 complete
  SQL result sets, including shuffled timestamps and more than 10,000 candidates.
  `/tmp/telar-perf-history-existing-order-pairs-01` passes 142 host boundaries,
  maximum load1 1.798. Current-snapshot CPU wins 6/7 (4.253 → 4.202 ms), but
  shuffled timestamps win only 1/7 (4.929 → 4.959 ms), rejecting it. Grouped/all
  ties and larger histories win 7/7. Scattered table lookups are a possible cause
  of the shuffled loss, not a causally isolated finding.
* **Native ordering with retained commands:** a bounded top-k heap replaces the
  temporary SQL tree, retaining at most 10,000 rows and 2 MiB of string capacity,
  plus fixed candidate storage and a transient incoming string. Over budget, it
  repeats the original SQL query. Full-row release and ASan/UBSan oracles pass
  144 cases; an inverted id tie-break mutation is rejected. Sanitizers cover the
  probe/native ordering, not system SQLite; leaks are disabled. Seven alternating
  pairs in `/tmp/telar-perf-history-native-order-pairs-01` pass 226 host boundaries,
  maximum load1 2.008. Every ordinary, tied, shuffled, larger, old and empty case
  wins 7/7; current-snapshot CPU drops from 4.309 to 1.315 ms. Long commands trigger
  the budget fallback and lose 0/7 (12.499 → 13.353 ms). This rejects that variant:
  copying commands and then repeating SQL adds work in the fallback.

The next private candidate, `out-perf/dlls-history-fused-rank-01`, fuses score/hash
calculation with the bounded recency selection. Each retained candidate contains
only id, timestamp, command hash and optional score. Command strings are consumed
directly from the current SQLite row and are not copied or retained. After keeping
the newest 10,000 candidates, the same recency order, duplicate-hash rule, score
ordering and pagination apply; the existing detail query loads only selected
results. It uses the project's allocator and leaves the schema unchanged.
The extra fixed-size vector still requires allocation/failure and size accounting.

Both variants rebuild main.cpp against the accepted dependency archives, using
VFS overlays to exclude pending attachment cadence work. The rebuilt A differs
from accepted `a0b8b9d5826c` only in 48 UUID/signature bytes; the original accepted
binary is measured. Candidate B is `474b46abbdbf328b635c53d895d5b7d54734566fb481d629d074adeeae28beba`.
Production source remains unchanged. Existing header warnings remain present.

`/tmp/telar-perf-history-fused-rank-qual-01` passes 480 independent reference/A/B
cases across monotonic dates, grouped ties, all ties, shuffled dates, 15,000
entries, long commands, 100 entries and an empty history. Each dataset covers
five queries, distinct/non-distinct results, two offsets and three snapshot bounds.
Selected command bytes/order, ids, timestamps, snapshot id and has-more match the
model; canonical A/B output agrees. This oracle does not yet qualify every history
metadata field, scoped/author/failed filters, cancellation or allocation failures.

Warm protocol measurements use identical fixed counts and order after seeding
and a 60-case model check, with seven alternating pairs per dataset. The primary
series is `/tmp/telar-perf-history-fused-rank-monotonic-01`; the remaining seven
are under `/tmp/telar-perf-history-fused-rank-controls-01`. All 112 executions and
240 host boundaries qualify, maximum load1 2.675, and every owned runtime/child
cleanup completes. Medians across seven runs per variant:

| History dataset | Runtime CPU A → B, ms/query | Mean protocol response A → B, ms | CPU / response wins |
| --- | ---: | ---: | ---: |
| 10,000 monotonic dates | 2.3746 → 0.6783 | 2.3803 → 0.6834 | 7/7, 7/7 |
| Grouped ties | 2.5528 → 0.6771 | 2.5593 → 0.6820 | 7/7, 7/7 |
| All dates equal | 2.6216 → 0.6790 | 2.6275 → 0.6837 | 7/7, 7/7 |
| Shuffled dates | 2.7600 → 0.9028 | 2.7677 → 0.9078 | 7/7, 7/7 |
| 15,000 entries | 4.0424 → 1.3291 | 4.0481 → 1.3343 | 7/7, 7/7 |
| Long commands | 5.6710 → 1.5500 | 5.6813 → 1.5571 | 7/7, 7/7 |
| 100 entries | 0.0666 → 0.0514 | 0.0704 → 0.0552 | 7/7, 6/7 |
| Empty | 0.0396 → 0.0307 | 0.0428 → 0.0340 | 7/7, 7/7 |

Response p95/p99 win 7/7 except the small history, which wins 6/7 for each.
External runtime CPU counters bracket probe release/completion and include boundary
time; the protocol response clock surrounds each request/reply. Neither is GUI
presentation latency. The primary end-footprint median rises by 327,680 bytes
(6,996,400 → 7,324,080). Long-command lifetime maximum footprint falls from
21,299,656 to 14,221,744 bytes. These are boundary and lifetime observations across
seeding/warmup/query work, not incremental vector size or measured-interval peaks.

The fused candidate is **pending**, not adopted. Remaining requirements include
candidate-header sanitizer/fault recovery, targeted history regression and filter
coverage, cross-architecture checks, cold queries, write controls, a qualified
native query-to-presented-results comparison, and the independent Zig F12 stack.
No flow or native120 requirement closes on these protocol results.

### Fused history ranking: filter, allocation and architecture qualification

The candidate remains private and pending. The reusable
`services/runtime-cpp/tools/check_history_store.py` and `history_store_probe.cpp`
now compare complete encoded `HistoryResults` payloads, including metadata. The
runner accepts baseline/candidate store headers and compiles them through private
VFS overlays; it never replaces production source. Its successful run is
`/tmp/telar-perf-history-store-check-01`. These are functional diagnostics, not
additional timing evidence, and no host-load performance gate is claimed for them.

Two fixtures contain 1,024 and 15,872 entries, including duplicate commands,
nonmonotonic/tied timestamps, Unicode text, imported human history and reported
agent commands. Each exercises 192 combinations of global/cwd/workspace/pane
scope, human/agent/all author, failed-only, distinct, current/old snapshot and
pagination. Every reply is checked against independent filter assertions and
compared byte-for-byte across implementations. Post-failure delete/import queries
also match. The canonical SHA-256 values are
`d891693b9f7db23005e9a9023025814cef16c3e2573fb65f2c83b86af5d720fa` and
`234d3107fbe8861fb685bb8f7a1f7deae8b7892138451943342536c3db2e671b`.

The private `out-perf/dlls-history-fused-rank-01/history-check-results.json` records
ARM64 baseline/candidate, candidate ASan/UBSan, and x86-64 baseline/v3 candidate
runs under Rosetta. All ten executions agree. The ARM64 diagnostic additionally
runs the existing history, queue and capacity tests, including their worker
cancellation cases. The Rosetta check covers the store oracle, not those worker
tests. ASan/UBSan instrument the candidate header and the four test translation
units; dependency archives and system SQLite remain uninstrumented. LeakSanitizer
is disabled; the injected allocator separately verifies zero live bytes after
store/reply/SQLite teardown. Linux execution is still unverified.

The allocation audit includes SQLite's configured allocation callbacks as well as
project vectors/hash storage. For one warmed fuzzy `gs`, distinct=true query:

| Fixture | Allocation calls A → B | Total allocated bytes A → B | Incremental peak live bytes A → B |
| --- | ---: | ---: | ---: |
| 1,024 entries | 132 → 30 | 685,719 → 485,472 | 185,215 → 485,120 |
| 15,872 entries | 2,834 → 30 | 16,591,815 → 485,472 | 191,879 → 485,120 |

These are instrumented query-local allocator figures, not process footprint or
Qt/framework allocations. The candidate's extra 320,000-byte vector holds at most
10,000 fixed 32-byte records; the existing 160,000-byte ranked vector remains.
The x86 candidate requests eight more bytes in total/peak in these fixtures.
This is a measured memory-for-work tradeoff, consistent with Adrian's preference,
not evidence that allocation alone explains all elapsed-time gains.

Each observed allocation ordinal is failed once, followed by an exact successful
query. Additional failures target the observed large reservation sizes. The
baseline passes 133/2,835 injections in the small/large fixtures, and every
candidate configuration passes 32 in each. Some SQLite baseline injections are
recovered internally; others throw `bad_alloc`. Every candidate injection throws,
recovers and leaves no audited live allocation at teardown.

Disassembly of the actual ARM64 runtime object confirms the 32-byte candidate
stride, scalar timestamp/id comparisons, paired 128-bit heap-record transfers,
and rejection before fetching/scoring text for rows older than the retained
boundary. The scoped x86 build uses two SSE transfers at baseline and 256-bit
transfers under v3 for corresponding record moves. The final recency sort still
passes a comparator function pointer; no new optimization is attributed to it.
These listings establish generated behavior, not a separate speed claim.

A negative control reverses the equal-timestamp id tie break. Its standalone
filter/failure audit still succeeds, but the complete-wire comparison rejects it;
`/tmp/telar-perf-history-store-check-01/negative/result.json` records the distinct
canonical digest. This checks that the differential oracle detects ordering errors
which simple filter assertions miss.

The candidate still needs cold first-query and non-fuzzy/write controls, native
query-to-presented-results measurement and independent Zig F12 comparison. None
of F01–F16 or native120 is closed by this validation.

### Fused history ranking: first requests and unchanged-path controls

The first-query experiment starts a fresh owned runtime for each request against
a copy of an existing fixture database. No history query precedes the timed fuzzy
`gb`, distinct=true request. An independent rank model is constructed before
readiness; runtime CPU counters surround probe release/completion, and a separate
clock surrounds the protocol exchange. Startup, database copying and model
construction are outside those intervals. Filesystem caching is uncontrolled and
may be warm: this is **first-query-after-restart**, not cold-disk latency or native
GUI latency. Each of seven alternating pairs averages eight fresh processes per
variant; table entries are medians of those seven pair means.

All four final series under `/tmp/telar-perf-history-first-query-pairs-02` qualify:
448 executions, 904 valid host boundaries, maximum load1 3.225, exact model/A/B
results and complete owned-process cleanup. `uptime` is recorded before every
series. The accepted A/B runtime binaries are unchanged.

| Fixture | Runtime CPU A → B, ms/request | Protocol response A → B, ms | CPU / response wins |
| --- | ---: | ---: | ---: |
| 10,000 monotonic dates | 5.4905 → 1.9769 | 5.4943 → 1.9749 | 7/7, 7/7 |
| 100 entries | 0.2776 → 0.2586 | 0.2635 → 0.2460 | 7/7, 7/7 |
| Long commands | 12.5358 → 4.1415 | 12.5547 → 4.1645 | 7/7, 7/7 |
| 15,000 shuffled dates | 9.0446 → 3.5035 | 9.0440 → 3.5056 | 7/7, 7/7 |

The main end-footprint statistic rises from 5,890,471 to 6,130,072 bytes. As before,
this process observation is distinct from the query-local allocator peak.

An earlier long-command series is excluded in full. Its runtime exited before a
query with `Disable socket SIGPIPE: Invalid argument`. The identity helper used a
raw connect/get-peer-pid/close connection. A separate local UNIX-socket diagnostic
reproduces `SO_NOSIGPIPE` failure in 1,000/1,000 accepted connections whose client
has already closed, versus zero failures in 1,000 retained connections. In
`LocalListener::accept`, signal configuration can throw outside the runtime's
admission exception handler. This exposed a runtime robustness defect, not a proven consequence of the
history candidate. The listener correction is recorded below.

The revised private harness obtains `LOCAL_PEERPID` from the measured probe's
already-handshaken connection and verifies its executable identity before release.
It uses bounded connect-only retries while the background runtime starts. An
intermediate qualification exposed the missing startup wait and is also excluded.
All four series were then repeated with the same final harness; no partial pairs
were reused. Receipts are in `socket-close-diagnostic.json`,
`socket-close-followup.json` and the excluded runs' `disposition.json` files under
the private prefix/output directories. The listener regression and correction are recorded below; the history timing
binaries were not altered to mask the defect.

The unchanged FTS/substring/empty-query control is
`/tmp/telar-perf-history-fused-rank-fts-01`: seven pairs, 600 queries per execution,
with 30 independently checked query/offset/snapshot cases before timing and exact
checks on every measured reply. CPU medians are 1.103683 → 1.104202 ms/query;
response medians are 1.109017 → 1.109318 ms, with 2/7 wins for both. Response p95
wins 2/7 and p99 wins 3/7. This is **not a performance improvement**; it does not
hit the original 0–1/7 control-rejection threshold. No gate was changed afterward.

The persisted import/delete control is
`/tmp/telar-perf-history-fused-rank-write-01`: seven pairs of 600 cycles after 20
warm cycles. Each cycle waits for import admission, queries the persisted newest
entry, waits for deletion and queries the restored prior newest entry. It checks
command bytes, timestamp, id/snapshot and removed count; matching restored entries
form the canonical A/B output. Its clock includes all four exchanges and the
small verification steps, rather than treating import acknowledgment as durable
completion. The generic raw result keys say `per_query`, but the denominator is
**completed four-request cycles**. CPU medians are 5.495882 → 5.461910 ms/cycle;
wall medians are 5.652373 → 5.585677 ms/cycle, both 6/7 wins. Wall p95 wins 6/7 and
p99 4/7. This path does not enter the changed fuzzy algorithm, so these differences
are control observations, not an established additional algorithmic gain.

Both unchanged-path controls have 14 valid executions, 30 valid host boundaries,
exact results and complete cleanup. Maximum load1 is 2.014 for FTS and 2.161 for
writes. The fused candidate remains **pending** native query-to-presented-results
qualification and independent Zig F12 comparison; Linux execution is also open.
The C++ GUI currently has a 60 ms history debounce (`qt/application.cpp`), which
must remain inside input-to-presentation measurements. None of F01–F16 or native120
is closed by the protocol measurements.

### Disconnected-client admission: runtime robustness correction

The first-query harness exposed a real macOS runtime failure: an accepted local
client can close before `SO_NOSIGPIPE` is configured, causing `EINVAL` to escape
`LocalListener::accept` and terminate the runtime. The production listener now
closes/rejects that connection when signal setup throws `SystemError(EINVAL)`.
Other errors propagate. Existing peer ownership, close-on-exec, nonblocking and
signal-suppression checks remain in place for admitted clients. No measured
history implementation or installed runtime was changed as part of this fix.

`tests/platform_test.cpp` adds 100 alternating abandoned/healthy connections. It
checks EOF or rejection for each abandoned client and a bidirectional byte exchange
for each healthy client, including nonblocking, close-on-exec and macOS SIGPIPE
flags. The original listener fails the new regression; the correction passes the
complete platform test group. That group includes a descriptor-at-4096 check;
the inherited soft limit was 2560, so only the test-launch process raises it to
8192. The initial limit-related failure and the successful rerun are retained.

The platform group also passes ASan/UBSan; instrumentation covers the platform test,
listener and test entry translation units, while configured dependency archives
remain uninstrumented and LeakSanitizer is disabled. The identical new regression
body passes x86-64 under Rosetta. Linux execution remains unverified. These are
correctness checks, not performance acceptance.

The reusable `tools/check_disconnected_clients.py` and
`tools/disconnected_clients_probe.cpp` under `services/runtime-cpp` verify the
complete runtime. They start owned processes, identify them through a live protocol
connection, pause only those processes, queue eight clients which disconnect, and
resume before issuing two healthy requests. In
`/tmp/telar-perf-local-accept-close-tool-01`, the original runtime exits on the first
batch with the expected `EINVAL` diagnostic; the corrected runtime survives ten
batches (80 abandoned connections), answers all 20 health requests and emits no
runtime error. Both variants and probes are cleaned up completely. A separate
private run obtains the same result. Build/source receipts and isolated binaries
are under `out-perf/dlls-local-accept-close-01`.

ARM64 disassembly preserves the healthy-path syscall sequence, but the new catch
adds a saved register pair and increases the stack frame from 64 to 80 bytes. No
speedup or unchanged instruction count is claimed. This is a correctness fix for
a measurement-discovered failure. Subsequent history A/B stages must contain this
listener correction in both variants; old frozen measurements remain evidence of
the earlier binaries, not measurements of the newly corrected stack. All F01–F16
and native120 acceptance remain open.

### History candidate on the corrected listener: native content qualification

`out-perf/dlls-history-fused-rank-02` stages the same verified baseline/candidate
main objects with the identical corrected listener object in both links. Link maps
confirm the old archive listener object is not pulled in. Runtime A is
`ffea7fb28307e3e990cc0bd51ddbfe268859293da562bf16488ebbd8dd642d09`;
B is `1f1849d1881fe60af13d46531c6f722fb5105f32fc8beaaadf7276ad50f55031`.
Both retain GUI `5a639c5f26f67892698088cd95e31555212e6508dae2e45a441dc58e641caef5`
and helper `87beebb065f0ea4274492eaadecea2ccef7cdedc28f36049bf61ecc21214924f`.
The frozen prior stages and their measurements remain intact.

A fresh seven-pair warm query run,
`/tmp/telar-perf-history-fused-rank-02-monotonic-01`, preserves the independent
60-case reference checks and exact measured replies. All 14 executions and 30 host
boundaries qualify, maximum load1 2.077, with complete cleanup. CPU medians are
2.385050 → 0.679151 ms/query and mean protocol response medians are
2.391025 → 0.683903 ms; both win 7/7. Response p95/p99 also win 7/7. End-footprint
medians are 7,045,552 → 7,602,608 bytes. These are measurements of the new common
listener stages, still not GUI latency acceptance.

The private `capture-native.py` reuses the repository's native history action and
Metal capture helpers, starts the selected C++ runtime explicitly, and imports the
existing 10,000-entry fixture by copying its standalone database before startup.
It checks the actual GUI/runtime executable identities and stages the expected
runtime helper beside the GUI. The final four captures are:

| Query | Baseline | Candidate | Complete PNG / pixels |
| --- | --- | --- | --- |
| `gb` | `/tmp/telar-perf-history-native-capture-A-02` | `/tmp/telar-perf-history-native-capture-B-01` | Byte-exact / exact |
| `GST` | `/tmp/telar-perf-history-native-capture-A-GST-01` | `/tmp/telar-perf-history-native-capture-B-GST-01` | Byte-exact / exact |

Each has a focused key window, 1600×1000 point viewport, 3200×2000 drawable, expected
native text-input query and a positive `MTLDrawable.presentedTime` after the final
scripted input. Both processes are identified and cleaned up. Database inspection
after capture confirms 10,000 rows/max-id 10,000 in all four cases. Visual inspection
of the baseline images shows selected commands `git build --target 4996` and
`git status --short 4995`, consistent with the independent ranking fixture. The
complete image equality includes the visible rows and metadata, not just that
selected command.

`native-capture-comparison.json` records the image digests. Two distinct BGRA
selected-command templates were extracted for a future per-frame observer. This
observer is **not qualified yet**: raw Metal readback must first match those
screenshot-derived bytes, and stale/wrong/missing/zero-presentation controls must
fail. The existing capture driver waits for a settled image and performs a final
resize; its elapsed time and last-input timestamp must not be repurposed as
query-response latency. Native input-to-results timing, separate GUI/runtime
resources, independent Zig F12 comparison and native120 remain open. No flow is
closed by these two content cases.

### Native history result observer and instrumented A/B comparison

The private history observer now verifies both screenshot-derived BGRA templates
against raw Metal bytes. `/tmp/telar-perf-history-observer-same-submit-gb-01` and
`/tmp/telar-perf-history-observer-same-submit-GST-01` pass with no readback drops.
The 512×48 region at (320,1592) contains the selected command, outside the query
field. The two commands differ, so changing query text or highlighting on an old
result cannot satisfy the new-result oracle.

Unlike the initial post-presentation snapshot experiment, the observer encodes
its blit into the render command buffer before commit. A per-drawable record joins
the GPU-completed pixel comparison with that drawable's positive native
presentation timestamp. Three reusable shared buffers total 294,912 bytes.
Pool exhaustion fails the run. A target-result frame with a zero timestamp also
invalidates the measured endpoint; non-target zero frames are counted separately.
This implementation currently observes the ordinary Metal command-buffer path
used by the C++ GUI; independent Zig/Metal4 qualification remains separate work.

Native query-replacement qualification passes in
`/tmp/telar-perf-history-query-observer-qual-A-02`. The driver posts Command-A,
verifies the native selected range, timestamps `NSTextInputClient.insertText`,
checks the resulting query text, and alternates `gb`/`GST`. Selection preparation
is outside the latency interval. The 60 ms application debounce remains inside it.
The earliest verified positive result timestamp is retained while callbacks drain
for 50 ms before the next query. No arbitrary settle delay is added to the reported
latency. Forced stale-result, absent-result and zero-presentation controls in
`/tmp/telar-perf-history-query-observer-negative-{stale,missing,zero}-01` all time
out without accepting a trial. These are detector fault injections, not claims
that the operating system generated every injected fault. The first A driver run
failed while serializing its summary and is superseded by A-02.

The two-query diagnostic
`/tmp/telar-perf-history-query-observer-timeline-B-01` retains all observed ROI
pixels and commit/GPU-completion/presentation times. Visual inspection shows old
command text, a blank region, then the new command at the first exact match. It
does not show an earlier new command merely fading into the settled template.
This is a check of these two transitions, not proof for arbitrary history layouts.

`/tmp/telar-perf-history-native-query-pairs-01` completes six alternating A/B pairs
with 60 replacements per run, using the corrected-listener stages above and one
frozen observer. All 720 queries, 12 owned-process cleanups and 62 nested/series
host boundaries pass; maximum load1 is 3.761. There are no dropped readbacks or
target-result zero timestamps. The observer rejects 610 old-result frames and
counts seven non-target zero frames during the trials.

The resource helper samples GUI and runtime separately after settled readiness,
before releasing the input driver, and after its final report. This excludes GUI
startup, fixture setup and shutdown, but includes native selection preparation,
the inter-query callback interval, observer work and counter boundary overhead.
The setup action timer stops after readiness; window-manager polling also stops
before query measurement. Median paired results are:

| Metric | A | B | B wins |
| --- | ---: | ---: | ---: |
| Mean input-to-presented-results, ms | 141.7414 | 137.9442 | 6/6 |
| Presentation latency p95, ms | 151.9116 | 148.8086 | 5/6 |
| Presentation latency p99, ms | 153.9799 | 151.4946 | 3/6 |
| Runtime CPU, ms/query cycle | 6.00394 | 1.82102 | 6/6 |
| GUI CPU, ms/query cycle | 68.74782 | 68.11187 | 6/6 |
| Runtime end footprint, bytes | 11,313,584 | 10,944,968 | 4/6 |
| GUI end footprint, bytes | 269,649,300 | 269,141,360 | 4/6 |

The p99 result is mixed, not a consistent tail-latency improvement. End footprints
and lifetime maxima are not interval peaks. Instrumented commit/encoder/drawable/
completion/record hooks account for approximately 0.305/0.274 ms per query cycle;
these are elapsed wall durations, despite the old scratch schema's `cpu_ns`
suffix. The reusable observer uses `elapsed_ns`. This excludes the native input
driver and does not isolate GPU readback
perturbation. GPU work counters cover the whole render submission, not just the
copy. The manifests therefore retain `adoption_eligible: false`: this is a
completed instrumented comparison, with observer overhead and independent Zig F12
still requiring qualification. Native120 and every full flow remain open.

Independent Zig captures now exist at
`/tmp/telar-perf-history-native-capture-Z-gb-02` and
`/tmp/telar-perf-history-native-capture-Z-GST-01`. Both actual processes identify as
`6ccf79485c5ca8baaa2d69d2590abb49d23c808891c04fe6e70f5602713a1d5e`;
the copied database still has 10,000 commands/max-id 10,000 after capture. Native
query/focus/viewport/positive-presentation and owned cleanup checks pass. The
selected commands are the same as in C++, but complete RGB captures differ at
64,029/66,649 pixels out of 6.4 million, respectively. The selected-command ROI
also differs: this is not just volatile outer chrome. For `gb`, its background
color is identical while the glyph pixels differ. Separate Zig templates are
saved, but neither their raw Metal4 readback nor the cross-stack visual difference
has been qualified yet. These captures do not establish visual parity or a Zig
latency comparison.

The GUI's larger CPU cost suggests the next algorithmic investigation. A history
page contains up to 100 records. `ListModel::reconcile` inserts new identities
individually, scans existing keys repeatedly, then removes the old suffix; the
history panel temporarily sets its model to null on removal and restores it with
`Qt.callLater`. This code path is consistent with the observed blank frame, but
its causal CPU/latency contribution has not yet been measured. A bounded page
replacement strategy should be tested against overlap, identical refresh,
deletion, paging and stale-action controls before changing production behavior.

### Independent Metal4 observer and history text rasterization diagnosis

`tools/gui_history_latency.py` and `.m` provide the native history observer as
reusable source. The caller supplies explicit GUI/runtime binaries, a shared
configuration, a SQLite fixture and a JSON case with two queries, BGRA templates,
viewport, drawable dimensions and ROI. The driver copies a consistent database
snapshot, validates actual process identities, stages no installed applications,
checks host load and owns cleanup. It supports ordinary Metal and Metal4 with the
same pixel/presentation predicate. Metal4 uses three reusable readback slots and
residency sets; each set contains its buffer and current source texture. It does
not allocate a new residency set for every frame.

`/tmp/telar-perf-history-metal4-raw-{gb,GST}-01` verifies both Zig templates against
same-submission raw Metal4 bytes. `/tmp/telar-perf-history-metal4-query-01` passes
12 alternating native replacements and records a diagnostic pixel timeline. The
three stale/missing/zero detector injections under
`/tmp/telar-perf-history-metal4-negative-{stale,missing,zero}-01` all reject the
trial by timeout. The reusable driver also passes C++, Zig, raw-template and all
three negative cases under `/tmp/telar-perf-history-public-*`. Final ordinary-Metal
and Metal4 positive reruns use `public-final-cpp-01` and `public-final-zig-01`.
The instructions and result/resource limitations are in
`services/gui-cpp/OPTIMIZATION.md`. Neither these qualifications nor the earlier
C++ A/B pairs establish the independent six-pair Zig comparison or native120.

The final source builds the observer with `-O2`, reports aligned buffer bytes,
and compares packed template rows without Metal transfer padding. It also refuses
to advance while any submitted drawable lacks either its pixel or presentation
callback. The final six-case cohort is
`/tmp/telar-perf-history-public-joined-{cpp,zig,stale,missing,zero,callback}-01`:
both positive runs complete 12 replacements with zero pending submissions; the
Zig case uses a 511-pixel-wide ROI to exercise padded row transfer. All four
negative controls reject, including a withheld callback despite a later verified
positive result. Every cleanup and host boundary passes; maximum load1 is 1.740.
`public-joined-padded-raw-01` additionally checks exact packed raw bytes. The probe
also compiles for macOS x86-64; native execution here remains ARM64.

An earlier `public-optimized-missing-01` run reached its expected detector timeout
but its final load1 was 5.608, so that execution is excluded for performance and
the interrupted qualification batch is superseded. No partial batch is reused as
an accepted timing series. The earlier six-pair C++ comparison remains historical
instrumented evidence; final acceptance requires remeasurement with the frozen
reusable observer and its stronger callback-completion gate.

The first 12-query Zig diagnostic produces 39.3–58.2 ms input-to-presented-result
samples. This is not a paired performance result: it retains diagnostic pixel
data and visual parity is still open. Source inspection identifies a timing
difference to investigate: C++ starts its 60 ms history timer, whereas Zig's
`name_prompt` history callback calls `history_palette.queryHistory`, which pushes
the bounded request through `requestHistoryPage` without that debounce timer.
Changing scheduling needs rapid-typing, cancellation and request-load controls;
the timer has not been changed.

The history glyph mismatch now has a concrete isolated experiment.
`NativeCellText::updatePaintNode` calls `paintChromeText`, whose rasterization is
always non-optical. Zig propagates the configured `thicken`/strength into its
primary and fallback font faces. The private
`out-perf/dlls-history-cell-optical-01` changes only the NativeCellText translation
unit to call the existing optical terminal-text route for the already-thickened
fixture. This deliberately forced route is diagnostic, not a configuration-aware
fix or an accepted performance variant.

Before that build, the configured GUI output still contained the unaccepted
same-grid reservation experiment (`c2b1d042…`), although source had been restored.
Rebuilding the accepted source restores `0d5ec9b958573ae7ee7a606a08e9d5537cc88606cca45467e2da8c27bd247f79`,
the previously verified baseline that differs from `5a639c5f…` only in resource
timestamps/signature metadata. Its complete `gb` PNG is byte-exact to the frozen
history baseline. The private optical GUI is
`6517982704afdb02ae3e1802b47a22f318eb72944778e0539a7600dd74cbb69b`;
both sides retain corrected runtime `ffea7fb2…` and the same helper. The link map
confirms the old NativeCellText archive member is not also linked.

Captures `/tmp/telar-perf-history-cell-optical-{A-gb,B-gb,B-GST}-01` preserve native
identity/focus/geometry/positive presentation and clean up all owned processes.
The `gb` selected-command ROI changes from 2,287 mismatching pixels against Zig to
two; `GST` also leaves two. Remaining channels differ by one level, including
the same pixel at (347,1623) in both queries. Complete-image differences fall to
22,261/22,282 pixels, so full visual parity is not achieved. The optical path
explains most of the selected-command mismatch, but the remaining blend/raster
rounding and other chrome text require investigation. No tolerance was substituted
for exact equality. A production change must propagate configuration and handle
reload/invalidation, non-optical mode, strengths, styles and fallback fonts before
adoption. The separate history page-replacement algorithm remains a source-based
lead rather than an implementation change.

## F12 history snapshot candidate and process work counters (2026-11-03)

The native history replacement profile identifies repeated Qt delegate work,
not record conversion, as the next substantial GUI cost. Two separate six-second
`sample` runs used the qualified observer and completed 120 queries each. In the
C++ main-thread profile, 549 of 4,521 stack observations include
`QQuickItemView::setModel`, 662 include `QQmlObjectCreator`, and only three include
`historyRecord`. These groups overlap and are neither additive CPU times nor
paired performance measurements. Receipts are in
`out-perf/dlls-history-row-profile-01/summary.json`.
The C++ profile used the private fused-query runtime; it is separate from the
accepted-runtime A/B stages below.

The working-tree candidate adds positional `ListModel::replaceRows` for history
snapshots only. Equal-sized replacements update records with one bounded
`dataChanged` range, avoiding keyed insertion/movement and whole-view retirement.
Unchanged snapshots emit nothing. Real suffix removal retains the existing QML
pending-delegate retirement safeguard; other models still use keyed `reconcile`.
The AArch64 body has one bounded shared-prefix loop, QMap pointer moves and a
single changed-range notification, rather than repeated searches and insertions.
The initial pass held the candidate for the runtime-cost investigation below;
the follow-up records its local adoption decision. This is not an accepted F12
or independent-Zig win.

Validation: 4,096 randomized final-record comparisons against keyed reconciliation,
Qt model integrity and positional persistent-index/signal checks passed. All 34
existing native history cases passed with owned-window floating and Cocoa-owner
acknowledgement; the initial unqualified geometry/setup attempts are retained in
the scratch logs. Two additional native cases passed: equal-sized replacement
while delegates are incubating, and press-before/release-after replacement without
acting on the new record. The existing retirement and stale-action cases were
rerun alongside them. Both complete native `gb` and `GST` images are byte-exact to
the accepted GUI, not merely equal inside the latency ROI.

Frozen GUI A is `0d5ec9b9…`; B is `aef2c9b0…`. Both use the same accepted runtime
`ffea7fb2…` and helper `87beebb0…`; no fused-history runtime candidate is included.
`stage-manifest.json`, `validation.json`, captures and assembly are in the same
scratch directory. Two independent series each contain six alternating pairs of
60 native queries per run, with positive verified result pixels and all submitted
callbacks completed. Each series has 720 queries and 62 valid host boundaries,
complete owned cleanup, no target-zero timestamps and no dropped readbacks.
Maximum load1 is 2.9102 for the original closed-loop driver and 3.5391 for the
fixed-cadence diagnostic. Series receipts are
`/tmp/telar-perf-history-row-snapshot-pairs-01` and
`/tmp/telar-perf-history-row-fixed-pairs-01`; `paired-results.json` aggregates them.

| Instrumented metric | Closed-loop A → B | B wins | Fixed-cadence A → B | B wins |
| --- | ---: | ---: | ---: | ---: |
| Mean input → verified presentation, ms | 141.068 → 110.725 | 6/6 | 141.668 → 110.586 | 6/6 |
| p95, ms | 151.563 → 122.495 | 6/6 | 152.416 → 119.993 | 6/6 |
| p99, ms | 156.293 → 124.353 | 6/6 | 156.942 → 122.297 | 6/6 |
| GUI CPU ms/query cycle | 69.644 → 32.466 | 6/6 | 76.072 → 39.199 | 6/6 |
| Runtime CPU ms/query cycle | 6.084 → 7.242 | **0/6** | 6.736 → 6.933 | **1/6** |
| GUI end footprint, bytes | 267,756,936 → 254,076,296 | 5/6 | 263,210,400 → 253,961,632 | 6/6 |

CPU intervals include the native input driver and callback drain/wait, not startup.
The fixed diagnostic adds a minimum 300ms wait before the next Select All, with
observed mean input intervals 309.452–310.381ms and the required 5% offered-rate
tolerance. It changes only a conjunction in the observer's advance gate. Combined
GUI+runtime CPU medians are 75.777 → 39.545ms in the closed-loop series and
82.805 → 46.006ms at fixed cadence. Runtime footprint is mixed, 3/6 wins in each.
Observer CPU/GPU perturbation remains a limitation; these are instrumented
comparisons, not native120 or independent-Zig acceptance.

The runtime CPU increase is smaller at fixed cadence but still consistent; its
cause is **not established**. A separate pass-through IPC census found exactly
24 queries and 24 responses in each variant, with no intercepted or duplicate
queries. Do not attribute the remaining difference to clock frequency, caches,
Qt conversions or additional runtime work without further evidence.

`macos_process_resources.c` now exposes the existing `proc_pid_rusage` instruction
and cycle fields. The parser keeps them as raw deltas, checks optional-field
pairing, representation and monotonicity, and distinguishes unavailable zero
lifetime counters from a supported idle interval. Older snapshots remain valid.
Eleven resource tests pass. An owned-child native helper/parser qualification
observed positive counters and verified exact deltas, process identity and cleanup
(`counter-helper-qualification-native-guarded.json`).

Cross-architecture qualification also exposed an existing CPU conversion error:
the translated x86 helper reports a 1:1 Mach timebase, while the native reader
uses 125:3 for the same kernel CPU counters. The translated reader reported only
3.800ms CPU over a 170.277ms busy interval. That receipt is invalid for CPU
interpretation. The helper now rejects translated execution or an unqualified
translation check instead of returning misleading JSON. A native ARM reader can
measure translated targets: an owned x86 child reports 274.613ms CPU over
278.285ms wall, with positive raw work counters and verified cleanup. See
`translated-helper-rejection.json` and `native-helper-translated-child.json`.
The two history series above used ARM readers and are unaffected.

### Follow-up: retained history rows adopted for the measured C++ workload

The source hashes and both frozen stages were rechecked before a third complete
six-pair series, now with native raw instruction/cycle counters. No application
code or fixture changed between these series. The fixed-rate observer, resource
helper/header, parser and host gate hashes are frozen in the new contract.
`/tmp/telar-perf-history-row-hardware-pairs-01` contains 720 queries, 62 qualified
host boundaries (maximum load1 3.75), complete cleanup and zero dropped readbacks,
pending callbacks or target-zero presentations. Mean input intervals range from
309.252 to 310.638ms, inside the required offered-rate tolerance. The compact
receipt is `out-perf/dlls-history-row-profile-01/hardware-results.json`.

| Instrumented query-cycle metric | Accepted GUI A | Retained rows B | B wins |
| --- | ---: | ---: | ---: |
| Input → verified result mean, ms | 141.695 | 109.558 | 6/6 |
| p95, ms | 153.419 | 119.002 | 6/6 |
| p99, ms | 155.946 | 125.008 | 6/6 |
| GUI CPU, ms | 76.284 | 39.975 | 6/6 |
| GUI instructions, millions | 558.654 | 168.654 | 6/6 |
| GUI cycles, millions | 213.775 | 89.674 | 6/6 |
| Runtime CPU, ms | 6.671 | 6.847 | 3/6 |
| Runtime instructions, millions | 71.632 | 71.640 | 2/6 |
| Runtime cycles, millions | 16.923 | 17.315 | 1/6 |
| Combined process CPU, ms | 82.966 | 46.974 | 6/6 |
| Combined process instructions, millions | 630.286 | 240.292 | 6/6 |
| Combined process cycles, millions | 230.638 | 106.769 | 6/6 |

Both query modes, `gb` and `GST`, independently win mean/p95/p99 in all six pairs.
GUI end footprint falls from 265,790,856 to 253,937,032 bytes, 6/6 wins. Runtime
memory is mixed, 3/6. Runtime instructions differ by only -0.016% to +0.059% per
pair; its CPU-time wins are now mixed. This does not establish a clock/cache/QoS
cause for the small runtime cycle increase. GUI interrupt wakeups also rise from
89.575 to 92.950 per cycle (0/6 lower), with the observer's 5ms main-thread polling
present. Do not turn this instrumented count into an idle or production wakeup
claim. These adverse counters remain recorded rather than discarded.

Adopt `replaceRows` for the history projection: the complete measured client
workload has substantially lower latency, CPU, instructions and cycles, with
unchanged results and the native interaction checks above. The adoption criterion
is the whole query workload, not a claim that every process counter improves.
Keyed reconciliation remains unchanged for other projections. No change is made
to debounce, runtime SQL, fonts or the removal safeguard. Frozen B (`aef2c9b0…`)
becomes the GUI baseline for the next experiments; runtime remains `ffea7fb2…`.

This local adoption does not close F12, certify uninstrumented latency/idle
behavior, complete x86/Linux GUI validation or establish native120. The next
experiment combines the retained GUI with the separately qualified fused-query
runtime candidate, preserving single-variable comparisons. The pre-existing
runtime cadence edits remain untouched. All F01–F16 requirements remain open.

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
| F08 | Native previous-tab to verified target generation, four 30 Hz producers | Baseline latency/CPU regression; workspaces, complete content, cadence and separate resources |
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
leads are repeated font coverage lookup, runtime scrollback projection and
history-query scratch/statement reuse. Same-grid capacity checks pass the component
gate but remain deferred on native qualification. Each new candidate needs a
fresh profile, equivalence oracle, disassembly and paired acceptance before it
can be retained as an optimization. Historical rejected batching, relay-buffer,
prefault, render-loop and update-idle variants remain documented in the existing
GUI/runtime performance reports.

## Follow-up: fused history ranking adopted on retained GUI, 2026-11-03

The fused-query candidate is now adopted for the measured C++ history workload.
This supersedes its earlier pending status; independent Zig parity, instrument
perturbation, native120 and every global F01–F16 gate remain open. The accepted
retained-row GUI is identical in both variants. Only history/store.hpp changes:
score/hash computation consumes the borrowed SQLite command, a bounded heap keeps
at most 10,000 scalar candidates, and the final recency ordering precedes the
existing duplicate-hash and score/page rules. Command strings are not retained.
The earlier allocation/failure, full-wire/filter, first-request, unchanged FTS/
write, ARM64 and Rosetta baseline/v3 evidence still applies to this exact source.
The extra candidate vector is 320,000 bytes; this is an explicit bounded memory
tradeoff, not a claim of universal allocation or memory reduction.

Before adoption, a scaling audit found a limitation in the algorithm. For
chronological insertion, ascending-id traversal can score every provisional
candidate even though only the newest 10,000 survive. An instrumented component
census in `out-perf/dlls-history-large-scan-01` confirms 1,000,000 score calls in
the million-row fixture, versus 10,000 in the accepted SQL path. In the 100,000-row
long-duplicate fixture, the counts are 100,000 versus five. Census `scanned`
counts rows returned to C++, not SQLite's internal scan work; score-input bytes
are command lengths offered to the scorer, not measured bytes actually read.
These instrumented executions are excluded from timing.

A fixed descending-id alternative reduces chronological score calls to 10,000
but reverses the problem for reverse-chronological imports. It is rejected:
`/tmp/telar-perf-history-large-scan-C-reverse-long-01` gives 151.814 → 246.126 ms
CPU/query, 0/7 wins, with all host boundaries valid. No descending-id change is
included in production. All three variants pass 324 independent ranking/recency/
dedup/snapshot/page cases across nine datasets, with byte-exact encoded replies.
The original qualification console mistakenly prints 72 per dataset; the stored
results and final counts correctly contain 36 per dataset.

The original fused candidate survives the larger controls. The following are
seven alternating pairs against the previously accepted store, O3 ARM64 direct
HistoryStore queries, distinct no-hit search, with one warmup per process. They
include response encoding/equality checking and clock overhead, but no IPC/GUI
or cold-disk claim. Commands use ordinary text or 2,048 padding bytes; the million
fixture contains 1,000,000 rows and all others contain 100,000. Every series uses
its own predeclared host gate. All 126 child exits and 270 host boundaries pass,
maximum load1 2.350. Results are in `B-expanded-results.json`; raw runs are
`/tmp/telar-perf-history-large-scan-B-<case>-01`.

| Case | A CPU ms/query | B CPU ms/query | B wins |
|---|---:|---:|---:|
| monotonic | 50.537 | 13.338 | 7/7 |
| reverse | 7.689 | 7.676 | 4/7 |
| shuffled | 25.485 | 10.512 | 7/7 |
| tied | 54.272 | 13.344 | 7/7 |
| long | 504.137 | 239.328 | 7/7 |
| duplicates | 485.633 | 238.984 | 7/7 |
| million | 535.742 | 146.225 | 7/7 |
| reverse-long | 152.487 | 105.977 | 7/7 |
| reverse-duplicates | 136.210 | 105.916 | 7/7 |

Reverse-short is neutral, not an improvement. Fewer score calls alone were not
an adequate optimization criterion: measured total work matters, including the
removed SQLite temporary sorting/copying. The enlarged work census is retained
as a lead for further algorithmic improvements, not hidden by the wins.

`out-perf/dlls-history-integrated-01` freezes accepted runtime `ffea7fb2…` and
candidate `1f1849d1…`, both with accepted GUI `aef2c9b0…` and helper `87beebb0…`.
Four complete native gb/GST captures match byte-for-byte, including the same
PNG hashes as the retained-row validation. The six alternating fixed-cadence
pairs in `/tmp/telar-perf-history-integrated-fixed-pairs-01` then complete 720
queries, all cleanup, 62 valid host boundaries (maximum load1 3.939), zero missing
pending callbacks, target-zero presentations or dropped observations. Mean input
intervals span 309.534–310.273 ms. The observer and GPU readback remain present;
these are instrumented C++ comparisons, not independent Zig/native120 acceptance.

| Native metric | A | B | B wins |
|---|---:|---:|---:|
| Input to verified presented result, mean (ms) | 110.093 | 105.635 | 6/6 |
| Input to result, p95 (ms) | 118.690 | 116.030 | 6/6 |
| Input to result, p99 (ms) | 123.075 | 120.306 | 5/6 |
| Runtime CPU (ms/query) | 6.887 | 2.389 | 6/6 |
| GUI CPU (ms/query) | 39.531 | 40.254 | 2/6 |
| Combined CPU (ms/query) | 46.491 | 42.643 | 6/6 |
| Combined instructions (millions/query) | 239.973 | 187.191 | 6/6 |
| Combined cycles (millions/query) | 106.171 | 93.626 | 6/6 |

Runtime instructions fall 71.633 → 21.485 million/query and cycles 17.176 →
5.682 million/query, both 6/6. GUI instructions fall 168.343 → 165.705 million,
6/6, and cycles 89.001 → 87.858 million, 5/6, although GUI CPU time rises in four
pairs. Its cause is not established; no clock/cache/QoS explanation is asserted.
Runtime interrupt wakeups rise 4.217 → 4.558/query, 0/6 wins; idle wakeups are
0.033 → 0.058, 2/6. GUI interrupt wakeups fall 92.958 → 92.017, 6/6. These active,
5 ms-polled instrumented runs do not qualify production idle behavior. Runtime
end footprint is 11,329,992 → 11,338,184 bytes, 3/6; GUI end footprint is
254,166,396 → 254,018,928 bytes, 3/6. Neither is a measured interval peak.
Combined CPU, instructions, cycles and mean latency win 6/6, supporting adoption
while preserving these adverse and mixed counters. Per-query gb mean/p95/p99
wins are 6/6, 6/6, 5/6; GST is 6/6, 5/6, 4/6. No universal p99 win is claimed.

The permanent testFuzzyRecencyBoundary regression covers an excluded older
high-score command at the 10,000-row cutoff, all-tied and shuffled dates, distinct
winner identity, an older insertion snapshot, pagination and a valid zero score.
The standalone form passes accepted/candidate ARM64, ASan/UBSan and Rosetta
baseline/v3; inverted-id and discarded-zero-score mutations both fail. Sanitizers
cover the probe, inline store and database.cpp, not system SQLite, with leak
sanitization disabled. The integrated production testHistory group also passes.
Pending attachment cadence edits remain separate and uncommitted.
The final runtime rebuild from the integrated production source is byte-for-byte
identical to measured B, including its UUID and signature: SHA-256
`1f1849d1881fe60af13d46531c6f722fb5105f32fc8beaaadf7276ad50f55031`.
The full comparison is `final-build-equivalence.json`; no ignored byte differences
are needed. GUI debounce and optical rendering remain unchanged in this pass.


## History card capture identity prerequisite, 2026-11-03

The next, unadopted match-highlight delegate reuse candidate exposed a held-copy
failure: pressing copy on query A and releasing after query B had replaced the
same row copied B. Its first full native history run passed 35 of 36 cases;
`out-perf/dlls-history-match-model-01/native-quick-result-01.json` and the adjacent
log retain the failure. A four-case original-QML control passed with the same
accepted fused runtime. That single control does not establish why the candidate
exposed the failure; neither timing nor adoption of that candidate followed it.

Card capture previously retained only the dialog generation and action enum.
It could therefore depend on presentation of an intermediate disabled card to
cancel an old press. The correction retains the rendered `HistoryChoice` (row
index and exact 64-bit content revision), cancels when that choice changes, and
checks the browser's current choice before activation. A press beginning on a
disabled target remains consumed but cannot later activate it. The QML revision
stays a string until C++ conversion, avoiding JavaScript number truncation.

Evidence is in `out-perf/dlls-history-action-identity-01`. The permanent input
test covers replacement without an intermediate disabled frame, a fresh click,
selection changes, disabled-to-enabled targets and secondary buttons. It passes
ARM64, ASan/UBSan, and Rosetta baseline/v3; removing identity comparison makes
it fail. The native regression also changes selection and releases synchronously,
before another frame can present. A separate negative control removing the
activation-time check copies B_FIRST and fails that new assertion.
Both the original QML and the unadopted match adapter now pass all 36 native
history cases (38 including init/cleanup). The adapter also passes all 36
component cases offscreen and five selected native component cases. Those
checks establish interaction correctness, not a performance gain. The correction
is separate from the adapter; subsequent A/B stages include it on both sides.
All F01–F16 remain open, and pending runtime cadence changes remain separate.

The follow-up static check adds direct includes, an explicit empty optional
initializer and a named test extent, and keeps the optional checks adjacent to
activation. The final input suite and four native interaction cases pass again.
Targeted clang-tidy passes `history_meta_layout.cpp` and `input_test.cpp`;
`history_pointer.cpp` and the final `pointer_dispatcher.cpp` report only the
pre-existing redundant alias in `config/callback.hpp:13`. The larger QuickTest
check reported that same alias and a const-correctness suggestion in the touched
regression, which was corrected. Full lint is not claimed green.


## Retained history match delegates: local CPU adoption, 2026-11-03

Adopt positional reuse of the inner history match delegates for reduced CPU
work. This is not a consistent latency improvement or global F12 acceptance.
The accepted comparison base is `f2b203cda`, including the separate card-choice
correction above. Both A and B include that correction and use the same accepted
fused runtime. Neither the runtime cadence edits nor the optical text candidate
are part of this change.

`HistoryMatchModel` keeps a stable ListModel for each existing command line.
Changed records update the shared prefix; only appended highlights create new
QML objects, and removed suffixes retire immediately. Unchanged input returns
without updating the model. This removes repeated delegate construction while
retaining one adapter and one ListModel per live command line, plus shared Qt
records. It does not retain a high-water pool of removed highlights. Existing
keyed ListModel consumers, command matching, shaping, line geometry and the
60 ms search debounce are unchanged.

Evidence lives in `out-perf/dlls-history-match-model-03` and
`out-perf/dlls-history-match-cadence-01`; the earlier stage 01 failure and stage 02
correctness controls remain intact. Each final series has six alternating pairs,
60 queries per run, 720 total queries, and 62 qualified load boundaries. Maximum
one-minute load was 2.647 and 2.316 respectively. All owned children exited; all
presentation callbacks drained, with no dropped or zero-timestamp result frames.
The second series was added to investigate the adverse first-series p95, without
replacing or excluding the first series. Offered mean intervals were
309.068–310.543 ms and 229.090–231.212 ms. These are two controlled query rates,
not a typing-burst or cold-open latency experiment.

Values below are medians of six per-run statistics. Wins are paired B < A.

| Metric | 300 ms minimum: A → B (wins) | 220 ms minimum: A → B (wins) |
| --- | --- | --- |
| GUI CPU ms/query | 39.778 → 35.229 (6/6) | 37.220 → 32.493 (6/6) |
| Runtime CPU ms/query | 2.442 → 2.632 (1/6) | 2.359 → 2.679 (0/6) |
| Combined CPU ms/query | 42.132 → 37.925 (6/6) | 39.571 → 35.206 (6/6) |
| Combined instructions, million/query | 187.754 → 142.423 (6/6) | 185.015 → 139.926 (6/6) |
| Combined cycles, million/query | 93.065 → 80.483 (6/6) | 92.595 → 78.007 (6/6) |
| Mean latency ms | 106.063 → 105.436 (4/6) | 106.142 → 105.893 (5/6) |
| p95 latency ms | 116.412 → 117.938 (2/6) | 116.689 → 116.147 (5/6) |
| p99 latency ms | 120.075 → 119.888 (4/6) | 121.400 → 119.564 (3/6) |
| GUI interrupt wakeups/query | 92.033 → 93.242 (0/6) | 69.600 → 70.700 (0/6) |
| GUI final footprint, bytes | 253756784 → 253928828 (2/6) | 254510472 → 253912444 (4/6) |
| GUI setup footprint, bytes | 313517484 → 314050012 (1/6) | 312862148 → 313664952 (1/6) |

Combined CPU falls about 10.0% and 11.0%, and combined instructions about 24.1%
and 24.4%, with 12/12 paired wins for both. Runtime CPU and GUI interrupt wakeups
are adverse despite identical runtime code. Their causes are not established;
no clock, cache, core-placement or QoS explanation is claimed. Runtime cycles
also rise: 5.743 → 6.111 million/query (0/6), and 5.621 → 6.115 (1/6), while
runtime instruction medians remain around 21.45–21.48 million. The whole-query
CPU and hardware totals include these costs. Wakeups belong to the instrumented
active-query workload with a 5 ms observer tick, not production idle behavior.

The separately retained setup counters include startup and scripted first
history preparation. Combined setup CPU is mixed: 880.537 → 884.545 ms (2/6)
and 892.247 → 878.007 ms (4/6). The higher GUI setup footprint, about 0.53/0.80 MB
in these medians, is an explicit bounded-memory tradeoff. Final footprints are
mixed, so no memory-saving claim is made. Individual query tails also remain
mixed: at the original cadence `gb` p99 rises 115.761 → 117.593 ms (2/6); at the
second it changes 119.157 → 118.925 (3/6). All counters and per-query statistics
are retained in both `hardware-results.json` files. The second cadence does not
prove the cause of the first cadence's adverse p95.

The target CPU-work reduction passes the five-of-six acceptance rule in both
cadences. Neither cadence has a consistent loss (zero or one wins) in whole-query
mean/p95/p99 or the individual query latency cases. Adoption is scoped to that
CPU reduction; it does not promote the mixed tails to a latency win. All F01–F16
remain open, and independent Zig comparison/native 120 Hz acceptance remains
outstanding. The observer's perturbation is not independently qualified.

Correctness checks include all 36 native history cases with both old QML and the
adapter after the choice fix, four final native interaction cases after guard
cleanup, all 36 component cases in software and five selected native component
cases. The retained-match test checks identity, text and positions across
same-size updates, grow/shrink/empty transitions, and wide/combining Unicode.
The final targeted component case and standalone header clang-tidy also pass.
Full native `gb` and `GST` images are byte-exact between A/B and retain accepted
PNG hashes `d488533203d1f1ec802f84ea2d3fc392f390ac241fd5c0456853ada0a0ed8f3f`
and `210477c351733af4fd5fa199c8184793bf6543a504a077d7f786b3848838d2ff`.

ARM64 disassembly in the action-identity evidence directory shows the initial
list size/shared-data checks, QVariant equality for unshared input, one list
reserve, per-record QVariant::toMap, and positional ListModel replacement.
Conversions and reference counting remain; this is not an allocation census or
proof that allocations explain the entire C++/Zig gap. The measured reduction
is work avoided by preserving QML delegates. No target-specific SIMD or integer
lowering was introduced.

Frozen GUI A is `7422966257e439674434c0b202bc576ba3885744c0ead38e1b448c179a26b511`;
B is `9661f8aa544f0d93aa41ce4ec6cf4f2a73b41b7661d2385a652ae704a58fda79`.
Both runtimes are `1f1849d1881fe60af13d46531c6f722fb5105f32fc8beaaadf7276ad50f55031`.
The final include-only cleanup rebuild is byte-for-byte identical to measured B,
including UUID and signature. Rebuilding first changed the embedded HistoryRow
resource modification timestamp and derived signatures; preserving the measured
resource timestamp restored exact identity. `resource-mtime-control.json` and
`final-build-equivalence.json` record this explicitly; no differing bytes are
ignored in the final equality check.


## Bounded retention of inactive history highlights, 2026-11-03

Adopt a small retained suffix on top of `6778544a5`. This avoids repeatedly
constructing the third highlight when queries alternate between two and three
matches. The fresh diagnostic profile in
`out-perf/dlls-history-after-matches-profile-01` had 4,437 main-thread observations,
including 84 in QML object creation and insertion-driven stacks beneath
HistoryMatchModel. These overlapping sample counts identify work to investigate;
they are not paired timing or CPU milliseconds. Flattening CellText was deferred
before edits because its wrapper and native item expose different baseline and
intrinsic-size behavior.

Each line now keeps `max(active_count, min(previous_model_count, 8))` model rows.
Inactive delegates retain their previous records and glyph state, and are hidden
through the active count. They cannot paint or appear as visible accessibility
content. Queries requiring more than eight active highlights remain supported;
shrinking to eight or fewer removes every excess delegate immediately. Destroying
the parent line releases all retained delegates. This is a bound on live retained
objects, not a claim that every Qt allocation has a fixed size or is immediately
returned to the OS. Actual history highlight strings are bounded by the existing
128-byte query limit. Generic ListModel behavior remains unchanged.

The new component oracle first failed against the accepted implementation because
the shortened suffix had been destroyed. It then passed with retention, including
2 → 3 → 1 → 0 → 3 identity reuse, visible text/positions/colors, wide and combining
Unicode, the eight-object shrink bound after a larger query, and parent teardown.
All 36 component cases pass in software, all 36 native history cases pass, and
five selected native component cases pass. The standalone model header passes
clang-tidy. Full native gb/GST captures are byte-exact to the accepted images.

Two cadences were declared before measuring. Evidence is in
`out-perf/dlls-history-match-retention-01` and
`out-perf/dlls-history-match-retention-cadence-01`. Each series has six alternating
pairs, 720 queries and 62 valid load boundaries; maximum one-minute load is
1.900 and 2.561. Input intervals average 309.396–310.212 ms and
229.079–230.164 ms respectively. All callbacks drain, every result has a positive
presentation timestamp, no result frames are dropped, and all owned children
exit. No other build or functional test runs alongside either timing series.

| Median statistic | 300 ms minimum: A → B (wins) | 220 ms minimum: A → B (wins) |
| --- | --- | --- |
| GUI CPU ms/query | 35.242 → 32.591 (6/6) | 32.763 → 29.982 (6/6) |
| Runtime CPU ms/query | 2.730 → 2.818 (1/6) | 2.731 → 2.813 (3/6) |
| Combined CPU ms/query | 37.928 → 35.494 (6/6) | 35.420 → 32.811 (6/6) |
| Combined instructions, million/query | 142.703 → 117.114 (6/6) | 139.547 → 113.582 (6/6) |
| Combined cycles, million/query | 80.562 → 71.601 (6/6) | 79.722 → 69.389 (6/6) |
| Mean latency ms | 106.179 → 104.967 (5/6) | 106.356 → 105.050 (6/6) |
| p95 latency ms | 116.853 → 115.731 (5/6) | 117.575 → 117.306 (4/6) |
| p99 latency ms | 122.876 → 119.517 (5/6) | 121.696 → 119.937 (4/6) |
| GUI final footprint, bytes | 253715836 → 253953428 (3/6) | 254166396 → 255427976 (2/6) |
| GUI setup footprint, bytes | 313918916 → 314090888 (2/6) | 313771460 → 313787856 (5/6) |
| GUI interrupt wakeups/query | 93.375 → 94.008 (0/6) | 70.517 → 71.058 (2/6) |

Combined CPU decreases 6.4% and 7.4%, and instructions 17.9% and 18.6%, with
12/12 paired wins for both. Whole-query mean latency improves in 11/12 pairs.
The extra final GUI footprint in these medians, about 0.24 MB and 1.26 MB, is an
accepted bounded-memory tradeoff. It is not attributed solely to retained object
sizes: allocator and timing effects were not isolated. The unchanged runtime's
CPU and active-query wakeups remain adverse or mixed; their causes are not
established. Observer wakeups are not production idle measurements.

The tails remain workload-dependent. At the shorter cadence gb p95 rises
114.548 → 116.771 ms (2/6) and gb p99 rises 116.800 → 119.894 (3/6), while GST
mean/p95/p99 improve in 6/6, 5/6 and 5/6. At the original cadence those GST win
counts are 6/6, 3/6 and 3/6. No universal p95/p99 improvement is claimed. Neither
cadence has a consistent latency loss under the zero-or-one-win rejection rule.
The repeated-query CPU target and whole-query mean pass in both cadences.

Startup plus scripted first-history setup is also retained. Combined setup CPU
is 890.778 → 895.605 ms (2/6), and 883.516 → 867.511 ms (5/6). Setup instructions
rise from 4.735 → 4.755 billion in the original cadence (0/6), and decrease from
4.753 → 4.737 billion in the shorter cadence (4/6). This is mixed setup evidence,
not a cold-open improvement. Every raw counter and individual query statistic
is retained in both hardware-results.json files.

ARM64 disassembly verifies the eight-entry bound and reuse of existing map
records before positional replacement; conversions and reference counting still
exist. There is no architecture-specific kernel change. The source hashes and
configured final GUI match frozen B exactly, SHA-256
`9bf92e972951d0b62aee68ea37199b7e9015353c4e4d1e42ad4abb1cad9904fa`, with no changes
since the measured build. A is the accepted `9661f8aa…` GUI, with identical
`1f1849d1…` runtime and helper on both sides. The final equality receipt is
`final-build-equivalence.json`. Pending runtime pacing and optical changes are
excluded. All F01–F16 remain open; these instrumented C++ comparisons do not
establish independent Zig parity or native 120 Hz acceptance.

## History burst and delayed-response controls, 2026-11-03

The accepted production stack remains GUI `9bf92e97…` and runtime `1f1849d1…`
from source HEAD `50f72f1a6`. The 60 ms history debounce is unchanged. Source
inspection confirms that each expired timer sends a new query; HistoryBrowser
tracks at most 128 outstanding requests and retires obsolete replies without
presenting them. Removing the timer without testing typing bursts could therefore
trade lower isolated-query latency for more obsolete runtime work.

`tools/gui_history_latency.py` now accepts `--burst-ms`, `--trace-history`,
`--delay-history QUERY=MS`, `--callback-drain-ms`, and
`--burst-main-stall-ms`. Bursts replace the selected query with individual composed
characters through the native text input client. A separate serial producer offers
characters at fixed deadlines, independently of the GUI thread. Each event records
its intended deadline, actual enqueue time, delivery time and resulting text.
Producer and delivery spans are checked separately against the existing 5%
tolerance. A failed rate check remains visible and excludes timing claims; it
does not erase a useful functional or queueing diagnostic. Last-character latency
is distinguished from the recorded whole-burst input timeline.

`HistoryQueryTrace` is an owned Unix-socket relay, with at most 4,096 recorded
queries/replies and 128 pending history requests per connection. Without delays it
preserves mixed-frame order and bytes. Selected replies can be delayed, allowing
newer results to arrive first. The census records request identities, query text,
frame hashes and receive/forward timestamps. It never enters a primary direct-
runtime performance series. Six socket tests verify byte/order preservation,
deliberate reordering, failure retirement, duplicate identities, truncated queries
and bounded capacity. Run them with
`python3 services/gui-cpp/tools/test_history_query_trace.py`.

The presentation observer also checks the latest positively presented ROI after
the drain interval, including unmatched images, instead of remembering only the
last matching template. Callback order cannot substitute for presentation order.
The new `--negative late-stale` control poisons the final-match metadata after a
real first match; it must fail even though a valid initial result was seen. This
is an observer negative control, not an actual production stale-result defect.

Final qualification is recorded in
`out-perf/dlls-history-query-scheduling-01/burst-qualification-final.json` and
`final-qualification-receipt.json`, with raw owned runs under
`/tmp/telar-perf-history-query-scheduling-*-02`. All ten runs use identical final
tool source hashes and unchanged production binaries. Thirty load boundaries
pass, maximum load1 1.951, and every owned GUI/runtime exits completely. The
Objective-C observer passes a warnings-enabled syntax check without diagnostics.

* Whole-query replacement passes two native trials.
* Four alternating gb/GST bursts at 15 ms per character send only the four final
  queries, after the two setup queries. The rate check fails on short-span jitter;
  these observations are functional evidence only.
* Four bursts at 45 ms also send only the four final queries and meet the rate
  tolerance.
* Four bursts at 90 ms send ten queries, including G, GS and g prefixes. Delaying
  those prefixes by 300–500 ms produces a peak of three pending requests. All six
  obsolete replies are forwarded 213–409 ms after the corresponding final reply;
  the correct final ROI survives the 750 ms observation interval. The input rate
  qualifies and every recorded reply is forwarded.
* A 200 ms main-thread stall is observed as up to 202.652 ms of main-queue delay.
  The producer continues offering events; compressed delivery correctly fails the
  rate check. Both native final results still match.
* Stale, missing, zero-timestamp, missing-callback and late-stale controls all
  fail with their expected errors. Their driver exit status is zero because the
  intended negative result is verified, not because the trial passed.

These are diagnostic controls, not an A/B speedup or a claim that the observer
has negligible overhead. Sustained outstanding-request pressure, large-history
bursts, changed scheduling policy and full cross-stack comparisons remain open.
No production scheduling candidate is adopted. The next algorithmic investigation
must account for obsolete query work and bounded reuse of repeated history work,
including invalidation after writes and external database changes. All F01–F16
and native120 acceptance remain open.

## In-place fuzzy ranking: rejected, 2026-11-03

`out-perf/dlls-history-inplace-rank-01` tests a private VFS-overlay candidate
against the accepted fused runtime source (`5d2167b7…`). It removes RankedEntry
storage and the fuzzy hash set. For distinct queries it sorts candidates by hash
and newest timestamp/id, keeps the newest hash winner before testing score
eligibility, then compacts valid scores in place. It partially sorts that vector
by score/timestamp/id to select the page. Non-distinct queries skip the full sort.
No retained command cache, database migration, production edit or timer change is
involved. A and B use freshly built direct HistoryStore probes with identical
flags/dependencies; production GUI/runtime binaries remain unchanged.

All 396 independent recency/score/page cases match A and B byte-exactly: 324 on
nine large/long/duplicate/shuffled/tied/reverse fixtures, plus 72 on the ordinary
and duplicate-heavy 10,000-entry timing fixtures. Scoped metadata and allocation
failure checks cover another 192 requests per variant on 13,312 entries, including
old snapshots, author/failed filters, pagination, deletion and subsequent import.
A, B and ASan/UBSan B produce the same canonical bytes and release all allocator-
observed live storage. System SQLite itself is not sanitizer-instrumented.

On that duplicate-heavy allocation oracle, calls fall from 30 to 5, allocated
bytes from 485,472 to 324,664, and incremental peak bytes from 485,120 to 324,456.
All 32 baseline and six candidate allocation-failure injection points recover
correctly. These counts describe that fixture and allocator, not all SQL or GUI
allocations. The first audit runner mixed JSON stdout with diagnostic stderr and
failed to parse a successful run; the final runner separates both streams and
repeats A/B/sanitized validation.

The predeclared initial timing screen uses five independent seven-pair series,
300 queries per execution and one warmup query, with no concurrent owned build,
test or profiler. Every measured response is checked exactly. All 150 load
boundaries pass, maximum load1 3.080. Results are component process CPU, including
the small equality/clock overhead, not GUI latency or cold-start measurements.

| Workload | A CPU ms/query | B CPU ms/query | B wins |
| --- | ---: | ---: | ---: |
| Ordinary gb, distinct | 1.241 | 1.375 | 0/7 |
| Ordinary GST, distinct | 1.278 | 1.402 | 0/7 |
| Ordinary gb, non-distinct | 0.960 | 0.979 | 0/7 |
| Duplicate-heavy gb, distinct | 0.938 | 1.331 | 0/7 |
| No match, distinct | 1.191 | 1.314 | 0/7 |

All five mean-response and p95 comparisons also lose 0/7. The candidate is
rejected despite lower allocation count and peak memory. ARM64 disassembly
confirms the conditional full sort, hash-group compaction, and selection over
32-byte candidates in place of the previous 16-byte ranked records. The separate
costs of those changes, including the non-distinct regression, are not causally
isolated; this is not attributed to code placement. No x86 or full-client
promotion is attempted after this failed component gate. Raw pairs are under
`/tmp/telar-perf-history-inplace-rank-*-pairs-01`; `decision.json` retains the
rejection and identities. The next selection experiment should isolate ordering
work from record size and duplicate handling. All F01–F16 remain open.

## Fuzzy recency order detection: superseded before adoption, 2026-11-04

`out-perf/dlls-history-order-detection-01` isolates the recency sort from the
rejected in-place ranking experiment. It retains the 32-byte candidate vector,
16-byte ranked records, hash set, scoring, duplicate policy and detail fetch. It
reverses an already reverse-sorted candidate range, leaves an already sorted
range alone, and otherwise uses the previous sort. No production source changes.
The independent model and exact encoded replies pass 576 evaluations across
large, long, duplicate, shuffled, tied, reversed and nearly ordered fixtures.
The 192 scoped/filter/metadata checks, allocation-failure recovery and zero-live-
allocation checks pass on ARM64 A/B, ASan/UBSan B and x86 baseline/v3 under Rosetta.
The existing History, HistoryQueue and HistoryCapacity tests also pass. System
SQLite is not sanitizer-instrumented; three existing test compiler warnings are
retained in the build log.

Allocations remain 30 calls, 485,472 bytes and 485,120 incremental peak bytes on
the ARM64 allocation fixture, with all 32 failure injections recovered. The x86
fixture has eight additional bytes in allocated and incremental peak totals.
Instrumented comparator counts explain what changes: ordinary and tied ranges
fall from 30,021 to 9,999 comparisons; reverse ranges from 20,006 to 10,000.
Shuffled input adds five comparisons and the heap control adds three. The
baseline libc++ sort already adapts to ordered input: this is fewer comparisons,
not evidence of an O(N log N) to O(N) change on these particular ranges.

Ten seven-pair component series use 300 queries per execution, or 32 for the
100,000-entry heap control. Component CPU wins are 6/7 for ordinary gb and GST,
7/7 for ordinary non-distinct, 6/7 for duplicates, 7/7 for no-match, 4/7 for
shuffled, 7/7 for reverse, 6/7 for tied, 3/7 for heap, and 2/7 for swapped first
timestamps. The latter adds 10,001 comparator calls before falling back to sort;
its median CPU increases from 0.957 to 0.967 ms. This avoidable failed reverse
scan motivates the guarded successor rather than native promotion of this one.

Full-runtime A is byte-exact to accepted `1f1849d1…`; private B is `d2843618…`.
Both explicitly link the accepted corrected local-listener object before the
runtime archive. An initial link omitted that object and was excluded before
measurement. A corrected link under a different executable basename changed the
ad-hoc signature identifier; rebuilding with the same `telar` basename restored
byte-exact A identity. These excluded binaries and comparison receipts remain in
the scratch prefix. GUI `9bf92e97…` and helper `87beebb0…` remain unchanged, and
overlays exclude the unadopted attachment-pacing edits from both runtime builds.

| Full-runtime workload | A CPU µs | B CPU µs | B CPU wins | Response mean / p95 / p99 wins |
| --- | ---: | ---: | ---: | --- |
| Warm monotonic query | 675.287 | 667.624 | 6/7 | 5 / 6 / 4 |
| Warm shuffled query | 903.871 | 906.657 | 3/7 | 4 / 3 / 3 |
| Warm small query | 51.139 | 50.764 | 6/7 | 6 / 6 / 5 |
| Warm empty query | 30.623 | 30.741 | 2/7 | 3 / 3 / 3 |
| First query in fresh runtime | 1,991.964 | 1,968.437 | 5/7 | 5 / — / — |
| Unchanged FTS / substring / empty query | 1,102.924 | 1,098.538 | 6/7 | 6 / 7 / 4 |
| Unchanged four-request import/delete cycle | 5,491.913 | 5,464.597 | 5/7 | 5 / 5 / 5 |

Warm ordinary series use 2,400 queries per execution, small/empty 4,800; the
first-query control uses eight fresh runtimes per variant per pair, and unchanged
paths use 600 queries or completed cycles. The first-query criterion is a
no-consistent-loss control, declared before running it, not a startup-improvement
claim. Memory results are mixed: warm monotonic end footprint rises from 7,553,456
to 7,668,120 bytes (3/7 wins), and first-query footprint rises from 6,121,880 to
6,125,970 bytes (4/7). Full counters, tails, cleanup and identities are retained
in `first-screen.json`, `runtime-screen.json`, `runtime-controls.json` and the
referenced raw runs. Do not attribute unchanged-path differences to this sort.

All 17 complete series and 706 host boundaries qualify, maximum load1 2.208.
No owned builds/tests overlap timing. The guard successor checks whether the
first adjacent pair already disproves reverse order, and adds middle/end-disorder
controls before measuring. Native scripts for the unguarded candidate were
prepared but never run. Neither version is adopted by this entry; F01–F16 and
independent Zig/native120 acceptance remain open.

## Guarded fuzzy recency detection: not adopted, 2026-11-04

`out-perf/dlls-history-order-guard-01` adds a necessary first-pair condition before
the reverse-order scan. If the first candidate is newer than the second, reverse
order is impossible and that scan is skipped. Empty/singleton ranges are guarded
before indexing. The original accepted source is still A; the unguarded candidate
was never promoted. The new B remains a private VFS overlay.

Independent model/exact A/B validation passes 324 large-fixture evaluations and
504 evaluations on fourteen smaller/boundary/control fixtures. These are
evaluations, not 828 unique requests: the empty fixture repeats snapshot zero.
Added cases include empty, singleton, two entries in both orders, equal dates,
and an adjacent timestamp swap at the beginning, middle and end of 10,000 rows.
All 192 scoped/filter/metadata cases and 32 allocation-failure injections pass
for A, B, sanitized B and both x86 targets; existing history/queue/capacity tests
also pass. Allocations and peaks match the unguarded experiment exactly.

Comparator census A→B: ordinary/tied 30,021→10,000, reverse 20,006→10,000,
shuffled 149,272→149,277, heap 1,551,857→1,551,861, beginning/end disorder
30,022→30,025, middle disorder 30,022→35,024. Thus the guard avoids the previously
identified failed full scan without removing all partial-scan overhead. ARM64
assembly has the size check at `0x100004f20`, first-pair test at `0x100004f60`,
reverse validation at `0x100004f94`, forward validation at `0x100004fcc`, and
fallback introsort at `0x100005010`. Reverse swaps use paired 128-bit loads/stores
for the 32-byte candidates; ranked records remain 16 bytes. x86 baseline/v3
also retain the guard, validation and fallback paths; their executable oracles
pass under Rosetta. These are codegen checks, not x86 performance evidence.

All twelve seven-pair component series complete and pass the initial CPU screen.
Ordinary gb/GST win 7/7, non-distinct 6/7, duplicates/no-match 7/7, shuffled 4/7,
reverse 7/7, tied/heap 6/7, beginning/middle disorder 4/7 and end disorder 6/7.
Ordinary distinct gb CPU falls from 1.2380 to 1.2198 ms; GST from 1.2805 to
1.2633 ms. Middle-disorder median CPU rises from 0.9594 to 0.9611 ms despite its
4/7 paired wins. All tails and exact replies are retained in `first-screen.json`.

Full-runtime rebuilt A is byte-exact `1f1849d1…`; private B is `15d66adc…`.
The corrected listener, accepted GUI/helper and exclusion of pending attachment
pacing are identical to the preceding experiment. The predeclared primary warm
monotonic CPU criterion requires at least 6/7 wins. It achieves only 5/7, so this
candidate is not adopted or promoted to native GUI measurement.

| Full-runtime workload | A CPU µs | B CPU µs | B CPU wins | Response mean / p95 / p99 wins |
| --- | ---: | ---: | ---: | --- |
| Warm monotonic query | 675.522 | 670.978 | 5/7 | 4 / 5 / 4 |
| Warm shuffled query | 903.895 | 903.167 | 3/7 | 2 / 4 / 4 |
| Warm small query | 51.077 | 50.756 | 5/7 | 5 / 3 / 5 |
| Warm empty query | 30.806 | 30.927 | 3/7 | 2 / 2 / 1 |
| First query in fresh runtime | 1,986.031 | 1,967.062 | 5/7 | 5 / — / — |
| Unchanged FTS / substring / empty query | 1,103.470 | 1,104.845 | 5/7 | 5 / 3 / 5 |
| Unchanged four-request import/delete cycle | 5,501.467 | 5,480.963 | 5/7 | 4 / 2 / 5 |

Sample counts match the preceding experiment. Empty-control p99 rises from
49.001 to 51.795 µs with only 1/7 wins; its cause is not established. First-query
end footprint rises from 6,130,075 to 6,136,213 bytes (3/7 wins), shuffled from
7,700,888 to 7,733,680 bytes (4/7), while monotonic end footprint falls from
7,569,840 to 7,455,152 bytes (5/7). Full counters remain in the receipts; mixed
medians/win counts are not converted into broad improvement claims.

All 19 complete series and 766 host boundaries qualify, maximum load1 2.594.
No series is rerun to seek a different decision, and no owned build/test overlaps
timing. `decision.json` records the failed promotion criterion and unchanged
production source `5d2167b7…`. Native scripts were prepared but never run. The
next isolated experiment targets per-key allocation/rehash work in fuzzy
deduplication, retaining the accepted ordering algorithm. All F01–F16 remain open.

## Flat fuzzy deduplication table: first version rejected, 2026-11-04

`out-perf/dlls-history-flat-dedup-01` replaces only the fuzzy query's node-based
hash set with a private contiguous table of the same 64-bit command hashes.
Original recency sorting and compact ranked records remain unchanged. The table
starts with sixteen zeroed slots on its first nonzero insertion, grows at half
occupancy, and uses masked linear probing. Hash zero has a separate presence bit.
It performs the same newest-hash-winner check before score eligibility. The
10,000-candidate bound limits the table to 32,768 slots; growth temporarily holds
old and new storage. No persistent cache, database/index change or GUI edit.

The independent model and byte-exact A/B oracle pass 324 large and 504 smaller
evaluations, including empty/singleton/two-entry boundaries. Duplicate-heavy
scoped metadata validation covers 192 requests on 13,312 entries for A/B,
sanitized B and both x86 targets. All original 32 allocation-failure injections
and eleven candidate injections recover, with zero observed live storage after
teardown. A separate exact-output allocation fixture uses 12,800 unique imported
commands plus 512 agent records. Its baseline samples the first 64 allocation
ordinals plus four large sizes; candidate validation covers all eighteen
allocation ordinals plus seven large sizes. All recover; A/B/sanitized B output
agrees. System SQLite remains outside sanitizer instrumentation.

| Allocation fixture | Calls A → B | Allocated bytes A → B | Incremental peak bytes A → B |
| --- | ---: | ---: | ---: |
| Duplicate-heavy | 30 → 9 | 485,472 → 485,560 | 485,120 → 484,968 |
| Mostly unique | 9,639 → 18 | 920,744 → 1,008,824 | 818,160 → 873,280 |

Fewer allocations do not imply fewer allocated bytes. On the mostly unique
fixture, the candidate trades 55,120 additional peak bytes for fewer allocator
operations. The separate table oracle compares 100,014 insertions/reinsertions
with `std::set`, including zero, maximum hash, sequential/random values, long
collision chains, wraparound and duplicates. Every one of its twelve growth
allocation failures leaves earlier entries intact and permits retry. Release and
ASan/UBSan both pass with zero allocator-observed live bytes at teardown.

Eighteen seven-pair component series use 300 queries per execution on ordinary
and small cases, or 32 on the 100,000-entry heap/long cases. The old-snapshot
control queries the first 100 ids in the 10,000-entry database. Every measured
reply is exact, all 540 host boundaries qualify, maximum load1 1.966, and no
owned build/test overlaps timing. Results are component process CPU, not native
presentation latency. Source, binary and fixture identities accompany raw runs.

| Workload | A CPU ms | B CPU ms | B CPU wins |
| --- | ---: | ---: | ---: |
| Ordinary gb, distinct | 1.237773 | 1.076853 | 7/7 |
| Ordinary GST, distinct | 1.275467 | 1.115313 | 7/7 |
| Ordinary gb, non-distinct | 0.955337 | 0.978817 | 0/7 |
| Duplicate-heavy, distinct | 0.939147 | 0.942593 | 2/7 |
| No match, distinct | 1.187520 | 1.037243 | 7/7 |
| Shuffled, non-distinct | 1.403520 | 1.420757 | 1/7 |
| Reverse, non-distinct | 0.944567 | 0.969763 | 0/7 |
| Tied, non-distinct | 0.967133 | 0.990507 | 0/7 |
| Heap, non-distinct | 12.533844 | 12.557375 | 3/7 |
| Beginning disorder, non-distinct | 0.958033 | 0.986210 | 0/7 |
| Middle disorder, non-distinct | 0.956320 | 0.978397 | 0/7 |
| End disorder, non-distinct | 0.961850 | 0.982767 | 1/7 |
| Singleton, distinct | 0.008810 | 0.008767 | 5/7 |
| Empty, distinct | 0.013593 | 0.013317 | 4/7 |
| Shuffled, distinct | 1.708873 | 1.539947 | 7/7 |
| Heap, distinct | 13.187219 | 13.055563 | 5/7 |
| Long commands, distinct | 189.410531 | 188.943625 | 7/7 |
| Old snapshot, distinct | 0.072993 | 0.069070 | 7/7 |

Ordinary gb/GST/no-match/shuffled distinct mean and p95 also win 7/7, but the
ordinary non-distinct mean/p95 lose 0/7. Heap-distinct p95 is adverse, with 2/7
wins and median 13.638→13.920 ms. Full mean/p95 counts remain in
`first-screen.json` and `/tmp/telar-perf-history-flat-dedup-*-pairs-01`.

The consistent non-distinct CPU regressions reject the candidate despite its
approximately 13% distinct-query gain. ARM64 and x86 assembly show insertion as
a separate function, so an inlined insertion body is not the explanation. ARM64
table probing at `0x1000061f0` uses a mask, indexed load and collision loop;
the original per-row distinct checks remain in the shared query path. No
identical-code placement exemption is established, and the regression's cause
is not isolated. `decision.json` records rejection; no full-runtime/native
promotion or production edit occurs. A separate successor specializes the two
query paths to remove those invariant per-row checks and unused table state;
it must pass fresh oracles and paired controls. All F01–F16 remain open.

The separate `out-perf/dlls-history-flat-dedup-02` successor dispatches distinct
and non-distinct fuzzy queries once, using two template instantiations and
`if constexpr` inside the loops. It passes 324 large plus 576 smaller/control
oracle evaluations (including repeated snapshot inputs), both allocation
fixtures, release/sanitized table collision and recovery checks, and x86
baseline/v3 canonical validation. Allocation counts/bytes/peaks are identical
to flat-dedup-01. The old-snapshot and long-command timing controls are now also
included explicitly in the smaller-oracle runner.

ARM64 disassembly confirms that the two per-row loads of `request.distinct`
disappear. The accepted query body contains 796 instructions; the new true/false
bodies contain 799 and 780 respectively, including exception paths. The false
body still has a cleanup reference to the table destructor, so this is not a
claim that every trace of unused table state disappears. The resulting total
code is larger. No timing conclusion follows from those static counts alone.

All eighteen fresh seven-pair series complete, with 540 valid host boundaries
and maximum load1 3.153. The repeated non-distinct losses reject this version
too: ordinary CPU 0.969907→0.992770 ms (1/7), shuffled 1.392900→1.422697 (0/7),
reverse 0.949847→0.965890 (1/7), tied 0.967037→0.987213 (0/7), beginning disorder
0.956837→0.982943 (1/7), middle 0.956907→0.982350 (0/7), end
0.958547→0.984637 (0/7). Heap non-distinct is mixed at 3/7. Duplicate-heavy
distinct is adverse at 2/7, singleton 2/7 and empty 3/7. Ordinary gb/GST,
no-match, shuffled-distinct, long and old-snapshot distinct CPU win 7/7; heap
distinct wins 6/7. Full mean/p95 values, sources and raw pairs are retained in
`first-screen.json` and `/tmp/telar-perf-history-flat-dedup-specialized-*-pairs-01`.
No series is rerun for a different outcome. No production/runtime/native
promotion occurs; the non-distinct regression's cause remains unisolated.

Inspecting the accepted recency sort reveals an independent lead: libc++'s
introsort instantiation receives a function pointer and invokes it indirectly
(for example ARM64 `blr` at `0x10000652c`, `0x100006540` and `0x100006568`). A
new isolated candidate passes a stateless typed comparator instead, preserving
the accepted containers and ordering algorithm. It does not inherit either
flat-table variant, their memory tradeoff, or the rejected order detector. Any
gain from removing those calls still requires fresh paired evidence.

## Typed recency comparator: rejected, 2026-11-04

`out-perf/dlls-history-typed-comparator-01` changes the accepted static comparator
function into a stateless constexpr lambda. Its comparison expression is
identical; containers, recency selection, sorting policy, scoring, deduplication
and memory ownership remain accepted code. Neither flat-table candidate nor the
order detector is included. Independent reference/exact A/B checks pass 900
evaluations, with repeated empty/old-snapshot inputs counted as evaluations.
The 192 scoped metadata cases, all 32 allocation failures, zero-live-storage
checks, sanitized B and x86 baseline/v3 canonical validation pass. ARM64
allocation calls/bytes/incremental peak remain 30 / 485,472 / 485,120.

The recency comparator census is identical A/B: 30,021 calls on ordinary/tied,
149,272 on shuffled, 20,006 on reverse, 1,551,857 on heap, and 30,022 on each
single adjacent-disorder fixture. The change removes call overhead, not
comparisons or an asymptotic sorting bound. ARM64 introsort has 47 static indirect
call sites in A and none in B. x86-v3 also has none. The raw x86 baseline listing
appears to contain one at `0x10000b39f`; Mach-O marks the surrounding 24 bytes at
`0x10000b388` as data-in-code, kind 4. It is a disassembly false positive in a
jump table, not an executable comparator call. Both raw and corrected evidence
are retained in `cross-assembly-census.json` and `cross-disassembly-data.json`.

All eighteen seven-pair component series complete, with 540 valid host boundaries,
maximum load1 3.166 and no concurrent owned build/test. Counts remain 300 queries
per execution, or 32 for the 100,000-entry heap/long fixtures. Every response is
checked exactly; there is no native/full-runtime promotion.

| Workload | A CPU ms | B CPU ms | B CPU / mean / p95 wins |
| --- | ---: | ---: | --- |
| Ordinary gb, distinct | 1.244313 | 1.235330 | 5 / 5 / 5 |
| Ordinary GST, distinct | 1.276500 | 1.273537 | 6 / 6 / 6 |
| Ordinary gb, non-distinct | 0.958043 | 0.958520 | 4 / 4 / 5 |
| Duplicate-heavy, distinct | 0.936207 | 0.939337 | 3 / 3 / 2 |
| No match, distinct | 1.188330 | 1.185393 | 5 / 5 / 3 |
| Shuffled, non-distinct | 1.403960 | 1.310807 | 7 / 7 / 7 |
| Reverse, non-distinct | 0.942903 | 0.946063 | 2 / 2 / 2 |
| Tied, non-distinct | 0.964200 | 0.963473 | 3 / 3 / 1 |
| Heap, non-distinct | 12.463656 | 12.471219 | 4 / 4 / 3 |
| Beginning disorder, non-distinct | 0.960917 | 0.954757 | 6 / 6 / 6 |
| Middle disorder, non-distinct | 0.956177 | 0.958530 | 1 / 1 / 3 |
| End disorder, non-distinct | 0.954020 | 0.956850 | 5 / 5 / 5 |
| Singleton, distinct | 0.008750 | 0.008803 | 3 / 3 / 4 |
| Empty, distinct | 0.013377 | 0.013230 | 6 / 6 / 5 |
| Shuffled, distinct | 1.715497 | 1.609300 | 7 / 7 / 7 |
| Heap, distinct | 13.403438 | 13.052719 | 7 / 7 / 5 |
| Long commands, distinct | 188.963469 | 189.512656 | 1 / 1 / 2 |
| Old snapshot, distinct | 0.073337 | 0.073513 | 1 / 2 / 2 |

Shuffled histories improve, but ordinary primary targets miss 6/7 and three CPU
controls lose consistently. Even the small regressions remain disqualifying;
their cause is not isolated and no placement exemption is established.
`decision.json` records rejection. The next private experiment tests natural-run
merging: fewer comparisons on partially ordered ranges in exchange for bounded
temporary storage and extra copying on random ranges. Its primary shuffled
target and all controls are declared before measurement. Production remains
unchanged, and F01–F16/independent Zig/native120 acceptance remain open.

## Natural-run merging: withheld after heap-path regression, 2026-11-04

`out-perf/dlls-history-natural-merge-01` detects monotonic candidate runs,
reverses strictly backward runs and merges adjacent runs with a temporary vector.
An already ordered range returns after one scan without auxiliary allocation.
The experiment also uses a stateless typed comparator; original hash-set
deduplication, score policy, top-10,000 selection and compact ranking remain.
It reduces comparisons but adds copying and up to 320,000 temporary heap bytes
plus 10,000 bytes of run ends on the stack. ARM64 emits a 10,144-byte frame
for the helper; its merge loop inlines comparisons and copies 32-byte records
with paired 128-bit loads/stores. Extra storage is released before deduplication.

Independent reference and byte-exact A/B checks pass 900 evaluations, including
repeated empty/old inputs. The helper passes 46,490 ordering cases in each of
Release and ASan/UBSan, including all permutations through length eight, large
random/tied/alternating inputs, zero allocations on a second ordered call and
scratch-allocation recovery. The 192 scoped metadata cases, allocation failures,
zero-live-storage checks and x86 baseline/v3 Rosetta checks pass. System SQLite
is not sanitizer-instrumented. History, HistoryQueue and HistoryCapacity pass
on A/B with new public-API ordering/page tests for eight shapes. Three existing
missing-designated-initializer warnings remain; no lint-green claim is made.

The 13,312-entry allocator fixture changes from 30 to 31 calls, 485,472 to
805,472 allocated bytes and 485,120 to 800,064 incremental peak bytes. All 32 A
and 33 B injected failures recover. The ARM64 comparator census changes from
30,021 to 9,999 on ordinary/tied, 20,006 to 9,999 on reverse, 149,272 to 126,468
on shuffled, and 1,551,857 to 1,512,557 on the monotonic heap control. These
instrumented counts are separate from timing.

All 26 complete seven-pair series have 976 qualified host boundaries;
maximum observed load1 is 3.300293. No owned build/test overlaps timing.
Each component execution has 300 queries, or 32 on 100,000-entry heap/long
fixtures. Every response is compared exactly.

| Component | A CPU ms | B CPU ms | CPU / mean / p95 wins |
| --- | ---: | ---: | --- |
| ordinary-gb | 1.242000 | 1.220743 | 6 / 6 / 6 |
| ordinary-GST | 1.279297 | 1.261470 | 6 / 6 / 7 |
| ordinary-all | 0.956323 | 0.940353 | 5 / 5 / 5 |
| duplicates | 0.934847 | 0.921263 | 7 / 7 / 6 |
| no-match | 1.188047 | 1.170667 | 7 / 7 / 7 |
| shuffled | 1.393500 | 1.068103 | 7 / 7 / 7 |
| reverse | 0.945403 | 0.932990 | 7 / 7 / 3 |
| tied | 0.967617 | 0.946903 | 7 / 7 / 7 |
| heap | 12.439375 | 12.215938 | 7 / 7 / 5 |
| late-disorder | 0.957887 | 0.951627 | 6 / 6 / 5 |
| middle-disorder | 0.956440 | 0.949003 | 7 / 7 / 6 |
| end-disorder | 0.960537 | 0.945207 | 6 / 6 / 5 |
| small-distinct | 0.008873 | 0.008917 | 3 / 3 / 3 |
| empty-distinct | 0.013237 | 0.013370 | 2 / 2 / 2 |
| shuffled-distinct | 1.700290 | 1.355523 | 7 / 7 / 7 |
| heap-distinct | 13.198469 | 13.019844 | 7 / 7 / 2 |
| long-distinct | 189.110250 | 188.976937 | 3 / 3 / 3 |
| old-distinct | 0.075530 | 0.072787 | 5 / 5 / 4 |

The complete runtime uses accepted corrected-listener linking. Rebuilt A is
byte-exact to accepted `1f1849d1881fe60af13d46531c6f722fb5105f32fc8beaaadf7276ad50f55031`;
B is `96d71930113cac78eb716eb20b1193feb1255478e4e0ab484d6fcc848ee86809`.
An actual-source rebuild also reproduces B object/executable exactly. GUI/helper
and pending attachment pacing are unchanged. The source was staged locally as
an experiment, not adopted. Warm runtime series use 2,400 requests/execution,
or 4,800 for small/empty, after 60 reference cases. All owned runtimes exit.

| Runtime | A CPU µs | B CPU µs | CPU / mean / p95 / p99 wins | A→B mean µs | A→B p95 µs |
| --- | ---: | ---: | --- | --- | --- |
| shuffled | 907.0908 | 737.2679 | 7 / 7 / 7 / 7 | 914.0645→745.1756 | 1891.6291→1544.8809 |
| monotonic | 677.7181 | 665.4579 | 7 / 5 / 7 / 4 | 683.7573→670.7364 | 1415.8610→1393.4622 |
| larger | 1318.1528 | 1244.2507 | 7 / 7 / 0 / 3 | 1323.2472→1250.3875 | 2720.5125→2731.3750 |
| small | 50.9427 | 50.7597 | 6 / 6 / 4 / 3 | 55.0112→54.7556 | 90.2080→90.3372 |
| empty | 30.7963 | 30.8277 | 3 / 3 / 4 / 4 | 34.3324→34.4745 | 40.2521→40.2941 |

| Runtime memory | A→B end footprint bytes | Wins | A→B lifetime peak bytes | Wins |
| --- | --- | ---: | --- | ---: |
| shuffled | 7881136→8339888 | 0 | 11043248→11485616 | 0 |
| monotonic | 7668144→7569840 | 5 | 11944368→11633072 | 4 |
| larger | 8176048→8241584 | 1 | 12599728→12648880 | 1 |
| small | 6111640→5931392 | 6 | 6242712→6062464 | 6 |
| empty | 5587328→5603712 | 2 | 5702016→5718400 | 2 |

Memory increases are permitted tradeoffs, not an automatic rejection. Peak is
process-lifetime peak, not the query interval peak. Controls preserve their
mixed results: first query uses 112 fresh runtimes; FTS has 600 requests per
execution; write has 600 completed import/query/delete/query cycles per execution.

| Control | A CPU ms | B CPU ms | CPU / mean / p95 / p99 wins |
| --- | ---: | ---: | --- |
| first-query | 1.975307 | 1.977370 | 3 / 3 / — / — |
| fts | 1.106273 | 1.101404 | 5 / 5 / 2 / 6 |
| write | 5.498582 | 5.493294 | 4 / 3 / 4 / 5 |

Despite passing the declared aggregate CPU/mean gates, larger-history p95 loses
all seven pairs. Post-hoc decomposition of its existing samples (40 samples per
case per run; no new timing) finds 18 of 20 full-snapshot case means at 0–1/7
wins. These 15,000-entry shuffled snapshots exercise top-10,000 heap selection;
the 7,500-entry snapshots do not, and improve enough to conceal the loss in
the aggregate mean. For example, non-distinct gb/full snapshot rises from
2.352767 to 2.396464 ms, 0/7, while gb/half snapshot falls from 1.205538 to
0.958649 ms, 7/7. The regression concentrates in heap-selected cases; copying,
cache, allocator state and code generation have not been individually isolated.

`decision.json` records no adoption and no native promotion. A fresh successor
keeps accepted sorting/comparator behavior after heap selection and uses natural
merging only before that point. It adds the actual shuffled 15,000-entry shape
to component controls and prospectively checks full-snapshot means and runtime
tails. It must pass its own oracles and paired measurements. This is not a
reclassification of the adverse first experiment. F01–F16, independent Zig
comparison and native120 acceptance remain open.

## Conditional natural merging: singleton control rejects, 2026-11-04

`out-perf/dlls-history-natural-merge-02` restores the accepted static comparator
and `std::sort` whenever top-k selection has used a heap. Natural-run merging
applies only before heap selection, with a local typed comparator wrapper.
The new 15,000-entry shuffled control is a SQLite backup of the previous owned
runtime fixture after verified cleanup. The accepted A source and binaries
remain byte-exact. No first-variant timings are reused as acceptance evidence.

Fresh independent reference/exact checks pass 936 evaluations (324 large and
612 expanded; repeated small snapshots remain evaluations). Release and
ASan/UBSan helper oracles each pass 46,490 cases. Scoped metadata, allocation
failure and zero-live-storage checks pass on both 13,312- and 6,912-entry
fixtures, including x86 baseline/v3 under Rosetta. On the heap fixture A/B
both use 30 allocations, 485,472 bytes and 485,120 incremental peak bytes;
all 32 injected failures recover. On the nonheap fixture B uses 31 calls,
706,656 bytes and 701,248 peak bytes versus A 30 / 485,472 / 485,120;
all 34 B failures recover. x86 metadata has the expected extra eight bytes.
History, HistoryQueue and HistoryCapacity, with the new ordering/page cases,
pass on both A and B. Dependency archives/system SQLite remain uninstrumented.

Comparator census is unchanged on both heap fixtures: 1,551,857 calls for
100,000 monotonic entries and 245,570 for 15,000 shuffled entries. Nonheap
counts retain the first variant reductions. ARM64 has a 175-instruction merge
helper with inline comparisons and paired 128-bit record copies. Its 10,144-
byte stack frame is established before the internal less-than-two guard.
The heap introsort retains 690 instructions and 47 indirect comparator call
sites. This does not establish identical whole-query code or a placement
exemption. The full runtime builds as
`8a7b00e9cd99809734b24a37500bd9adc170b6f931520309178934164b4d30a0`,
but is not timed after the component rejection.

The first 16 complete seven-pair component series have 480 qualified host
boundaries, maximum load1 1.967773, and exact responses. Each run has
300 queries for at most 15,000 entries, or 32 for the 100,000-entry heap case.

| Component | A CPU ms | B CPU ms | CPU / mean / p95 wins |
| --- | ---: | ---: | --- |
| shuffled-heap-all | 2.183163 | 2.177543 | 6 / 5 / 4 |
| shuffled-heap-distinct | 2.536950 | 2.527003 | 5 / 4 / 4 |
| shuffled-heap-GST | 2.563227 | 2.566200 | 3 / 3 / 2 |
| ordinary-gb | 1.245100 | 1.217003 | 7 / 7 / 6 |
| ordinary-GST | 1.281570 | 1.260447 | 7 / 7 / 7 |
| ordinary-all | 0.962497 | 0.939857 | 7 / 7 / 6 |
| duplicates | 0.939163 | 0.920557 | 6 / 6 / 6 |
| no-match | 1.191620 | 1.171460 | 7 / 7 / 7 |
| shuffled | 1.393177 | 1.066403 | 7 / 7 / 7 |
| reverse | 0.945740 | 0.930123 | 7 / 7 / 7 |
| tied | 0.964463 | 0.948050 | 5 / 5 / 5 |
| heap | 12.427750 | 12.401781 | 5 / 5 / 3 |
| late-disorder | 0.959033 | 0.946837 | 7 / 7 / 7 |
| middle-disorder | 0.962073 | 0.953627 | 6 / 6 / 6 |
| end-disorder | 0.959113 | 0.946773 | 7 / 7 / 5 |
| small-distinct | 0.008773 | 0.008900 | 1 / 1 / 1 |

Singleton CPU rises by about 127 ns and wins only 1/7; mean and p95 also win
1/7. The predeclared early-stop rule rejects this candidate after that complete
series. Empty, shuffled-distinct, heap-distinct, long and old controls are
unmeasured, not passes. Full-runtime and native promotion do not run. The prior
heap regression is therefore not declared resolved by these component results.

The successor adds a caller-side zero/one-candidate guard to avoid entering the
merge helper at all. Assembly establishes that this avoids work; it does not
establish how much of the preceding timing loss it caused. New measurements
put singleton and empty controls first and retain every other control and the
prospective larger-runtime per-case/tail criteria. Accepted production code
remains unchanged; F01–F16 and independent Zig/native120 gates remain open.

## Trivial-range guard: shuffled heap control rejects, 2026-11-04

`out-perf/dlls-history-natural-merge-03` adds a caller-side candidate-count guard
before natural merging. ARM64 emits a range-length comparison before the call
at `0x100004f68`; zero/one candidates skip the helper and its stack frame.
The helper source is byte-identical to variant02, whose 46,490-case Release
and sanitized helper oracle is explicitly reused in `helper-validation-reuse.json`.
Fresh independent query-level reference/exact checks pass 936 evaluations.
Fresh 13,312- and 6,912-entry allocation/scoped/sanitized checks pass, with
the same calls/bytes/peaks and recovered failures as variant02. Fresh x86
baseline/v3 checks and History/HistoryQueue/HistoryCapacity tests also pass.
Runtime B builds as
`11fcd220b6effdb73a19659d4296f2ace5a2b74f8053e485a794a58d454d0578`,
but is not timed after rejection. Accepted A remains byte-exact.

Seven complete alternating-pair component series have 210 qualified host
boundaries, maximum load1 2.717773, with 300 queries/execution and
exact responses. No owned build/test overlaps timing.

| Component | A CPU ms | B CPU ms | CPU / mean / p95 wins |
| --- | ---: | ---: | --- |
| small-distinct | 0.008863 | 0.008850 | 5 / 5 / 4 |
| empty-distinct | 0.013413 | 0.013307 | 4 / 4 / 3 |
| shuffled | 1.389083 | 1.070950 | 7 / 7 / 7 |
| shuffled-distinct | 1.702927 | 1.352600 | 7 / 7 / 7 |
| shuffled-heap-all | 2.179997 | 2.172530 | 5 / 5 / 4 |
| shuffled-heap-distinct | 2.525577 | 2.534550 | 4 / 4 / 4 |
| shuffled-heap-GST | 2.565447 | 2.567157 | 1 / 1 / 1 |

Singleton no longer loses consistently and both nonheap shuffled targets win
7/7, but shuffled-heap GST CPU, mean and p95 each win only 1/7. Median CPU
increases by just 1,710 ns (about 0.067%); the small magnitude is retained
alongside the adverse win count. The declared rule rejects the variant. The
remaining fourteen component series, full runtime and native checks are
unmeasured. No repeat is used to fish for a passing result, and identical
whole-query normalized code has not been established for a placement exemption.

The next algorithmic candidate consumes the already valid top-k heap with
`std::sort_heap` and a local typed comparator, instead of introsorting the
heap array. It retains natural runs for nonheap inputs and the trivial guard.
This seeks less repeated ordering work on the failing path; comparison counts,
record movement, exact results and paired performance must be checked afresh.
Production acceptance and all F01–F16/independent Zig/native120 gates remain open.

## Existing-heap extraction: large distinct control rejects, 2026-11-04

`out-perf/dlls-history-natural-merge-04` consumes an already constructed heap
with `std::sort_heap` and a local typed comparator. It retains natural merging
for nonheap ranges and skips that helper for zero/one candidates. Original
heap selection, hashing, scoring, compact ranking and response policy remain.
The independent query oracle passes 936 evaluations; scoped metadata, all
allocation failures and ASan/UBSan pass at 13,312 and 6,912 entries. The large
heap query keeps A allocation calls/bytes/peak; nonheap scratch storage remains
bounded as in variant02. x86 baseline/v3 checks pass. The identical natural-
merge helper reuses its recorded direct oracle; the new heap extraction is
exercised by fresh query-level oracles, including ties, reverse, shuffled,
old snapshots, scopes and the top-10,000 boundary. History, HistoryQueue and
HistoryCapacity pass with committed ordering/page tests `9e0a3ff2c`.

Instrumented comparator counts fall from 245,570 to 206,466 on the shuffled
15,000-entry heap and from 1,551,857 to 1,513,930 on 100,000 monotonic entries.
ARM64 inlines heap extraction in the 881-instruction query function without
indirect comparator calls there. The natural helper remains 175 instructions.
Counts and assembly describe work, not a replacement for end-to-end timings.

Nineteen complete seven-pair component series have 570 valid host boundaries,
maximum load1 2.020996. Runs use 300 queries through 15,000 entries and
32 for 100,000-entry heap controls. Responses are exact and no owned builds
or tests overlap timing.

| Component | A CPU ms | B CPU ms | CPU / mean / p95 wins |
| --- | ---: | ---: | --- |
| shuffled-heap-GST | 2.570957 | 2.500863 | 7 / 7 / 7 |
| shuffled-heap-all | 2.181317 | 2.111013 | 7 / 7 / 7 |
| shuffled-heap-distinct | 2.525037 | 2.447290 | 7 / 7 / 7 |
| shuffled | 1.395810 | 1.070827 | 7 / 7 / 7 |
| shuffled-distinct | 1.704113 | 1.359727 | 7 / 7 / 7 |
| small-distinct | 0.008797 | 0.008850 | 3 / 3 / 4 |
| empty-distinct | 0.013390 | 0.013320 | 4 / 4 / 3 |
| ordinary-gb | 1.236727 | 1.223210 | 7 / 6 / 5 |
| ordinary-GST | 1.280110 | 1.262827 | 6 / 6 / 3 |
| ordinary-all | 0.960980 | 0.941770 | 7 / 7 / 5 |
| duplicates | 0.940140 | 0.921343 | 6 / 6 / 6 |
| no-match | 1.189570 | 1.171720 | 6 / 5 / 4 |
| reverse | 0.942743 | 0.931407 | 6 / 6 / 5 |
| tied | 0.964870 | 0.948377 | 7 / 7 / 6 |
| heap | 12.411750 | 12.389500 | 6 / 6 / 5 |
| late-disorder | 0.959527 | 0.948743 | 6 / 6 / 6 |
| middle-disorder | 0.960607 | 0.949867 | 7 / 7 / 7 |
| end-disorder | 0.961990 | 0.946803 | 7 / 6 / 5 |
| heap-distinct | 13.168938 | 13.333031 | 1 / 1 / 1 |

The 100,000-entry distinct heap control rises from 13.168938 to 13.333031 ms
CPU, winning only 1/7; mean and p95 also win 1/7. The predeclared rule rejects
the candidate. Long/old are unmeasured, and no full-runtime build/timing or
native promotion is performed. Other completed controls do not lose
consistently, but their gains do not excuse this regression.

A separate diagnostic inserts seven process-CPU boundaries per query: setup,
scan/selection/score/hash, recency ordering, dedup/rank collection, partial
page ranking, detail/encoding and destruction. It runs four seven-pair series
of 64 queries/execution, with 120 valid host boundaries and maximum load1
1.490234. It preserves exact replies. Clocks change code generation and
cache state; these timings cannot overturn the uninstrumented rejection or
independently establish its cause.

| Diagnostic case / phase | A CPU µs | B CPU µs | Wins |
| --- | ---: | ---: | ---: |
| heap-distinct / setup | 5.0625 | 4.8906 | 4 |
| heap-distinct / scan_select_score_hash | 12178.4844 | 12223.8281 | 4 |
| heap-distinct / recency_order | 417.4688 | 411.6406 | 6 |
| heap-distinct / dedup_collect | 374.8750 | 368.6719 | 6 |
| heap-distinct / rank_page | 4.2344 | 4.3281 | 2 |
| heap-distinct / detail_encode | 107.3125 | 107.7344 | 4 |
| heap-distinct / destroy | 167.2656 | 167.3906 | 3 |
| heap-all / setup | 5.0625 | 4.7656 | 6 |
| heap-all / scan_select_score_hash | 12038.3750 | 12002.7969 | 5 |
| heap-all / recency_order | 419.7031 | 405.9844 | 7 |
| heap-all / dedup_collect | 10.6719 | 10.3594 | 6 |
| heap-all / rank_page | 3.9062 | 3.8906 | 3 |
| heap-all / detail_encode | 109.6250 | 105.9219 | 5 |
| heap-all / destroy | 2.4375 | 2.4531 | 2 |
| shuffled-heap-distinct / setup | 3.4844 | 3.7344 | 4 |
| shuffled-heap-distinct / scan_select_score_hash | 1638.1875 | 1653.1406 | 3 |
| shuffled-heap-distinct / recency_order | 486.8906 | 427.5781 | 7 |
| shuffled-heap-distinct / dedup_collect | 252.5469 | 237.6719 | 6 |
| shuffled-heap-distinct / rank_page | 2.5469 | 2.6094 | 2 |
| shuffled-heap-distinct / detail_encode | 76.2812 | 75.8281 | 2 |
| shuffled-heap-distinct / destroy | 95.6094 | 96.8594 | 2 |
| ordinary-distinct / setup | 3.1719 | 3.2344 | 3 |
| ordinary-distinct / scan_select_score_hash | 868.5000 | 872.3125 | 2 |
| ordinary-distinct / recency_order | 31.4062 | 13.9531 | 7 |
| ordinary-distinct / dedup_collect | 202.4219 | 201.8438 | 4 |
| ordinary-distinct / rank_page | 2.2812 | 2.3750 | 3 |
| ordinary-distinct / detail_encode | 70.4531 | 70.1562 | 3 |
| ordinary-distinct / destroy | 84.6875 | 84.5469 | 5 |

The diagnostic does not clearly reproduce the rejected total regression:
large distinct scan/selection is mixed at 4/7, while final ordering and dedup
each win 6/7. Cause remains unisolated. It does locate roughly 92% of large
distinct CPU in scan/selection/score/hash, where the accepted code performs
`pop_heap`, overwrites the last candidate, then `push_heap` for every retained
replacement. The next isolated experiment starts from accepted A and tests
one root replacement/heap repair, without inheriting natural merging or heap
extraction. This targets earlier repeated selection work, and requires new
heap-property, top-k, failure and paired checks. Accepted production code and
F01–F16/independent Zig/native120 status remain unchanged.

## Single heap-root replacement: rejected, 2026-11-04

`out-perf/dlls-history-heap-replace-01` starts from accepted A, without natural
merging or heap extraction. Each eligible replacement moves older children up
to a leaf, then inserts the new record with one upward repair. It avoids
preserving the discarded root at the tail and repairing an intermediate heap
before reinsertion. Final recency sorting, hashes, scoring, compact ranking
and detail fetch remain accepted code. No storage or allocation is added.

Fresh direct Release and ASan/UBSan oracles each pass 139,083 single replacement
cases: permutations through length eight, tied/random large heaps, extreme
signed timestamps and complete score/hash/id preservation. A 100,000-candidate
stream verifies the heap property after every eligible replacement and the
final independent top-10,000 reference. Replacement allocates zero times and
all storage returns to zero. Fresh query reference/exact checks pass 936
evaluations, 192 scoped metadata cases pass on each of 13,312 and 6,912 entries,
and every one of 32 allocation failures recovers. A/B calls/bytes/peak remain
30 / 485,472 / 485,120. Sanitized B, x86 baseline/v3 and scoped History/
HistoryQueue/HistoryCapacity pass. System SQLite/dependency archives are not
fully sanitizer-instrumented; no Linux timing or global acceptance is claimed.

Comparator census falls from 1,551,857 to 1,457,806 on the monotonic 100,000-
entry heap and from 245,570 to 231,854 on shuffled 15,000 entries; nonheap
counts are unchanged. ARM64 inlines replacement and reduces query size from
796 to 728 instructions, but size/count reductions do not establish speed.

The first primary series completes seven alternating pairs of 32 queries,
with 30 valid host boundaries and maximum load1 2.443359. Its distinct heap
CPU rises from 13.110906 to 13.648344 ms (4.099%), with 0/7 wins.
Mean is 13.113842→13.652470 ms and p95
13.557206→14.164503 ms, both 0/7. Exact responses pass.
The predeclared early stop rejects the candidate; twenty remaining component
cases, full runtime and native are unmeasured. No owned builds/tests overlap.

Three separate instrumented phase diagnostics use 64 queries/execution, seven
alternating pairs, 90 valid boundaries and maximum load1 3.248047. These retain
exact responses but are diagnostic, not replacement acceptance timings.

| Diagnostic case / phase | A CPU µs | B CPU µs | Wins |
| --- | ---: | ---: | ---: |
| heap-distinct / setup | 5.2969 | 5.4219 | 2 |
| heap-distinct / scan_select_score_hash | 12187.3906 | 12712.9531 | 0 |
| heap-distinct / recency_order | 417.5938 | 417.1875 | 4 |
| heap-distinct / dedup_collect | 374.5469 | 375.5156 | 3 |
| heap-distinct / rank_page | 4.1875 | 4.3281 | 1 |
| heap-distinct / detail_encode | 108.3906 | 110.8906 | 2 |
| heap-distinct / destroy | 167.9062 | 168.2812 | 2 |
| heap-all / setup | 5.1562 | 5.6094 | 3 |
| heap-all / scan_select_score_hash | 12199.7969 | 12717.5781 | 0 |
| heap-all / recency_order | 423.9375 | 423.4062 | 5 |
| heap-all / dedup_collect | 10.7031 | 10.5469 | 5 |
| heap-all / rank_page | 4.0156 | 4.0938 | 3 |
| heap-all / detail_encode | 111.8750 | 114.5156 | 2 |
| heap-all / destroy | 2.4688 | 2.7031 | 3 |
| shuffled-heap-distinct / setup | 3.6406 | 3.9062 | 2 |
| shuffled-heap-distinct / scan_select_score_hash | 1650.3594 | 1700.7656 | 0 |
| shuffled-heap-distinct / recency_order | 485.7500 | 479.2500 | 7 |
| shuffled-heap-distinct / dedup_collect | 253.4219 | 252.8125 | 5 |
| shuffled-heap-distinct / rank_page | 2.7500 | 2.6562 | 5 |
| shuffled-heap-distinct / detail_encode | 76.4688 | 78.1250 | 2 |
| shuffled-heap-distinct / destroy | 96.2344 | 96.6719 | 4 |

Unlike the earlier extraction diagnostic, this reproduces the major loss:
large scan/selection/score/hash adds about 0.52 ms and wins 0/7 in both distinct
and non-distinct runs; final sorting stays mixed. ARM64 reloads the vector
data pointer from `[sp, #0x30]` on every descent at `0x100004d50`, and again
during ascent. The accepted library path retains a pointer while descending.
This is a concrete code-generation difference, not an isolated causal proof.

A successor explicitly captures `candidates.data()` once before repair.
Its initial assembly removes those repeated base loads and has 725 query
instructions. It must pass fresh equivalence and paired checks; the rejected
variant is not reclassified. Production remains accepted A and F01–F16/
independent Zig/native120 remain open.

## Fixed-base heap replacement: rejected, 2026-11-04

`out-perf/dlls-history-heap-replace-02` captures the vector data pointer before
repair and indexes that fixed base. ARM64 removes the predecessor's repeated
base-field loads; the query has 725 instructions. The replacement algorithm,
heap shapes, comparison counts and storage are unchanged. Direct Release and
ASan/UBSan checks each pass 139,083 cases and the 100,000-candidate stream.
Fresh expanded reference/exact checks pass 612 evaluations; the previous 324
large-fixture evaluations are not rerun or counted as fresh. The 192 scoped
metadata cases, all 32 allocation failures, zero-live-storage checks, sanitized
B, x86 baseline/v3 and History/HistoryQueue/HistoryCapacity pass. A/B calls,
allocated bytes and incremental peak remain 30 / 485,472 / 485,120.

The first primary seven-pair series has 30 qualified host boundaries,
maximum load1 2.148926, and 32 queries per execution. Every response is exact.
Distinct heap CPU rises 13.185531→13.676344 ms (3.722%), 0/7 wins;
mean is 13.191074→13.680818 ms, 0/7, and p95
13.570675→14.141933 ms, 1/7. The declared rule rejects the candidate;
the other twenty controls, full runtime and native remain unmeasured.

Removing those loads is therefore insufficient to explain or fix the preceding
loss. The new descent still chooses a child index before computing its address,
while the accepted library descent can select a child pointer already computed.
The successor retains hole/child pointers through the repair and bounds pointer
formation before reaching a leaf. This is another code-generation hypothesis,
not a proven causal attribution. It needs fresh pointer-safety/equivalence and
paired evidence. Production remains unchanged; F01–F16 and independent Zig/
native120 acceptance remain open.

## Pointer-walk heap replacement: primary threshold missed, 2026-11-04

`out-perf/dlls-history-heap-replace-03` retains hole and child pointers during
descent, selecting a precomputed child address before copying. Index bounds
are checked before forming child pointers past a leaf; singleton replacement
has a direct path. The same bottom-up repair and accepted final sort remain.
ARM64 emits a 735-instruction query; descent uses pointer selection at
`0x100004d1c`, followed by paired 128-bit copy. No per-level base reload remains.
Ascent still reconstructs its index from a pointer difference and emits signed
division correction at `0x100004d84`.

Fresh Release and ASan/UBSan direct tests each pass 139,083 replacements and
the 100,000-candidate stream, with zero repair allocations. Fresh expanded
reference/exact checks pass 612 evaluations; scoped metadata, all 32 allocation
failures, zero-live-storage, sanitized B, x86 baseline/v3 and History/HistoryQueue/
HistoryCapacity pass. Calls/bytes/peak remain 30 / 485,472 / 485,120, and the
comparison census is identical to the two prior replacement variants.

The first primary series has seven alternating pairs, 32 queries/execution,
30 qualified host boundaries and maximum load1 1.757812. Distinct heap CPU
is 13.223250→13.100625 ms (-0.927%), with 5/7 wins. Mean is
13.229102→13.104228 ms and p95 14.060659→13.597537 ms,
both 5/7. Replies match exactly. The result misses the predeclared 6/7 primary
threshold, so it is not adopted or repeated. The remaining twenty controls,
full runtime and native checks remain unmeasured.

A successor retains the already available unsigned child index for ascent,
avoiding pointer-distance scaling and signed-division correction. This is a
concrete redundant-work reduction, not a claimed performance result. Its
oracles and measurements are fresh. Production and F01–F16/independent Zig/
native120 acceptance remain unchanged.

## Retained-index heap replacement: second primary missed, 2026-11-04

`out-perf/dlls-history-heap-replace-04` reuses the unsigned descent index during
ascent, removing pointer-distance reconstruction and signed-division correction.
ARM64 emits 728 query instructions; its ascent starts with subtract/shift and
direct address formation. The same repair algorithm, comparison census,
accepted final sort and memory use remain. Fresh Release/ASan/UBSan direct
oracles pass 139,083 cases and the 100,000-candidate stream; expanded reference/
exact checks pass 612 evaluations. Scoped metadata, 32 allocation failures,
zero-live-storage, sanitized B, x86 baseline/v3 and History/HistoryQueue/
HistoryCapacity pass. No allocations or retained storage are introduced.

Two complete seven-pair primary series have 60 qualified host boundaries,
maximum load1 2.012695. Each execution has 32 queries; every response matches.

| Primary | A CPU ms | B CPU ms | CPU / mean / p95 wins |
| --- | ---: | ---: | --- |
| heap-distinct | 13.238563 | 13.015531 | 7 / 7 / 5 |
| heap | 12.438844 | 12.346063 | 3 / 3 / 3 |

Distinct passes 7/7, but non-distinct only wins 3/7 and misses its separately
predeclared 6/7 target. The candidate is not adopted or repeated. The remaining
nineteen controls, full runtime and native remain unmeasured. The isolated
family has produced useful work/code-generation evidence, but no version has
passed its complete declared gate. No production heap change is committed.

Further prioritization returns to the accepted GUI profile, where the latest
qualified history interaction still costs roughly 30–33 ms GUI CPU per query.
A fresh profile after bounded highlight retention is required before choosing
its next work-reduction candidate. All F01–F16/independent Zig/native120 gates
remain open; the persistent objective remains active.
