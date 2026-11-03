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
QtGui `abd4bdf7f504`. Each qualifies 240 measured inputs, four 39×19 panes,
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
100 measured inputs after 20 warmups, four 39×19 panes at 1600×1000, three variable
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
leads are repeated font coverage lookup, per-cell row-revision division, runtime
scrollback projection and history-query scratch/statement reuse. Each needs a
fresh profile, equivalence oracle, disassembly and paired acceptance before it
can be retained as an optimization. Historical rejected batching, relay-buffer,
prefault, render-loop and update-idle variants remain documented in the existing
GUI/runtime performance reports.
