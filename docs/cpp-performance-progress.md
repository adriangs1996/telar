# Complete-stack performance progress

This is the current work log for [F01–F16](cpp-performance-flows.md), starting
from `6152393b18f8b3e7ae1a1322eca6c8f1eb718bbd` on 2026-11-02. The persistent
objective is active and unbounded. No flow has complete-stack performance
acceptance yet. Conditional cursor invalidation is accepted for the measured
warm-typing layouts against the frozen C++ baseline; complete-flow and Zig-stack
acceptance remain open.

The latest accepted local GUI is `bc55d0e8`, with runtime `1f1849d1`: the
compile-time OpenPane flush below improves discrete tab switching against the
preceding C++ build and passes typing controls. It does not close F08 against
Zig or any complete-flow/native120 requirement.

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
The November4 follow-up, documented below, supplies that qualified rerun and
rejects the candidate for loaded latency despite passing its primary CPU target.
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
| F06 | Native discrete wheel to exact top-row packet; stationary 4,096-row corpus and six independent-stack pairs | Continuous scrollback/selection/live-return content and cadence; complete intermediate body parity |
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


## Geometry dependency investigation after highlight retention, 2026-11-04

The fresh accepted-GUI diagnostic in
`out-perf/dlls-history-after-retention-profile-01` completes 120 verified queries,
with no pending submissions and complete owned-process cleanup. The six-second
sample requested 1 ms intervals. Host qualification passes with maximum load1
1.481934. Of 4,442 main-thread stack observations, the overlapping inclusive
categories contain 252 QML binding, 205 scene synchronization, 181 polish,
131 row layout, 91 history refresh, 52 row snapshot, 27 allocation and one QML
creation observation. These are diagnostic observations, not CPU percentages
or paired performance. Zero matches for the narrowly defined conversion and
text-layout patterns do not establish absence of that work. Allocation, copy
and Qt conversion costs remain hypotheses to test, not a global proven cause.

Inspection found that query-only changes publish the full row layout map,
invalidating geometry bindings even when all geometry fields remain equal.
`out-perf/dlls-history-geometry-signals-01` freezes accepted GUI `9bf92e97` and
runtime `1f1849d1`. Before implementation, its new component oracle observes
one layout and one regions notification for a query-only change, verifies that
lines change and geometry does not, and fails at the missing independent
geometry dependency. The candidate preserves the full layout/regions API and
adds a geometry-only map and notifier. Geometry bindings use that dependency;
line/highlight bindings retain the original content notification. A typed
snapshot comparison controls the new notifier without allocating a map to
compare it. This adds one QML geometry map per live row, with no unbounded cache.

The candidate oracle checks unchanged geometry for query/short-command changes
and real notifications for resizing, expansion and collapse. Software component
tests pass 39 checks including setup/cleanup; native selected component checks
pass six cases, and native QuickTest passes 36 history cases plus setup/cleanup.
Both full-window query captures (`gb`, `GST`) are RGBA-exact between A and B.
Clang-tidy passes after designated initialization/default-member cleanup; the
final GUI is byte-exact to frozen B `d0825666`. ARM64 updatePolish grows from
634 to 705 instructions and its local stack reservation from 688 to 784 bytes.
The extra equality test is inlined with floating-point comparisons and branches
over the geometry notifier; full layout notification remains. The final C++
translation unit also compiles for x86-64 baseline and v3, with disassemblies
retained. Those are compile checks, not x86 GUI execution or timing.

The predeclared native gate is six alternating pairs of 60 queries at each of
300 and 220 ms minimum cadence, combined CPU wins at least 5/6 at both cadences,
and no consistent mean/p95/p99 latency regression. Uptime and HostLoadGate
qualify every series. The candidate remains unadopted while that gate runs;
F01–F16, independent Zig comparison and native120 acceptance remain open.

The first 300 ms series is wholly discarded: load1 reached 5.532227 after
execution 4-B, exceeding the predeclared maximum of 5. Both the inner and outer
host gates reject it. Owned GUI/runtime/children cleanup completed. Its partial
pairs are not used for acceptance; any retry starts all six pairs afresh with
the same frozen binaries and thresholds. This follows the shared-laptop load
constraint without changing or stopping other agents.

The complete retry (`/tmp/telar-perf-history-geometry-signals-fixed-pairs-02`)
has 26 qualified host boundaries, maximum load1 3.331543, and twelve valid
executions of 60 queries. It rejects the candidate:

| 300 ms cadence metric | A median | B median | B wins / 6 |
| --- | ---: | ---: | ---: |
| Combined CPU ms/query | 34.753402 | 34.468378 | 2 |
| GUI CPU ms/query | 31.954456 | 31.686433 | 3 |
| Runtime CPU ms/query | 2.700962 | 2.742773 | 3 |
| Mean presentation latency ms | 104.556230 | 104.555835 | 3 |
| p95 presentation latency ms | 116.543377 | 116.582956 | 1 |
| p99 presentation latency ms | 120.220737 | 120.130055 | 4 |
| GUI instructions/query | 95,201,583 | 90,209,704 | 6 |
| GUI end footprint bytes | 253,830,524 | 255,624,584 | 2 |

Instruction reduction is repeatable, but combined CPU misses the declared
5/6 requirement, and p95 loses five pairs despite the small median difference.
No placement exception is claimed. The 220 ms cadence is not run after this
failure. The candidate source/patch, tests, code generation and raw evidence
are retained privately; all four production/test files are restored to the
accepted baseline. No geometry dependency change is adopted. The next lead is
the earlier measurement-map propagation itself: query changes currently rebuild
and convert the whole measurements map before recomputing unchanged row geometry.
This is an unmeasured hypothesis, not an accepted optimization.


## Query-only measurement bypass candidate, 2026-11-04

`out-perf/dlls-history-query-measurements-01` starts from accepted GUI `9bf92e97`
and runtime `1f1849d1`, not the rejected geometry variant. It extends the verified
work-avoidance idea to its upstream dependencies: a typed query property owns
its UTF-8 representation; query changes no longer construct the measurements
map, and query-only polish bypasses all measurement conversions and row/card
geometry derivation. A separate line list drives highlights; geometry bindings
retain a geometry-only map and conditional notifier. The complete layout map
remains available, and the QML `regions` compatibility name becomes an alias
rather than an eagerly evaluated map binding. No delay, matching algorithm,
gesture revision or delegate-retention policy changes.

The baseline oracle verifies a query-only `measurementsChanged` notification
and fails the required zero count. Candidate validation verifies zero measurement
and geometry notifications, updated visible match text, complete settled regions,
and notifications for resizing/expansion/collapse. Its initial candidate test
incorrectly assumed that reading the compatibility alias would wait for polish:
the alias can read fresh content before its deferred notification. The corrected
test explicitly waits for both notifications and visible highlights; all original
zero-notification requirements remain. Initial failure logs are retained.

All 39 software component checks, six selected native component cases and
36 native history QuickTest cases plus setup/cleanup pass. Both full-window
query captures are RGBA-exact to A. Clang-tidy passes. ARM64 code confirms that
the query-only branch skips QVariant lookups/conversions and geometry derivation;
it still pays the common stack prologue. Full updatePolish grows from 634 to
733 instructions. Exact source compilation for x86-64 baseline/v3 also passes;
those are not native x86 GUI runs. Frozen/final B is byte-exact at `a88e53a8`.
The same six-pair, 60-query, 300/220 ms CPU/tail gate is predeclared. Adoption
remains pending; all global F01–F16/Zig/native120 gates remain open.

Both original timing series pass their predeclared gate, with 26 qualified
host boundaries each (maximum load1 2.975098 and 1.897461 respectively).
Each cadence has six alternating pairs and 60 verified queries per execution.

| Metric | 300 ms A→B | B wins / 6 | 220 ms A→B | B wins / 6 |
| --- | ---: | ---: | ---: | ---: |
| Combined CPU ms/query | 34.507861→32.735227 | 5 | 32.524957→30.533151 | 5 |
| GUI CPU ms/query | 31.608825→30.034739 | 5 | 29.684909→27.813305 | 5 |
| Runtime CPU ms/query | 2.791315→2.714670 | 4 | 2.658768→2.677102 | 2 |
| Mean latency ms | 105.380112→103.576424 | 6 | 104.676125→104.484155 | 3 |
| p95 latency ms | 116.458635→116.468459 | 3 | 116.293772→114.394686 | 6 |
| p99 latency ms | 118.555688→121.410484 | 3 | 119.234575→118.476862 | 4 |
| GUI instructions/query | 95280427.975000→80690111.016667 | 6 | 92333611.258333→77740088.466667 | 6 |
| GUI cycles/query | 64541028.600000→60686015.858333 | 6 | 63702143.266667→57467190.733333 | 6 |
| GUI final footprint bytes | 263832956.000000→289916344.000000 | 1 | 254330284.000000→258876808.000000 | 3 |
| GUI interrupt wakeups/query | 94.375000→94.475000 | 3 | 71.033333→71.616667 | 0 |
| Runtime interrupt wakeups/query | 4.491667→4.491667 | 2 | 3.625000→3.658333 | 1 |

CPU and instruction reductions pass, while latency tails are mixed rather than
uniformly faster. At 220 ms, GUI interrupt wakeups increase in all six pairs
and runtime interrupt wakeups in five; these small counter increases are
retained explicitly, and no energy reduction is claimed. The unchanged runtime
is measured separately. GUI setup CPU wins 4/6 and 2/6; idle wakeups win 5/6
and 3/6. Footprint values vary substantially between executions, so their median
difference is not attributed to a proven fixed per-row memory cost.

A separate periodic-resource diagnostic runs 600 queries per variant followed
by 0.25/1/5-second idle snapshots. Its first attempt is discarded in full when
load1 reaches 7.239746 after A; B is not started. This does not invalidate the
already completed, independently qualified timing series. A retry uses identical
binaries and workload. QML lint for HistoryRow also passes. Adoption is pending
that memory review; the wider objective remains active.

The memory retry (`/tmp/telar-perf-history-query-measurements-memory-02`)
qualifies all six host boundaries, maximum load1 2.851074. A and B each complete
600 verified queries and 134 periodic resource observations over about 138 s;
both clean up completely. First/last 30-second footprint medians are
263,619,928 / 263,816,536 bytes for A and 263,964,040 / 254,363,016 for B.
Peak observed footprints are 325,256,608 and 325,682,616 bytes. After five
seconds idle, A is 244,057,432 bytes and B 244,516,232 (+458,800 bytes).
Neither trace shows sustained growth. This finite instrumented diagnostic does
not prove a global memory bound or supply timing evidence, but does not support
attributing the earlier 26 MB median gap to fixed retained per-row storage.

The query/measurement candidate is adopted locally: combined CPU improves in
5/6 pairs at both cadences, with approximately 5.14% and 6.12% lower medians;
GUI instructions improve in 6/6 at both, by approximately 15.31% and 15.81%.
The final production sources are identical to the measured ones and the final
GUI remains byte-exact to B. Removing temporary test logging and naming its
settle duration leaves all 39 final software checks passing. The separate
runtime cadence work is preserved unchanged. This acceptance closes only the
local candidate; F01–F16, independent Zig comparison and native120 remain open.


## Profile of the accepted query bypass, 2026-11-04

`out-perf/dlls-history-after-query-measurements-profile-01` samples accepted
GUI `a88e53a8` with runtime `1f1849d1`, completing 120 verified queries and
owned cleanup. Host qualification passes, maximum load1 2.183105. The six-second
sample requested 1 ms intervals. Its 4,431 main-thread observations include
124 history refresh, 65 row snapshot, 68 row layout, 228 QML binding,
123 polish and 140 scene synchronization observations. Counts overlap and are
diagnostic, not a controlled before/after performance comparison.

Inspection of actual stacks expands the narrow conversion classifier: free
`toVariant`/`objectToVariant` functions account for 26 inclusive observations,
`VariantAssociationObject` for 106, and V4 garbage collection for 46. The old
conversion regex matches zero because it misses these names; that zero is not
evidence that conversions are absent. Footer layout appears in 27 observations,
metadata layout in 13, accessibility in 19 and QMap comparisons in five.
This gives a concrete local allocation/conversion lead without proving a global
root cause or attributing the entire cost to one component.

Source review confirms that footer and metadata inputs rebuild labels and
unconditionally notify layout even for some changes that leave the displayed
labels and geometry unchanged. Footer label preparation also updates the
hover/action choice revision, so any caching must separate that mandatory
identity update from label regeneration. The next oracle must prove that
revision changes retire gestures and refresh hover choices while unchanged
labels avoid notification, and that genuine label/geometry changes still
propagate. Filters already narrow their input, and the empty state already
uses a conditional Loader; those are not missing optimizations. No new
candidate is implemented or accepted from this profile yet. The persistent
objective remains active.


## Presented history copy target qualification, 2026-11-04

The stable footer/metadata label experiment's first native history run passed
35 of 36 cases but left the clipboard empty in
`historyPointerSelectionNeverSubmits`. Three isolated fresh reproductions with
the same candidate passed. The original failure is retained; its specific cause
is not established. No timing was started with that qualification unresolved.

Source inspection identified a readiness weakness in that test: it clicked the
live QML copy geometry after a 100 ms settle, while selection motion lasts
140 ms and native dispatch resolves actions against the presented frame. The
fixture now waits for a delivered current revision/generation and an enabled
copy target for the current selection, then clicks its presented bounds. It
retains selection, double-click, no-submit, visible-copy and exact clipboard
assertions. Production dispatch and its stale-gesture protections are unchanged.

The accepted baseline and candidate each pass all 36 native history cases
(38 checks including setup/cleanup) with this qualification. Receipts are in
`out-perf/dlls-history-stable-labels-01/qualified-result-{A,B}.json`; the original
failure and isolated repetitions remain alongside them. Rebuilt candidate GUI
`1a20e898` is byte-identical to its frozen executable. This test correction
is independent of the pending optimization decision.


## Stable history labels rejected, 2026-11-04

`out-perf/dlls-history-stable-labels-01` tests retaining bounded typed label
inputs in the footer and metadata item. Unchanged inputs skip repeated UTF-8
conversion, label/map generation and label notifications; unchanged typed geometry
skips layout notifications. Every input and choice revision still updates, and
old captured gestures retire. The baseline fails the redundant-notification
oracles; the candidate passes all 40 software component checks, ten native
component cases and the 36 native history cases after the independent presented-
copy test qualification above. Complete `gb` and `GST` window captures are exact.
Both implementation units pass clang-tidy and compile for x86-64 baseline/v3;
ARM64 and x86 disassemblies are retained. Instruction counts alone are not timing.

Frozen A GUI is `a88e53a8`, B is `1a20e898`; both use runtime `1f1849d1` and
helper `87beebb0`. Six alternating pairs of 60 queries at a 300 ms minimum
cadence complete under `/tmp/telar-perf-history-stable-labels-fixed-pairs-01`.
All 26 outer host boundaries qualify, maximum load1 4.483887; native result,
offered-rate and owned-cleanup checks pass. No owned build/test/profile runs
alongside timing. Values below are medians of the six per-run summaries.

| Metric | A | B | B lower |
| --- | ---: | ---: | ---: |
| Combined CPU/query (ms) | 32.852747 | 31.807033 | 5/6 |
| GUI CPU/query (ms) | 30.133651 | 28.821730 | 6/6 |
| Runtime CPU/query (ms) | 2.722464 | 2.954096 | 1/6 |
| GUI instructions/query (millions) | 80.859057 | 74.130762 | 6/6 |
| GUI cycles/query (millions) | 59.405511 | 56.900765 | 6/6 |
| Mean latency (ms) | 104.114248 | 103.637358 | 4/6 |
| p95 latency (ms) | 116.361469 | 117.360960 | 2/6 |
| p99 latency (ms) | 120.941637 | 120.967491 | 1/6 |
| GUI end footprint (bytes) | 258778516.000000 | 255313276.000000 | 3/6 |

The candidate is rejected: p99 latency improves in only 1/6 pairs, failing the
predeclared no-consistent-latency-regression rule despite combined CPU winning
5/6 and GUI CPU/instructions/cycles winning 6/6. The small difference between
p99 medians does not override the paired direction rule. The cause is not
established, and no code-placement explanation is claimed. The unchanged runtime
also has higher CPU in 5/6 and cycles in 6/6; these observations are retained
without attributing them to a demonstrated runtime-code effect. GUI setup CPU
wins 2/6 and setup cycles 1/6; GUI/runtime interrupt wakeups both win 2/6.
Every resource counter remains in the raw receipt.

The 220 ms series is not started after this primary rejection. All nine candidate
source/test files are restored exactly to the accepted baseline; the independent
presented-copy test correction remains. Rebuilding the accepted source is required
to replace candidate objects before further qualification. F01–F16, independent
Zig comparison and native120 remain open. The next step checks the current
independent C++ and Zig history endpoints, including the timing difference
between C++'s 60 ms debounce and Zig's immediate bounded request submission.

Restoration completes with a byte-exact `a88e53a8` GUI and all 39 accepted
software component checks passing. The source and executable both match A.
Only the independent test correction and this rejection report are retained.
The pre-existing runtime cadence edits remain untouched.


## Current independent history endpoint qualification, 2026-11-04

`out-perf/dlls-history-cross-stack-current-01` verifies frozen Zig `6ccf7948`
against its successful ReleaseFast build receipt. Its `src`, `lib`, `build`,
build manifests, `run_widget.zig`, vendor and diagram-renderer inputs have no
committed or working-tree changes since build HEAD `5c619b85`. The executable
hash matches that receipt; the current toolchain hash and source paths are saved.
No new Zig build or performance equivalence is inferred from this identity check.

Fresh runs using the current reusable history observer qualify 12 replacements
each on accepted C++ `a88e53a8`/runtime `1f1849d1` and the independent Zig stack.
Zig also correctly fails injected late-stale and missing-callback controls. All
four runs qualify host load (maximum load1 3.323730) and owned cleanup. These
are endpoint controls, not a paired speed comparison or cross-renderer optical
parity. Raw directories are `/tmp/telar-perf-history-cross-stack-current-*-01`.

The next equal-cadence comparison must use the current observer's final
latest-presentation check, preserving its burst and late-stale controls. Older
private fixed-cadence copies predate that stronger check and must not become
the new observer base. Investigate scheduling only with the existing rapid-input,
delayed-reply and request-load controls. The persistent all-flow objective remains
active; no F01–F16 or native120 requirement closes here.


## Equal-cadence current history observer, 2026-11-04

The reusable observer now accepts `--minimum-query-interval-ms`. It retains
latest-result and pending-callback validation, waits before preparing the next
whole-query replacement, and records actual minimum/mean input intervals and
the 5% offered-rate qualification. Default zero preserves prior behavior;
burst/observe-only modes cannot be mixed with the new whole-query cadence.
Out-of-range and nonfinite values fail before creating output.

`out-perf/dlls-history-cross-stack-cadence-01` qualifies 12 native replacements
per independent stack at a requested 300 ms minimum: mean intervals are
308.758788 ms for C++ and 308.663818 ms for Zig, both rate-qualified. Zig's
late-stale and missing-callback negative controls still fail as required. All
four runs qualify host load and cleanup; Objective-C syntax checking reports
no warnings. This enables the next six-pair equal-load comparison without
dropping the current observer's stronger final-result controls.


## Independent warm history comparison at equal cadence, 2026-11-04

`/tmp/telar-perf-history-cross-stack-pairs-01` completes six alternating pairs
of 60 replacements per run with the current observer and a 300 ms minimum
query interval. C++ GUI `a88e53a8` uses C++ runtime `1f1849d1`; Zig GUI and
runtime both use `6ccf7948`. The fixture, configuration, cases, templates,
executables/helpers and observer sources are frozen by hash. All 26 outer host
boundaries qualify (maximum load1 2.038574); every native result, final-match,
callback, offered-rate and owned-cleanup check passes.

The table reports medians of the six per-run summaries, with paired win counts.

| Metric | C++ | Zig | C++ lower |
| --- | ---: | ---: | ---: |
| Mean latency (ms) | 103.698201 | 51.746027 | 0/6 |
| p50 latency (ms) | 105.112323 | 50.475177 | 0/6 |
| p95 latency (ms) | 115.149120 | 66.145023 | 0/6 |
| p99 latency (ms) | 119.537262 | 69.611662 | 0/6 |
| GUI CPU/query (ms) | 29.877808 | 13.999987 | 0/6 |
| Runtime CPU/query (ms) | 2.769275 | 12.137768 | 6/6 |
| Combined CPU/query (ms) | 32.647083 | 26.273176 | 0/6 |
| GUI end footprint (bytes) | 253969776.000000 | 193913912.000000 | 0/6 |
| Runtime end footprint (bytes) | 11297224.000000 | 16491168.000000 | 6/6 |

C++ loses the warm visible endpoint in every pair. Its runtime is substantially
cheaper, but the GUI's CPU cost exceeds that saving: GUI instructions are
80.578594M versus 29.196562M per query (0/6), while runtime instructions are
21.491953M versus 110.234095M (6/6). GUI interrupt wakeups are lower
(94.383333 versus 124.633333, 6/6); runtime interrupt wakeups are higher
(4.516667 versus 0.466667, 0/6). No energy conclusion follows. All process
counters, including setup costs, remain in the raw result. Footprints are
separate process snapshots, not a sum of shared RSS or proven fixed storage.

The fixed 60 ms C++ timer is a concrete latency hypothesis, not proof that it
explains the whole measured gap. A private zero-delay single-shot candidate
now isolates that wait; it must also qualify rapid-input/request-load behavior
before adoption. The single-shot event-loop coalescence, request revisions,
stale rejection and 128-request bound remain in place.

This comparison uses independently checked result templates for each renderer;
it does not close optical/ranking parity, instrumentation perturbation, cold
queries, inspection, scrolling or native120. The complete F01–F16 goal remains
active. The observed warm F12 loss is now an explicit optimization target.


## Zero-delay history dispatch rejected on live capture, 2026-11-04

`out-perf/dlls-history-immediate-query-01` changes only the GUI history timer
from 60 ms to a zero-delay single shot. Private GUI `abffa8d6` builds, and the
existing bounded-request/stale-failure history oracle passes. The original
36-case native cohort passes 35 cases but fails
`historyInspectionTracksTabRenamingAndPaneClosure`: after a command prints its
marker and the test sends Ctrl-U, the first history query never returns its
expected single row. No performance series or capture adoption follows this
functional failure.

The unchanged case fails again in isolation. A separate diagnostic run records
a ready, error-free empty first result, observes the matching command in the
owned temporary SQLite database, and obtains the expected row with a second
query. That diagnostic adds logging and a post-failure requery only in a backed-up
test copy; it is not a passing oracle or a production fix. Both diagnostic edits
and the timer change are removed. The rebuilt GUI is byte-exact to accepted
`a88e53a8`, and the original isolated case then passes all three checks in
1.512 seconds. Original failure logs and all database observations remain saved.

Source inspection identifies a relevant asynchronous boundary: pane input/output
observation runs through `ObservationWorker`; `PaneObserver` later submits
`command_finished` persistence to the history worker. `Runtime::handle(QueryHistory)`
submits directly to that worker. FIFO ordering covers already-submitted history
jobs, but does not itself wait for an observation that has not submitted its
capture event yet. This is consistent with the observed failure; exact inter-worker
ordering has not yet been traced. The fixed wait cannot simply be removed while
claiming preserved live-history behavior.

The next investigation needs a deterministic observation/query ordering oracle
and bounded, nonblocking coordination of relevant pending capture work. Existing
deferred-report ownership patterns are a source lead, but pausing reads on the
interactive GUI connection would also delay terminal input and must not be copied
blindly. The existing native test remains unchanged. No speedup or scheduling
candidate is adopted; the all-flow objective remains active.


## Live capture ordering traced; admission prototype, 2026-11-04

The private SQLite interposer in `out-perf/dlls-history-capture-order-01`
confirms the missing ordering directly. With zero-delay GUI dispatch and the
accepted runtime, the first query reads snapshot ID 1 and finishes scanning
before the live command is inserted as ID 2. With the accepted 60 ms GUI timer,
the insertion precedes the snapshot. These are diagnostic runs with additional
allocation and logging, excluded from performance comparisons.

`out-perf/dlls-history-observation-admission-01` contains an unadopted composite
prototype: zero-delay GUI dispatch plus runtime admission of history queries
after already-received observation batches have submitted their capture writes.
A batch sequence cutoff avoids waiting for a busy pane to become idle. A lazy,
bounded queue retains history request order without pausing connection reads.
Disconnected clients' requests are cancelled, and replay checks client event
identity. Warm queries with no preceding observation work require no queue or
payload allocation. No result cache is introduced.

The focused component oracle passes capture-before-delivery, owned payload,
FIFO, cancellation, capacity, exception recovery and future-batch cases. ASan
and UBSan pass for the touched tests/header instantiations; dependency archives
remain uninstrumented. All 36 original native history cases pass, including the
previous live-capture failure, without changing their assertions. The candidate
SQL trace now records insertion before snapshot selection. Full native `gb` and
`GST` images match accepted A byte-for-byte. Runtime B is `537764da`; GUI B is
`abffa8d6`; A remains runtime `1f1849d1` and GUI `a88e53a8`.

The actual sequence methods compile for arm64, x86-64 baseline and x86-64-v3.
The completion check lowers to scalar load/subtract/sign extraction on arm64
and compare/sign test on x86; neither uses allocation or synchronization. This
is assembly qualification, not cross-target execution. Full runtime assembly
also exposes the added 256-slot pane scan per query; its cost still needs the
runtime-only control. The observer limit matches existing active-plus-retired
pane capacity.

No speedup or adoption follows these functional results. The frozen contract
requires six alternating latency/CPU pairs, burst typing/request-load controls,
runtime-only overhead checks and current host-load qualification. Removing a
debounce can increase intermediate query work; lower replacement latency alone
is insufficient. The queue has 64 slots and at most 256 observer references
per request. The wire payload ceiling implies a conservative 256 MiB payload
bound across a full queue, not measured ordinary consumption; cancelled vector
capacity can remain until that queue entry drains. Memory and unrelated-flow
effects remain open, as do the complete F01–F16 and native120 requirements.


## Observation admission: primary six-pair result, 2026-11-04

`/tmp/telar-perf-history-observation-admission-pairs-01` completes six
alternating accepted-A/candidate-B pairs, 60 native whole-query replacements
per run at a 300 ms minimum interval. The unchanged current observer validates
the last presented match, callbacks, focus, geometry, actual cadence and owned
cleanup. All 26 outer host boundaries qualify; maximum load1 is 3.553711.
No owned compilation, tests or profiling overlap the series. Executables,
fixtures, cases, templates and observer sources remain hash-frozen.

Medians of the six per-run summaries:

| Metric | Accepted A | Candidate B | B lower |
| --- | ---: | ---: | ---: |
| Mean latency (ms) | 103.218674 | 47.888118 | 6/6 |
| p95 latency (ms) | 115.911576 | 59.635262 | 6/6 |
| p99 latency (ms) | 120.513861 | 63.208280 | 6/6 |
| GUI CPU/query (ms) | 31.059770 | 25.352960 | 6/6 |
| Runtime CPU/query (ms) | 2.831395 | 3.176421 | 0/6 |
| Combined CPU/query (ms) | 33.938989 | 28.550481 | 6/6 |
| GUI instructions/query (M) | 80.484232 | 72.230176 | 6/6 |
| GUI end footprint (bytes) | 257942920 | 259695972 | 2/6 |
| Runtime end footprint (bytes) | 11600328 | 11534792 | 4/6 |

This passes the primary paced-replacement contract. Runtime CPU consistently
increases even though runtime cycles decrease in all six pairs and instructions
are nearly equal. The cause is not established; attributing it to the pane scan
requires the runtime-only control with the accepted GUI timer. Separate end
footprints do not establish retained-memory growth or a peak-memory bound.

The preceding diagnostic controls pass final-result/callback/cleanup checks for
both variants. At qualified 45 ms character spacing, four bursts issue four
measured queries in A and ten in B, excluding the two setup queries. The
90 ms delayed-response cases also qualify cadence and retain the final result
with up to three pending responses. Both 15 ms runs fail the 5% offered-rate
tolerance despite driver exit zero: their timings are excluded. The intentional
200 ms main-thread stalls preserve the final result and same-event-loop
coalescence, but are also outside offered-rate acceptance. These short controls
are not paired speed comparisons; `burst-assessment.json` records that distinction.

Focused clang-tidy finishes without diagnostics in the new observation/admission
lines. Full `main.cpp` analysis was stopped after more than five minutes without
output and remains open; a successful focused check does not replace it.

The composite remains unadopted. Next are paired burst CPU/request-load checks,
runtime-only overhead and busy-observation/input controls, then the secondary
220 ms comparison if those modes survive. Cross-target execution, final checks,
independent current Zig comparison and all wider flow/optical/native120 gates
remain open. The persistent goal stays active.


## Admission runtime-only control rejects the prototype, 2026-11-04

`/tmp/telar-perf-history-admission-runtime-only-pairs-01` holds GUI `a88e53a8`
and its helper fixed, comparing accepted runtime `1f1849d1` with admission
runtime `537764da`. Six alternating pairs of 60 replacements at 300 ms pass
all native endpoint, cadence, cleanup and host-load checks. The exact binaries
and the rejection rule were frozen before the series.

| Metric | Accepted runtime | Admission runtime | Admission lower |
| --- | ---: | ---: | ---: |
| Mean latency (ms) | 103.643620 | 104.823693 | 1/6 |
| p95 latency (ms) | 115.803218 | 116.399137 | 3/6 |
| p99 latency (ms) | 120.282842 | 118.892503 | 3/6 |
| Runtime CPU/query (ms) | 2.746578 | 2.724365 | 4/6 |
| Combined CPU/query (ms) | 32.751404 | 32.267561 | 5/6 |

The composite's consistent runtime CPU increase does not reproduce with the
accepted GUI timing. This control does not establish its cause. Mean presentation
latency nevertheless loses five of six pairs, failing the predeclared runtime-only
control. No placement explanation is proven. The composite primary speedup is
retained as evidence, but this particular prototype is rejected; no secondary
220 ms or adoption series follows it. These are instrumented results, not proof
of a universal 1.18 ms product regression.

Only the owned prototype source changes are restored. The rejected source,
patch, binary stages and decision remain under
`out-perf/dlls-history-observation-admission-01`. Rebuilt GUI `a88e53a8` is
byte-exact to accepted A, and the unchanged isolated live-capture test passes
again. Pre-existing client/attachment pacing work is preserved. The proven
capture/query ordering problem and its deterministic oracle remain useful for
the next scheduling design.

Before another burst CPU comparison, the reusable observer needs equal query-start
cadence in burst mode: previously the next burst followed final presentation,
allowing a faster variant to receive more bursts per second. Character-span
qualification and final-character-to-presentation latency must remain separate
from that inter-burst workload control. The 5% tolerance, negative controls and
full persistent objective remain unchanged.


## Equal-rate burst observer qualified, 2026-11-04

The reusable history observer now permits a minimum query interval with burst
input. Its first delivered character anchors inter-query cadence; the final
delivered character still anchors presentation latency. Whole-query replacement
keeps the same anchor as before. Both the character span and the interval
between query starts must satisfy the unchanged 5% offered-rate threshold.

The input producer uses a user-interactive serial queue and a strict dispatch
timer, with absolute deadlines and zero requested leeway. It does not spin or
block the GUI thread. The source cancels and releases its timer after the last
character. Earlier private absolute-deadline `mach_wait_until` variants remain
recorded: default queue priority produced up to 7.5–10 ms lag, and explicit
user-interactive priority still produced about 2 ms. Both fail 15 ms cadence;
their failed rows remain ineligible rather than being retried as successes.

`out-perf/dlls-history-burst-cadence-03` qualifies 12 bursts each at 15 and 45 ms
character spacing in both independent stacks, with a 300 ms minimum query-start
interval. At 15 ms, maximum producer lag is 0.136750 ms for C++ and 0.068500 ms
for Zig; mean query-start intervals are 311.601648 and 309.650576 ms. Whole-query
replacement and delayed-response controls also pass. The intentional 200 ms
GUI-thread stall preserves the final result but correctly fails rate qualification.
Late-stale and missing-callback negative controls fail for their intended reasons.
All nine native runs qualify host load and owned cleanup. Objective-C syntax
checking is clean; invalid one-sample and observe-only combinations fail before
creating output.

This qualifies workload delivery and existing endpoint guards, not observer
perturbation, cross-renderer optical parity, an optimization speedup or full F12.
The corrected producer enables the next independent equal-rate burst comparison;
all wider flow and native120 gates remain open.


## Independent short-burst comparison and GUI profile, 2026-11-04

Later endpoint-order controls below narrow the latency interpretation: Zig can
prepare the matching `gb`/`GST` region from prefix-query results before receiving
the final reply. These latencies describe first matching visible pixels, not
final-query round-trip completion. The resource census and original functional
gates remain observations of this offered workload; they do not close full F12.

`/tmp/telar-perf-history-burst-cross-stack-pairs-01` completes six alternating
independent-stack pairs using the qualified strict-timer observer. Each run
offers 60 alternating `GST`/`gb` bursts, 45 ms between characters and at least
300 ms between query starts. Actual mean start intervals span 309.178693–310.666038
ms. Every character-span, query-rate, final-result, callback, focus, geometry and
cleanup gate passes. All 26 outer host boundaries qualify, maximum load1 2.163086.
No owned compilation, tests or profiling overlap the timed series.

Accepted C++ GUI `a88e53a8` uses runtime `1f1849d1`; Zig uses `6ccf7948` for
both. The frozen contract includes binaries/helpers, fixture, configuration,
cases, templates and observer sources. A fresh source check confirms that the
Zig build inputs remain unchanged from build commit `5c619b85`; the new observer
is independently frozen. The two templates qualify separate endpoints, not
cross-renderer optical or ranking parity.

Medians of the six per-run summaries; CPU is per completed user burst, not per
internal backend query. Latency starts at the final delivered character.

| Metric | C++ stack | Zig stack | C++ lower |
| --- | ---: | ---: | ---: |
| Mean latency (ms) | 104.577655 | 27.852494 | 0/6 |
| p95 latency (ms) | 114.009920 | 36.386415 | 0/6 |
| p99 latency (ms) | 117.334420 | 40.669695 | 0/6 |
| GUI CPU/burst (ms) | 40.187140 | 18.982875 | 0/6 |
| Runtime CPU/burst (ms) | 2.797963 | 30.654747 | 6/6 |
| Combined CPU/burst (ms) | 43.038844 | 49.633458 | 6/6 |
| GUI instructions/burst (M) | 100.415930 | 51.915545 | 0/6 |
| Runtime instructions/burst (M) | 21.488063 | 274.290136 | 6/6 |
| GUI end footprint (bytes) | 255337864 | 194462764 | 0/6 |
| Runtime end footprint (bytes) | 11444680 | 16310944 | 6/6 |

The accepted C++ runtime saves enough CPU to win the combined resource metric,
but presentation and GUI cost lose every pair. Neither that CPU win nor these
short bursts close sustained typing, complete F12, observer perturbation or
native120. Separate process footprints are not summed shared RSS, and no energy
claim follows from the wakeup counters retained in the raw report.

After the paired series finished, `out-perf/dlls-history-burst-profile-01`
sampled the accepted C++ GUI for six seconds at requested 1 ms intervals during
120 verified bursts. Both cadence checks, host qualification and cleanup pass;
maximum load1 is 3.314941. Of 4,431 main-thread observations, the classifier
finds 189 QML-binding, 69 variant-association, 24 JS-to-variant, 32 GC, 55 row-layout,
40 row-snapshot and 78 history-refresh observations. Categories overlap and are
not CPU milliseconds. Direct line projection appears in four observations;
the sample does not establish it as the dominant cost.

Source review identifies a narrower work-avoidance hypothesis: `commandLines()`
recreates maps containing text, bounds, continuation markers and matches when
the query changes, and QML delegates bind to the aggregate line value. Separating
stable line data from changing match roles could avoid conversions and binding
updates, with bounded retained storage. Actual propagation needs a census and
an oracle preserving text, geometry, highlights, delivered identities and full
native output before implementation or acceptance. This remains a candidate
lead, not a demonstrated global allocation cause. All F01–F16 remain open and
the persistent objective stays active.

## Retained history-line roles rejected, 2026-11-04

`out-perf/dlls-history-line-roles-01` tested bounded line retention against accepted
GUI `a88e53a8`, with unchanged runtime `1f1849d1` and helper `87beebb0`.
Candidate GUI `c863fa6b` retained at most ten owned UTF-8/UTF-16 lines per row,
published independent text/geometry/match model roles, and suppressed unchanged
match notifications. This avoided rebuilding aggregate line maps and invalidating
static QML bindings for query-only changes. It did not cache search results.

The oracle preceded implementation: two new tests failed against the old model
while its existing query-measurement test passed. The candidate passed all 41
software component cases, eleven selected native component cases and all 36
native history cases. Typed fields matched the unchanged legacy snapshots across
Unicode, wrapping, expansion and viewport clipping; query-only notifications
contained only changed match roles. Full native `gb` and `GST` captures matched
accepted A byte-for-byte in RGBA. Focused clang-tidy passed after enum/include
fixes that left the GUI binary identical. The actual final layout source also
compiled for x86-64 baseline and v3; no x86 or Linux GUI execution is claimed.

ARM64 disassembly separates the query-only match loop from static line projection.
The new loop still constructs match records, compares variants and emits model
notifications; it is not allocation-free. The lifetime-preserving QByteArray copy
uses reference-count atomics. This is a work-avoidance experiment, not evidence
that RAII or allocations globally explain the C++/Zig gap.

Two six-pair alternating series used the same strict native observer, fixture,
templates and 300 ms minimum query-start interval. The second also delivered
characters at 45 ms intervals. Both qualified all 26 outer host boundaries
(maximum load1 4.221191 whole-query, 2.167969 burst), offered-rate, final-result,
callback, focus, geometry and cleanup checks. No owned build, test or profile
overlapped timing. Raw series are
`/tmp/telar-perf-history-line-roles-whole-pairs-01` and
`/tmp/telar-perf-history-line-roles-burst-pairs-01`.

Medians of six run summaries; CPU is per completed query/burst and burst latency
begins at the final delivered character.

| Workload / metric | Accepted A | Candidate B | B lower |
| --- | ---: | ---: | ---: |
| Whole mean latency (ms) | 103.970483 | 103.496949 | 4/6 |
| Whole p95 latency (ms) | 114.768322 | 115.688980 | 2/6 |
| Whole p99 latency (ms) | 119.031233 | 121.062710 | 2/6 |
| Whole GUI CPU (ms) | 30.059567 | 28.430919 | 6/6 |
| Whole combined CPU (ms) | 32.814684 | 31.231382 | 6/6 |
| Whole GUI instructions (M) | 80.392130 | 72.557096 | 6/6 |
| Burst mean latency (ms) | 104.070558 | 104.111353 | 1/6 |
| Burst p95 latency (ms) | 113.454134 | 116.609447 | 0/6 |
| Burst p99 latency (ms) | 115.507380 | 119.351879 | 0/6 |
| Burst GUI CPU (ms) | 39.345905 | 37.368823 | 6/6 |
| Burst combined CPU (ms) | 42.052715 | 40.160812 | 6/6 |
| Burst GUI instructions (M) | 100.636539 | 85.594249 | 6/6 |

**Rejected under the frozen contract:** burst mean/p95/p99 meet its consistent
loss threshold despite CPU wins in both workloads. The nearly equal median mean
does not negate the p95/p99 losses. Their cause is not established; no identical
disassembly placement exception was demonstrated. The GUI end-footprint medians
were 254076308/258459028 bytes for whole queries and 254215536/255370608 for
bursts. Memory concessions remain permitted; memory is not this rejection's
reason. A longer retention/churn diagnostic was therefore not run.

The candidate, new oracles, patch, binaries and logs remain in ignored private
scratch. Only this experiment's production/test edits were restored; preexisting
runtime cadence work was preserved. No independent-stack, complete F12 or
native120 acceptance follows. All F01–F16 and the persistent objective remain open.

Restoration passes the original 39 software component cases. Recompiling produces
accepted GUI `a88e53a8` byte-exactly after restoring the original QML resource
timestamp through RCC; only resource metadata, the derived Mach-O UUID and code
signature had initially differed. Source hashes match the frozen pre-experiment
files. The next diagnostic will separate wire response, drawable submission and
presentation stages; it is not a continuation of acceptance testing for this
rejected candidate.

`out-perf/dlls-history-line-role-phases-01` subsequently ran 60 diagnostic bursts
per archived binary through the existing byte-preserving history relay, retaining
each drawable's native pixel/timestamp record. Both rates, endpoints, callbacks,
cleanup and all six host boundaries pass (maximum load1 1.713867). Bracketing
`CACurrentMediaTime` with Python's monotonic clock before and after each run gives
intersecting alignment intervals narrower than 84 ns. Each of the 60 timed final
queries maps uniquely to one request, reply and verified drawable; both runs have
62 total requests including setup. No intermediate-character backend queries were
observed in this workload.

| Diagnostic mean stage (ms) | Accepted A | Rejected B |
| --- | ---: | ---: |
| Final input to query at relay | 63.871247 | 63.569576 |
| Query to reply at relay | 2.527483 | 2.458741 |
| Reply forwarding | 0.024931 | 0.024558 |
| Forwarded reply to frame commit | 9.199385 | 9.221360 |
| Frame commit to positive presentation | 27.682686 | 29.024544 |
| Frame commit to readback completion callback | 6.656369 | 7.771872 |

These are single diagnostic runs with extra relay/copying work, not paired timing
or causal attribution. The callback interval includes scheduling and is not GPU
execution time; phase percentiles must not be added. The presentation-stage lead
is consistent with earlier native drawable diagnostics, which already found a
long completion-to-presentation interval. Reducing the drawable pool to two and
changing Qt render-loop/update-idle settings previously supplied no accepted
large gain; those experiments must not be silently repeated as new findings.
The rejected line-role candidate remains rejected, the accepted production GUI
remains `a88e53a8`, and native presentation scheduling remains an unresolved lead.

## Burst endpoint ordering corrected, 2026-11-04

The previous goal turn made progress by rejecting line-role retention and
restoring accepted production. This continuation rechecked HEAD `5b2f3465f`,
the active unlimited objective, the unchanged accepted binaries and Zig build
inputs. It found a qualification gap while investigating presentation stages,
before changing any production scheduling policy.

Qt's installed-source Metal backend presents from a scheduled handler under its
display lock; Zig's Metal4 path submits, signals the drawable and calls present.
These differences alone do not explain native latency. The earlier private
inline-bindings Qt source differs from the installed source only in that unrelated
experiment; its presentation section is unchanged. Earlier drawable-pool and
standalone scheduled/command controls already supplied no accepted large gain.
Reanalysis of the old standalone control retains all five zero timestamps per
policy; its37 positive frames show completion-to-presentation medians around
20–21 ms in both policies. It remains a different, historical diagnostic workload.

The first independent60-query phase trace aborts inside the Zig observer. A
private message-only reproduction identifies the exact bound:512 retained
diagnostic frames after52 trials. Cleanup succeeds. That incomplete series is
not aggregated. A fresh24-query trace for each stack keeps the same512-frame
limit and all native/cadence guards, with maximum host load1 2.272949.

`out-perf/dlls-history-cross-stack-phases-02` shows22/24 Zig matching drawables
committed before the final query reply was forwarded; C++ has0/24. None in this
undelayed diagnostic presents before the reply. Zig rows compute highlights from
the current prompt, and preceding `g`/`gb`/`GS` results can already contain the
command selected by the final `gb`/`GST` query. Thus the old region can match
without rendering the final reply. A linear input/query/reply/commit breakdown
correctly rejects the resulting negative reply-to-commit intervals.

The control in `out-perf/dlls-history-final-reply-control-01` delays only final
`gb`/`GST` replies by500 ms, leaves prefixes immediate, and spaces query starts by
900 ms. Both stacks pass all12 trials, cadence, focus, drawable, callback and
cleanup checks; all host boundaries qualify, maximum load1 1.989746. Every Zig
endpoint now commits **and presents before** its final reply; every C++ endpoint
follows its reply. Diagnostic median visible-region latencies are27.555771 and
608.707042 ms respectively. These are a negative endpoint-order control, not
performance measurements. Early correct rendering is not a product bug, nor
does this disprove the prior CPU census. It narrows the old burst latency claim
to first matching visible pixels, excluding final-query completion and full F12.
Whole-query replacement and the C++-only rejection remain separately scoped.

`out-perf/dlls-history-final-command-endpoint-01` captures independent full native
templates for fuzzy queries `gb1` and `gs0`. Their final characters change command
content in the same bounded region; the existing fixture's displayed selected
build command changes from target4996 to1996, for example. These captures do not
prove cross-renderer optical/ranking parity. With final replies delayed500 ms,
all12 endpoints per stack commit after their uniquely identified final reply.
Both offered rates and all host boundaries pass, maximum load1 2.613770. Bracketed
clock alignment uncertainty is below125 ns.

In that diagnostic, mean input-to-query intervals are64.084222 ms for C++ and
0.214087 ms for Zig; query-to-reply intervals are2.369049/13.126142 ms. After the
intentional relay delay, reply-to-commit means are9.559958/1.834365 ms and
commit-to-presentation means27.200698/29.747076 ms. These instrumented single
runs identify stages, not speedups or causal attribution. They redirect the next
latency investigation toward query admission and delivered GUI work; they do not
justify replacing Metal presentation policy or restoring a rejected admission
prototype. No fresh six-pair baseline for the new case is claimed yet.

The reusable [endpoint verifier](../tools/check_history_endpoint.py) checks
request identity, successful response kind, relay ordering, matching drawable,
bounded before/after clock alignment, final-reply ordering, offered rates,
presentation guards, host qualification and cleanup. It always reports
`performance_eligible=false`; ordering alone cannot prove causation. The native
driver now records clock brackets only for trace/frame diagnostics and explains
diagnostic-capacity aborts. The observer guide distinguishes reply-dependent
completion from legitimate cached/anticipatory updates.

`out-perf/dlls-history-endpoint-verifier-01` exercises the final reusable tools on
eight delayed queries each: new C++ and Zig cases qualify, and old Zig `gb`/`GST`
correctly fails the reply-dependent check. All eight host boundaries qualify,
maximum load1 1.867188. Seventeen mutations also reject missing/duplicate/failed
replies, wrong drawable pixels, invalid clocks/order, rate failure, dropped/zero
frames, disabled synchronization, pending callbacks, host failure, relay errors
and incomplete cleanup. CLI help and diff checks pass. Production GUI/runtime
remain accepted A; unrelated runtime cadence edits are preserved. All F01–F16,
observer perturbation, optical parity and native120 requirements remain open.


## Final-command burst baseline and ordered admission, 2026-11-04

The previous turn qualified the endpoint against delayed final replies. This
continuation starts from `f97d2f6e3`, with the unlimited goal active and the four
unrelated runtime cadence files preserved. Allocation/copy/Qt conversion remains
an additional hypothesis; the coordinator's memory-versus-work tradeoff is
permitted, subject to actual bounded ownership and measured regressions.

A fresh six-pair independent comparison uses the final-command-dependent `gb1`
and `gs0` templates, the same10k fixture,60 bursts per run,45 ms characters and
at least300 ms between query starts. The strict current observer, source inputs,
endpoint qualification receipts and accepted binary identities are frozen in
`/tmp/telar-perf-history-final-command-cross-stack-pairs-01/contract.json`.
Zig build inputs remain unchanged from its recorded build, and its binary remains
`6ccf7948`; no stale-source rebuild exemption is inferred from C++ changes.
All native result, presentation, callback, offered-rate and cleanup gates pass.
All26 host boundaries qualify, maximum load1 2.141602; no owned build, test or
profile overlaps timing.

Medians of six runs per variant, with C++ pair wins:

| Metric | C++ | Zig | C++ wins |
| --- | ---: | ---: | ---: |
| Mean final-character latency, ms | 103.527201 | 44.383258 | 0/6 |
| p95, ms | 114.308677 | 49.499701 | 0/6 |
| p99, ms | 117.877121 | 50.636353 | 0/6 |
| GUI CPU, ms/burst | 40.454628 | 19.682776 | 0/6 |
| Runtime CPU, ms/burst | 2.789955 | 36.584392 | 6/6 |
| Combined CPU, ms/burst | 43.319090 | 56.575646 | 6/6 |
| GUI instructions, million/burst | 109.220053 | 59.983676 | 0/6 |
| Runtime instructions, million/burst | 22.304999 | 330.143234 | 6/6 |

This independently qualifies the narrower final-command endpoint instead of
reusing prefix-match latency. It does not establish cross-renderer ranking or
optical parity, sustained typing, full F12, native120, or observer perturbation.
The accepted C++ stack remains slower in latency despite winning combined CPU
for this offered burst workload. The current candidate must preserve both costs;
no component-only gain closes the all-flow objective.


### Ordered observation admission rejected

`out-perf/dlls-history-ordered-admission-01` freezes a different algorithm from
the earlier rejected256-slot fence scan. Each nonempty observation buffer owns
one intrusive node in a shared order; a query inserts a marker after preceding
buffers. Completing a buffer unlinks its node, and readiness checks the head.
Later buffers do not extend an existing marker. Queries keep the bounded64-entry
FIFO, owned payloads, mutation ordering and client/event-identity cancellation.
Two nodes plus one shared owner use48 bytes of additional fields per observer on this64-bit target,
with one shared order and one marker per pending query. Empty process-only batches
are not enrolled; discarded active events retire their node so an oversized
input cannot strand admission on an empty buffer. No worker accesses the list.
The GUI uses the already-qualified zero-delay search form.

An independent list oracle is written before the implementation. It passes720
completion permutations and200,000 random track/remove/move transitions with
ARM64 ASan/UBSan, uninstrumented ARM64 and x86-64 under Rosetta. A separate20,000-transition
admission oracle matches the old per-observer sequence reference through
cancellation, empty sealed batches, two-buffer rollover and future batches.
Focused capture, ownership, FIFO bounds, exception recovery, retired-observer
and dropped-batch tests pass, including instrumented header instantiations;
dependency archives are not sanitizer-instrumented. Two initial test-development
failures, a missing order variable and a retired test using a different order,
are retained and corrected before native validation.

All36 native history cases pass on the final GUI/runtime pair. A diagnostic SQL
trace records the live command INSERT before the query snapshot and its `id<=2`
scan. Full native `gb1`/`gs0` RGBA images are byte-exact A/B. The rebuilt zero-delay
GUI matches `abffa8d6`; using the integer rather than chrono QTimer overload first
produces a different executable, so it is corrected and the final native suite
rerun. A final rebuild reproduces all three staged B binary hashes exactly.
ARM64 and x86 baseline/v3 compile/assembly show bounded pointer loads/stores and
no iteration or allocation in readiness/track/retire; only native ARM64 and the
standalone x86 list oracle are executed. Linux and full x86 GUI are not qualified.
Focused clang-tidy completes with existing broad test/style diagnostics and an
intra-TU lifetime-annotation suggestion; no warning-free full-runtime audit is
claimed. Diff whitespace checks pass.

The first primary series deliberately tests short bursts, because removing the
GUI wait can submit more prefixes. Six alternating pairs,60 bursts each, use
45 ms characters, at least300 ms query starts and the qualified final-command
case. Raw evidence is
`/tmp/telar-perf-history-ordered-admission-burst-pairs-01`. All26 host boundaries
qualify, maximum load1 4.712891; all offered-rate, result, callback, drawable and
cleanup checks pass. No owned build, test or profile overlaps timing.

| Metric | Accepted A | Ordered admission + immediate GUI B | B wins |
| --- | ---: | ---: | ---: |
| Mean final-character latency, ms | 104.470433 | 38.841953 | 6/6 |
| p95, ms | 115.686153 | 49.260603 | 6/6 |
| p99, ms | 118.156704 | 54.806749 | 6/6 |
| GUI CPU, ms/burst | 42.697102 | 42.716370 | 4/6 |
| Runtime CPU, ms/burst | 2.843076 | 6.895604 | 0/6 |
| Combined CPU, ms/burst | 45.540897 | 49.732807 | 0/6 |
| GUI instructions, million/burst | 109.934982 | 175.447407 | 0/6 |
| Runtime instructions, million/burst | 22.304329 | 63.657944 | 0/6 |

**Reject:** combined CPU loses all six pairs, failing the predeclared5/6 rule.
The memory increase is permitted and is not the reason for rejection. The
whole-query, unchanged-GUI runtime-only and input/output timing controls are not
started after this primary failure. Therefore these results do not isolate the
cost of the admission list itself, and must not be reported as a runtime-only
regression. The large latency improvement does not override the frozen rule.

Separate twelve-burst trace/frame diagnostics pass the final-reply endpoint
verifier for both A and B. Clock-aligned request census finds exactly12 queries
for A and36 for B: B submits `g`, the two-character prefix and the final query.
This demonstrates additional query work, not its isolated share of CPU or a
global allocation cause. Neither these traces nor their timings are acceptance
measurements. The next verified source lead is eager `refreshHistory` projection
of every returned row: up to100 records, each with more than20 QVariantMap
fields, are constructed before the virtualized view requests visible records.
A lazy owned projection needs its own equivalence and lifecycle oracle; it is
not yet implemented or accepted. The rejected line-role experiment remains
rejected and must not be silently reintroduced.

The private candidate source, commands, failed and successful oracles, native
captures, assembly, complete paired results and decision are archived. Every
changed production source is restored to its frozen accepted hash; new private
headers are removed. The four unrelated runtime cadence edits remain intact.
The unlimited objective remains active. F01–F16, independent all-flow acceptance,
optical parity, observer perturbation and native120 remain open.


## Lazy history record projection not accepted, 2026-11-04

The previous turn completes a qualified independent final-command baseline and
rejects ordered admission. This turn starts from `042578b54`, verifies the
unlimited objective remains active, and tests the next source-backed work lead.
Accepted runtime `1f1849d1` and GUI `a88e53a8` are frozen again; unrelated runtime
cadence work remains untouched. No prior rejected renderer/admission is restored.

`out-perf/dlls-history-lazy-records-01` replaces only the GUI history list with a
bounded owned snapshot model. Each returned UTF8 row and its calendar sample are
copied before notifications; its Qt record is materialized on first data access.
Previously materialized positions are compared before emitting updates, while
unrequested positions may receive conservative change notifications without
being projected. This retains the existing record role, position-based identity,
suffix insertion/removal, grouping and retired-row lifetime. It does not retain
borrowed browser storage or add an unbounded cross-query cache. The existing
60 ms GUI search wait and runtime executable remain unchanged.

Two new component oracles precede implementation. They compare complete maps
with the existing eager projection, exercise Unicode, grouping, source lifetime,
calendar changes, invalid indexes and reentrant removal reads, and prove zero
projections on publication followed by eight projections for eight requested rows
of a hundred. All41 component cases and36 native history cases pass. A separate
512-snapshot reference run with `QAbstractItemModelTester` passes ASan/UBSan;
independent input/model allocators confirm ownership and complete deallocation.
Capacity overflow and injected allocation failure preserve the previous page.
Dependency Qt/Ghostty libraries are not sanitizer-instrumented.

Focused strict clang-tidy on the new model passes. The final implementation uses
nonassignable snapshot rows with explicit field transfer and suffix destruction;
its allocator-aware string transfer is not falsely declared noexcept. Initial
fixture namespace/link and static-analysis development failures are retained.
Final sources rebuild as GUI `dffb8d0c`, distinct from the first private `83f38287`
binary, so the full component/native suites and complete native captures are
repeated. Final `gb1`/`gs0` RGBA captures are byte-exact against A. ARM64 and x86
baseline/v3 compilation and generated assembly pass; x86 GUI and Linux execution
remain unqualified. Actual A/B disassembly replaces eager per-row projection in
`refreshHistory` with snapshot publication; the new model branches around
projection for unmaterialized rows. This is a work census, not a timing proof.

Two complete six-pair native series use the unchanged10k fixture, qualified
final-command templates,60 samples per run and at least300 ms query starts.
The second adds45 ms character bursts. Sources, tools, binaries, helper and
inputs remain frozen. All rate, focus, content, callback, drawable and cleanup
gates pass. Each series has26 qualified host boundaries: maximum load1 1.880371
for whole queries and2.228516 for bursts. No owned build/test/profile overlaps.
Raw series are `/tmp/telar-perf-history-lazy-records-{whole,burst}-pairs-01`.

| Mode / metric | Accepted A | Lazy B | B wins |
| --- | ---: | ---: | ---: |
| Whole: mean latency, ms | 104.438947 | 103.334716 | 4/6 |
| Whole: p95, ms | 114.860025 | 115.808421 | 3/6 |
| Whole: p99, ms | 120.393206 | 117.712507 | 5/6 |
| Whole: GUI CPU, ms/query | 30.808743 | 29.789936 | 5/6 |
| Whole: combined CPU, ms/query | 33.761352 | 32.558709 | 5/6 |
| Whole: GUI instructions, million/query | 83.898691 | 81.456411 | 6/6 |
| Burst: mean latency, ms | 104.738102 | 104.869739 | 3/6 |
| Burst: p95, ms | 115.111762 | 114.544204 | 4/6 |
| Burst: p99, ms | 118.018641 | 118.273610 | 4/6 |
| Burst: GUI CPU, ms/burst | 43.858043 | 42.814283 | 4/6 |
| Burst: combined CPU, ms/burst | 46.757096 | 45.756361 | 4/6 |
| Burst: GUI instructions, million/burst | 109.453358 | 107.881106 | 6/6 |

**Do not accept:** the predeclared combined-CPU criterion requires at least5/6
wins in both workloads; bursts supply only4/6. This is insufficient consistency,
not evidence of an overall slowdown. Lower instruction counts do not override
the timing rule. Runtime CPU is3.016734/2.832284 ms per whole query (6/6 B wins)
and2.914753/2.961681 ms per burst (1/6). Both variants use the same runtime binary;
there is no runtime code change or isolated causal attribution for these shifts.
Closed-history single/four-split typing controls are prepared but not started
after the primary failure. No independent Zig/all-flow/native120 claim follows.

A post-series allocator census uses100 actual build-command strings from the
owned fixture and requests eight projected rows per update. It records102 owned
allocations initially, then101 per subsequent replacement, with24,800 live owned
bytes and eight projections each time. This counts only the model's injected
allocator, excluding Qt allocations; it neither measures their time nor proves
a global allocation bottleneck. It identifies a concrete possible refinement:
retain bounded snapshot buffers rather than reconstructing their UTF8 storage.
Its benefit still needs an oracle and separate timing. The same census does not
prove how many records the actual native view requests.

The complete candidate, source/build identities, oracles, captures, three-target
assembly and both paired series are archived privately. Changed production
sources are restored to their frozen accepted hashes and the new model header
is removed. The configured GUI rebuild matches accepted `a88e53a8` byte for byte;
all39 original component cases pass after restoration. The persistent objective
remains active, with every F01–F16 full-flow
acceptance, optical parity, observer perturbation and native120 requirement open.

## Bounded history snapshot reuse cost ranking, 2026-11-04

`out-perf/dlls-history-reused-records-01` investigates the previous census without
changing production. A private variant retains two vectors of at most 100 raw
rows, reuses their string capacities and exchanges owned rows before the existing
notifications. Shrinking destroys the suffix; clearing destroys both snapshots'
contents. It preserves the lazy model's record role and eager-map oracle. The
previous lazy model is a rejected diagnostic comparator, not the accepted base.

The zero-steady-allocation oracle first fails against that previous model, then
passes after reuse: 102 allocations on initial publication, 100 on the second,
zero thereafter. Live injected-allocator bytes increase from 24,800 to 49,600.
Qt allocations are excluded. The 512-snapshot eager-reference/model-tester check,
independent allocator ownership, capacity overflow and allocation-failure checks
pass with ASan/UBSan; dependency archives remain uninstrumented. ARM64 and x86
baseline/v3 compilation pass. ARM64 lowering retains string copy assignments and
owned row swaps; it does not eliminate raw copying. This is compile-only evidence
for x86, with no Linux or x86 GUI execution claim.

An isolated native ARM64 benchmark reproduces accepted eager publication, the
previous lazy model and the reused model. It publishes 100 fixture-shaped build
commands, with fixed pages or alternating target 4996/1996 pages and declared
0/8/100 record reads. Calendar/input storage is prepared before timing. Each run
warms 100 updates and measures at least 300 ms of thread CPU in 1000-update batches.
Six triplets per case alternate eager/lazy/reused order with its reverse. Frozen
source/binary hashes, raw output and the driver are retained under `paired-01`.
All 146 host boundaries qualify, maximum load1 1.678711. No owned compilation,
test or profile overlaps. These measurements exclude QML, rendering, IPC and the
runtime and do not estimate how many records a real view requests.

| Record requests / pages | Eager µs/update | Previous lazy | Reused lazy | Reused wins vs eager / lazy |
| --- | ---: | ---: | ---: | ---: |
| 0 / alternating | 140.817 | 3.932 | 2.881 | 6/6 / 6/6 |
| 8 / unchanged | 161.691 | 17.202 | 16.174 | 6/6 / 6/6 |
| 8 / alternating | 141.297 | 15.517 | 14.669 | 6/6 / 6/6 |
| 100 / alternating | 144.877 | 148.500 | 146.979 | 0/6 / 5/6 |

The median paired saving from buffer reuse is 0.848–1.066 µs/update. Avoiding
unrequested projections accounts for the much larger isolated difference from
eager publication. Removing 101 raw allocations is real but not evidence that
allocation dominates native GUI cost. When all records are requested, reuse still
loses every pair against accepted eager publication. Do not integrate this model;
the absolute refinement is too small to prioritize another complete GUI series
after the previous native rejection. No new native performance or memory claim
follows. All production sources and accepted executables remain unchanged, and
the four unrelated runtime cadence edits are preserved. The objective remains
active; all complete flow, optical and native120 gates remain open.

## Current tab-switch qualification and cost investigation, 2026-11-04

After ranking the history allocation refinement, work returns to F08. The native
tab driver now wraps each execution with `HostLoadGate` and qualifies the entire
series before publishing its summary. Its manifest also records the owned-window
floating policy and preserves the load-observer source. No production application
changes accompany this correction. All 13 tab fixture/packet/report tests and
12 host-gate tests pass.

The first current qualification stops before input because the window manager
supplies 1760×2230 rather than the requested 1600×1000 pixels. Its runtime and
children cleanly exit. Floating only the owned benchmark windows fixes geometry;
both accepted C++ executables (`a88e53a8` / `1f1849d1`) and independent Zig `6ccf7948`
then pass 40 measured switches after 20 warmups, matching the 82×21 grid, positive
native presentation, target identity/generation and four independent 30 Hz PTYs.
All six host boundaries qualify, maximum load1 3.160156. This is qualification,
not paired acceptance. Six current negative controls separately reject wrong
tab, stale generation and corrupt checksum in both stacks, after initial readiness
and with no accepted responses; all owned runtimes/children exit.

Two attempts at six alternating 100-switch pairs are excluded in their entirety:
`/tmp/telar-perf-tab-switch-current-pairs-{01,02}`. Both stop at the Zig execution
of pair 1 on the unchanged 5% offered-rate gate. The first has 16 publications in
the first 500 ms bucket for producers 1/2. The second has producer 0 counts 16,14,16
in buckets 0,19,20, despite maximum host load1 only 2.485352. Its event receipts show
publications crossing bucket boundaries by about 1–2 ms. This is a concrete
generator/quantization limitation, not permission to relax the gate. Neither
series publishes an aggregate or contributes selected halves to another series.
Failed runs, process cleanup and detailed bucket receipts remain archived under
`out-perf/dlls-tab-switch-current-01`.

A separate diagnostic execution samples the accepted C++ GUI for eight seconds
at a 1 ms interval. Both stacks complete 240 switches with their content/rate gates;
all six host boundaries qualify (maximum load1 2.835938), and cleanup passes.
Every timing/resource value from that instrumented execution is excluded from
baseline and acceptance. The 5875 main-thread stack observations contain 216 under
tab-layout rebuild, 26 under tab measurement (18 caption measurement), 296 under
list reconciliation, 125 under pane refresh, 99 under QML object construction,
156 under binding update and 69 under variant association conversion. Counts
exclude nested repeats within each category; categories overlap and include
waiting/observer effects, so they are neither additive CPU percentages nor
allocation counts. One 166-observation branch directly connects tab rebuild to
`ListModel::reconcile`, `dataChanged` and synchronous QML notification/binding work.

Source inspection confirms `TabStripLayout::rebuild` remeasures captions, rebuilds
positioned records and reconciles the list on animation samples. The earlier
field-role, scalar-role and pane-retention variants remain rejected; this profile
does not reverse them. The next candidate should separate animation geometry
sampling from semantic tab-record publication so unchanged content avoids the
model/conversion/notification path entirely. Its geometry, drag, selection,
visibility and accessibility oracles and native regression gates are still needed.
Producer phase/receipt qualification must also precede another headline F08 series.
No new F08 performance acceptance, workspace coverage or native120 claim follows.
The unlimited objective remains active and unrelated runtime edits are preserved.

## Phase-qualified tab-switch baseline, 2026-11-04

The current tab observer now schedules its first warmup input between predicted
producer publications. A bounded helper takes the median phase origin from the
last 16 publication records of each of the four unchanged 30 Hz producers (at
least eight are required), finds the widest circular gap and schedules its
midpoint with a strict dispatch timer. Planning precedes warmup and measured CPU
accounting. Later inputs and producer scheduling are unchanged. There is one
attempt, with no retry or retrospective choice of a favorable bucket phase.
The receipt records the native-clock deadline and predicted clearance; the driver
requires delivery at or after the deadline with lateness no greater than half
that clearance. The original actual-publication count gate remains unchanged:
5% in every complete 500 ms window across all four streams, including warmup.

All 17 focused tests pass. The native C phase planner matches an independent
circular-gap reference over 2,050 deterministic cases and rejects malformed
publication records and invalid clocks. The initial functional qualification
completes 40 switches in each stack, with first-input lateness of 1.007/0.516 ms
for Zig/C++. Wrong-tab, stale-generation and bad-checksum controls still reject
the first incorrect response in both stacks. Source, commands and qualification
receipts are under `out-perf/dlls-tab-switch-phase-start-01`.

The first complete six-pair attempt passes all 12 native phase/content/rate and
cleanup checks, but its final host boundary has load1 6.588867 against the frozen
limit of 5. The entire `/tmp/telar-perf-tab-switch-phase-start-pairs-01` series is
discarded; no earlier quiet pair is reused. A new complete six-pair series,
`...-pairs-02`, passes all 26 host boundaries, maximum load1 4.013672. Frozen
source hashes remain unchanged and all owned runtime/child cleanup succeeds.
First-input lateness ranges from 0.139 to 1.138 ms, with predicted clearance from
5.732 to 10.618 ms. All invalid earlier series remain invalid.

The qualified baseline uses accepted GUI `a88e53a8`, runtime `1f1849d1`, command
helper `87beebb0` and independent Zig `6ccf7948`. Each of the six alternating pairs
has 100 measured switches after 20 warmups, four 30 Hz producers, matching
1600×1000 backing pixels and 82×21 cells, opaque appearance, the existing optical
font policy, and floated owned windows. Medians of the six run summaries:

| Metric | Zig stack | C++ stack | C++ wins |
| --- | ---: | ---: | ---: |
| p50 latency, ms | 37.103 | 44.083 | 0/6 |
| p95 latency, ms | 41.129 | 49.213 | 0/6 |
| p99 latency, ms | 41.814 | 49.310 | 0/6 |
| Maximum latency, ms | 41.991 | 49.754 | 0/6 |
| GUI CPU, ms/action | 18.045 | 30.382 | 0/6 |

This establishes a current discrete-switch deficit, not F08 completion. Runtime
CPU accounting, workspace switching, complete animated content equivalence,
observer perturbation and continuous native120 remain open. The initial phase
policy is explicit and differs from older runs; it is not a Telar optimization.

The next private candidate is `out-perf/dlls-tab-presentation-objects-01`.
Its presentation model retains at most 64 active QObject records, publishes
typed geometry independently of tab content, and materializes the complete old
record map only when requested. The old record role and notifications remain
available to legacy readers. The oracle fails before the missing implementation
and then passes 2,048 randomized legacy-map/model-notification snapshots under
ASan/UBSan, plus persistent-index, content/geometry isolation, retirement and
capacity rejection checks. A real QML model delegate receives 240 geometry
updates without rebinding content; a semantic change notifies once. Qt dependency
libraries are not sanitizer-instrumented. A further live-delegate oracle catches
null-property reads and a surviving delegate during immediate row/model teardown.
The private correction removes model rows while readers are still valid, then
defers detached QObject destruction until Qt can retire its delegates. Both row
removal and model destruction now pass without QML warnings under ASan/UBSan.
The active-row bound does not include transient deferred deletions; their peak
must be measured separately. These are private component results,
not accepted production or native application performance. The earlier rejected
role and pane-retention variants remain rejected. The unlimited goal remains
active with the complete flow, visual and native120 requirements still open.

## 2026-11-04: stable tab QObject presentations rejected on native latency

The `dlls-tab-presentation-objects-01` candidate was integrated temporarily on
`f9082686e`, preserving the unrelated dirty runtime pacing work. It separates
semantic tab content from typed geometry on stable QObjects. Animated geometry
updates avoid rebuilding the positioned nine-field QVariantMap and rebinding
unchanged content. The complete legacy `record` role remains available lazily.
It does not cache hidden pane surfaces or remove caption measurement, and does
not reinstate the previously rejected field/scalar-role candidates.

The configured Release GUI, Qt 6.12 and LLVM 23.1.4 on this M1 Pro/macOS 26.6.2
produced candidate GUI `e4aea9301639238e9a24f1531aea5f4c687304b6a060a1cdeea4c06c39576804`.
Accepted A remains `a88e53a81bbf7d96e8547f9a92e1b2be2d98e9bfddd1c69095422ab330ec37c8`;
both use runtime `1f1849d1881fe60af13d46531c6f722fb5105f32fc8beaaadf7276ad50f55031`
and helper `87beebb065f0ea4274492eaadecea2ccef7cdedc28f36049bf61ecc21214924f`.
Source copies, hashes, original QML timestamps, commands and rejected binaries
remain in the ignored experiment prefix. No runtime source was changed.

Validation before timing:

- The private ASan/UBSan randomized map/model and live QML retirement oracles
  passed; dependency libraries remain uninstrumented. The integrated Qt test,
  chrome test and tab activity scene test passed. Focused changed-source
  clang-tidy passed after correcting four diagnostics.
- Seventeen Cocoa/Metal functional cases passed: switching, viewport, workspace
  visibility, close/split, drag cancellation/reordering, palettes, nested splits,
  fullscreen strip, configuration ownership/reload and native window reopen.
  The first reopen run failed because the private controller acknowledged only
  the initial native window ID. Cocoa recreated it on show. A controller that
  continues acknowledging newly observed windows owned by the same test PID
  passes with unchanged product/test code; both receipts remain archived.
- Settled complete 1600x1000 captures are byte-exact A/B for a single pane,
  four splits and four tabs. This is not animated equivalence or native120
  acceptance. Instrumented QML checks verify 240 geometry changes do not rebind
  content; one semantic change notifies once.
- ARM64 disassembly of both rebuild functions and candidate reconcile/update
  was inspected. The candidate publishes typed geometry and individual signals;
  semantic map comparison, key lookup and allocation on insertion remain.
  This is not an instruction-count or cross-platform performance claim.

`/tmp/telar-perf-tab-presentation-pairs-01` contains six alternating native
A/B pairs, 100 measured plus 20 warmup inputs each, four independent 30 Hz
producers, the qualified first-input phase policy, opaque matched font/config,
1600x1000 backing pixels and an 82x21 terminal grid. All twelve target/content,
publication-rate, initial phase and owned-runtime cleanup checks passed.
All 26 host boundaries qualified; maximum one-minute load was 4.03125, below
5. No owned builds, functional tests or profiles ran during this series.
Frozen binaries and source hashes were rechecked unchanged afterward.

| Metric | Accepted A median | Candidate B median | B wins |
|---|---:|---:|---:|
| p50, ms | 43.225 | 45.315 | 2/6 |
| p95, ms | 49.198 | 49.166 | 2/6 |
| p99, ms | 49.357 | 49.522 | 3/6 |
| maximum, ms | 52.457 | 49.891 | 6/6 |
| GUI CPU, ms/action | 30.290 | 28.637 | 5/6 |
| GUI lifetime peak RSS, MiB | 192.086 | 204.297 | 3/6 lower |

**Rejected:** the predeclared target requires at least 5/6 wins in both GUI CPU
and p95. CPU passes, p95 does not. The near-equal median p95 cannot substitute
for paired consistency. The latency outcome's cause is not established.
The observed memory increase is not the reason for rejection. RSS is process
peak memory, not summed GUI/runtime memory; runtime CPU accounting remains open.
No extra typing-regression or independent Zig timing was run after this failed
target. Linux/x86 GUI checks and a separate peak census of deferred retired
QObjects also remain unperformed; no acceptance depends on them.

A separate eight-second, 1 ms interval A/B `sample` diagnosis covers 91/88
switches; both 240-action diagnostic workloads pass content/rate/phase checks.
Those timings are excluded from acceptance. Inclusive main-thread observations,
with nested repeats removed within each category, are: tab rebuild 198/98,
QML var writes 79/30, variant associations 60/29 and QML binding update 137/77.
Caption measurement remains 20/25. Categories overlap and include observer/wait
samples; these are neither allocation counts nor CPU percentages. The profile
is consistent with less tab/QML work but does not explain the p95 outcome.

The rejected implementation and its tests are preserved privately; production
source is restored, and rebuilding after regenerating the stale raw QML resource
reproduces accepted GUI hash `a88e53a8` byte exactly. The restored chrome and tab
activity scene tests pass. The unlimited goal stays active. Full F01-F16, independent
complete-stack wins and continuous native120 remain open. This experiment narrows
the allocation/conversion hypothesis without promoting it to a universal cause.

## Single unframed pane rebinding: target wins, split tails reject, 2026-11-04

The new experiment on `e0981f756` reuses the sole visible, unframed pane delegate
across pane identity changes, using existing positional `ListModel::replaceRows`.
All multi-pane and framed transitions retain keyed reconciliation. It avoids
reconstructing the terminal/header QML tree without retaining hidden pane objects
or reinstating the earlier pane cache. The visible count and existing global
image/glyph limits remain unchanged; longer resource lifetimes are not a claim
of zero memory cost. The original five source files, their timestamps, all failed
controls and withdrawn candidate are in `out-perf/dlls-single-pane-rebind-01`.

Accepted A GUI is `a88e53a81bbf7d96e8547f9a92e1b2be2d98e9bfddd1c69095422ab330ec37c8`.
Final B is `288a5a036dc483b90809cb01de0aaa33da3df115fdb2bda2774785b9eed5a6d6`.
Both use runtime `1f1849d1881fe60af13d46531c6f722fb5105f32fc8beaaadf7276ad50f55031`
and helper `87beebb065f0ea4274492eaadecea2ccef7cdedc28f36049bf61ecc21214924f`.
The Release toolchain remains LLVM 23.1.4/Qt 6.12 on M1 Pro/macOS 26.6.2.
No runtime source or unrelated pacing changes were modified.

The original native viewport test fails the added delegate-identity oracle before
implementation. A direct composition test also fails: `setPaneId` retains the old
preedit. The candidate clears preedit/pointer state, retires old input ownership
and resets keyboard focus before rebinding. A byte-exact PTY test verifies that a
held Kitty key is released to the old pane, its later physical release does not
leak into the new pane, and the new pane receives its own complete key sequence.
Its first setup attempted to configure the previous pane; the corrected fixture
waits for the newly created pane's identity before sending its capture command.

Focus coverage exposed two more lifecycle requirements before timing:

- The runtime's mode-enable focus reply must be captured separately from the
  departure/return reports. After isolating it, only three of the expected six
  transition bytes arrive. Source inspection finds that `Application::input`
  rejects reports while the pane is unattached, while `synchronizeFocus` has
  already updated its local keyboard state. Requiring attachment before that
  focus transition makes the exact `ESC[O ESC[I` oracle pass. Earlier binaries
  and both failing receipts remain archived; this does not establish whether the
  original accepted GUI also exhibits this focus issue.
- A retained delegate does not run `Component.onCompleted` again. Opening a tab
  while another chrome item owns focus therefore fails a new native focus oracle.
  Invoking the existing focus policy on `paneIdChanged`, after initial completion,
  restores the behavior and passes the oracle.

Final source passes 28 distinct Cocoa/Metal Quick cases and the rebuilt chrome,
software graphics-retention scene and machine-window component tests. Coverage
includes viewport, focus, held input, copy, links, images, close/split/fullscreen,
configuration, stale frames and window reopening. A requested custom link-host
case is not compiled into this configuration and is explicitly unexecuted.
Focused production/test clang-tidy passes after six test-style corrections.
Complete settled 1600x1000 A/B PNGs match byte exactly for single, four-split and
four-tab layouts. None of these checks establishes continuous animated/native120
parity. Final ARM64 disassembly confirms the positional/keyed branches and the
additional attached-state load/branch in focus synchronization; no cross-target
GUI execution or code-placement exemption is claimed.

`/tmp/telar-perf-single-pane-rebind-pairs-01` contains six alternating F08 target
pairs, 100 measured plus 20 warmup inputs, four independent 30 Hz producers,
matched 82x21 grids, working directory, opaque configuration and qualified initial
phase. All target/content/rate/phase/cleanup checks pass. All 26 host boundaries
qualify, maximum one-minute load 3.1181640625; source and binaries remain frozen.
Median per-run results:

| Metric | Accepted A | Candidate B | B wins |
|---|---:|---:|---:|
| p50, ms | 42.905 | 38.187 | 6/6 |
| p95, ms | 48.488 | 42.562 | 6/6 |
| p99, ms | 49.228 | 43.582 | 6/6 |
| maximum, ms | 49.584 | 43.945 | 6/6 |
| GUI CPU, ms/action | 29.959 | 27.145 | 5/6 |
| GUI lifetime peak RSS, MiB | 205.969 | 203.500 | 3/6 lower |

The independent typing controls in
`/tmp/telar-perf-single-pane-rebind-regressions-01` contain six alternating pairs
per layout and 100 measured inputs per run. All 50 host boundaries qualify,
maximum load 3.181640625; all 24 owned-runtime cleanups complete. No owned
builds/tests/profiles overlap either headline series.

| Typing metric | Single A → B (wins) | Four splits A → B (wins) |
|---|---|---|
| p50, ms | 25.579 → 25.270 (4/6) | 26.021 → 25.644 (4/6) |
| p95, ms | 33.139 → 32.809 (3/6) | 32.151 → 33.867 (1/6) |
| p99, ms | 36.697 → 36.313 (3/6) | 34.937 → 36.710 (1/6) |
| maximum, ms | 37.286 → 39.352 (2/6) | 41.653 → 40.063 (3/6) |
| GUI CPU, ms/input | 4.071 → 3.953 (4/6) | 4.220 → 4.233 (4/6) |

**Rejected:** target CPU/p95 pass, but four-split p95 and p99 each win only 1/6.
The tail cause remains unestablished. No favorable target/median or memory result
overrides that gate, and no new independent Zig timing is justified for adoption
of this rejected source. Runtime resource accounting remains open for these runs.

Separate eight-second sampling overlaps 93 A and 94 B switches; both diagnostic
240-action workloads qualify. Inclusive main-thread observations are QML
construction 31/1, pane refresh 124/16, tab rebuild 188/393 and QML var writes
100/155. Categories overlap and exclude nested repeats only within each category;
these are not allocation counts or CPU percentages. They support avoided pane
construction, while exposing remaining tab work; they do not explain split tails.
Instrumented timings are excluded from acceptance.

Before retrying this mechanism, isolate rebind-only deferred focus delivery from
the new attached-state check in steady focus synchronization. A one-shot callback
retired on identity change/attachment could preserve the original steady path,
but is only a proposed experiment: it is not an established regression fix and
must pass the same ownership and native performance controls. The current candidate
is withdrawn. The unlimited goal remains active; all complete-flow and native120
acceptance stays open.

Restoration verifies all five source hashes against the frozen originals.
Regenerating both the raw QML resource and stale PaneArea AOT cache reproduces
accepted GUI `a88e53a8` byte exactly; restoring the older source timestamp alone
did not invalidate the candidate AOT cache. The restored three component tests
and native viewport/tab-palette cases pass. Both diagnostic runtime cleanups
complete. The receipt is `out-perf/dlls-single-pane-rebind-01/restoration.json`.

## Transition-only focus eligibility: typing regression rejects, 2026-11-04

On `aaa493981`, a new isolated variant keeps the previous single-unframed-pane
reuse but moves attachment eligibility inside the keyboard-focus transition.
It adds no callback, retained hidden delegate or new per-frame state. ARM64
inspection confirms that the equal-focus path skips the attachment load; this
removes that specific additional steady-path operation, not all possible causes
of the previous typing regression. Original A remains GUI `a88e53a8`, runtime
`1f1849d1`, helper `87beebb0`. New B GUI is
`3e88033b7b5b4e4d72cbbd40c46532011d3c8706005be41dbdff1e8fa5589523`.
The source, contract and full hashes are in `out-perf/dlls-pane-transition-focus-01`.

Thirty distinct Cocoa/Metal Quick cases pass. A new focus test explicitly checks
unattached/attached state, and the byte-exact PTY focus oracle now ends with a
sentinel so an extra report cannot hide behind a fixed-length read. Three rebuilt
component cases, focused production/test clang-tidy and settled full-PNG equality
for single/splits/tabs also pass. One native runner stalls in its AeroSpace query
after the test has exited successfully: only that owned query is terminated, the
query gets a five-second timeout, and the remaining cases run to completion. No
timing overlaps these checks. No x86/Linux GUI run or placement exception is claimed.

Six alternating target pairs in `/tmp/telar-perf-pane-transition-focus-pairs-01`
pass content, producer rate, initial phase and cleanup checks, with 100 measured
and 20 warmup actions per run. All 26 host boundaries qualify, maximum load
3.1865234375. Median per-run results:

| Target metric | A | B | B wins |
|---|---:|---:|---:|
| p50, ms | 41.917 | 38.114 | 5/6 |
| p95, ms | 47.865 | 43.171 | 6/6 |
| p99, ms | 49.301 | 44.561 | 6/6 |
| maximum, ms | 49.421 | 44.692 | 5/6 |
| GUI CPU, ms/action | 28.942 | 27.414 | 5/6 |
| GUI lifetime peak RSS, MiB | 191.773 | 204.008 | 1/6 lower |

Typing series `...-regressions-01` is discarded in full when load reaches
5.30322265625 after its ninth run; all nine owned runtimes clean up. None of its
rows is salvaged. The complete restart in
`/tmp/telar-perf-pane-transition-focus-regressions-02` qualifies all 50 host
boundaries, maximum load 3.5966796875, and all 24 cleanups. Its medians are:

| Typing metric | Single A → B (wins) | Four splits A → B (wins) |
|---|---|---|
| p50, ms | 24.905 → 25.075 (1/6) | 25.717 → 25.102 (4/6) |
| p95, ms | 33.138 → 32.905 (3/6) | 32.898 → 33.154 (2/6) |
| p99, ms | 34.774 → 34.663 (4/6) | 35.029 → 36.407 (2/6) |
| maximum, ms | 39.972 → 37.230 (4/6) | 37.636 → 39.096 (2/6) |
| GUI CPU, ms/input | 3.840 → 4.225 (1/6) | 3.996 → 4.169 (2/6) |

Existing native runtime resource capture is reused outside the input/presentation
interval: its 11 tests pass and a native self-CPU check agrees with getrusage at a
1.0068 ratio. Runtime CPU brackets GUI startup, warmup and measurement, excluding
runtime startup/shutdown and child CPU; it is not summed with the narrower GUI
interval. Target runtime CPU is 394.209 → 400.052 ms/run (3/6); single typing is
83.091 → 87.870 (2/6), and splits 96.618 → 99.444 (1/6). Target final runtime
footprint is 19.039 → 19.164 MiB; snapshots and lifetime footprint maxima are
retained separately from GUI lifetime RSS. Shared memory is not summed. Observer
source/helper hashes, identities, timebase and raw receipts are preserved.

**Rejected:** single typing CPU and p50 each win only 1/6; split runtime CPU also
wins only 1/6 over its broader interval. The roughly 12 MiB target GUI memory
increase is not the rejection reason. Removing the steady attachment read does
not make this reuse variant acceptable, and the regression cause remains
unestablished. No independent Zig timing is used to promote this rejected source.

A separate next candidate may reuse bounded caption measurements when label,
font and display scale are unchanged, starting from accepted source. Existing
code reshapes the same labels on every tab-layout rebuild. Earlier gesture
instrumentation attributes only about 8.5–8.9% of rebuild time to caption
measurement, so it cannot explain most tab work and is not a promised large win.
No caption cache is implemented here. Full F01–F16 and continuous native120
acceptance remain open; the unlimited goal stays active.

All five production/test source files are restored to their original hashes.
Regenerating the raw QML resource and PaneArea AOT cache reproduces accepted GUI
`a88e53a8` byte exactly. The restored three component tests and two native
viewport/tab-palette checks pass; `restoration.json` records the final state.

## Bounded caption measurement cache: work avoided, target rejected, 2026-11-04

A separate experiment on `15c6e9b5a` starts from accepted GUI `a88e53a8` and
runtime `1f1849d1`, without any withdrawn pane/model variant. It keeps one caption
measurement per existing tab slot (maximum 64), keyed by exact text and display
scale, and clears entries on font/pixel-size/model/context changes. Only successful
bundled-font measurements are cached; fallback font measurements remain fresh.
Labels longer than 4096 UTF-16 code units are measured fully and left uncached.
Retained strings are compact copies, so a short QString with a large reserved
backing allocation cannot defeat the bound. This uses up to 512 KiB of label data
plus 64 entries/allocator overhead, rather than retaining arbitrary label storage.
Full source/binaries/contracts are in `out-perf/dlls-tab-caption-cache-01`.
B GUI is `e3a08dead9648a7d4dd63b333be704ea6aece6f547a36704a4fc964baffb03fb`.

A fresh-instance oracle is prepared before caching, then passes with caching
across all 64 slots, repeated/renamed/empty/long labels, combining sequences,
Arabic/CJK/emoji, regular/bold fonts, two pixel sizes and five scale transitions.
A separate capacity test checks oversized QString reserves, uncached long labels,
font-size invalidation and uncached CJK fallback. Fifteen native Cocoa/Metal cases
pass on final production code; rebuilt chrome/tab-activity scene tests and full
settled PNG equality for single/splits/tabs also pass. Focused clang-tidy passes
after new nesting, parameter-order and test-constant corrections. An unchanged
101-line rebuild warning is recorded and excluded from the changed-line scope.
No x86/Linux GUI execution or placement exemption is claimed.

A private instrumented B run with 100 actions passes target content, generation,
checksum, offered-rate and initial-phase checks. Across GUI lifetime including
startup and warmup, it counts 6098 caption requests: 6089 hits, 9 conversions and 9
shaping calls, with no fallback. These are operation counts, not allocation
counts or timing evidence. ARM64 disassembly confirms that a hit checks occupancy,
scale and exact QString equality before loading the saved float and returning
without conversion/coverage/shaping. After this diagnosis, the configured GUI is
rebuilt without counters and matches frozen B byte exactly before timed runs.

`/tmp/telar-perf-tab-caption-cache-pairs-01` contains six alternating native pairs,
100 measured plus 20 warmup actions, four independent 30 Hz producers and matched
82x21 grids. All 26 host boundaries qualify, maximum load 4.05126953125; every
content/rate/phase and runtime-cleanup check passes. Source and binaries remain
frozen, with no owned build/test/profile overlap. Median per-run results:

| Target metric | A | B | B wins |
|---|---:|---:|---:|
| p50, ms | 42.278 | 44.829 | 2/6 |
| p95, ms | 48.484 | 48.293 | 2/6 |
| p99, ms | 49.178 | 49.192 | 3/6 |
| maximum, ms | 49.587 | 49.290 | 3/6 |
| GUI CPU, ms/action | 29.066 | 30.171 | 2/6 |
| GUI lifetime peak RSS, MiB | 200.664 | 193.555 | 3/6 lower |

Separate runtime counters bracket GUI startup/warmup/measurement and exclude child
CPU. Runtime CPU is 379.437 → 402.966 ms/run (1/6), and final footprint is 18.454 →
18.766 MiB (1/6 lower). Neither this broader interval nor memory snapshots are
summed with GUI measurement CPU or lifetime RSS. Their raw identities, timebase,
source hashes and qualified existing resource observer are retained.

**Rejected:** target GUI CPU and p95 each win 2/6 instead of the required 5/6.
Avoided shaping is proven but whole-flow improvement is not; the cause of the
CPU/latency outcome remains unestablished. No additional typing or independent
Zig adoption series is run for this rejected source. The next diagnostic counts
baseline rebuilds without intervening input invalidation, to assess whether
reusing an entire layout plan during animation could avoid more work. This is a
new hypothesis, not acceptance of this caption-only cache. Full F01–F16 and
continuous native120 remain open; the unlimited goal stays active.

The independent baseline diagnostic subsequently qualifies 100 actions and counts
1565 rebuilds, of which 1428 follow no intervening source-input polish request;
278 input-invalidating requests and 5990 caption calls occur across its full GUI
lifetime. Animation sampling/afterAnimating polish requests intentionally do not
mark the input dirty. This is notification-based classification, not proof that
external font-catalog changes are covered. The record is `baseline-census.json`
and `/tmp/telar-perf-tab-layout-invalidation-census-01`; all diagnostic timing is
excluded and the owned runtime cleanup completes. About 91% of rebuilds therefore
offer a concrete next investigation into reusing layout inputs during animation,
with explicit model/font/scale/drag/context invalidation and visual oracles.

Restoration verifies all three original source hashes and reproduces accepted
GUI `a88e53a8` byte exactly. Restored chrome/tab-activity scene tests and native
viewport/tab-drag cases pass. The final receipt is `restoration.json`; unrelated
runtime pacing work remains untouched.

## Reusing tab layout plans: work avoided, target rejected, 2026-11-04

An isolated experiment on `e9c077cc0` starts from accepted GUI `a88e53a8` and
runtime `1f1849d1`. It retains the current projected records, measurements and
packing plan across animation-only rebuilds. Model, font/catalog, display scale,
geometry, hover, drag and context changes invalidate the plan. The next rebuild
replaces the snapshot; invalid geometry clears it. Storage holds at most 64
records and fixed measurement/plan arrays, with no historical generations. The
record-count bound is not a fixed byte bound on arbitrary source strings/maps.
Motion sampling, positioned records, drop targets and publication still run on
every frame. Neither rejected caption-only caching nor pane retention is included.
Source, contracts and binaries are in `out-perf/dlls-tab-layout-plan-01`; final B
GUI is `b4be2399aa235e58557bd0239e215fbb26cb04e236585819b8408edd0f42e73a`.

A counting-model oracle first fails on the original repeated reads, then passes
with reuse. A new read-exception oracle catches a real prototype retry bug;
refresh now restores dirty state on exceptions. Reentrant invalidation and
external-input checks pass. A differential oracle compares 450 complete animated
snapshots against forced fresh plans at synthetic approximately 120 Hz, covering
rename/Unicode, reorder, font/scale, resizing, hover, drag, context, replacement,
destruction and the 65-source-row clamp. This proves geometry/model equivalence,
not native120 cadence. Two rebuilt component tests, fifteen native Cocoa/Metal
cases, full settled single/splits/tabs PNG equality and focused clang-tidy pass.

ARM64 inspection finds an initial helper allocated a 0x5f0-byte stack frame even
on hits. Final code tests dirty state/density in rebuild and calls the refresh
helper only on misses. Rebuild itself still allocates 0x600 bytes; this is not
zero stack work. No target-specific construct or placement exemption is used,
and no x86/Linux GUI execution is claimed.

An instrumented final-variant census qualifies 100 actions and runtime cleanup.
Across GUI lifetime including startup/warmup it counts 1569 rebuilds/requests,
136 measurement passes and 514 caption calls: 1433 plans reused, about 91%.
These are work counts, not allocations or performance evidence. All diagnostic
timing is excluded; removing instrumentation reproduces frozen B byte exactly.

`/tmp/telar-perf-tab-layout-plan-pairs-01` contains six alternating native pairs,
100 measured plus 20 warmup actions and four independent 30 Hz producers.
All 26 host boundaries qualify, maximum load 3.21923828125; content, generation,
checksum, offered-rate, phase, grid and runtime-cleanup checks pass. No owned
build/test/profile overlaps this series. Median per-run results:

| Target metric | A | B | B wins |
|---|---:|---:|---:|
| p50, ms | 44.221 | 41.866 | 5/6 |
| p95, ms | 49.199 | 48.607 | 4/6 |
| p99, ms | 49.302 | 49.264 | 4/6 |
| maximum, ms | 49.641 | 49.284 | 4/6 |
| GUI CPU, ms/action | 30.527 | 29.895 | 4/6 |
| GUI lifetime peak RSS, MiB | 202.633 | 205.148 | 2/6 lower |

Separate runtime counters cover GUI startup/warmup/measurement and exclude child
CPU. Runtime CPU is 411.737 -> 411.752 ms/run (2/6); final footprint is 18.665 ->
18.774 MiB (3/6 lower). This broader CPU interval and boundary memory snapshots
are not combined with GUI measured-input CPU or lifetime RSS.

**Rejected:** target CPU and p95 each win 4/6, below the predeclared 5/6 threshold.
The modest memory increase is not the rejection reason. Avoiding most measurement
passes does not establish a sufficiently repeatable complete-flow win. No typing
or independent Zig adoption series is run for this rejected source. A separate
sampling diagnosis investigates the remaining work without using its timing for
acceptance. All F01–F16 and continuous native120 acceptance remain open; the
unlimited goal stays active.

All three production/test files are restored to their original hashes, and the
configured GUI reproduces accepted `a88e53a8` byte exactly. Restored chrome and
tab-activity scene tests plus native viewport/tab-drag checks pass. The receipt is
`restoration.json`; unrelated runtime pacing work remains untouched.

The subsequent eight-second, 1 ms sampling diagnosis covers 95 A and 89 B
switches; both 240-action workloads qualify content/rate/phase and owned-runtime
cleanup. Inclusive main-thread observations are 5863/5848 in total, tab rebuild
209/183, measurements 28/3, caption measurement 22/2, list reconciliation 285/260,
QML var writes 110/103 and variant associations 72/71. Nested repeats are excluded
within each category; categories overlap and include waits/observer work, so these
are not CPU percentages or allocation counts. Direct rebuild children account
for 161/154 reconciliation observations and 14/18 signal-activation observations.
This supports looking beyond measurement reuse: publication remains substantial,
whereas the global layout notification alone has smaller sampled weight. It does
not establish the latency cause or reinstate the rejected typed-object/role
variants. Raw stacks and qualified receipts are in
`/tmp/telar-perf-tab-layout-plan-profile-01`, with `profile-census.json` in the
experiment prefix. All diagnostic timing remains excluded from acceptance.

## Direct QML tab-record reads rejected on tails, 2026-11-04

On `cd498c935`, `out-perf/dlls-tab-direct-record-01` isolates removal of the
intermediate `readonly property var source: record.tab` in TerminalTabs. Bindings
and actions read `record.tab` directly. The original model, positioned maps,
measurements and animation remain unchanged; no rejected cache/role/QObject
variant is included. Accepted GUI/runtime are `a88e53a8`/`1f1849d1`; B GUI is
`c76bd97800b075741de255ccbd30219d08aa6244b0e3c1fc28079cc03c4f6cb4`.

The local Qt 6.12 source and ARM64 disassembly verify that `writeVarProperty`
detaches association values. The detach path allocates a new JavaScript wrapper
and, for detached input, converts the JS object back into a QVariantMap. Removing
one assignment avoids that intermediate representation but adds direct nested-map
lookups; it does not remove all conversions or establish allocation counts.
No target-specific construct is added; Linux/x86 GUI execution is not claimed.

Before modifying production QML, a live-delegate oracle passes on A. It also
passes on B through 40 record changes, Unicode captions, selection, bounds,
complete activity records, prefix numbers, accessibility names/selection, left
and middle click identities, removal/reinsertion and zero QML warnings. The two
component suites, fifteen native Cocoa/Metal cases and full settled PNG equality
for single/splits/tabs pass. Focused clang-tidy passes after adding a missing
direct accessibility header. Animated pixel/native120 acceptance is not claimed.

A separate eight-second, 1 ms sampling diagnosis covers 90/92 A/B switches; both
240-action runs qualify content/rate/phase and cleanup. Main-thread observations
are 5883/5872; QML var-write observations fall 92 -> 45, while association
observations rise 61 -> 82, tab rebuild 210 -> 268 and reconciliation 287 -> 310.
Categories overlap, exclude nested repeats and include waits/observer effects.
They are not CPU percentages or allocation counts, and do not prove the cause of
the measured regression. All profile timing is excluded from acceptance.

`/tmp/telar-perf-tab-direct-record-pairs-01` contains six alternating pairs,
100 measured plus 20 warmup switches and four independent 30 Hz producers. All
26 host boundaries qualify, maximum load1 4.15234375, with no owned builds/tests/
profiles overlapping. Content, generation, checksum, phase, rate, geometry and
all twelve owned-runtime cleanup checks pass. Median per-run results:

| Target metric | A | B | B wins |
|---|---:|---:|---:|
| p50, ms | 42.791 | 42.574 | 3/6 |
| p95, ms | 47.843 | 49.074 | 1/6 |
| p99, ms | 49.189 | 49.331 | 1/6 |
| maximum, ms | 49.321 | 49.899 | 1/6 |
| GUI CPU, ms/action | 30.132 | 30.019 | 3/6 |
| GUI lifetime peak RSS, MiB | 198.406 | 204.633 | 2/6 lower |

The separate runtime startup/warmup/measurement interval, excluding child CPU,
records CPU 411.155 -> 411.999 ms/run (3/6) and final footprint 18.610 -> 18.422 MiB
(4/6 lower). These scopes are not summed with GUI measured CPU/lifetime RSS.

**Rejected:** CPU and p95 miss the predeclared 5/6 requirement, and p95/p99/maximum
each show a consistent 1/6 loss. Memory is not the rejection reason. No further
typing or independent Zig adoption series is run. Original QML/test hashes are
restored; regenerating both raw resources and TerminalTabs AOT output with the
original QML timestamp reproduces accepted GUI `a88e53a8` exactly. Restored two
component and two native viewport/drag checks pass (`restoration.json`). Unrelated
runtime pacing work is untouched. All F01–F16/native120 acceptance remains open.

## Offline decomposition of qualified tab-switch observations

`stage_samples()` in [tab_switch_report.py](../tools/tab_switch_report.py) now
separates existing per-input completion-callback and presentation observations,
after excluding warmup and cross-checking relative and absolute presentation
times. Eight report tests pass, including mismatched/missing arrays, invalid
durations, warmup bounds and late callbacks. Presentation minus callback remains
signed: a delayed callback does not imply that physical presentation waited for
it. GPU execution is a separate overlapping interval; stage quantiles must not
be added. This helper does not replace native/producer/host qualification or
alter the input/presentation observer or acceptance gates.

`out-perf/dlls-tab-switch-stages-01` rechecks all 24 original rows, their
content/rate/phase, native timing identities, host eligibility and cleanup, then
decomposes the independent baseline and the direct-record experiment above.
This is analysis of existing evidence, not a newly measured baseline. For the
independent `/tmp/telar-perf-tab-switch-phase-start-pairs-02` series:

| Median of per-run stage p50, ms | Zig | Accepted C++ | C++ lower pairs |
|---|---:|---:|---:|
| Input to completion callback | 9.403 | 13.463 | 0/6 |
| Presentation minus callback | 26.313 | 31.499 | 0/6 |
| GPU execution, overlapping interval | 1.123 | 0.321 | 5/6 |
| Input to positive presentation | 37.103 | 44.083 | 0/6 |

The direct-record candidate's input-to-callback p50 improves 5/6, but p99 and
maximum each improve only 1/6, matching a remaining tail problem before callback
completion. Its presentation-minus-callback p50 is 31.381 -> 31.425 ms (3/6).
These observations do not establish IPC, CPU, GPU queueing or display scheduling
as the cause. They motivate tracing the switch from attachment response through
frame preparation/submission, rather than another unqualified map-copy change.
Earlier drawable-pool/render-loop experiments remain rejected/unaccepted and are
not reinstated. The unlimited objective stays active.

## Tab-switch attachment and drawable timeline, 2026-11-04

`out-perf/dlls-tab-switch-timeline-01` starts from `03ddf5620` and accepted GUI
`a88e53a8`/runtime `1f1849d1`. Private instrumentation adds a bounded 65,536-event
buffer to three GUI translation units: navigation/model refresh, socket delivery,
frame preparation and terminal painting. Slots publish atomically and dump only
at process exit. The first build catches integer narrowing in the diagnostic
scope arguments; explicit conversions correct it. A refinement records actual
pane/frame identities, avoiding attribution of a previous pane's pending message
to the new target. The header parser matches real Codec-encoded PaneOpened and
PaneFrame messages under ASan/UBSan, including truncated-prefix controls.

The native observer additionally records commit, GPU start/end and completion
callback times on the same drawable whose tab/generation/checksum and positive
presentation are accepted. A commit counter rejects ambiguous multiple
submissions. The diagnostic builder is now reusable as
`python3 tools/build_tab_switch_timeline.py NEW_DIRECTORY`; its
`timeline-probe.dylib` is explicitly diagnostic. The ordinary probe remains
unchanged. Canonical generated native source matches the tested private source
exactly; both probes compile, and four incompatible-source controls fail closed.
No existing headline observer or endpoint is changed.

Final instrumented GUI is
`fb038d41af1349c4132c312d0087bade0e9787fa51dd3443f625f316ee24014c`.
Before running it, all three working production files are restored to their
original hashes and the configured GUI is rebuilt byte-exactly to `a88e53a8`.
Independent Zig remains `6ccf7948`; its source inputs are rechecked unchanged
against build HEAD `5c619b85c`. Unrelated runtime work is untouched.

`/tmp/telar-perf-tab-switch-timeline-01` runs 100 measured plus 20 warmup switches
per stack, four independent 30 Hz producers, matched 1600x1000 viewports/82x21
grids. Both content/rate/phase and cleanup gates pass. All six host boundaries
qualify, maximum load1 2.33984375. C++ records 16,901 events without overflow or
unpublished slots. Clock brackets before/after each run contain zero offset
between CLOCK_UPTIME_RAW and CACurrentMediaTime and are narrower than 210 ns.
Every accepted drawable has one commit and ordered native timestamps. All 120
C++ samples correlate selection, OpenPane queueing, PaneOpened, the exact received
frame ID, scene painting/preparation and that drawable's commit. Per-input stage
sums reproduce the full presentation interval; warmup is excluded below.

| C++ diagnostic stage | Mean, ms | p50, ms | p95, ms |
|---|---:|---:|---:|
| Input to OpenPane queued | 0.815 | 0.449 | 2.153 |
| OpenPane queued to PaneOpened delivery | 3.277 | 2.364 | 6.463 |
| PaneOpened to matching frame received | 0.121 | 0.063 | 0.274 |
| Frame dispatch including synchronous subscribers | 0.033 | 0.031 | 0.042 |
| Dispatch complete to paint start | 4.255 | 4.047 | 7.542 |
| Terminal scene paint | 0.584 | 0.723 | 0.906 |
| Paint end to drawable commit | 0.788 | 0.831 | 1.265 |
| Commit to GPU start | 0.270 | 0.188 | 0.716 |
| GPU execution | 3.443 | 4.533 | 6.007 |
| GPU end to positive presentation | 26.411 | 24.914 | 31.823 |

These instrumented single-run observations are not an A/B performance result,
CPU attribution or native120 acceptance. Stage quantiles cannot be added. Zig's
separate mean input-to-commit/GPU-execution/GPU-end-to-presentation intervals are
8.692/1.052/28.475 ms; C++ is 9.874/3.443/26.411 ms. This does not establish a
universal Qt presentation penalty or supersede the six-pair independent baseline.

Within C++'s queue-to-opened interval, the first post-queue `bytesWritten`
notification occurs after mean 2.701 ms (median 2.234); the remaining mean time to
PaneOpened delivery is 0.577 ms (median 0.091). That notification covers a batch,
not an OpenPane-specific syscall; pending queue size at enqueue is 0 or 13 bytes.
Inclusive pane-refresh scopes before PaneOpened total mean 1.999 ms. Thirty-three
of 100 measured switches prepare a frame before the attachment reply arrives.
After target-frame dispatch, 43 switches encounter an explicit frame-pacer hold.
These observations identify two scheduling leads without proving their causes.

The strict correlation analyzer passes the original trace and rejects ten
mutations: duplicate/missing commit, reversed GPU ordering, stale target,
incompatible clock, buffer overflow, missing frame, wrong pane, rejected host
and incomplete cleanup. Raw events, clocks, identities and controls remain in the
ignored prefix. The next isolated candidate will flush a fully queued OpenPane
request before synchronous UI refresh, potentially overlapping runtime work and
avoiding an intermediate empty frame. It must preserve nonblocking output,
backpressure, byte ordering and all pacing/visibility rules; the ordinary six-pair
CPU/p95 and regression gates still apply. No immediate-flush change is implemented
or accepted here. All F01–F16/native120 requirements and the unlimited goal remain
open and active.

## Immediate OpenPane flush in the shared writer rejected, 2026-11-04

`out-perf/dlls-open-pane-flush-01` starts from `546d9a2d1`, accepted GUI
`a88e53a8` and runtime `1f1849d1`. The preceding timeline motivates one
nonblocking `QLocalSocket::flush()` after queuing an entire OpenPane on an
accepted connection. The experiment adds a message-tag check to the common
`RuntimeConnection::write` path. It preserves prefix/payload ordering, the 4 MiB
queue bound, handshake behavior and existing presentation pacing. The intent is
to overlap attachment work with synchronous UI refresh; the trace does not yet
prove which downstream work this avoids.

Before implementation, two new private connection oracles fail specifically
because the peer cannot receive OpenPane without processing sender events. They
cover a preceding DetachPane, subsequent input, a stalled receiver, bounded queue
failure, byte-exact draining and immediate recovery. An initial fixture has an
overlong Unix socket path; shortening it allows the backpressure oracle to reach
its intended baseline failure. The peer's bounded wait cannot become a negative
infinite timeout. Both oracles pass with the candidate, as do all 15 connection
cases, including audited schema fallback, retry and simulated SSH transport.
All 15 selected native window cases pass, and settled full-viewport PNGs are
byte-exact for single, four-split and tab layouts. Focused clang-tidy passes after
naming the mutable test request's initial value. The rejected oracles and patch
remain in the ignored experiment prefix.

Candidate GUI SHA-256 is
`41469a20993454579ec6547359241f8d1cef313bc4db6cd66081c40300d1426c`.
ARM64 disassembly retains both ordered QIODevice writes and the queue bound,
then checks accepted/nonempty/OpenPane and calls QLocalSocket::flush once. Import
table addresses verify the actual callee. The pinned Qt Unix implementation
delegates to its nonblocking socket drain, stopping when further writing cannot
progress. No target-specific kernel is introduced; Linux/x86 execution is not
claimed. Build, lint, functional tests and capture checks finish before timing.

`/tmp/telar-perf-open-pane-flush-pairs-01` contains six alternating pairs of 100
measured plus 20 warmup switches, four 30 Hz producers, matched 1600x1000 views
and 82x21 grids. All native content/generation/checksum, producer-rate/phase and
cleanup checks pass. All 26 host boundaries qualify, maximum load1 3.2001953125.

| F08 median of run summaries | Accepted A | Candidate B | B lower pairs |
|---|---:|---:|---:|
| p50, ms | 44.409 | 37.333 | 6/6 |
| p95, ms | 49.130 | 41.523 | 6/6 |
| p99, ms | 49.298 | 43.771 | 6/6 |
| Maximum, ms | 49.557 | 44.446 | 6/6 |
| GUI CPU, ms/input | 28.752 | 27.436 | 6/6 |
| GUI lifetime peak RSS, MiB | 201.617 | 192.109 | 5/6 |

Runtime CPU in its separate GUI-startup/warmup/measurement window is
398.933 -> 376.356 ms (5/6 lower); retired instructions are
843,272,270 -> 823,545,765 (6/6), cycles 824,381,134 -> 771,969,534 (4/6).
Runtime final footprint rises 18.305 -> 19.524 MiB (0/6 lower). These are
runtime-only observations, exclude child CPU and runtime startup/shutdown, and
do not establish causality. Memory snapshots/lifetime maxima are not interval
peaks; shared resident memory is not summed. The modest memory increase is
acceptable in principle and is not the rejection reason.

`/tmp/telar-perf-open-pane-flush-regressions-01` completes six alternating pairs
each for single-pane and four-split typing. All 50 host boundaries qualify,
maximum load1 2.72900390625; all cleanup checks pass.

| Typing metric | Single A -> B | B lower pairs | Four splits A -> B | B lower pairs |
|---|---:|---:|---:|---:|
| p50, ms | 24.895 -> 25.475 | 1/6 | 25.424 -> 25.694 | 1/6 |
| p95, ms | 32.056 -> 32.967 | 3/6 | 32.931 -> 32.745 | 3/6 |
| p99, ms | 36.360 -> 35.228 | 4/6 | 36.860 -> 37.213 | 3/6 |
| Maximum, ms | 38.950 -> 37.781 | 5/6 | 36.899 -> 39.469 | 1/6 |
| GUI CPU, ms/input | 3.874 -> 4.044 | 3/6 | 4.265 -> 4.185 | 3/6 |
| GUI lifetime peak RSS, MiB | 204.602 -> 205.133 | 2/6 | 205.906 -> 206.070 | 3/6 |

Runtime CPU in those broader windows is 82.510 -> 86.921 ms for single and
98.555 -> 100.211 ms for splits, each 2/6 lower. The candidate is rejected for
consistent typing p50 losses and four-split maximum latency, despite its strong
target result. Cause is not established; no placement exemption is proven. No
fresh independent Zig series is needed for an already rejected candidate.

Both production/test source files are restored to their original hashes. The
configured GUI rebuilds byte-exactly to `a88e53a8`; the restored connection suite
and two selected native tab/split cases pass. Unrelated runtime work is preserved.
The next isolated experiment can place the flush in the compile-time OpenPane
send specialization, leaving other request specializations and the shared writer
unchanged. That is a new hypothesis to test, not an explanation established by
these results. The unlimited goal remains active; complete F01–F16 and native120
acceptance remain open.

## Compile-time OpenPane flush accepted locally, 2026-11-04

`out-perf/dlls-open-pane-typed-flush-01` freezes accepted GUI `a88e53a8` and
runtime `1f1849d1` on source HEAD `06e3246a6`. This distinct experiment places
the nonblocking flush in `RuntimeConnection::send<OpenPane>` using
`if constexpr`. The common writer and every other request specialization avoid
the previous variant's extra runtime tag check. A successful complete write and
an accepted connection precede the flush; output ordering, queue capacity and
asynchronous recovery under backpressure retain their existing behavior.

The previous failed variant is not reinstated. Its typing regressions remain
unexplained; removing the common-path check is a testable change, not proof of
their cause. The new baseline oracles again fail at immediate OpenPane delivery,
including recovery after a saturated queue. An additional check confirms that
a preceding DetachPane remains buffered until OpenPane is sent. All 15 connection
cases then pass with the change, including ordering, backpressure, audited
schemas, retries and simulated SSH transport. All 15 selected native window
cases and three byte-exact settled full-viewport PNG comparisons pass. Focused
clang-tidy and whitespace checks pass. These connection oracles are now retained
in `remote_connection_test.cpp`.

ARM64 inspection compares the normal entry-to-return path of `write` and the
entry-to-tail-call path of `send<PaneInput>`. All 58 and 28 instructions,
respectively, match after normalizing addresses while preserving registers,
constants, relative branch destinations and actual external symbols. A changed
register is rejected by each comparison. Cold exception paths are not claimed
identical, nor is this a whole-application placement exemption. OpenPane now calls
the shared writer, checks acceptance and tail-calls QLocalSocket::flush. There is
no target-specific construct; Linux/x86 execution remains unverified.

Candidate and now locally accepted GUI SHA-256 is
`bc55d0e84d76c5eb6d7518a7c83acf8de2aca8ff6894ea71645a626f41a9ccb3`.
The runtime remains `1f1849d1` and command helper `87beebb0`. Sources, staged
binaries and the configured GUI are rehashed after all measurements and still
match the frozen inputs. No production edit follows the measured build.

`/tmp/telar-perf-open-pane-typed-flush-pairs-01` completes six alternating pairs,
100 measured plus 20 warmup switches, four independent 30 Hz producers,
1600x1000 views and 82x21 grids. Native presentation/content/generation/checksum,
producer-rate/phase and cleanup gates pass. All 26 host boundaries qualify,
maximum load1 3.9375. Builds, tests, lint and capture oracles finish before timing;
an earlier validation-time load1 of 5.02 is observed before the series starts.

| Discrete F08 median of run summaries | Previous A | Candidate B | B lower pairs |
|---|---:|---:|---:|
| p50, ms | 42.643 | 37.984 | 6/6 |
| p95, ms | 49.204 | 41.846 | 6/6 |
| p99, ms | 49.495 | 42.767 | 6/6 |
| Maximum, ms | 49.837 | 43.101 | 6/6 |
| GUI CPU, ms/input | 28.668 | 28.029 | 5/6 |
| GUI lifetime peak RSS, MiB | 205.133 | 197.852 | 5/6 |

The separate runtime GUI-startup/warmup/measurement interval reports
399.474 -> 382.274 ms CPU (3/6 lower), 838,965,421 -> 816,382,743 retired
instructions (6/6), and 783,741,198 -> 786,889,055 cycles (3/6). Final runtime
footprint is 18.907 -> 20.032 MiB (0/6 lower). Instruction counts support less
runtime work in this observation window, but do not identify which work or
establish a consistent runtime CPU gain against A.

`/tmp/telar-perf-open-pane-typed-flush-regressions-01` completes six pairs each
for single and four-split typing. All 50 host boundaries pass, maximum load1
3.673828125; all cleanup receipts pass.

| Typing metric | Single A -> B | B lower pairs | Four splits A -> B | B lower pairs |
|---|---:|---:|---:|---:|
| p50, ms | 25.234 -> 25.185 | 3/6 | 25.875 -> 25.304 | 5/6 |
| p95, ms | 32.985 -> 32.774 | 4/6 | 33.391 -> 32.924 | 4/6 |
| p99, ms | 34.186 -> 35.458 | 3/6 | 37.391 -> 36.045 | 6/6 |
| Maximum, ms | 39.526 -> 37.824 | 4/6 | 39.286 -> 39.196 | 3/6 |
| GUI CPU, ms/input | 4.029 -> 3.999 | 3/6 | 4.324 -> 4.239 | 5/6 |
| GUI lifetime peak RSS, MiB | 191.469 -> 206.219 | 1/6 | 197.984 -> 198.859 | 1/6 |

Runtime CPU in those broader windows is 86.775 -> 84.272 ms for single (4/6)
and 105.390 -> 102.346 ms for splits (5/6). No measured typing latency or
GUI/runtime CPU metric has the consistent 0–1/6 loss that rejects a candidate.
The single-pane GUI peak RSS increase of 14.750 MiB, smaller split increase and
1.125 MiB runtime footprint increase in the target are accepted under Adrian's
explicit memory/performance tradeoff authorization. They are observed process
memory values, not a new cache allocation or a summed stack footprint. All
runtime observations exclude child CPU and runtime startup/shutdown; memory is
boundary snapshots/lifetime maximum, not an interval peak.

The private `independent.py` reuses the qualified ordinary tab observer and
resource adapter for two genuinely independent stacks. Zig `6ccf7948` is frozen
again; source inputs are verified unchanged against build HEAD `5c619b85c`.
`/tmp/telar-perf-open-pane-typed-flush-zig-pairs-01` completes six alternating
pairs with the same content/rate/phase, geometry and cleanup qualification.
All 26 host boundaries pass, maximum load1 3.82470703125.

| Independent stacks, median of run summaries | Zig | Accepted C++ | C++ lower pairs |
|---|---:|---:|---:|
| p50, ms | 37.184 | 37.534 | 1/6 |
| p95, ms | 40.080 | 42.737 | 2/6 |
| p99, ms | 43.825 | 44.331 | 3/6 |
| Maximum, ms | 45.826 | 45.436 | 3/6 |
| GUI CPU, ms/input | 17.020 | 27.783 | 0/6 |
| GUI lifetime peak RSS, MiB | 133.703 | 191.961 | 0/6 |
| Runtime CPU, separate broader interval, ms | 519.245 | 370.484 | 6/6 |
| Runtime final footprint, MiB | 21.595 | 20.250 | 6/6 |

Runtime retired instructions are 1,031,980,082 -> 818,528,488 and cycles
974,877,430 -> 761,100,638, each 6/6 lower for C++. The GUI remains the major
CPU deficit in this workload. These separate observation windows cannot be
added into a claimed total-stack CPU result.

Accept the source change as an incremental improvement against the previous
C++ baseline, with the measured memory tradeoff. F08 does not pass against Zig:
GUI CPU loses every pair and p50 improves only one. Workspace switching,
continuous native120 and complete F01–F16 coverage remain open. The next pass
will profile the newly accepted GUI and correlate attachment/frame preparation
to quantify avoided work and locate the remaining CPU cost. Unrelated runtime
changes remain untouched, and the persistent unlimited goal remains active.

## Accepted-flush CPU profile and preparation timeline, 2026-11-04

On `3ed35ad46`, `out-perf/dlls-post-flush-profile-01` freezes accepted GUI
`bc55d0e8`, runtime `1f1849d1` and independent Zig `6ccf7948`. An eight-second,
1 ms `sample` capture runs inside each owned 240-switch workload. The first
attempt completes both workloads but its controller incorrectly uses only
HostLoadGate checkpoints: `finish()` rejects it because no `run()` scope was
registered. `/tmp/telar-perf-post-flush-profile-01` is not promoted to validated
evidence. The corrected controller repeats both stacks in `...-profile-02`.
All content/rate/phase and cleanup checks pass; six host boundaries qualify,
maximum load1 2.1767578125. Captures overlap 95 C++ and 89 Zig switches.

The accepted C++ main-thread profile has 5,873 sample observations. Inclusive
category counts, excluding nested repeats within each category, are: tab rebuild
199, caption measurement 19, list reconciliation 281, pane refresh 118, QML
binding update 152, var-property write 85, variant association 78 and garbage
collection 18. Categories overlap and include observer/wait samples; they are
neither allocation counts nor CPU percentages. The render thread also has long
drawable and event waits; its inclusive renderer count is not CPU attribution.
An additional exact tree-to-leaf accounting verifies count conservation but
explicitly does not treat every unclassified syscall as runnable CPU work.

Source inspection reconfirms that `TabStripLayout` reconciles positioned records
during geometry animation. `ListModel::reconcile` publishes its complete record
role when a row differs, and TerminalTabs binds `source` from `record.tab`.
Pinned Qt's `QQmlVMEMetaObject::writeVarProperty` detaches an association wrapper
on that path. This supports a specific conversion/publication hypothesis, not a
claim that every notification deeply copies the full map. The earlier typed
presentation experiment cut this sampled work and passed its CPU gate, but
failed p95 on the pre-flush baseline; that rejection remains valid.

`out-perf/dlls-post-flush-timeline-01` reuses the bounded private trace and native
commit/GPU observer. Before GUI is the prior instrumented `fb038d41`; after GUI
is `7f52bbc2045240d46103750b96a8c45a0001c47ea12a33e1336a66e37219c698`,
containing the accepted typed flush. Only three otherwise unchanged translation
units are temporarily instrumented. They are restored to their original hashes,
and the configured GUI rebuilds byte-exactly to `bc55d0e8` before running the
diagnostic copies. The accepted header and unrelated runtime changes are preserved.

`/tmp/telar-perf-post-flush-timeline-01` runs before/after C++ and independent Zig,
100 measured plus 20 warmup actions each. Every action has qualified native
content/rate/phase and clock ordering. All 120 actions in each C++ run correlate
the actual selected pane, OpenPane, PaneOpened, matching frame ID, painting,
preparation and one accepted drawable commit. Counts are 16,460/16,645 trace
events without overflow or unpublished slots. Clock brackets contain zero and
are narrower than 210 ns. All eight host boundaries pass, maximum load1
3.60888671875, and all owned cleanup completes.

| Diagnostic C++ observation | Before flush | Accepted flush |
|---|---:|---:|
| Mean queued to first bytesWritten notification, ms | 2.732 | 0.017 |
| Mean first bytesWritten to PaneOpened delivery, ms | 0.697 | 2.548 |
| Mean inclusive pane refresh before reply delivery, ms | 1.950 | 2.068 |
| Actions preparing before PaneOpened, of 100 | 44 | 0 |
| Preparations through target drawable commit per action | 1.44 | 1.00 |
| Paint events through target drawable commit per action | 1.44 | 1.00 |
| Mean OpenPane queued to PaneOpened delivery, ms | 3.429 | 2.566 |
| Mean target-frame dispatch complete to paint start, ms | 4.211 | 2.466 |
| Mean input to target drawable commit, ms | 10.729 | 7.756 |

This records fewer intermediate preparations in the critical interval, not a
total-process frame-count or CPU saving. A preparation before the reply does not
prove an empty or presented frame. `bytesWritten` is a batch notification rather
than a syscall timestamp. Pane refresh remains approximately 2 ms; the new
post-write delivery interval is consistent with synchronous UI work delaying
reply dispatch, without assigning that whole interval to runtime service time.
Explicit pacer holds after target-frame dispatch occur in 43/55 actions.

These are instrumented single-run diagnostics, not another acceptance series.
GPU execution means vary 1.658 -> 4.695 ms while GPU-end-to-presentation varies
30.326 -> 24.698 ms; neither observation identifies a universal Qt/GPU penalty.
Zig's separate input-to-commit mean is 7.837 ms. The existing six-pair independent
comparison remains authoritative for performance acceptance. Stage quantiles
cannot be added. The analyzer accepts the positive trace and rejects ten fresh
controls against the after run: duplicate/missing commit, reversed GPU times,
stale target, incompatible clock, missing frame, wrong pane, overflow, rejected
host and incomplete cleanup. Rejections are checked at their intended assertions.

The next frozen contract is `out-perf/dlls-tab-presentation-post-flush-01`:
re-evaluate stable semantic tab presentations as a new combination with the
accepted OpenPane schedule. Current profiling still finds that work, and the
critical path has materially changed. It is not automatic reinstatement of the
rejected `e4aea930` binary or reuse of old timings. The new baseline is
`bc55d0e8`; oracles, deferred-retirement peak/lifetime observations, fresh target
pairs, typing controls and independent Zig qualification are required again.
No candidate source is applied yet. Production remains the accepted flush build;
complete F01–F16/native120 requirements and the unlimited goal remain open.

## Stable tab presentations on the accepted flush base, 2026-11-04

On `c61a8b181`, `out-perf/dlls-tab-presentation-post-flush-01` applies the
previously rejected typed-presentation algorithm as a new combination with the
accepted compile-time OpenPane flush. Baseline GUI is `bc55d0e8`; candidate GUI
is `345974b5da42cb5ed03b0bfe99112578acbf5f9542755202a29bd2f8e90685be`.
Both use runtime `1f1849d1` and command helper `87beebb0`. The accepted flush
source remains unchanged. The earlier unflushed-base rejection remains valid.

A stable QObject owns each tab's semantic content and typed geometry. Geometry
updates notify only changed geometry properties, leaving QML semantic content
bindings intact. Legacy map records remain lazily available to existing callers.
The new integrated test covers 2,048 deterministic reference-model reconciliations,
persistent indices, stable identity, selective signals, overflow, deferred removal
and real QML delegates. Its 240 geometry updates cause zero semantic rebindings;
semantic changes still notify, and model destruction retires readers safely.

Private model/QML oracles pass again with ASan/UBSan (Qt dependencies remain
uninstrumented and leak detection is disabled). A new lifetime census corrects a
potentially misleading capacity claim: 64 is the settled-row limit, not a global
live-object limit. Four disjoint batches of 64 rows reach 128 transient model
rows. Draining deferred deletions after each batch peaks at 128 live objects;
without intermediate drains, the same four batches peak at 256. Both create and
destroy all 256 objects and finish with zero live objects after model destruction
and a final drain. These are object counts, not byte/RSS bounds; longer undrained
sequences can retain more retired objects.

Production and integrated-test focused clang-tidy pass. The integrated test's
initial lint failure is retained; direct includes, named fixtures, internal linkage,
static slots and const correctness are fixed. The reproducible PRNG seed has one
explicit diagnostic suppression. Presentation, chrome and activity component tests
pass, as do all 17 focused Cocoa/Metal cases covering window reopening, tabs,
drag/drop cancellation, palettes, nested splits, fullscreen and configuration reload.
Three settled full-window PNGs (single, four splits and tabs) match byte-for-byte
in `/tmp/telar-perf-tab-presentation-post-flush-pixels-01`.

Fresh ARM64 disassembly has 2,624/2,176 static instructions in A/B tab rebuild;
B also has 483 in typed reconciliation and 209 in presentation update. Static
QVariant-named call sites in rebuild fall 56 to 27, and QMap-named sites 39 to 19;
these overlapping name counts are neither executed instructions nor allocations.
Source and the QML oracle establish the avoided semantic publication. Actual
performance acceptance still requires the frozen six-pair CPU/p95 gates.

`/tmp/telar-perf-tab-presentation-post-flush-pairs-01` completes six alternating
pairs, 100 measured plus 20 warmup actions, four 30 Hz producers, 1600x1000
viewport and 82x21 grid. All native content/phase/rate, pair geometry and owned
cleanup checks pass. All 26 host boundaries qualify, maximum load1 2.68798828125;
no owned build, test or profile overlaps timing. Values below are medians of runs.

| Target metric | A accepted flush | B typed presentations | B lower, /6 |
|---|---:|---:|---:|
| p50, ms | 38.043 | 38.561 | 3 |
| p95, ms | 43.329 | 41.845 | 4 |
| p99, ms | 44.666 | 43.614 | 4 |
| Maximum, ms | 45.337 | 46.119 | 3 |
| GUI CPU/input, ms | 27.580 | 27.153 | 4 |
| GUI lifetime peak RSS, MiB | 203.852 | 192.703 | 5 |

The separate runtime window includes GUI startup, warmup, measured actions and
boundary-observer time, excluding runtime startup/shutdown and child CPU. Its
CPU is 379.554/391.396 ms (B lower 2/6), instructions 817,878,205/823,700,783
(2/6), and cycles 762,573,143/777,490,826.5 (2/6). End RSS is
28.547/28.914 MiB (1/6), end footprint 20.165/20.532 MiB (1/6), and lifetime
maximum footprint 20.180/20.547 MiB (1/6). Memory observations are endpoint
snapshots and lifetime maximums, not interval peaks; GUI and runtime RSS are not
summed. The runtime CPU window differs from GUI CPU/input.

Reject the combination: both frozen GUI CPU and p95 gates require at least 5/6
wins and both achieve only 4/6. The lower median p95 and five RSS wins do not
supersede that rule. This is not a rejection of a memory/performance tradeoff.
The exact cause of inconsistent end-to-end gains is not established. Typing
controls and a new independent Zig comparison are not run for this rejected
candidate; previous accepted-build comparisons remain authoritative.

All seven candidate files are frozen before restoring the four original files
with their original timestamps and removing the three candidate-only files.
Qt resource/AOT outputs and objects depending on changed headers are invalidated
before rebuilding. The configured GUI is byte-exactly `bc55d0e8` again; restored
chrome/activity tests pass. The accepted OpenPane implementation and unrelated
dirty runtime work are preserved. F01–F16 and native120 acceptance remain open,
and the unlimited persistent goal remains active.

After restoration, a separate eight-second/1 ms `sample` diagnostic of each
frozen binary completes 240 qualified actions in
`/tmp/telar-perf-tab-presentation-post-flush-profile-01`. The captures overlap
98/95 switches. All six host boundaries qualify, maximum load1 3.9619140625,
and cleanup completes. Main-thread totals are 5,895/5,844 observations. Inclusive
counts A/B are tab rebuild 218/135, ListModel reconciliation 293/141, new typed
reconciliation 0/84, typed update 0/82, var-property write 92/32, variant
association 67/27, QML binding 162/89, and garbage collection 26/7. Pane refresh
is 117/143 and QML construction 19/34. Categories overlap, contain waits, and
have different action overlap; they are not additive CPU percentages or allocation
counts. The intended publication reduction remains observable, but these profiles
do not establish the cause of the insufficient six-pair gain or reinstate B.

The next diagnostic will separate observed GUI CPU by thread on the accepted
build before choosing another presentation optimization. Existing sampled render
and main-thread stacks include substantial waits; interpreting their inclusive
sample counts as CPU cost would mis-rank the remaining work. Thread observations
must account explicitly for threads that appear/disappear, clock units and
unattributed residuals against process CPU, and remain separate from headline
latency. No new production candidate is applied.

## GUI thread CPU attribution and optical-cache lifetime census, 2026-11-04

On `1b7db2874`, production remains accepted GUI `bc55d0e8` with runtime
`1f1849d1`. `out-perf/dlls-gui-thread-cpu-census-01` implements a separate native
CPU observer before choosing another presentation optimization. The reusable
`macos_thread_cpu.c/.h`, `macos_thread_cpu_control.c`, `thread_cpu_report.py`,
`test_thread_cpu_report.py` and `build_thread_cpu_probe.py` live in `tools`.
They do not modify the ordinary acceptance probe or production rendering.

The observer enumerates its own process's threads every 100 ms during measured
inputs. It records stable thread IDs, names, user/system CPU from Mach
`THREAD_BASIC_INFO`, process `getrusage` brackets and uptime-clock boundaries.
Both CPU APIs expose seconds/microseconds here; raw Mach tick scaling does not
apply. New threads contribute observed lifetime CPU; retired threads retain their
last observation, and unseen work remains in a signed process residual. Different
accounting update times can yield small negative residuals, which are not clamped.
The analyzer rejects failed reads, missing completion, incomplete enumeration,
duplicate IDs, counter/clock reversal and inconsistent boundary/sampler identity.

The first two busy/sleep/churn controls pass. A third is rejected because the
sampler exits before final enumeration, leaving an invalid thread port. The
observer now takes the final snapshot under its mutex while the sampler is alive,
then joins it. Three corrected controls record 250.528–250.683 ms for 250 ms of
known worker CPU, 80.221–80.297 ms for 80 ms of main-thread work, and only
1.329–1.455 ms for the waiting thread. Seven of eight short-lived workers are
unseen in each run; the reported residual differs from their known unobserved
work by less than 0.2 ms. A final source control also passes. The private
ASan/UBSan control passes, with leak detection disabled. Two positive synthetic
cases and fourteen negative mutations pass; two initial expected-error-string
mismatches are fixed and retained in the logs. Native arm64/macOS is validated;
there is no Linux, Rosetta or x86 execution claim.

`/tmp/telar-perf-gui-thread-cpu-01` observes accepted C++ and independent Zig
`6ccf7948`, each with 240 measured switches after 20 warmups, four 30 Hz producers,
1600x1000 viewport and an 82x21 grid. Native content/rate/phase and cleanup checks
pass. All six host boundaries qualify, maximum load1 2.89013671875. CPU below is
for the diagnostic interval, in milliseconds; the process column is the midpoint
of its boundary readings. Other threads include unnamed dispatch workers.

| Diagnostic GUI | Process CPU | Main thread | Qt render thread | Observer | Other observed threads |
|---|---:|---:|---:|---:|---:|
| C++ | 7258.678 | 3338.428 | 2481.994 | 35.950 | 1402.303 |
| Zig | 4268.447 | 1625.882 | — | 47.844 | 2594.705 |

There are 203/194 snapshots. Signed residual ranges are -0.099..0.104 ms and
-0.141..0.173 ms. CPU differs from the ordinary probe's slightly different
measurement boundaries by -0.5705/-1.908 ms; wall duration differs by less than
2.23 ms. Maximum individual snapshot duration is 1.794/1.527 ms. Observed sampler
CPU does not capture every scheduling/cache effect of instrumentation and must
not be subtracted to claim uninstrumented performance.

A separate diagnosis, `/tmp/telar-perf-gui-thread-cpu-profile-01`, adds eight-second,
1 ms `sample` captures overlapping 96 switches in each stack. Both workloads and
all six host boundaries pass, maximum load1 2.0654296875. C++/Zig process CPU is
5977.854/4022.368 ms, main-thread CPU 2767.010/1525.237 ms, and C++ render CPU
1991.090 ms. These differ from the preceding instrumented run; neither run is a
paired acceptance series. All four thread reports revalidate against the final
identity checks, with absolute residual endpoints below 0.2 ms and boundary CPU
differences below 3.14 ms.

Same-run stacks identify C++'s main and QSG render threads by ID. `sample` groups
some dispatch queues under `Thread_<multiple>`; Zig's `telar.surface.metal` queue
cannot therefore be assigned an exact per-worker CPU total from that listing.
Large drawable/semaphore waits remain waits. The C++ render stack nevertheless
locates repeated optical rasterization under TerminalScene -> paintRow ->
paintTerminalText -> ChromeGlyphImages::glyph: 37 inclusive glyph-cache samples,
25 in rasterization and 22 in CTFontDrawGlyphs. These overlap and are not CPU
percentages. Source `ChromeGlyphImages::shared` holds weak pointers, so its cached
masks can disappear when the last pane scene retires. This is a specific remaining
work hypothesis, separate from the rejected typed-tab publication experiment.

`out-perf/dlls-glyph-lifetime-census-01` then instruments only
`chrome_glyph_images.hpp` in a private GUI copy. It counts cache creation/destruction,
requests/hits and successful misses, logging native font-asset identity, glyph key,
geometry and a 64-bit checksum of zero-padded alpha bytes. The first run passes the
native flow but produces no trace because the launcher sanitizes the parent
environment variable. It is invalid for the census. The second passes the native
flow but fails accounting: diagnostic asset lookup on standard regular/emphasized
roles throws `MissingNativeFontAsset`, leaving 59 stored glyphs but only 24 miss
records in the standard cache. This instrumentation changed behavior; the entire
second capture is excluded, including its otherwise consistent optical rows.

The corrected instrumentation queries native assets only on the optical path,
where the original rasterizer already uses them. Three settled full-window PNGs
(single, splits, tabs) match accepted A byte-for-byte in
`/tmp/telar-perf-glyph-lifetime-pixels-01`. After each temporary build the header is
restored with its original timestamp and dependent objects are rebuilt. The
configured GUI is again byte-exactly `bc55d0e8` before running the staged copy.

`/tmp/telar-perf-glyph-lifetime-census-03` passes 240 measured plus 20 warmup
switches, native content/rate/phase, complete owned cleanup and all four host
boundaries; maximum load1 is 3.97412109375. All 8,047 events have contiguous
sequence IDs and closed lifetimes. Requests equal hits plus misses, stored glyph
counts equal miss records, and reconstructed alpha-byte totals equal destruction
receipts. Four corrupted-trace controls reject an unclosed lifetime, missing event,
incorrect request count and incorrect alpha-byte count.

| Whole-GUI-lifetime observation | Standard cache | Optical caches |
|---|---:|---:|
| Caches created and destroyed | 1 | 267 |
| Requests | 297865 | 671975 |
| Hits | 297776 | 664553 |
| Successful misses | 89 | 7422 |
| Unique request identities | 89 | 28 |
| Repeated matching-checksum/geometry misses | 0 | 7394 |
| Largest cache-owned alpha bytes | 26812 | 10600 |

Optical requests use one font-object address and one native font-asset address in
this fixed-configuration run; no matching request changes checksum or geometry.
Of 7,422 optical misses, 7,155 have nonempty masks and 267 have empty masks.
Peak live caches are two overall, one optical; peak cache-owned alpha sum is
37,412 bytes. These observations span startup, warmup, measurement and teardown,
not just measured inputs. Checksums are diagnostic evidence, not an independent
byte-exact oracle. Alpha sums exclude GPU textures, font objects, nodes retaining
retired mask references and process RSS; they are not global memory bounds.

The next frozen experiment is `out-perf/dlls-optical-glyph-residency-01`: retain
one most-recent optical glyph cache per window across pane-consumer lifetimes.
This targets repeat rasterization/texture construction without retaining hidden
pane delegates. Window/font/strength separation, render-thread invalidation,
eviction with active readers, close/reopen and exact-image oracles must precede
fresh target pairs and typing controls. The accepted flush remains unchanged;
no production residency candidate is applied yet. Unrelated runtime work is
preserved, F01–F16/native120 remain open, and the unlimited goal stays active.

## Bounded optical-mask residency rejected by typing, 2026-11-04

`out-perf/dlls-optical-glyph-residency-01` tests the preceding lifetime finding
against accepted GUI `bc55d0e8`, with unchanged runtime `1f1849d1` and helper
`87beebb0`. Before implementation, the whole-cache retention plan was replaced:
keeping an active cache across unrelated pane lifetimes could accumulate glyphs
toward its existing 4096-entry/4 MiB limit. The candidate instead keeps a separate
window-owned store of at most 128 masks and 64 KiB of alpha, for the latest
font-set/rasterization identity. Each active cache keeps its original independent
limits and admits only requested glyphs. Eviction drops window ownership while
active readers retain their references; scene-graph invalidation clears retained
ownership directly on the render thread. GPU textures, fonts, hash storage and
references held by active scenes are additional memory, not covered by the alpha
limit. Standard glyphs do not use the store.

The ownership/bounds oracle passes before integration, while the consumer-gap
oracle fails with `consumer gap rasterized a new mask`. After integration, it
proves reuse after the active cache expires, separation across windows, font and
strength changes, reader survival after eviction, entry/byte limits, oversized
bypass and invalidation. A 72-case matrix covers three strengths, two heights,
three glyphs including a space, and four styles; masks/geometry match a fresh
cache in a separate window without residency. A separate native oracle draws a
real texture into the framebuffer, closes/reopens twice and verifies destruction
on its creation/render thread after actual scene-graph invalidation. ASan/UBSan
passes both test translation units, including the new header implementations;
linked Qt/other GUI libraries are not sanitizer builds and leak detection is off.

Four focused CTest entries pass, including the existing 432-case optical oracle,
chrome text and scene tests. All 17 native window/tab/split/drag/palette/configuration
cases pass. Three settled full-window PNGs match A byte-for-byte in
`/tmp/telar-perf-optical-glyph-residency-pixels-02`. New test/header lint passes;
application/terminal translation units retain only the unchanged
`config/callback.hpp:13` redundant-alias diagnostic. This is not a clean global
lint claim. Native validation is macOS/arm64; no cross-platform acceptance follows.

An initial untimed draft `197c65ba` passed the oracles but its by-value insertion
helper introduced a temporary: standard/optical stack frames grew from 288 bytes
to 352/432. Passing the existing glyph by rvalue reference restores both to 288.
The measured candidate is `64a75208b3150ca7662ac43ed968cce4af59ebded9c324d955a388babcc09f34`;
both drafts and source snapshots remain private. Final ARM64 code returns on an
active-cache hit before consulting window residency. A residency hit bypasses
optical rasterization, alpha allocation/copy/conversion and texture creation.
Standard glyph code retains 328 decoded instruction lines but changes register
scheduling around insertion; optical lookup also saves/restores an extra register
pair. The binaries are not instruction-identical, and no placement exemption is
established. These observations do not prove the cause of the later regression.

`/tmp/telar-perf-optical-glyph-residency-pairs-01` completes six alternating native
switch pairs, 100 measured plus 20 warmup actions per run, four 30 Hz producers,
1600x1000 viewport and 82x21 grid. Content, phase, offered rate and presentation
checks pass. All 26 host boundaries qualify; maximum load1 is 3.25048828125.
No own builds/tests/profiles overlap timing.

| Discrete tab switch | A median | B median | B wins/6 |
|---|---:|---:|---:|
| p50 ms | 38.906 | 31.396 | 6 |
| p95 ms | 42.799 | 35.004 | 5 |
| p99 ms | 43.844 | 36.752 | 6 |
| maximum ms | 45.023 | 39.564 | 6 |
| GUI CPU ms/input | 28.236 | 24.697 | 6 |
| GUI lifetime peak RSS MiB | 206.109 | 191.797 | 5 |
| Runtime CPU ms | 381.872 | 362.435 | 5 |
| Runtime lifetime maximum footprint MiB | 20.297 | 19.922 | 4 |

Runtime instructions/cycles improve 6/6. Runtime counters bracket GUI startup,
warmup and measured work, excluding runtime startup/shutdown and child CPU;
footprint is a lifetime maximum, not an interval peak. These resource scopes
must not be summed with GUI RSS.

The mandatory typing controls in
`/tmp/telar-perf-optical-glyph-residency-regressions-01` complete six alternating
pairs for each layout. All 50 host boundaries qualify; maximum load1 is
4.81640625, below the fixed limit of 5. No series was excluded for load.

| Typing control | A median | B median | B wins/6 |
|---|---:|---:|---:|
| Single p50 ms | 24.905 | 25.559 | **0** |
| Single p95 ms | 32.523 | 31.753 | 4 |
| Single p99 ms | 34.490 | 34.532 | 3 |
| Single maximum ms | 36.841 | 35.766 | 4 |
| Single GUI CPU ms/input | 3.994 | 4.206 | **1** |
| Four-split p50 ms | 25.239 | 25.440 | 3 |
| Four-split p95 ms | 33.046 | 33.105 | 4 |
| Four-split p99 ms | 37.077 | 36.948 | 5 |
| Four-split maximum ms | 38.279 | 41.611 | **1** |
| Four-split GUI CPU ms/input | 4.400 | 4.358 | 3 |

Single/split runtime CPU wins 3/6 and 4/6; instructions win 2/6 and 1/6,
cycles 2/6 in both. GUI RSS wins 3/6 in each layout. The variant is rejected by
single-pane median/CPU and split maximum losses despite its target gain. Memory
is not the rejection reason. Cause is not established, and the result is not
reclassified as noisy or placement-only. No candidate lifetime census or
independent Zig timing follows this rejection, so production rasterization counts
and a Zig-stack win are not claimed.

All 48 owned shutdown receipts across the two pixel series, target pairs and
typing controls pass, as do the separate resource-capture cleanup checks. Four
modified GUI files are restored with original timestamps, and the three new
candidate files are withdrawn into the frozen private source snapshot. Reconfigure
and dependency rebuild produce exactly accepted `bc55d0e8` again. Unrelated dirty
runtime sources remain untouched. The next experiment will test separating cold
glyph admission from the hot lookup while retaining bounded mask reuse; it must
pass fresh oracles and all paired controls. F01–F16/native120 remain open and the
unlimited goal remains active.

## Cold glyph admission rejected; reuse verified in the application, 2026-11-04

`out-perf/dlls-optical-glyph-cold-admission-01` rechecks HEAD `b5397f318`, accepted
GUI `bc55d0e8` and the preserved runtime work before applying another candidate.
It retains the separate bounded optical-mask store but moves cache-miss admission
into a non-inlined `loadGlyph` method taking the existing glyph request type.
The common key/lookup path can then inline into its caller. This tests a different
call structure; it does not assume that the prior typing losses were caused by
register saves or code placement.

The first build command sees an unknown new test target because the restored
CMake cache has not regenerated; a concurrent initial lint matches zero files and
is not validation. Explicit reconfiguration and current candidate timestamps then
force all affected translation units, including application and terminal item, to
rebuild. Final staged B is
`7f3e3323d72a54522c2efb7a04715d6463855a2c738588e91370776e7aa6c10a`.
Four focused tests (including 432 optical reference rasters), the 72-request reuse
matrix, ownership/bounds/invalidation checks, native texture close/reopen,
ASan/UBSan on both new test translation units, all 17 native application cases and
three byte-exact full-window PNGs pass. Final new-test/header lint examines two
translation units and passes; no global lint or new platform acceptance is claimed.

ARM64 disassembly shows both standalone `glyph` specializations disappear from
B. `ChromeScene::appendSpan` directly calls `QHash::findImpl`, and only its miss
branch calls `loadGlyph`. Its optical caller frame remains 368 bytes; a hit no
longer enters A's separate 288-byte glyph frame. Window-store lookup, rasterization
and admission remain in the cold function. This proves the intended call-structure
change, not a whole-application performance gain.

`/tmp/telar-perf-optical-glyph-cold-admission-pairs-01` completes six alternating
pairs with the unchanged native 100-action/20-warmup, four-producer 30 Hz contract.
All content, phase, rate, presentation and cleanup checks pass. All 26 host bounds
qualify, maximum load1 4.14404296875; no own builds/tests/profiles overlap timing.

| Discrete switch | A median | B median | B wins/6 |
|---|---:|---:|---:|
| p50 ms | 38.556 | 32.276 | 6 |
| p95 ms | 42.718 | 40.209 | **4** |
| p99 ms | 43.808 | 40.868 | 3 |
| maximum ms | 45.217 | 43.842 | 3 |
| GUI CPU ms/input | 28.041 | 26.247 | 5 |
| GUI lifetime peak RSS MiB | 205.930 | 203.406 | 2 |
| Runtime CPU ms | 376.572 | 376.655 | 3 |
| Runtime lifetime maximum footprint MiB | 20.266 | 20.344 | 4 |

Runtime instructions/cycles win 5/6 and 4/6. Resource scopes remain the same as in
the preceding report. **Reject:** p95 wins only 4/6 against the predefined 5/6
threshold. No typing or independent Zig acceptance series follows this failure.
The earlier variant is not reinstated. Both source and the configured GUI are
restored byte-exactly to accepted A, preserving original source timestamps and
all four recorded dirty-runtime source hashes.

A separate diagnostic, `out-perf/dlls-glyph-reuse-census-01`, then tests whether the
actual application uses the retained masks. Its private instrumented copy of B
(`2f4ac88d`) records active-cache hits, raster misses, resident reuse, window-store
selection/insertion/eviction/clear/destruction and mask identity/checksum/geometry.
The logger's first build warns about passing a typed pointer to `%p`; an explicit
void-pointer cast fixes the final diagnostic. Production is restored to `bc55d0e8`
before the staged copy runs. Its single/splits/tabs full-window PNGs match A
byte-for-byte in `/tmp/telar-perf-glyph-reuse-census-pixels-01`.

`/tmp/telar-perf-glyph-reuse-census-01` qualifies 240 measured plus 20 warmup
switches, producer rate/content/phase, native presentation and cleanup. All four
host observations pass, maximum load1 3.91015625. The 8,139 events are contiguous,
all cache/store lifetimes close, requests equal hits plus raster misses plus reuse,
and cache/store byte counts reconcile. Every reuse names a matching live retained
mask with unchanged checksum and geometry. Eight corrupted-trace controls reject
missing events, wrong mask/hash/font, wrong request/byte counts, oversized geometry
and an unclosed cache.

| Whole-GUI-lifetime census | Standard | Optical |
|---|---:|---:|
| Caches created and destroyed | 1 | 267 |
| Requests | 286502 | 661731 |
| Own-cache hits | 286408 | 654255 |
| Raster misses | 94 | 28 |
| Resident reuses | 0 | 7448 |
| Unique request identities | 94 | 28 |
| Groups with different checksum/geometry | 0 | 0 |
| Native optical rasterizers created | 0 | 1 |
| Caches with a raster scratch buffer | 0 | 1 |

One window store reaches 28 entries and 10,600 alpha bytes. The peak union of
cache/store-owned masks is 122 masks and 38,496 alpha bytes, avoiding duplicate
counting of references. One optical cache retires with a 4,194,304-byte raster
scratch buffer; the others allocate no such buffer. These are diagnostic lifetime
counts, not paired timing or total process allocation volume. Alpha excludes GPU
textures, fonts, hash/Qt storage, node-only references and RSS. The earlier accepted
census had 7,422 optical misses across 267 cache lifetimes, but its request totals
are different; it is not a paired performance comparison. Reuse is effective in
the application, so an absent/nonfunctioning store does not explain the rejection.

Post hoc decomposition of the already-qualified, uninstrumented six pairs retains
the original endpoint and warmup exclusion:

| Median of per-run stage p50, ms | A | B | B lower pairs |
|---|---:|---:|---:|
| Input to completion callback | 10.512 | 7.615 | 6/6 |
| Presentation minus callback | 29.025 | 25.121 | 3/6 |
| GPU execution, overlapping interval | 0.883 | 0.277 | 6/6 |

The callback includes CPU/submission/scheduling; it is not GPU execution end.
Stage quantiles must not be added or interpreted as drawable queue depth. Measured
wall time/input is 89.248/83.842 ms (B lower 5/6), and process CPU/wall second is
0.314877/0.313352 (4/6). Faster completion shortens the interval containing
fixed-rate background work; CPU/input savings must not all be assigned to avoided
rasterization. The variable presentation interval remains unresolved. Earlier
drawable-pool/render-loop controls are not silently repeated or reinstated.

`out-perf/dlls-glyph-reuse-thread-cpu-01` subsequently reuses the source/hash-verified
100 ms thread observer for one separate A/B diagnostic, not acceptance timing.
`/tmp/telar-perf-glyph-reuse-thread-cpu-01` passes both 240-action workloads and all
six host bounds (maximum load1 3.94921875). Process CPU midpoints are
7103.5945/6604.1415 ms; main-thread CPU is 3296.111/3275.077 ms and render-thread CPU
2415.426/2042.235 ms. Measured wall intervals are 21712.063/20604.349 ms, so the
corresponding render CPU/wall fractions are 0.111248/0.099117, while main fractions
are 0.151810/0.158951. Observer CPU is 33.660/33.525 ms and remains included.
Signed process residuals are [-0.095,0.090]/[1.482,1.645] ms; sampler-to-probe CPU
boundary differences are -0.3675/-0.4075 ms. This is evidence of a render-side
reduction with substantial main-thread work remaining, not causal attribution of
presentation scheduling or subtraction of observer perturbation.

All 27 owned shutdown receipts in these target/pixel/census/thread runs pass,
along with separate runtime-resource cleanup checks. The configured GUI remains
accepted `bc55d0e8`; both failed candidates and all diagnostic sources remain in
ignored prefixes. The next experiment will evaluate complementary main-thread
publication and render-mask work reduction together, reusing the typed-tab and
glyph oracles but requiring fresh full paired controls. Component gains are not
assumed additive, and neither rejected component is accepted independently.
All F01–F16/native120 requirements and the unlimited goal remain open.

## Combined typed tabs and glyph residency rejected, 2026-11-04

`out-perf/dlls-tab-model-glyph-residency-01` combines the previously rejected
typed-tab publication and bounded optical-mask reuse/cold-admission candidates
on accepted GUI `bc55d0e8`, HEAD `f05fdff8d`. The preceding application census and
thread diagnostic motivate reducing main-thread and render-thread work together;
they do not establish additive gains or independently accept either component.
Fresh source timestamps and explicit CMake reconfiguration produce candidate
`ab2efd4aee794900b0fe1f82bcfcf22a37b7ca8548644708776e894c8200fb51`.
The runtime remains `1f1849d1`, command helper `87beebb0`.

All seven focused CTests, 17 native interaction cases and single/splits/tabs
byte-exact full-window PNGs pass. ASan/UBSan passes for both glyph test translation
units and the typed-tab test, including their header-only candidate code. Linked
Qt, MOC and other GUI archive objects are unsanitized; leak detection is disabled.
The typed oracle exercises 2,048 reconciliations, 240 QML geometry changes without
semantic rebinding, and retirement. Snapshot-before-notification coverage does
not claim safety for arbitrary recursive model mutation. The window store has
independent 128-entry/64 KiB alpha limits; active-cache and rendering references
have separate ownership. A settled typed model has at most 64 rows, but deferred
deletion means 128 transient rows is not a global lifetime memory bound.

The first two lint invocations fail tool/config discovery and are not validation.
The corrected invocation checks four translation units: the three new tests pass,
while `TabStripLayout::rebuild` exceeds the 100-line limit by one line. A VFS overlay
of the saved baseline reproduces exactly the same 101-line diagnostic. No global
clean-lint claim is made. ARM64 assembly retains inline glyph lookup and separate
non-inlined miss admission; both `appendSpan` caller stack subtractions remain
368 bytes. Typed publication branches around unchanged property notifications.
This is changed generated code, not a code-placement exemption.

`/tmp/telar-perf-tab-model-glyph-residency-pairs-01` completes six alternating
100-action/20-warmup pairs with four 30 Hz producers. Native presentation,
content, rate, phase and cleanup checks pass. All 26 host observations qualify,
maximum load1 3.6669921875; no own build/test/profile overlaps headline timing.

| Discrete switch | A median | B median | B wins/6 |
|---|---:|---:|---:|
| p50 ms | 39.010 | 31.326 | 6 |
| p95 ms | 42.894 | 34.921 | 6 |
| p99 ms | 44.577 | 35.326 | 6 |
| maximum ms | 45.081 | 39.882 | 6 |
| GUI CPU ms/input | 28.269 | 24.042 | 6 |
| GUI lifetime peak RSS MiB | 196.391 | 198.305 | 3 |
| Runtime CPU ms | 389.425 | 376.245 | 4 |
| Runtime lifetime maximum footprint MiB | 20.344 | 20.164 | 4 |

Runtime instructions/cycles win 5/6 and 4/6. This passes the target gate; the
approximately 1.9 MiB difference in median GUI peak RSS is not a rejection reason.
Runtime counters retain the preceding reports' setup/warmup/measurement scope,
excluding runtime startup/shutdown and child CPU. Memory snapshots and lifetime
maxima are not interval allocation volume or a sum of GUI/runtime RSS.

`/tmp/telar-perf-tab-model-glyph-residency-regressions-01` then completes all
24 typing runs, six alternating pairs per layout. All 50 host bounds qualify,
maximum load1 1.93603515625. Native/content/cleanup checks pass.

| Typing metric | Single A | Single B | B wins/6 | Four splits A | Four splits B | B wins/6 |
|---|---:|---:|---:|---:|---:|---:|
| p50 ms | 25.137 | 24.944 | 4 | 25.598 | 25.640 | 2 |
| p95 ms | 32.830 | 32.657 | 5 | 32.968 | 33.251 | **0** |
| p99 ms | 34.936 | 37.183 | 3 | 37.213 | 36.713 | 3 |
| maximum ms | 36.863 | 40.159 | 3 | 37.855 | 40.106 | **1** |
| GUI CPU ms/input | 4.028 | 4.009 | 5 | 4.130 | 4.365 | **1** |
| GUI lifetime peak RSS MiB | 201.133 | 205.758 | 4 | 204.688 | 199.617 | 3 |

Runtime CPU is 85.921/82.661 ms for single (B wins 5/6), and 99.305/100.860 ms
for splits (2/6); instructions/cycles win 4/6 and 5/6 for single, 2/6 and 2/6
for splits. Post hoc GUI CPU per measured wall second is 0.053491/0.056206 in
splits (B wins 1/6), while wall ms/input is 77.224/77.602 (2/6). The CPU loss
persists after this interval normalization, without identifying its cause.

**Reject:** four-split p95, maximum and GUI CPU consistently regress. The target
win cannot override those controls. No independent Zig acceptance series follows
this failure. All 42 owned shutdown receipts across pixels, target and controls
pass, together with runtime-resource cleanup checks. The seven original GUI files
and QML generated-resource metadata are restored; six new candidate files are
withdrawn into the frozen private snapshot. Reconfiguration/dependency rebuild
restores exactly accepted `bc55d0e8`. All four recorded dirty-runtime source hashes
are preserved. F01–F16/native120 and the unlimited goal remain open.

A separate follow-up, `out-perf/dlls-combined-splits-thread-cpu-01`, compares
the frozen binaries using measured-interval thread counters. Its first attempt
incorrectly reuses the tab-switch-specific probe/fixture for typing: setup fails
with zero completed samples and owned cleanup succeeds. That entire attempt is
invalid, not evidence of a GUI failure. A new private ordinary-typing probe adds
the same begin/end observer hooks; the counter C/header bytes match validated v2.
The current analyzer includes the already-checked sampler/boundary identity
guards. An initial overly broad equality assertion also detects those analyzer
guard differences before any probe compilation; the counter identity check is
then scoped to the actual counter sources. No repository harness is changed.

`/tmp/telar-perf-combined-splits-thread-cpu-02` completes three alternating
four-split pairs, 240 measured plus 20 warmup inputs each, with verified native
presentation, fixtures, equal grids, thread/process accounting and cleanup.
All 14 host bounds qualify, maximum load1 4.27685546875. CPU boundary differences
range from -1.732 to 0.311 ms, wall differences from -2.132 to 0.215 ms; signed
accounting residual bounds stay between -0.272 and 0.889 ms.
Unlike the acceptance controls, these runs include the observer and use 240
instead of 100 measured inputs. They cannot override the rejection.

| Diagnostic median over three pairs | A | B | B lower pairs |
|---|---:|---:|---:|
| Process CPU ms | 1089.506 | 1055.112 | 2/3 |
| Main-thread CPU ms | 405.528 | 391.191 | 2/3 |
| Render-thread CPU ms | 309.683 | 307.068 | 1/3 |
| Observer CPU ms, included | 76.585 | 75.461 | 1/3 |
| Measured wall ms | 18597.924 | 18573.170 | 2/3 |
| Main CPU / wall second | 0.021671 | 0.021067 | 2/3 |
| Render CPU / wall second | 0.016651 | 0.016537 | 1/3 |

The observer accounts for about 7% of process CPU in these short typing
workloads; its CPU is not subtracted and its scheduling effect is unknown.
Results are mixed and do not localize the original consistent regression.
The next diagnostic must preserve the 100-action workload and bound observer
perturbation before assigning the loss to main/render work, Qt conversions,
cache structure or code placement. All six diagnostic runtimes and the failed
setup runtime exit with complete cleanup. Production remains accepted `bc55d0e8`.

## Boundary-only thread counters and crossed calibration, 2026-11-04

The preceding periodic observer consumed about 7% of typing CPU and used a longer
workload than the failed control. `tools/macos_thread_cpu.c/.h` now offers an
explicit boundary-only mode: it creates no observer thread and takes exactly two
snapshots. The existing API still selects periodic sampling. The analyzer records
the sampling period, rejects extra samples in boundary mode and preserves signed
process residuals rather than assigning unseen-thread CPU to live threads.
`tools/build_thread_cpu_probe.py` now accepts `--workload typing --sampling
boundaries`; its defaults remain tab switching with periodic sampling. These are
diagnostic-tool changes; neither GUI nor runtime production code changes.

`out-perf/dlls-splits-boundary-cpu-01` freezes the observer patch, source hashes,
build commands and controls. Four report tests, including 16 corrupted-trace
controls, pass. ARM64 busy/sleep/churn controls pass in both modes, ordinarily and
with ASan/UBSan; all eight short-lived threads remain unseen in boundary mode and
their known approximately 80 ms appears in the residual. The first sanitizer
attempt aborts because leak detection is unsupported on this platform; the
successful runs explicitly disable it. Diagnostic tools use Apple Clang 21.0.0;
the frozen production binaries/toolchain remain those of the preceding report.

The x86 executable builds and runs under Rosetta but fails the independent
thread-clock control. A separate one-thread, 150 ms wall experiment observes
149.905 ms process CPU and 149.906 ms thread-clock CPU on ARM64, versus 149.919 ms
process CPU and 3.598 ms from both POSIX and `_np` thread clocks under translation.
This implicates the reference clock used by that control, without establishing
the platform cause. Mach counters are not rescaled to manufacture a pass; no
translated-x86 validation is claimed. All GUI measurements below are native ARM64.

The calibration crosses accepted A `bc55d0e8` and rejected B `ab2efd4a` with plain
and boundary-only probes, six alternating pairs for each comparison. Every run
uses exactly the failed control's four-split, 100-action/20-warmup workload, fonts,
grid, viewport, presentation endpoint and separate runtime-resource collection.
The ordinary native probe sources match; current Python measurement functions
match the archived probe's AST, while later CLI host-load guards are retained.

The first two series, `/tmp/telar-perf-splits-boundary-cpu-01` and `-02`, are
discarded in full at load1 6.75390625 and 5.501953125. Their timings are not pooled
or reused. `/tmp/telar-perf-splits-boundary-cpu-03` completes all 24 runs and 50
host checks, maximum load1 2.7177734375, without overlapping own builds/tests.
Native/content/grid/accounting/cleanup checks pass. All 30 owned shutdown receipts
across the valid and discarded series pass, as do resource-capture cleanup checks.

| Calibration within the same GUI | Plain median | Boundary median | Boundary lower pairs |
|---|---:|---:|---:|
| A GUI CPU ms/input | 4.412 | 4.174 | 4/6 |
| A p95 ms | 32.906 | 32.546 | 3/6 |
| A maximum ms | 37.715 | 41.486 | **1/6** |
| B GUI CPU ms/input | 4.438 | 4.410 | 4/6 |
| B p95 ms | 32.994 | 33.192 | 3/6 |
| B p99 ms | 36.989 | 37.635 | **1/6** |

Removing the periodic observer does not establish a neutral probe: tail
calibration still has consistent differences. Instrumented CPU is not corrected
by subtracting estimated snapshot cost, and its timings cannot rescue B.

| Candidate comparison | A median | B median | B lower pairs |
|---|---:|---:|---:|
| Plain p95 ms | 32.906 | 32.994 | **1/6** |
| Plain GUI CPU ms/input | 4.412 | 4.438 | 2/6 |
| Boundary GUI CPU ms/input | 4.174 | 4.410 | **1/6** |
| Boundary process CPU ms | 416.853 | 441.179 | 1/6 |
| Boundary main-thread CPU ms | 164.782 | 172.406 | 2/6 |
| Boundary render-thread CPU ms | 127.577 | 141.456 | 1/6 |
| Boundary render CPU / wall second | 0.016466 | 0.018310 | 1/6 |

The plain probe reproduces a consistent p95 loss. The instrumented render-thread
increase is a lead for an operation/frame census, not a demonstrated cause of the
original regression. Main and render threads exist at both boundaries; completely
unseen threads remain unassigned. Snapshot maxima span 0.115–0.480 ms, CPU boundary
differences -1.146–0.284 ms and wall differences -1.647–0.199 ms. Signed residual
bounds span -0.242–31.236 ms; they are not exact dead-thread CPU. Medians from
different accounting categories must not be added as a per-run decomposition.
The next investigation will count actual render work in the same 100-action
scenario before changing another cache/call structure. Accepted GUI `bc55d0e8`
and the four preserved runtime source hashes remain unchanged. B stays rejected;
all F01–F16/native120 requirements and the unlimited goal remain open.

## Render-work census of the split typing regression, 2026-11-04

`tools/build_render_work_probe.py`, `render_work_census.c/.h` and
`render_work_report.py` add a private legacy-Metal operation census around the
ordinary typing probe. Counters run only between its existing measured
boundaries. A lock makes category pairs and the final snapshot coherent; there
is no observer thread or per-event log. The analyzer rejects incomplete/schema
errors, unclassified requests, missing native work and unsupported Metal4.
Private GUI source hooks must also demonstrate terminal synchronization and row
work. Callback counts are not display cadence and pass counts are not draw calls.
Neither this probe nor the source hooks establish neutral timing overhead.

`out-perf/dlls-splits-render-work-01` retains the builds, hook sources, manifests,
original/generated source restoration and summary. Native ARM64, ASan/UBSan
(leak detection off), and translated-x86 integer/concurrency controls pass:
eight workers, exact paired counts, concurrent stop, inactive boundaries,
restart, overflow and invalid enum rejection. These controls do not depend on
the translated thread clock that failed the previous CPU experiment. Three
report tests with 15 corrupted-input controls pass. A separate injected-symbol
control passes and its uninjected negative control fails as intended.

The unmodified accepted A `bc55d0e8` and rejected B `ab2efd4a` run three
alternating pairs of exactly 100 inputs plus 20 warmups in four splits.
`/tmp/telar-perf-splits-render-work-metal-01` passes all 14 host boundaries,
maximum load1 1.86083984375. Commits, render passes, IOSurface passes, drawable
returns and positive presentation callbacks coincide within each run:
A `[103, 105, 103]`, B `[104, 104, 105]`. Offscreen passes, nil returns,
zero-time callbacks and Metal4 counters are zero. No software hooks are present.
This does not show a substantially larger frame volume in B or explain its CPU
regression.

Private source-instrumented A `aa358d5c` and B `f72aaa26` additionally count
terminal synchronization, repainted rows, text chunks, spans, mesh operations,
classified glyph requests and tab layout/model updates. Each matches its own
uninstrumented reference byte-for-byte in a settled full-window four-split PNG;
all four images have SHA256 `ea6c64606637ad762dc86a5fac1e1558b3d61d5027a59c9fd75209bd71f2afdb`.
The source witnesses pass. These images do not establish animated equivalence.

`/tmp/telar-perf-splits-render-work-source-01` completes another three alternating
pairs, 14 host boundaries, maximum load1 3.697265625. No own builds/tests overlap
either census series. Counts below are per 100 measured inputs, in pair order:

| Operation | A | B |
|---|---|---|
| Commits / IOSurface passes / positive callbacks | 103, 103, 103 | 104, 104, 104 |
| Terminal sync / repainted rows / text chunks | 100 each run | 100 each run |
| Optical paint / rebuild | 100 each run | 100 each run |
| Optical spans / requests / hits | 3900 each run | 3900 each run |
| Optical rasterizations / residency reuse / mesh create or reuse | 0 | 0 |
| Standard text requests | 8, 8, 6 | 24, 29, 22 |
| Standard text mesh creations | 3, 4, 3 | 6, 7, 6 |
| Tab layout / typed reconciliation / typed updates | 0 | 0 |

The fixture changes the background of one space. The terminal path still visits
39 spans per repainted row, but all optical requests hit and emit no text meshes.
Thus cold optical mask reuse and typed tab reconciliation do no useful work in
this measured interval. B has extra standard interface text work in these runs;
its identity and contribution to the original CPU regression remain unproved.
Counts alone cannot assign the loss to allocation, Qt conversion or code
placement. B remains rejected. A separate source/assembly lead is that empty
masks acquire a temporary shared reference before the null-image check; this
avoidable work can be tested independently without assuming spaces are always
empty in every font.

All 16 owned runtime shutdowns (12 census runs plus four image runs) and resource
capture cleanup checks pass. Production source and GUI binary restore exactly to
`bc55d0e8`; the four pre-existing runtime source hashes remain unchanged. Only
diagnostic tools and this report are retained. All F01–F16/native120 requirements
and the unlimited goal remain open.

## Empty glyph reference fast path rejected, 2026-11-04

The work census exposed an independent, concrete cost in the accepted renderer:
`ChromeScene::appendSpan` constructs a `GlyphPlacement`, copying its shared mask
reference, before testing whether the mask image is null. A four-line candidate
moves construction after that check and preserves the glyph advance in both
paths. It assumes nothing about which characters or fonts produce empty masks.
This avoids reference/copy work, not a heap allocation per glyph, and does not
establish the cause of the preceding combined-candidate regression.

`out-perf/dlls-empty-glyph-reference-01` freezes accepted A `bc55d0e8`, candidate
B `31330f0f`, original/candidate source, build and validation commands, resource
receipts and the rejected patch. Runtime `1f1849d1` and helper `87beebb0` are
identical in both stages. Production uses the existing LLVM 23.1.4/Qt 6.12
Release configuration on the native ARM64 M1 Pro; the probe, fonts, grids and
presentation endpoint remain unchanged.

Four focused tests pass: row text, optical text, chrome text and scene rendering,
including retained/fresh rows, font styles, combining sequences, selection and
cursor behavior. Three settled full-window native PNG comparisons (single,
four splits and tabs) are byte-exact. `clang-tidy` reports no user-code warning;
third-party warnings are suppressed. Actual ARM64 disassembly shows that null
images skip the temporary-reference increment and decrement (`ldaddal`) in B;
the optical caller still reserves 368 stack bytes. Both standard and optical
specializations compile for baseline x86-64 and x86-64-v3 and branch around the
two locked reference operations. These are compilation/lowering checks, not
linked/executed x86 Qt or Linux validation. No byte-identical placement claim is
made. An initial objdump invocation emitted whole-binary listings; the corrected
symbol-specific listings are the reviewed evidence.

The ordinary, uninstrumented probe runs six alternating pairs in each of single
and four-split typing, 100 measured inputs plus 20 warmups, in
`/tmp/telar-perf-empty-glyph-reference-pairs-01`. All 24 runs and 50 host boundaries
qualify; maximum load1 is 3.4814453125. No own build, test, lint or profiler
runs overlap timing. Native identity/content/grid/presentation checks pass.

| Case / metric | A median | B median | B lower pairs |
|---|---:|---:|---:|
| Single p50 ms | 24.936 | 25.250 | 3/6 |
| Single p95 ms | 32.872 | 33.127 | 3/6 |
| Single p99 ms | 37.258 | 36.362 | 3/6 |
| Single maximum ms | 38.259 | 38.733 | 3/6 |
| Single GUI CPU ms/input | 4.118 | 4.171 | 2/6 |
| Single GUI peak RSS MiB | 206.117 | 204.313 | 4/6 |
| Splits p50 ms | 26.045 | 25.434 | 5/6 |
| Splits p95 ms | 33.117 | 31.873 | **4/6** |
| Splits p99 ms | 38.099 | 35.193 | 5/6 |
| Splits maximum ms | 40.732 | 37.334 | 5/6 |
| Splits GUI CPU ms/input | 4.284 | 4.128 | **4/6** |
| Splits GUI peak RSS MiB | 200.164 | 205.508 | 4/6 |

Separate runtime CPU, including setup/warmup/measurement and excluding child CPU,
is 84.790/87.812 ms for single (**1/6** lower pairs) and 99.611/99.985 ms for
splits (4/6). End-boundary footprint is 13.883/13.860 MiB and 17.438/17.383 MiB,
respectively (both 4/6). Runtime instruction/cycle wins are 3/6 and 2/6 in each
case. These accounting intervals differ from GUI measured-input CPU and are not
summed. The runtime binary is unchanged; the cause of the CPU difference is not
established.

Reject B: target split p95 and GUI CPU win only 4/6 pairs, single GUI CPU only
2/6, and single runtime CPU loses consistently. The split median reductions and
smaller empty-glyph path do not satisfy acceptance. RSS is not the rejection
reason. No additional independent Zig acceptance series is warranted for this
rejected variant. All 30 runtime shutdowns (24 timings plus six PNG runs) and
runtime resource cleanup checks pass. The one production source file is restored;
the configured GUI matches accepted `bc55d0e8` byte-for-byte. The four
pre-existing runtime source hashes remain intact. All F01–F16/native120 complete
flow requirements and the unlimited goal remain open.

## Representative ASCII TUI qualification and work profile, 2026-11-04

The preceding typing fixture changes a space's background. A new, explicitly
separate `tui` case exercises ASCII text throughout an alternate screen: full
repaints every eight inputs, one-quarter of rows otherwise, grayscale foreground
and background changes, bold styles, a moving visible cursor and alternate-screen
resets every 32 inputs. Each update writes its body before the existing native
marker. Geometry changes rebuild the fixture, with SIGWINCH deferred through
output and the receipt. Producer generation and receipt I/O are part of this
workload; their overhead has not been separately calibrated. This is an
interaction trace, not a continuous 120 Hz producer or complete F05 acceptance.

Reusable sources are `tools/tui_bench_trace.py`, `tui_bench_fixture.py`,
`tui_bench_report.py`, `read_cpp_pane.cpp` and `build_tui_bench_probe.py`.
The builder copies the ordinary native presentation probe unchanged, selects a
separate fixture, labels results `tui` rather than `single`, and verifies all final
runtime text rows after GUI exit and before cleanup. C++ uses the existing typed
protocol client; Zig uses its frozen `pane read --source screen --json` command.
The check rejects wrong identities, truncated/exited replies, missing/stale row
updates and text mismatches. It does not verify cell styles or all intermediate
presented body pixels. The shared report loader rejects TUI results without the
matching final-screen qualification.

Nine fixture/report tests pass, including an independent interpreter of the
fixture's CSI subset, full/partial/reset/resize/capture transitions, damaged
payloads and 17 malformed-content/receipt controls. All 20 ordinary native-harness
report tests pass, including the new TUI admission guard. The C++ reader builds
with `-Wall -Wextra -Werror`; seven argument/connection-failure controls pass.
Production GUI/runtime source and binaries remain unchanged. Tool builds use
Apple Clang 21.0.0; a prototype reader also built with LLVM 23.1.4. No x86/Linux
GUI validation is claimed.

`out-perf/dlls-tui-trace-01`, `-02` and `-04` retain development, profiles and final
reproducible qualification; `-03` is an unrun intermediate builder. The native
stacks remain C++ GUI `bc55d0e8` plus runtime `1f1849d1`, versus independent Zig
`6ccf7948`, using the same JBM15 optical configuration and 1600×1000 viewport.
Both have an 82×21 PTY and 2× backing scale. The initial 20-measured/20-warmup
qualification ends after a full repaint at sequence40. A second, 23/20 run ends
at sequence43 after partial updates. Both stacks return exactly the modeled text
in both successful series. A capture attempt with zero idle time fails before
inputs because the controller checks capture completion immediately; it remains
invalid. The corrected capture controller uses the existing 0.2-second capture
settle, without changing the native witness or pixel tolerances.

The final builder is exercised through its actual CLI in
`/tmp/telar-perf-tui-builder-qual-01`, one diagnostic pair, 23/20 inputs. Both final
screen checks pass with normalized text SHA256
`e9c6dab3ea45cb541615ab766bdce660942832671ceb9d0a7d0ccfbf7b91a712`.
The shared source report loader admits those qualified results. A separate
live negative control corrupts only the expected-text receipt: all 23 native
presentations complete and native `failed` remains zero, but the final-screen
oracle rejects it, no comparison is published, and cleanup completes. This is a
content-oracle failure after successful native activity, not a setup-failure
substitute.

Full-window C++/Zig PNGs in `/tmp/telar-perf-tui-trace-qual-03` are **not**
byte-exact: 5,167 of 1,600,000 pixels differ, maximum channel delta141. Manual
inspection of the terminal interior rectangle `(120,84)..(1596,924)` finds 435
differing pixels, all in the seven bold rows, with maximum channel delta1; other
differences are outside that rectangle. This region is an inspected diagnostic,
not a general pane detector or a relaxed oracle. The cause remains unestablished;
visual parity is not certified and tolerances are not widened.

A separate two-stack profile uses 240 measured inputs after 20 warmups in
`/tmp/telar-perf-tui-trace-profile-01`. Four eight-second samplers at 1 ms start
after sequence25, with verified GUI/runtime process identities. C++ GUI/runtime
finish at sequences133/129; Zig at131/129, all before the final sequence260.
Both final text checks pass. Inclusive C++ GUI stack observations include:
terminal synchronization40, row painting36, text preparation8, node insertion/
removal14, merged-batch rendering22, opaque-batch preparation17 and render-list
construction15. Groups overlap, waits dominate the traces, and these are neither
call counts nor CPU percentages. C++ runtime feed/refresh observations are5/3;
these sparse samples do not establish a runtime bottleneck. Instrumented timings
are not acceptance evidence.

Source inspection of `qt/terminal_scene.cpp::paintRun` identifies a new algorithmic
lead: every nondefault-background cell appends its own `QSGSimpleRectNode`. A
uniform 82-cell row therefore creates 82 background rectangles even when one
opaque run would cover the same area. This is a source-derived work count, not a
measured allocation census. Coalescing adjacent opaque backgrounds could remove
node and renderer bookkeeping; it still needs pixel oracles for alternating
colors, transparent and wide/continuation cells, selection, scale and clipping,
plus paired application evidence. The previously rejected attached-text-root
experiment is not being reinstated.

All completed diagnostic series pass their host gates: maximum load1 is 4.013672
in the profile, lower in qualification. The failed capture and deliberate negative
control remain ineligible. All ten owned runtime/child shutdowns and resource
capture cleanups pass. Prototype profile resource snapshots precede the final
screen query. The reusable builder's query precedes `stop_runtime`, so callers
wrapping that with the ordinary resource adapter must account for its query in
the wider runtime interval; no such runtime timing acceptance is claimed here.
Accepted GUI `bc55d0e8` and all four pre-existing runtime source hashes remain
intact. No performance optimization is accepted by this tooling/profile pass;
all F01–F16/native120 requirements and the unlimited goal remain open.

## Opaque row background runs rejected on tail consistency, 2026-11-04

The representative TUI profile leads to one algorithmic experiment, retained in
`out-perf/dlls-row-background-runs-01`: accumulate adjacent, equal, opaque cell
backgrounds and append one rectangle per run. `paintRow` still visits every cell;
background node allocation, color conversion and scene-graph insertion become
proportional to runs. Exact adjacency is required. Overlapping wide/continuation
rectangles retain their ordering; translucent rectangles are never merged. No
persistent cache or additional heap buffer is introduced. The previous rejected
attached-text-root change remains absent.

The new `SceneTest::rowBackgroundsMatchIndependentRectangles` oracle renders
independently specified rectangles and compares every pixel against the terminal
scene. Seven cases cover uniform/alternating backgrounds, default-color gaps,
selection plus inverse, wide/continuation overlap, translucent overlap and clipped
wide cells. Each uses three integer/fractional cell widths and a repeated
appearance invalidation. The accepted baseline passes software and native Metal.
The first candidate fails five software cases at fractional width9.2/scale1;
Metal passes. That candidate is retained as a negative control. The revised
candidate keeps individual rectangles on Qt's software backend and passes all45
scene checks on both software/offscreen and native Cocoa/Metal. No tolerance is
relaxed. Native Metal runs at backing scale2; these tests do not certify every
scale, Linux or x86 Qt execution.

Frozen revised GUI B2 is
`30d12a5a2667d8aa5d53fb8baa1bbbd287c1a1b43bda6acba2c3830bedf10bfc`,
against accepted A `bc55d0e8`. Both use unchanged runtime `1f1849d1`, helper
`87beebb0`, LLVM23.1.4, Qt6.12 and the same optical JBM15 configuration. Native
qualification in `/tmp/telar-perf-row-background-pixels-01` produces byte-exact
full-window PNG pairs for TUI, single typing and four splits. All six runs and14
host boundaries qualify (maximum load1 2.69580078125). The final TUI text oracle
also passes; settled PNGs do not prove every intermediate TUI body frame.

ARM64 `paintRow` disassembly shows the matching-run path bypassing
`QColor::fromRgbF`, `operator new(312)`, `QSGSimpleRectNode` construction and
`appendChildNode`. Its stack frame grows from576 to656 bytes. The same actual
translation unit compiles for x86-64 baseline and v3: baseline uses
`cmpeqps`/`movmskps` for the color comparison, v3 uses `vcmpeqps`/`vtestps`, followed
by ordered scalar geometry comparisons and the same allocation-bypassing branch.
This is static lowering evidence, not executed x86 GUI validation. Clang-tidy
reports no diagnostics. For one complete 82×21 ASCII frame, source-derived
background rectangle counts fall from1,722 to23 (one per ordinary row, three in
the marker row); actual frame/invocation/allocation counts were not instrumented.

The first timing attempt, `/tmp/telar-perf-row-background-tui-pairs-01`, fails
initial native presentation qualification on A before any inputs. Its cause is
not established; it is retained and excluded. The unchanged retry in
`/tmp/telar-perf-row-background-tui-pairs-02` completes six alternating pairs,
100 measured inputs plus20 warmups each, using the ordinary native probe without
profilers or counters inside its measured interval. All12 final text and native
presentation checks pass. All26 host boundaries qualify; maximum load1 is
2.138671875. No own compilation, tests or profiling overlaps this series.

| TUI metric | A median | B2 median | B2 lower pairs |
|---|---:|---:|---:|
| p50 ms | 28.851 | 26.983 | 6/6 |
| p95 ms | 39.803 | 38.645 | **4/6** |
| p99 ms | 46.545 | 44.592 | 6/6 |
| Maximum ms | 49.779 | 48.498 | 4/6 |
| GUI CPU ms/input | 5.377 | 4.498 | 6/6 |
| GUI peak RSS MiB | 223.203 | 209.625 | 5/6 |

Separate runtime CPU is105.180/99.733 ms (5/6 lower pairs), instructions
179,585,682/179,169,847 (4/6), cycles185,938,169/178,614,902 (5/6), and end-boundary
footprint14.235/14.196 MiB (3/6). This interval includes GUI setup, warmup, measured
inputs and the final TUI screen query; it excludes runtime startup/shutdown and
child CPU. It differs from GUI measured-input CPU and is not summed with it.
The runtime binary is unchanged; the cause of its CPU difference is not established.

Reject promotion despite the16.3% GUI CPU and6.5% median-latency reductions:
target p95 improves only4/6 pairs. Memory is not the rejection reason. The saved
work and candidate remain available for a later distinct experiment, without
repeating this valid series to seek a favorable result. Further typing-regression
or independent Zig acceptance timings are not warranted for this rejected variant.
All19 owned runtime/child shutdowns and resource capture cleanups pass. Production
source is restored and the configured GUI is verified byte-exact against accepted
`bc55d0e8`; all four pre-existing runtime source hashes remain intact. The reusable
background oracle is retained, with named test patterns. Its final seven cases
pass again on software and Metal, and changed-line clang-tidy is clean. Whole-file
clang-tidy retains two pre-existing diagnostics in the older text test: Qt
`_data` naming and a non-const `QFETCH(bool)`. All F01–F16/native120 complete-flow
requirements and the unlimited goal remain open.

## TUI tail partition and input-epoch render census, 2026-11-04

The row-background experiment remains rejected. A post-hoc partition of its
already qualified six-pair series separates each run's87 partial updates,10 full
updates and3 alternate-screen resets. The script and raw derivation are in
`out-perf/dlls-tui-tail-work-01/partition.py` and `partition.json`; the source
series remains `/tmp/telar-perf-row-background-tui-pairs-02`. Classification uses
input sequence after the declared20 warmups, not observed latency. These small
subgroups are descriptive, not replacement acceptance metrics.

Partial-update presentation p50 medians are28.133/26.141 ms (B lower6/6), and p95
35.535/33.622 ms (5/6). Full-update p50 is30.362/35.196 ms (**1/6** lower), while
its p95 is46.275/46.468 ms (3/6). Reset p50 is37.930/37.590 ms (4/6). In each
variant's30 slowest-five observations across runs,16 are full updates,6 resets
and8 partial updates. Full-update GPU-work p50 is0.270/0.281 ms (0/6 lower), but
neither those command-buffer durations nor the signed presentation-minus-GPU
callback residual establish the cause of the presentation difference. No accepted
result is inferred from selecting a favorable subgroup.

First reuse the existing aggregate legacy-Metal census with the TUI harness and
unmodified frozen GUIs A `bc55d0e8` and rejected B2 `30d12a5a`, both with runtime
`1f1849d1`. Two instrumented PNGs match their ordinary-probe full-window PNGs
byte-for-byte in `/tmp/telar-perf-tui-tail-census-pixels-01`. Three alternating
100-measured/20-warmup pairs in `/tmp/telar-perf-tui-tail-census-pairs-01` count
A commits115/109/110 and B115/113/113. Aggregate counts cannot assign that work to
a specific input, so they do not explain the tail regression.

`tools/render_work_census.h/.c` and `build_render_work_probe.py` now additionally
record the input epoch observed at each qualified queue's commit entry. A bounded
513-entry table accommodates the native probe's512 inputs plus epoch0, with a
compile-time capacity check. The total and sequence counter increment together
under the existing census lock; end-boundary snapshots cannot split the partition.
Overflow/out-of-range observations fail closed. The table adds4,104 bytes to each
diagnostic snapshot; production application code is unchanged. The attribution
includes work between inputs and does **not** identify the content or cause of a
frame. It is not a display-cadence measurement.

`render_work_report.analyze_sequences` requires the exact sequence table, integral
counts, matching total, valid warmup/range, no attribution after the final input,
and at least one commit per measured input. Boundary work before the first
measured input is preserved separately. Six report tests pass, including13 new
sequence/range negative controls alongside the existing15 aggregate controls.
The original concurrent aggregate control still passes. New
`tools/render_sequence_control.c` covers concurrent partitioning, stop, restart,
inactive boundaries, invalid indexes and overflow; it passes ordinary ARM64,
ASan/UBSan with leak detection disabled, and x86-64 under Rosetta. This validates
the counter, not x86 Qt rendering or comparative performance.

The extended probe passes another byte-exact PNG pair in
`/tmp/telar-perf-tui-sequence-census-pixels-01`. Three alternating diagnostic pairs
in `/tmp/telar-perf-tui-sequence-census-pairs-01` preserve all final text/native
qualification checks. Results are:

| Variant | Commits across three runs | Extra partial commits | Extra full commits | Extra reset commits |
|---|---|---:|---:|---:|
| A | 108 / 111 / 114 | 7 | 19 | 7 |
| B2 | 113 / 116 / 113 | 14 | 21 | 7 |

Each variant has261 measured partial inputs,30 full inputs and9 resets. Neither
has any pre-measurement-context commits in the measured census. In both variants,
26 of39 full/reset input epochs have multiple commits; therefore an increased
frequency of multi-commit full updates is **not** established as the explanation
for B's slower full-update median. Some epochs contain three commits. Across all
four diagnostic series, commits equal surface passes, drawables and positive
presentation callbacks per run; offscreen passes, zero callbacks and source hooks
are zero. This does not prove that every frame contains a complete TUI update.

All four series qualify their host gates; maximum load1 is2.541015625. All16 owned
runtime/child shutdowns and resource cleanups pass. No build, test or profiler
overlaps the native series. Diagnostic timings do not count toward acceptance.
Accepted GUI `bc55d0e8` and the four pre-existing runtime source hashes remain intact.

A concrete next control is producer fragmentation. `TuiFixture::draw_marker`
writes the body, native marker and final cursor separately. The body is2,602 bytes
for an ordinary full82×21 update and2,626 bytes for a reset. Emitting exactly the
same bytes in one write, after a byte-stream oracle, can test whether intermediate
work depends on those boundaries. That changes producer behavior and must remain
a labeled diagnostic, not a production optimization or an easier acceptance
workload. No causal scheduling claim or new optimization is accepted here. All
F01–F16/native120 complete-flow requirements and the unlimited goal remain open.

## 2026-11-04 — Retained background rectangles rejected despite allocation reduction

`out-perf/dlls-retained-background-nodes-01` tests the heap-site lead against the
accepted stack at source `87964cefd`. A private row helper reuses existing
`QSGSimpleRectNode` siblings in order, updates their rectangle only when it differs,
updates their color through Qt's existing equality guard, appends missing nodes,
and deletes unused trailing nodes on scope exit. Each original rectangle remains
separate, including overlapping wide cells and translucent backgrounds. There is
no extra heap cache; existing scene children hold the reusable nodes. Grid changes
retain the existing whole-grid reset behavior. This differs from the previously
rejected rectangle-merging candidate.

The first prototype uses a static downcast and passes the visual checks, but
clang-tidy rejects that cast. The final B2 uses a checked reference dynamic cast
and passes production lint. Only B2 is measured. Its GUI hash is
`43914e7f0a7987bb156a2006ba2b0fe7e4665c7fbc1111f2b6282425817b34e4`;
accepted A remains `bc55d0e8`, and both use runtime `1f1849d1` and helper `87beebb0`.
Build/toolchain/dependencies are unchanged LLVM23.1.4, Qt6.12 Release/O3. Candidate
source, patch, frozen executables and all commands remain in the ignored prefix.
Production `terminal_scene.cpp` and the configured GUI executable are restored to
the byte-identical accepted baseline before native measurements.

The new reusable `changedBackgroundsMatchFreshRectangles` test keeps a production
scene alive while a separate reference builds fresh individual rectangles. It
checks seven background patterns at cell widths9,9.2 and9.1: uniform, default gaps,
alternating, selection/inverse, wide overlap, translucent wide overlap and clipped
wide cells. Each transition checks the new image, an unchanged appearance repaint,
and return to all-default backgrounds, giving63 image comparisons per backend.
The reference and candidate pass on software and Metal. Deliberately disabling
trailing-node removal fails exactly the default-background comparison; the oracle
does not depend on the candidate's node layout or allocation policy. Both full B2
scene suites pass46 QtTest cases. Changed test lines pass scoped clang-tidy.

The actual candidate translation unit compiles for x86-64 baseline and v3.
Accepted/candidate listings are retained. ARM disassembly shows the reused-node
path calling the dynamic cast, reading the existing rectangle, conditionally
updating geometry, and setting color, while bypassing `operator new(312)`, the
rectangle constructor and child insertion. New nodes still use the original
allocation path; the unused tail has a deletion loop. These lowerings are not
executed x86/Linux whole-GUI validation or a CPU-gain claim.

`/tmp/telar-perf-retained-background-pixels-01` passes all six full-window PNGs
for TUI, single typing and four splits, against both A/B and accepted references.
`...retained-background-tui-pairs-01` then qualifies six alternating ordinary pairs
of100 measured inputs plus20 warmups. No heap/render census, own compilation,
tests or profiler overlaps those runs. Configuration is optical JBM15,1600×1000,
scale2 and82×21 TUI cells. `hypothesis.json` freezes both TUI p95 and GUI CPU as
co-primary metrics requiring at least5/6 lower pairs before any timing starts.

| TUI metric | Accepted A | Retained B2 | B2 lower pairs |
|---|---:|---:|---:|
| p50 ms | 28.298 | 28.802 | **1/6** |
| p95 ms | 41.675 | 40.707 | **3/6** |
| p99 ms | 47.136 | 46.673 | 4/6 |
| Maximum ms | 52.028 | 50.186 | 4/6 |
| GUI CPU ms/input | 5.169 | 4.997 | **3/6** |
| GUI peak RSS MiB | 217.969 | 221.359 | 1/6 |
| Runtime CPU ms/run | 99.125 | 96.330 | 4/6 |

Both co-primary metrics fail the acceptance threshold and p50 regresses
consistently. That rejects the candidate; the small RSS increase does not.
Runtime intervals include GUI setup, warmup, measured inputs and final TUI text
query, exclude runtime startup/shutdown and child CPU, and are not added to GUI
interval CPU. Runtime instructions are179,736,739→179,589,592.5 (3/6 lower).
The cause of the latency regression is not established. Further typing/split/load
regression series are unnecessary for this decisively rejected target candidate.

A separate same-stack sampled-heap pair in `...retained-background-census-01`
confirms the intended mechanism without reversing the ordinary decision:
successful covered allocation calls fall184,695→110,071 and requested bytes
40,605,430→17,103,920 over100 inputs. Recorded stacks are734/465. Scene-inclusive
samples fall289→16;312-byte allocations at the background `paintRow` site fall
275→2. The normalized return PCs match the old constructor path and B2's cold
new-node branch. Metal-binding samples remain321/356. Counts include framework
and probe work, categories overlap, and this single perturbed pair neither proves
a repeatable allocation percentage nor attributes CPU or latency to allocations.

All three native series qualify their host gates:14 pixel boundaries (maximum
load1 3.87695),26 timing boundaries (2.76758), and6 census boundaries (2.43457).
All20 owned runtime/child shutdowns and resource cleanups pass. Accepted binaries,
production scene source and all four pending runtime hashes remain verified intact.
`validation.json`, `table.json`, `attribution.json` and `decision.json` retain the
audit. Only the independent transition oracle and this report are committed.

The next investigation should revisit the previously inconclusive Metal-binding
experiment on the current accepted GUI, with qualified ordinary pairs and the
new site census. Eliminating one large allocation category has not produced the
required full-client gain. All F01–F16/native120 requirements and the active goal
remain open.

## Byte-equivalent TUI producer control, 2026-11-04

The next diagnostic changes only the producer's write boundaries. New
`tools/tui_coalesced_fixture.py` combines the ordinary body, marker and final
cursor buffers into one `write_all` call. This is not an atomic-output guarantee:
short writes may require several system calls, and the consumer may read separate
pieces. Capture still writes its separate witness first. The original TUI fixture
and production application code are unchanged.

The byte-stream oracle compares 510 draws across five geometries, repeated input,
full/reset transitions and capture. Bytes and trace models match exactly; ordinary
draw calls decrease from three to one and capture calls from four to two. Forced
short writes of one, seven and257 bytes preserve the complete stream. All12 TUI
and20 shared-harness tests pass. The builder exposes `--write-mode coalesced` and
records that mode in its manifest and validated receipt. The shared timing loader
rejects this diagnostic workload; older ordinary receipts retain their original
meaning through the default `split` mode.

Artifacts and the frozen controller are in `out-perf/dlls-tui-write-control-01`.
Both modes use accepted GUI `bc55d0e8`, runtime `1f1849d1`, helper `87beebb0`, the
same optical JBM15 configuration, native1600×1000 viewport/backing scale2 and
82×21 PTY. In `/tmp/telar-perf-tui-write-control-pixels-01`, both full-window PNGs
match the previous ordinary TUI baseline byte-for-byte. Final text checks pass.
Three alternating diagnostic pairs,100 measured inputs plus20 warmups per run,
in `/tmp/telar-perf-tui-write-control-pairs-01` produce:

| Producer | Commits across three runs | Extra partial commits | Extra full commits | Extra reset commits |
|---|---|---:|---:|---:|
| Original split writes | 113 / 114 / 109 | 10 | 21 | 5 |
| Coalesced draw buffer | 112 / 109 / 110 | 10 | 15 | 6 |

Full/reset epochs with multiple commits are23/39 and20/39 respectively. Extra
commits persist in both modes; this small diagnostic does not establish producer
write boundaries as their cause or constitute a performance acceptance result.
Commit attribution records the observed input epoch, including inter-input work,
not the causal origin or contents of each frame.

A separate pair in `/tmp/telar-perf-tui-write-readback-01` enables the existing
native readback log. All100 measured epochs are represented, geometry matches,
and readback counts equal census commits:110 split and109 coalesced. The split
run contains five non-marker pixel samples, all in full/reset epochs, plus one
opposite-color sample in a partial epoch. The coalesced run contains six non-marker
samples, again in full/reset epochs. Both also contain repeated matching-marker
samples. Thus one contiguous producer draw buffer does not eliminate intermediate
non-marker pixels. This observes one marker point, not complete body frames, and
does not demonstrate where bytes or terminal updates split. Logging perturbs the
run; its timings remain diagnostic. The parser and exact samples are retained in
`readback.py` and `readback-summary.json` under the artifact prefix.

The final public builder and generated CLI also pass a native23-input capture run
in `/tmp/telar-perf-tui-coalesced-public-01`, including exact final text and explicit
coalesced labeling. Replaying its result through the ordinary report is rejected
as intended. Across the four series, all host gates qualify; maximum load1 is
3.70166015625. All11 owned runtime/child shutdowns and resource cleanups pass.
No own build, tests or profiling overlaps the native series. The accepted GUI and
all four pre-existing dirty runtime source hashes remain intact.

A useful next observation is the actual PTY read boundary. The accepted runtime
uses a16KiB buffer and, for one pane, a burst capped at eight reads/64KiB; each
positive read feeds the terminal before another read. A roughly2.6KiB full TUI
body does not itself exceed that buffer. Whether kernel readiness/read boundaries
expose intermediate updates still requires evidence. The allocation/copy/Qt
conversion hypothesis remains open, and bounded memory tradeoffs remain eligible
when they demonstrably avoid work. No production optimization is promoted here;
all F01–F16/native120 complete-flow requirements and the unlimited goal stay open.

## PTY read boundaries and intermediate marker pixels, 2026-11-04

New Darwin diagnostic `tools/pty_read_probe.c` observes `read` and `readv` only
for an exact configured executable and terminal descriptors. The owned runtime
launcher and daemon get separate bounded shared mappings; fork children are
excluded by PID. Each record retains syscall entry/return timestamps, requested
capacity, result, errno and complete returned bytes. Capacity is16,384 records
plus4MiB of bytes (5,505,088 bytes total mapping). There is no per-read file write,
but filtering, clocks, locking, copying and page faults perturb execution. This
is diagnostic instrumentation, not a production memory/performance change.

`pty_read_control.c` verifies6,000 exact bytes across scalar/vectored reads,
errno preservation, non-terminal pipe exclusion, fork exclusion and invalid-iovec
EFAULT handling. Plain, observed, deliberately overflowing and wrong-executable
controls pass on ARM64 and x86-64 under Rosetta; ARM ASan/UBSan also passes with
leak detection disabled. The initial scalar-only control used3,000 bytes. A
single blocking producer write cannot be completed synchronously before reading
on this PTY: the first control attempt timed out before instrumentation. Its
replacement uses a writer thread and bounded poll waits; no process survived the
failed attempt. Three Python decoder tests pass, including18 malformed/truncated
trace controls and five invalid expected identities. Empty, unsealed and overflowed
traces are rejected. Failed vectored calls intentionally record capacity0 without
dereferencing potentially invalid iovecs. The wire record does not distinguish
scalar from vectored calls.

Artifacts, frozen sources/binaries, controllers, byte reconstruction and readback
parsers are in `out-perf/dlls-pty-read-boundaries-01`. No runtime is rebuilt.
Accepted GUI `bc55d0e8`, runtime `1f1849d1`, helper `87beebb0` and independent Zig
`6ccf7948` remain unchanged. All runs use the same optical JBM15 configuration,
1600×1000 native viewport/backing scale2 and82×21 PTY. Only the owned runtime's
startup receives the extra library; the native GUI probe is injected separately.

First, scalar-read instrumentation passes two exact settled full-window PNG
comparisons in `/tmp/telar-perf-pty-read-pixels-01`, using split and coalesced
producers on the accepted C++ application. A100-measured/20-warmup diagnostic
pair in `/tmp/telar-perf-pty-read-boundaries-01` reconstructs the entire continuous
expected byte stream from input8 through120 in both modes. The parser also
requires the expected runtime PID, a single terminal descriptor, complete byte
partition and no overflow. Startup bytes outside that verified interval are not
claimed equivalent. Every request is16KiB; the largest positive return is1KiB.

| C++ producer | Partial inputs in multiple reads | Full/reset inputs in multiple reads | Incomplete inputs interrupted by EAGAIN | Non-marker pixel epochs |
|---|---:|---:|---:|---:|
| Split | 38/87 | 13/13 | 9 | 8 |
| Coalesced | 0/87 | 13/13 | 6 | 6 |

All eight split non-marker epochs and all six coalesced non-marker epochs coincide
with an EAGAIN between the first and last bytes of that update. The ninth split
gap is a partial update with an opposite-marker sample. Each run has110 qualified
commits/readbacks. Multiple reads alone are insufficient: some full updates are
read completely in the same burst and have no non-marker sample. The coalesced
control demonstrates that the phenomenon does not require separate body/marker
producer calls. One sampled pixel is not a full-frame oracle, and instrumentation
can affect the frequency. This correlation does not yet trace the runtime frame
publication or prove every extra commit's cause.

Two attempted independent-stack qualifications are excluded, with clean owned
shutdowns. `/tmp/telar-perf-pty-read-stacks-pixels-01` uses the legacy-Metal census,
whose queue-identity guard exits75 on Zig after warmup; it cannot supply this
cross-renderer census. The ordinary native probe supports both renderers and is
used thereafter. In `...stacks-pixels-02`, native presentation/final text succeed,
but Zig's scalar-only read trace is empty. This is missing observation, not zero
PTY work. Adding vectored-read observation and passing its controls resolves that
coverage gap. `...stacks-pixels-03` qualifies both final probes and produces exact
PNGs against each application's own prior ordinary-probe reference. Existing
C++/Zig cross-application visual differences remain open; references are not
substituted for cross-application parity.

A final independent-stack diagnostic pair in `/tmp/telar-perf-pty-read-stacks-01`
uses ordinary split writes,100 measured inputs and20 warmups, with the qualified
read/readv observer and ordinary native readback probe. Both final text/native
checks and complete expected byte streams8–120 pass. Both runtimes again return
at most1KiB per observed read. C++ has54 inputs spanning multiple reads (41 partial
plus13 full/reset), with six EAGAIN-interrupted full/reset inputs. Exactly those
six epochs have a non-marker sample; its110 readbacks include four additional
matching samples in partial epochs. Zig has66 inputs spanning multiple reads
(53 partial plus13 full/reset), no EAGAIN inside those input byte ranges, and120
readbacks:104 matching, seven opposite-marker and nine non-marker samples. Its
blocking read interval can include waiting for the next input, so it is not
comparable to the C++ nonblocking syscall duration. Entry-to-return durations are
retained separately from first-to-last return spans. Neither application's
instrumented latency or CPU is eligible for acceptance.

All four completed series qualify their host gates; maximum load1 is2.87939453125.
Both excluded series also have clean observed load boundaries but remain ineligible.
All12 owned runtime/child shutdowns, socket removals and resource cleanups pass.
No own build/test/profile overlaps a native series. A whitespace-only final source
cleanup has identical disassembly to the measured read/readv dylib; its different
output filename changes the Mach-O install name. Accepted GUI/runtime identities
and all four pre-existing dirty runtime hashes are verified intact.

The next candidate is bounded collection of already-ready PTY events before
another frame snapshot, avoiding deliberate sleeps. `Runtime::run` currently
publishes before its next poll, and a burst ends at EAGAIN. This may construct an
intermediate snapshot even when the remaining output has become ready by then.
The prior rejected experiment that accumulated immediately available reads inside
a16KiB turn is recorded in `services/runtime-cpp/performance.md`; it must not be
reintroduced unchanged. A distinct event-delivery candidate needs its own isolated
clean runtime build, functional/byte oracles and ordinary paired timing, including
single typing and multi-pane fairness. No scheduling fix or production optimization
is accepted by this diagnostic. All F01–F16/native120 requirements and the unlimited
goal remain open.

## Bounded ready-event collection: reject the all-pane variant, 2026-11-04

**Reject promotion.** One additional nonblocking event batch improves the ASCII
TUI, but the qualified four-pane background-load series regresses consistently
in p95 and maximum latency (only1/6 lower pairs). Memory is not the rejection
reason. Production source and accepted runtime `1f1849d1` remain unchanged.

The candidate in `out-perf/dlls-ready-event-batch-01` moves the existing event
dispatch into `Runtime::pollEvents(timeout)`. After a batch containing a readable
pane event, and only if the runtime is not stopping, it processes one additional
batch with timeout0 before returning to `publish`. There is no deliberate sleep,
no additional idle poll, no event-buffer copy and no new heap state. It processes
at most two128-event batches per turn; existing per-pane read/byte limits remain.
Client writable events still call `writeClient`, so the source change alone does
not guarantee elimination of intermediate frames. The previous rejected
within-read16KiB accumulation experiment is not reinstated.

Builds use an isolated `git archive` of `2fb0ce343`, preserving all four pending
runtime files. A rebuilt unchanged runtime is
`b9c87068d67a9f7a79447f8ae6de80fa1e5a6c0146e88c47351456c34cbdbdee`;
candidate B is
`37c695cd3fe99b7ceb19adcf0c82c8ded1a4ba84f74688e534485fe9e4173446`.
Both use LLVM23.1.4, Release/O3, diagnostics off and the prior pinned dependency
paths. Fresh default discovery selected incompatible OpenSSL4; configuration was
corrected to the accepted OpenSSL3 prefix before either build. Both use unchanged
GUI `bc55d0e8` and GUI-command helper `87beebb0`. The rebuilt baseline is not
byte-identical to the accepted runtime: text-section size matches, but placement
and embedded source paths differ. Normalized source-path string sets match.
Therefore a separate direct comparison against the accepted executable is required
and completed below; equivalent timing is not inferred from the rebuild.

Thirty-three functional runs compare accepted, rebuilt A and B across11 scenarios:
sparse/full/scrolling output, Unicode, modes, links, colors, mixed terminal state,
bulk output, long graphemes and a foreground probe alongside continuous bulk work.
Their exact screen-state/text dumps match, including the probe's resize, reconnect
and complete-exit checks where applicable. Event-loop and control-queue tests pass.
The event-loop control also compiles and runs as x86-64 under Rosetta. The actual
candidate main translation unit compiles for x86-64 baseline and v3. ARM disassembly
shows the second call guarded by the readable-output result and stopping flag,
with timeout0; the outlined dispatch helper uses an80-byte stack frame. x86 uses
the corresponding conditional call. This is lowering/event-loop evidence, not
executed x86/Linux full-runtime validation. Both main builds retain the same59
pre-existing warnings.

Native qualification in `/tmp/telar-perf-ready-event-pixels-01` passes all six
settled full-window PNG checks: TUI, single typing and four splits, for A and B,
against each other and the accepted reference. Configuration remains optical
JBM15, native1600×1000, backing scale2; primary PTYs are82×21 for TUI/single and
39×19 for four splits. All subsequent timings use ordinary uninstrumented native
input-to-positive-presentation probes,100 measured inputs plus20 warmups, with
six alternating pairs per case. No own build, test or profiler overlaps them.

The initial TUI series `...ready-event-tui-pairs-01` is discarded in full: load1
rises from3.047 to7.552 during its first A run. The unchanged retry
`...ready-event-tui-pairs-02` qualifies all26 host boundaries (maximum4.4668).
Against rebuilt A, B wins p50/p95/p99 in5/6,6/6,5/6 pairs; p95 medians are
41.292/36.897 ms. GUI CPU falls5.218→4.852 ms/input (5/6), runtime CPU
97.763→90.430 ms/run (6/6), and runtime instructions180,688,440.5→177,479,605.5
(6/6). Maximum latency improves only3/6. GUI peak RSS217.508→219.797 MiB is not a
reason to reject the candidate.

The direct accepted-runtime comparison in `...ready-event-accepted-pairs-01`
qualifies all36 runs and74 host boundaries (maximum load1 2.95996). Its results,
plus the qualified background-load series described next, are:

| Case | p95 A→B ms | B lower pairs | GUI CPU A→B ms/input | B lower pairs | Runtime CPU A→B ms/run | B lower pairs |
|---|---:|---:|---:|---:|---:|---:|
| TUI | 38.161→35.908 | 6/6 | 5.217→4.889 | 5/6 | 100.359→96.444 | 6/6 |
| Single typing | 32.196→33.016 | 2/6 | 3.851→4.004 | 2/6 | 82.410→81.844 | 2/6 |
| Four splits | 33.056→32.661 | 3/6 | 4.119→4.142 | 3/6 | 97.394→95.778 | 4/6 |
| Four splits with background output | 37.355→37.551 | **1/6** | 19.702→19.744 | 2/6 | 1163.595→1186.395 | 3/6 |

TUI p50 is28.852→27.743 ms (5/6), p99 48.091→43.930 (5/6), maximum49.354→47.011
(3/6), and GUI peak RSS216.945→220.930 MiB (3/6 lower). Single typing and idle
splits do not meet the consistent-latency-regression threshold, but add work:
runtime instructions rise90,076,812→90,845,144.5 (0/6 lower) and
130,198,163→131,133,221 (1/6 lower), respectively. The TUI reduction therefore does
not establish a general instruction-count reduction. Runtime resource intervals
include GUI setup, warmup, measurement and the final screen query for TUI, exclude
runtime startup/shutdown and child CPU, and are not summed with GUI interval CPU.

Background output is variable text from three producers at0.125MiB/s each. The
first series, `...ready-event-load-pairs-01`, is excluded as a whole when one
producer in round4 A reaches0.1174149MiB/s in a checkpoint interval, outside the
unchanged5% tolerance; host load remains eligible. Its cause is not established.
The unchanged repeat `...ready-event-load-pairs-02` qualifies all12 runs, offered
rates and26 host boundaries (maximum load1 3.84326). Alongside the p95 regression
above, maximum latency is41.055→41.087 ms with only1/6 lower pairs. p50 improves
2/6, p99 2/6, GUI CPU2/6 and runtime CPU3/6. This consistent loaded-interaction
regression rejects the all-pane variant despite the targeted TUI gain.

A separate mechanism diagnostic in `/tmp/telar-perf-ready-event-census-01` compares
the accepted runtime and rejected B with read/readv and legacy-Metal census/readback
instrumentation. Both exact continuous byte streams8–120 and final text checks
pass. Commits/readbacks are110/108 and non-marker epochs6/3. All non-marker epochs
have an EAGAIN inside that update's byte range. Full/reset inputs contain such
gaps5/13 on A and6/13 on B, but non-marker samples occur in5 and2 of those epochs;
partial non-marker counts are1 each. This is consistent with some output being
collected before publication, but is one perturbed diagnostic pair and does not
trace publication directly or prove full-frame contents. Its timings cannot
reverse the ordinary-series rejection.

All five completed native series qualify their host gates; the highest load1 is
4.57959 in pixel qualification. Both failed series remain excluded. All111 owned
runtime/child shutdowns and resource cleanups pass, including33 functional runs.
Accepted binaries, production `runtime.hpp`, and all four pending runtime hashes
are verified intact. Frozen patches, assembly, commands, raw observations,
`tables.json`, and `validation.json` remain under the artifact prefix.

The next distinct variant should restrict the extra event batch to a single pane,
matching the existing single-pane read-burst policy. It may retain the targeted
TUI benefit while avoiding another ready batch of competing background panes;
that is a hypothesis requiring new ordinary pairs and regression checks. No
production optimization is accepted here, and all F01–F16/native120 complete-flow
requirements and the unlimited goal remain open.

## 2026-11-04 — Single-pane ready-event batching rejected

The follow-up in `out-perf/dlls-ready-event-single-pane-01` restricts the extra
zero-timeout event batch to a runtime with exactly one pane. This is the global
pane count, read in O(1), not a client's visible-pane count. The original event
dispatch remains in the extracted helper; the second call requires a readable
pane event, no stop request, and one pane. It adds no heap state or deliberate
delay and retains the existing per-pane read limits and at most two128-event
batches. The hypothesis is to collect already-available output before publishing
an intermediate state, while avoiding the competing-pane regression of the
previous experiment. No allocation/copy explanation is assumed.

Source is a fresh archive of `f64f0283e`, built separately with the same pinned
LLVM23.1.4, Release/O3, OpenSSL3 and Ghostty dependencies. Candidate runtime
`16e14b17443f0b2b8100f4064f94256114904fd583b07812e55310f61856adc8` is compared
directly against accepted runtime `1f1849d1`, with unchanged GUI `bc55d0e8` and
helper `87beebb0`. The main working tree's four pending runtime files are never
built into either measured executable. Frozen sources, patch, commands and
identities remain under the artifact prefix.

All22 functional runs pass: accepted/B across sparse, full, scrolling, Unicode,
modes, links, colors, mixed state, bulk, graphemes and concurrent foreground/bulk
work. Exact screen/text dumps agree, including resize, reconnect and exit checks
where applicable. Event-loop and control-queue CTest entries pass. The actual
main translation unit compiles for x86-64 baseline and v3. ARM disassembly shows
the stopping/readable checks, cached pane-count comparison against1, and guarded
zero-timeout call. This is compile/lowering evidence; full x86/Linux runtime
execution is not established. The build retains59 pre-existing main warnings.

`/tmp/telar-perf-ready-event-single-pixels-01` qualifies all six full-window PNGs
for TUI, single typing and four splits, matching both A/B and the accepted
references exactly. Configuration remains optical JBM15,1600×1000 at scale2,
with82×21 cells for single/TUI and39×19 for the primary split pane. Ordinary
timings use100 measured inputs plus20 warmups and six alternating pairs, without
read/allocation/render-census instrumentation or overlapping own builds/tests.

The first TUI series, `...ready-event-single-tui-pairs-01`, is excluded entirely
after load1 reaches5.40234 on round4 B. The unchanged repeat
`...ready-event-single-tui-pairs-02` qualifies26 host boundaries, maximum load1
2.57715. The later single-typing series `...ready-event-single-typing-pairs-01`
also qualifies26 boundaries, maximum2.74463. Results are:

| Case | p95 A→B ms | B lower pairs | GUI CPU A→B ms/input | B lower pairs | Runtime CPU A→B ms/run | B lower pairs |
|---|---:|---:|---:|---:|---:|---:|
| TUI | 41.440→36.357 | 5/6 | 5.442→5.314 | 4/6 | 103.612→102.123 | 4/6 |
| Single typing | 32.936→32.773 | 3/6 | 3.897→3.995 | **1/6** | 83.111→83.134 | 3/6 |

TUI p50 is28.854→28.842 ms (4/6), p99 46.051→46.256 (3/6), maximum49.307→49.264
(4/6). Runtime instructions fall180,498,636.5→178,600,254 (5/6), but the CPU
reduction is not consistent. Single typing p50 is25.010→24.937 (3/6), p99
37.021→35.521 (4/6), maximum41.701→36.908 (5/6); runtime instructions rise
90,186,069→91,214,711.5 (2/6 lower). GUI peak RSS is218.469→218.422MiB for TUI
and197.539→204.102MiB for typing. Memory is not the rejection reason. Runtime
resource intervals include GUI setup, warmup, measurement and the final TUI
query, exclude runtime startup/shutdown and child CPU, and are not added to the
differently scoped GUI CPU interval.

Three attempts to qualify four splits with variable background output at
0.125MiB/s per producer fail the unchanged5% rate check. Each entire series is
excluded; partial pairs are not pooled or used to decide the candidate:

| Series suffix | Failed run | Lowest producer interval MiB/s | Maximum load1 |
|---|---|---:|---:|
| `single-load-pairs-01` | round5 B | 0.114839 | 3.18457 |
| `single-load-pairs-02` | round3 A | 0.107962 | 4.77637 |
| `single-load-pairs-03` | round4 B | 0.113117 | 3.63135 |

In each failed run, all three producers have deficient checkpoint intervals
that overlap in time (shared intersections324,357 and86ms). Their maximum
individual write durations range0.299–5.098ms. The pacer deliberately drops missed
slots rather than catching up with a burst. These observations motivate a
separate producer-scheduling diagnostic, but establish neither its cause nor a
runtime-induced stall. Raw observations and `rate-failures.json` are retained.
Host reports remain ineligible/pending because those series never finish;
eligible boundary loads alone do not qualify a workload.

The completed typing series is sufficient to reject this variant: GUI CPU is
worse in five of six pairs. No normalized-code-placement proof excuses it, and
its cause is not established. The TUI p95 win does not override that consistent
regression. Further idle-split timing and another background retry are unnecessary
for this rejected candidate; loaded-interaction qualification remains open.

All91 owned runtime/child shutdowns and resource cleanups pass, including22
functional runs and every interrupted series. The accepted binaries, production
`runtime.hpp`, and all four pending runtime hashes remain intact. `validation.json`,
`tables.json` and `decision.json` record the audit. Only this report is committed;
the candidate is not promoted. The next investigation should measure publication
and GUI work directly rather than adding another unconditional event-loop batch.
Allocation/copy/conversion hypotheses and memory-for-work tradeoffs remain in
scope, as do all F01–F16/native120 requirements and the unlimited active goal.

## 2026-11-04 — Measured transport-copy volume, not per-message allocation

The next diagnostic examines the allocation/copy hypothesis at GUI `FrameStream`.
Its retained vector copies every received payload before synchronous consumption,
including bodies already contiguous in the input buffer. Capacity reuse is visible
in source; it does not establish whether actual workloads grow that capacity.
`out-perf/dlls-frame-stream-copy-01` adds six private counters to the existing
legacy-Metal measured-interval census: payloads, payload bytes, bodies complete
when their prefix finishes, their bytes, inserted bytes, and capacity increases.
No borrowing optimization or production semantic change is implemented.

The private GUI is built from `ccae2b908` with the unchanged accepted runtime
`1f1849d1`, LLVM23.1.4 and the existing Qt6.12 Release configuration. A weak
counter import requires an explicit Darwin dynamic-lookup link option; the first
link failure is retained. The production header is restored in a `finally` block,
and the subsequent ordinary GUI rebuild is byte-identical to accepted `bc55d0e8`.
The exact diagnostic executable/probe hashes, source hooks and link command are
in `census-build.json`, `frame-stream-census.hpp` and `link-census.txt`.

The counter oracle exercises all1,275 three-chunk partitions of three differently
sized messages. It independently checks received bytes and message count, summed
copy bytes, and the intervals whose bodies are complete in the same chunk that
finishes their prefix. A prefix ending exactly at a chunk boundary is deliberately
not counted as that opportunity. Final controls pass on ARM, x86-64 under Rosetta,
and ARM ASan/UBSan. Explicit non-elidable checks are used; corrupting a copy count
fails each executable with status1. Earlier runs inherited `NDEBUG` and are not
used as oracle evidence. Commands and final positive/negative results are retained
in `control-commands.json` and `control-final.log`.

`/tmp/telar-perf-frame-stream-pixels-01` compares accepted and instrumented GUI
captures for TUI, single typing and four splits. All six settled full-window PNGs
match the accepted references byte-for-byte. The subsequent diagnostic in
`/tmp/telar-perf-frame-stream-counts-01` runs100 measured inputs plus20 warmups for
each GUI/case, with optical JBM15 and1600×1000 at scale2. The source counters are
all zero in the unmodified GUI, the absent-hook control; the instrumented GUI
reports:

| Case | Transport payloads | Payload/copied bytes | Complete bodies at prefix completion | Capacity increases | Metal commits |
|---|---:|---:|---:|---:|---:|
| TUI | 111 | 143,506 | 111 | 0 | 111 |
| Single typing | 103 | 8,554 | 103 | 0 | 103 |
| Four splits | 104 | 8,572 | 104 | 0 | 105 |

Every copied body is contiguous at the recorded decision point, so a borrowing
fast path could avoid that volume. However, the observed totals are only1,435
bytes/input for this TUI and about86 for typing, and no vector-capacity increase
occurs inside these intervals. This directly rules out repeated payload-vector
growth in these runs, not allocations elsewhere in Qt or the whole application.
The counters count all transport messages, not only terminal frames. Equal message
and commit totals do not prove a one-to-one relationship or establish publication
causality. The counters add calls and locks; these runs establish no timing gain,
CPU attribution, Zig-stack advantage or continuous-refresh acceptance.

Both series qualify all14 host boundaries, with maximum load1 2.92773 and2.28711.
All12 owned runtime/child shutdowns pass. Accepted executables, production source
and the four pending runtime hashes are verified intact in `validation.json`.
The borrowing lead is lower priority on this measured volume; no candidate is
promoted or declared performance-rejected without ordinary timing. The next heap
diagnostic should reuse the existing six-API observer and add allocation-site
attribution plus a probe-overhead control, rather than repeating aggregate counts.
All complete-flow and native120 requirements remain open and the goal stays active.

## 2026-11-04 — Heap-site samples identify repeated background-node construction

The follow-up in `out-perf/dlls-heap-stack-sites-01` adds reusable Darwin heap
site tools: `heap_stack_census.c/.h`, `heap_stack_control.c`,
`build_heap_stack_probe.py`, `heap_stack_report.py` and its tests. The observer
reuses the previous six-API interposition approach but brackets the measured
interval explicitly, serializes its counters and samples successful allocations
by hashed ordinal. The nominal sampling frequency is1/256, with8192 fixed records
and at most24 return addresses per record. It records requested bytes, API, thread
identity and monotonic timestamp; it does not track allocation lifetimes or CPU.
Fork children and observer-recursive allocations are excluded. Overflow or missing
sample ordinals invalidates the report. Dynamic zone/other uncovered APIs remain
outside scope. Serialization, stack unwinding and observer locks perturb execution.

Exact five-allocation controls verify344 requested bytes, four non-null frees,
each covered allocation API once, errno on overflowing calloc/invalid alignment,
symbolized allocation sites, disabled sampling, child exclusion, concurrent
callers and overflowing the fixed record capacity. They pass with actual DYLD
interposition on ARM and x86-64 under Rosetta, and with both combined native-probe
libraries. The absent-library control returns2. ASan's allocator interposer changes
the observed totals, so that combined attempt is not accepted; direct wrapper
calls instead pass ASan/UBSan with intentional allocation failure enabled and leak
detection disabled. Three Python tests include24 malformed-evidence controls.
Commands, failed attempts and final receipts remain under the artifact prefix.

The application binaries remain accepted GUI `bc55d0e8` and runtime `1f1849d1`,
from source base `98f5f1438`; neither application is rebuilt in this pass.
Final probes are `sampled-v3/probe.dylib` and `counts-v3/probe.dylib`, with source
hashes and build commands in their manifests. Both run optical JBM15 at1600×1000,
scale2,82×21 cells. `/tmp/telar-perf-heap-sites-pixels-01` validates all four
settled full-window PNGs, TUI and typing under both observers, against the accepted
references exactly. `/tmp/telar-perf-heap-sites-01` then collects100 measured
inputs after20 warmups in each condition:

| Case | Counts-only successful calls | Sampled-observer successful calls | Counts-only requested bytes | Sampled-observer requested bytes | Recorded stacks |
|---|---:|---:|---:|---:|---:|
| TUI | 176,563 | 181,161 | 39,899,988 | 41,682,945 | 722 |
| Single typing | 48,413 | 42,381 | 9,925,689 | 9,184,093 | 179 |

The different signs of these count changes are not an overhead estimate or an
optimization result. This is one diagnostic control pair per case, not six-pair
timing acceptance; native-probe allocations remain included. The sampled TUI has
300 stacks through `TerminalScene` and308 through `QRhiBatchedBindings`; typing
has1 and114 respectively. Categories are inclusive and may overlap. TUI has58
depth-limited records and typing36, so ancestor attribution is incomplete for
those samples. `dladdr` records image/load addresses and symbols; batched
`llvm-cxxfilt` demangles them after execution in `attribute.py`/`attribution.json`.

Of the300 TUI scene samples,282 request312 bytes.281 of those carry the exact
`paintRow` return PC which, normalized to the accepted executable's load address,
is `0x10002c1b8`. The existing accepted disassembly at that site loads312 into
the allocation argument, calls `operator new`, constructs `QSGSimpleRectNode`
and appends it to the background node. The remaining312-byte scene sample is not
attributed to that call. This connects actual repeated allocations to the source
path: `paintRow` clears the row's background children, and `paintRun` creates a
rectangle for each non-default cell background. It establishes the allocation
site, not its share of CPU or a proven tail-latency cause.

The separate Metal-binding samples are32/48-byte allocations inside Qt's transient
binding batches. A prior inline-binding experiment already reduced allocation
counts but lacked a qualified ordinary CPU result; those counts must not be
re-presented as an accepted optimization. The next distinct application candidate
will retain and update background rectangle nodes across changed rows, preserving
individual geometry and ordering, unlike the previously rejected merging variant.
It must handle shrinking/default backgrounds, geometry changes, transparency and
software rendering, prove pixels against the independent oracle, then pass ordinary
TUI pairs and typing/split/load regression controls. No production optimization is
accepted on the present census.

Both native series qualify all10 host boundaries, maximum load1 2.70850 and
2.49121 respectively. No build/test/profile overlaps their native observations.
All eight owned runtime/child shutdowns pass; PID identities, accepted binaries,
and the four pending runtime hashes are verified in `validation.json`. All
F01–F16/native120 complete-flow requirements and the unlimited goal remain open.

## 2026-11-04 — Metal inline bindings pass the CPU target but regress loaded latency

The fresh qualification in `out-perf/dlls-metal-inline-current-01`, from source
`a316740ac`, rejects the previously inconclusive Metal inline-binding candidate.
This decision uses new host-qualified measurements on the current accepted stack;
the earlier high-load series remains discarded. The candidate passes its original
four-split GUI CPU target but loses loaded p50 in all six pairs and loaded p95 and
maximum latency in five. Memory concessions remain allowed and are not the reason
for rejection. The latency regression's cause is not established.

Both stages use identical accepted GUI `bc55d0e8`, runtime `1f1849d1` and helper
`87beebb0`. Only QtGui differs: accepted `abd4bdf7` versus candidate `34fa13cf`,
with full hashes retained in `frameworks.json`. All60 framework binaries, the
original and patched Metal source, patch and prior LLVM23.1.4 Release/O3 build
receipt are checked. No application or dependency is rebuilt for these ordinary
comparisons. The private patch still changes only Metal shader-resource batch
storage; vertex-input batches remain unchanged. The prior assembly findings apply
to these same verified dependency bytes, including the larger inline stack frame.
No production Qt recipe or renderer change is applied.

Fresh normal and ASan/UBSan container oracles each pass4,123 cases. Their generated
container matches the patched Metal class after removing comments/whitespace and
normalizing its name. The scalar container grows64→224 bytes. Both stages pass46
scene cases on software and Metal, including independent background-transition
comparisons. The first candidate scene launch lacks the relocated plugin path and
aborts before tests; explicit original plugin/QML paths fix the setup, after which
both complete suites pass. The failed launch log remains preserved.

The ordinary native probe now records dyld loaded-image paths after measured
CPU/timing snapshots. `tools/qt_framework_receipt.py` verifies resolved paths and
SHA-256 against frozen framework identities, rejects unknown/duplicate frameworks,
and requires QtCore,QtGui and QtQuick. Every run has a verified receipt; no loader
logging is enabled during inputs. A focused test covers missing/malformed receipts,
missing required libraries, duplicates, unexpected paths/modules and changed
bytes. An actual candidate receipt also fails against baseline expectations.
Hashing occurs after GUI exit. The final source only expands the new loop's
single-line conditional into braces; archived ordinary probes retain their exact
source, and the final combined heap probe compiles and exercises that same loop.

`/tmp/telar-perf-metal-inline-current-pixels-01` matches all six full-window PNGs
for TUI, single typing and four splits byte-for-byte against A/B and accepted
references. Ordinary series `...-splits-01`, `...-tui-01`, `...-typing-tabs-01` and
`...-load-01` each run six alternating pairs per case,100 measured inputs after20
warmups, at1600×1000/scale2 with optical JetBrains Mono15. Single/TUI/tabs use82×21
cells; the primary split has39×19. The fixed-rate case has three variable-output
background producers at0.125MiB/s each; all measured producer windows satisfy the
unchanged5% rate tolerance. No own compilation, tests, profiler or heap census
overlaps ordinary timing. The CPU target remains at least5/6 lower pairs; any
latency/CPU control with0–1 lower pairs rejects the candidate.

Values below are medians of run metrics; parenthesized counts are candidate-lower
pairs out of six. Runtime CPU covers GUI setup, warmup, inputs and final TUI query
where applicable, excludes runtime startup/shutdown and child CPU, and must not be
added to GUI interval CPU.

| Case | GUI CPU ms/input A→B (lower pairs) | GUI peak RSS MiB A→B (lower pairs) | Runtime CPU ms/run A→B (lower pairs) |
|---|---:|---:|---:|
| splits | 4.085→3.998 (5/6) | 204.664→191.578 (4/6) | 100.422→96.520 (3/6) |
| tui | 5.248→5.003 (4/6) | 218.523→215.961 (5/6) | 101.649→99.785 (4/6) |
| single | 4.060→3.861 (6/6) | 206.094→204.859 (5/6) | 87.105→81.196 (6/6) |
| tabs | 4.123→4.045 (3/6) | 205.273→204.688 (3/6) | 100.501→96.370 (6/6) |
| splits-load | 19.366→18.292 (4/6) | 197.344→204.711 (2/6) | 1141.056→1130.732 (3/6) |

| Case | p50 ms A→B (lower pairs) | p95 ms A→B (lower pairs) | p99 ms A→B (lower pairs) | Maximum ms A→B (lower pairs) |
|---|---:|---:|---:|---:|
| splits | 25.899→24.898 (5/6) | 33.101→32.866 (4/6) | 37.730→34.257 (4/6) | 39.573→37.250 (5/6) |
| tui | 28.837→28.806 (4/6) | 42.013→40.176 (3/6) | 47.159→47.187 (2/6) | 50.045→49.502 (3/6) |
| single | 25.829→24.942 (5/6) | 33.188→33.059 (3/6) | 35.919→36.187 (4/6) | 37.915→39.298 (2/6) |
| tabs | 25.552→24.926 (3/6) | 32.924→32.685 (4/6) | 36.453→35.095 (3/6) | 37.018→36.673 (3/6) |
| splits-load | 31.061→32.680 (0/6) | 36.646→37.400 (1/6) | 39.719→39.235 (3/6) | 41.053→41.062 (1/6) |

The primary CPU target passes5/6 and single typing improves6/6, but the loaded
p50/p95/maximum losses reject promotion. Loaded runtime instructions also rise
3,501,285,088→3,532,337,856.5 with0/6 lower pairs, without a proven causal link to
the GUI regression. Full runtime CPU/instruction/cycle tables remain in
`tables.json`; the runtime executable itself is unchanged.

A separate sampled-heap pair per TUI and four-split case, in `...-census-01`, uses
a fresh combined probe with the same loaded-image receipt. Its exact API/errno,
site, sampling-disabled, child-exclusion, threaded and overflow control passes.
These timings are diagnostic only. Observed successful covered calls and requested
bytes over100 inputs are:

| Case | Calls A→B | Requested bytes A→B | Recorded stacks A→B |
|---|---:|---:|---:|
| TUI | 180,714→127,741 | 40,626,201→38,238,069 | 722→533 |
| Four splits | 87,466→50,881 | 11,601,603→10,163,007 | 367→212 |

TUI binding-inclusive samples fall314→111 and split samples241→102.
Samples through `enqueueShaderResourceBindings` fall189→0 and159→0 respectively.
All remaining candidate `QRhiBatchedBindings` samples carry `setVertexInput`,
which the patch intentionally leaves unchanged. TUI scene samples remain301→327.
These inclusive, depth-limited samples and aggregate counts include framework and
probe work. They establish observed allocation sites, not CPU shares, live memory,
a repeatable allocation percentage or the cause of the loaded latency loss.
`attribute.py`, `attribution.json` and `remaining-binding-sites.json` preserve the
symbol attribution. Fewer allocations cannot override the ordinary decision.

All six series qualify their host gates: pixel14 boundaries/max load1=3.16553,
splits26/4.42773, TUI26/1.95313, typing+tabs50/2.12842, load26/2.70117 and
census10/3.06641. All70 owned runtime/child shutdowns and resource cleanups pass.
Every run's Qt receipt is rechecked, along with all60 frozen frameworks, accepted
executables and the four untouched pending runtime files. `validation.json` and
`decision.json` contain the final audit. Only reusable receipt tooling and this
report are retained. The next investigation should identify work that can be
skipped before pursuing another storage substitution; no unverified caching
proposal is accepted here. All F01–F16/native120 requirements and the goal remain
open.

## 2026-11-04 — Vertex-input reconstruction has no observed whole-state reuse

The next source audit at `2effb4b73` finds `QRhiMetal::setVertexInput` constructing
contiguous generic buffer/offset batches before comparing them to its cached
state. Host buffer writes and in-use tracking must still occur on any cache hit;
`executeBufferHostWritesForSlot` copies pending content and clears updates without
replacing buffer handles. A preconstruction comparison is therefore a plausible
lead, but its usefulness depends on actual repeated state.

`out-perf/dlls-metal-vertex-reuse-01` tests that premise without implementing an
optimization. It extracts the accepted Qt compile/link arguments, recompiles only
`qrhimetal.mm` into private output and links all other original objects unchanged.
Relinking the unmodified object reproduces both the build QtGui and, after the
original rpath installation edit, the accepted installed QtGui byte-for-byte.
Neither original source, objects nor installed libraries are overwritten. Both
stages retain GUI `bc55d0e8`, runtime `1f1849d1` and helper `87beebb0`.

The private diagnostic extends the existing measured-interval render observer.
It records complete calls, changed/unchanged cached state, binding totals and
empty/single-binding shapes. The final D2 also records cached buffer-batch,
offset-batch and firstVertexBinding comparisons, plus offset-only changes.
Comparisons inspect complete batches, including their start/count, not solely
resource pointer identity. Final diagnostic QtGui SHA256 is
`def5afd224b4d547f7214854ffe85e786568c98c7c200f6344517c4e4d58ad5a`.
Its counters add locking and comparisons; no diagnostic timing qualifies a win.
The sampled heap results from the previous experiment identify the call site,
not its share of CPU or this proposed cache's hit rate.

The initial visual series is discarded in full when load1 reaches5.14307 at its
last boundary. Its logs remain at `/tmp/telar-perf-metal-vertex-pixels-01`.
The expanded observer passes all six TUI/single/split PNGs against both A/B and
accepted references in `...-pixels-02`. `...-counts-01` then runs100 measured
inputs after20 warmups in each condition, optical JBM15,1600×1000/scale2. All
four cases use the accepted independent runtime; the three background producers
in split-load each satisfy the unchanged0.125MiB/s±5% contract.

| Case | Vertex-input calls | Total bindings | Changed buffer batches | Changed offset batches | Changed first binding | Unchanged / offset-only calls |
|---|---:|---:|---:|---:|---:|---:|
| TUI | 4,815 | 9,630 | 4,815 | 2,743 | 660 | 0 / 0 |
| Single typing | 1,664 | 3,328 | 1,664 | 1,248 | 624 | 0 / 0 |
| Four splits | 4,120 | 8,240 | 4,120 | 3,708 | 1,339 | 0 / 0 |
| Split-load | 36,880 | 73,760 | 36,880 | 33,192 | 11,986 | 0 / 0 |

Every observed call has at least two bindings, and the totals equal two per call.
There are no complete cache hits or offset-only updates in these runs. That
removes the evidence for adding the proposed early cache check to these flows;
it does not prove such hits impossible in every application or reject an
unimplemented optimization on timing. The next distinct investigation is
upstream scene grouping with per-vertex background colors, preserving original
rectangle geometry/order and using exact-representation/software fallbacks.
It must pass the independent background oracle before ordinary paired timing.

`tools/metal_vertex_report.py` validates the observer extension alongside the
existing render-census contract. It rejects disconnected hooks, malformed schemas,
invalid call/shape partitions and impossible change unions/offset-only counts.
Two tests include13 negative evidence controls. Actual rows pass the same report;
A's intentionally absent source hook fails its connected-observer requirement.
The qualified pixel/count series pass14/18 host boundaries, maximum load1
2.72559/2.49414. All20 owned runtime/child shutdowns across qualified and discarded
series pass. Framework receipts, original Qt source/library, accepted binaries and
all four pending runtime hashes are rechecked. No production optimization is
promoted. All F01–F16/native120 requirements and the unlimited goal remain open.

## 2026-11-04 — Per-vertex background grouping saves CPU but fails the TUI p95 target

`out-perf/dlls-colored-background-mesh-01` tests a distinct upstream algorithm at
source `c8a2e6ffb`. Consecutive background rectangles with exactly representable
opaque8-bit colors become one `QSGGeometryNode` with per-vertex color. Each cell
keeps its original rectangle bounds and contributes six triangle vertices;
no borders are merged. Qt's vertex-color material compares equal across colors,
allowing grouping that flat-color materials cannot share. Software, translucent,
extended and non-byte-representable colors retain individual rectangles. Encountering
such a rectangle flushes the accumulated mesh first, preserving scene order.
The temporary row vector reserves only when first used and reuses its capacity
across fallback groups, avoiding quadratic storage when groups alternate.

Accepted A is GUI `bc55d0e8`; B is
`2bd9c7dca9f3f5dbd1a60720d731d865faf03f7e91c3f14c9eeded29b323e287`.
Both use runtime `1f1849d1`, helper `87beebb0`, original QtGui `abd4bdf7`, and the
unchanged LLVM23.1.4 Release/O3 build. All private source, patch, build receipts
and frozen identities remain in the ignored prefix. Production scene code and
the configured GUI are restored byte-for-byte to accepted A before native timing.

Both full candidate scene suites pass46 cases on software and Metal. A new
`mixedBackgroundColorsMatchIndependentRectangles` oracle then compares a row of
wide/continuation cells against fresh independent rectangles, mixing opaque8-bit,
higher-precision opaque and translucent colors. It covers widths9,9.2,9.1 and
parent opacities1,.5: six additional comparisons per backend on both A and B.
Forcing valid nonrepresentable/translucent colors into the mesh fails that exact
oracle. The initial test nesting exceeds clang-tidy's threshold; moving constant
palette preparation outside the capture loops fixes it without changing cases.
The final oracle and negative control are rerun, and scoped test lint passes.
Candidate production lint passes separately.

The actual translation unit compiles for x86-64 baseline and v3; this is not a
whole-GUI x86/Linux runtime result. ARM listings show the eligible path constructing
six colored vertices per rectangle, with a separate group flush allocating one
288-byte mesh node, creating its geometry/material, copying vertices and appending
the node. Individual312-byte rectangle construction remains in the fallback.
Mach-O indirect-symbol tables resolve the allocation/Qt/memmove call sites;
unresolved disassembler stub labels are not treated as function names. These
listings establish code paths, not executed allocation totals or CPU attribution.

The first native pixel series is discarded at load1=5.10547 after three runs.
`/tmp/telar-perf-colored-background-pixels-02` repeats all six TUI/single/split
captures and matches A/B and accepted full-window PNGs exactly. Every run verifies
loaded framework paths and hashes after measurement. `...-tui-01` then qualifies
six alternating ordinary pairs,100 inputs after20 warmups, optical JBM15,
1600×1000/scale2 and82×21 cells. No own build, test, profiler or census overlaps
these timings. The frozen contract requires both TUI p95 and GUI CPU to improve
in at least5/6 pairs, with later single/split/tab/load regression controls only
if the primary gate passes.

| TUI metric | Accepted A | Mesh B | B lower pairs |
|---|---:|---:|---:|
| p50 ms | 25.498 | 24.947 | 4/6 |
| p95 ms | 33.005 | 35.923 | 2/6 |
| p99 ms | 37.528 | 37.786 | 2/6 |
| Maximum ms | 40.972 | 39.936 | 4/6 |
| GUI CPU ms/input | 4.095 | 3.521 | 6/6 |
| GUI peak RSS MiB | 226.008 | 218.234 | 3/6 |
| Runtime CPU ms/run | 77.849 | 79.874 | 3/6 |
| Runtime instructions/run | 181968779.500 | 181661414.500 | 4/6 |
| Runtime cycles/run | 158925348.000 | 158797408.000 | 4/6 |

CPU improves in all six pairs, about14% by these medians, but p95 improves in only
two. That fails the co-primary gate, so B is rejected and further ordinary
regression series are not run. The p95 change is not a0–1-win consistent loss
under the separate regression rule; failure to meet the declared primary target
is sufficient here. Its cause is not established. RSS is not the rejection reason.
Runtime intervals include setup, warmup, measured inputs and final TUI query,
exclude runtime startup/shutdown and child CPU, and are not added to GUI CPU.
The TUI harness/fixture/trace/report sources match the preceding inline-binding
experiment; comparisons across different host intervals are not substituted for
these paired results.

A separate mechanism check uses the same diagnostic QtGui `def5afd2` and render
probe for both GUI variants, with strict loaded-library receipts. Its first
controller enables a PNG capture while leaving the initial capture wait at zero;
the probe rejects it with failure19 before any responses. This invalid run is
retained at `...-census-01` and excluded. Restoring the established200ms initial
capture wait fixes the controller without changing ordinary timing. The fresh
`...-census-02` qualifies one100-input pair for TUI and four splits, including
byte-exact A/B capture comparisons:

| Case | Metal commits A→B | Vertex-input calls A→B | Total vertex bindings A→B |
|---|---:|---:|---:|
| TUI | 116→116 | 5,068→4,157 | 10,136→8,314 |
| Four splits | 103→104 | 4,120→4,264 | 8,240→8,528 |

The TUI saves observed vertex-input calls with equal commit counts. Four splits
instead move40→41 calls per commit, so the change does not uniformly reduce this
work across cases. These are instrumented calls, including inter-input work, not
GPU draw counts, CPU shares or continuous-content cadence. Equal commit totals
and settled pixels do not prove every intermediate frame equivalent. The census
cannot override the ordinary p95 rejection.

One next hypothesis is explicit in Qt's source: `QSGVertexColorMaterial` enables
blending by default, although this fast path emits only opaque vertices. Changing
that classification may affect opaque-pass ordering, especially differently
colored overlapping wide cells, and must first receive an independent overlap
oracle plus parent-opacity checks. The small-background split case also needs
attention because its per-commit binding calls increase. Neither observation is
a proven cause or an accepted follow-up optimization.

Qualified series pass14 pixel boundaries (maximum load1=3.58154),26 ordinary
boundaries (3.42188) and10 census boundaries (3.51514). All26 owned runtime/child
shutdowns across qualified, discarded and failed series pass; resource observers
report no errors. `validation.json` checks accepted production source/executables,
frozen stages, framework receipts and all four untouched pending runtime hashes.
Only the independent mixed-color oracle and report are retained. All F01–F16 and
native120 acceptance requirements remain open and the goal stays active.


## 2026-11-04: overlap-safe opaque background meshes rejected under load

On source `4ced947dd`, `out-perf/dlls-opaque-background-mesh-01` tests explicit
opaque classification for the earlier per-vertex background mesh. Accepted GUI
`bc55d0e8`, runtime `1f1849d1`, helper `87beebb0` and original Qt remain A;
B GUI is `382c3e5e694cf352a08303b2a88c6af1349c5b43d2ca7a455eaaac605467a4d0`.
The production source and main GUI build are restored to A before native timing.

Qt's opaque pass writes depth with a strict Less comparison. Putting overlapping,
differently colored rectangles at one mesh depth can therefore change their order.
The independent mixed-color oracle now also exercises an entirely opaque palette,
with wide/continuation overlap, widths9/9.2/9.1 and parent opacity1/0.5. Each backend
compares twelve captures against independent original rectangles. A deliberately
unconditional opaque mesh fails the opaque-overlap row while passing the mixed
precision/alpha row. B detects overlap using the actual emitted float left/right
coordinates and retains blending for overlapping groups. Exactly opaque byte-color,
software, precision and alpha eligibility rules otherwise match the preceding mesh.

The expanded oracle passes A and B on software/Metal, and B passes all48 scene
cases on both backends. Initial oracle lint rejects Qt's required data suffix,
mutable QFETCH and unnamed literals; a scoped Qt naming annotation, const fetch
and named constexpr palette values resolve those diagnostics. Final oracle lint,
production lint and repeated negative control pass. No oracle is weakened.
ARM disassembly shows scalar float comparisons for overlap/right-edge tracking
and the overlap Boolean passed to QSGMaterial::setFlag; indirect symbols resolve
the setFlag and memmove stubs. Actual-TU x86 baseline/v3 compilation passes and
shows scalar ucomiss comparisons. These are codegen checks, not whole-GUI x86 or
Linux execution or a claim of measured savings on those targets.

`/tmp/telar-perf-opaque-background-pixels-01` qualifies all six native TUI,
single-pane and four-split captures, byte-exact against A and accepted references.
`...-tui-01` qualifies six alternating100-input pairs after20 warmups, using the
unchanged optical JBM15,1600×1000/scale2,82×21 setup. No own build, test, profiler
or census overlaps ordinary timing. The frozen co-primary gate requires at least
5/6 improvements in both TUI p95 and GUI CPU, then regression controls.

| TUI metric | Accepted A | Mesh B | B lower pairs |
|---|---:|---:|---:|
| p50 ms | 28.826 | 26.785 | 5/6 |
| p95 ms | 37.545 | 34.810 | 5/6 |
| p99 ms | 44.380 | 41.448 | 3/6 |
| Maximum ms | 48.271 | 45.498 | 3/6 |
| GUI CPU ms/input | 4.850 | 4.150 | 6/6 |
| GUI peak RSS MiB | 221.656 | 215.195 | 4/6 |
| Runtime CPU ms/run | 99.027 | 100.898 | 4/6 |

The primary gate passes. Fixed-rate four-split load is checked next because it
rejected an earlier Qt candidate. `...-load-01` is excluded in full: its final A
run has producer intervals around0.109–0.112MiB/s instead of0.125MiB/s, outside
the unchanged5% tolerance. Host observations themselves remain below limits;
the rate failure's cause is not established. No eleven-run aggregate is used.
`...-load-02` repeats all six pairs and qualifies every producer interval.

| Four-split load metric | Accepted A | Mesh B | B lower pairs |
|---|---:|---:|---:|
| p50 ms | 30.859 | 31.930 | 1/6 |
| p95 ms | 37.349 | 37.317 | 5/6 |
| p99 ms | 38.354 | 39.653 | 1/6 |
| Maximum ms | 38.785 | 41.092 | 1/6 |
| GUI CPU ms/input | 20.553 | 20.408 | 2/6 |
| GUI peak RSS MiB | 205.313 | 191.500 | 4/6 |
| Runtime CPU ms/run | 1195.192 | 1202.975 | 3/6 |

The consistent p50/p99/maximum regressions reject B despite the TUI improvement.
Their cause is not established; there is no placement exemption. RSS is not the
rejection reason. Remaining ordinary single/split/tab controls are not run after
this rejection. Runtime CPU windows include GUI setup, warmup and final readback,
exclude runtime startup/shutdown and child CPU, and are not summed with GUI CPU.
Full instructions/cycles and pair data remain in table.json and load-table.json.

A separate identical-instrumented-Qt census, `...-census-01`, uses QtGui `def5afd2`
for both apps,100 inputs after20 warmups and200ms initial capture wait. All four
A/B PNGs match. TUI A has111 commits/4867 vertex-input calls/9734 bindings; B has
117/4187/8374. Four splits have105/4200/8400 versus103/4120/8240: exactly40 calls
per commit for both, so the preceding candidate's extra split call is absent.
Unchanged and offset-only cache hits remain zero. The TUI commit counts differ;
call totals include inter-input work and do not prove per-frame equivalence,
GPU draw counts, CPU attribution, continuous cadence or the cause of load latency.

Qualified host boundaries/max load1 are14/3.92188 for pixels,26/3.60742 for TUI,
26/4.46143 for repeated load and10/3.04199 for census. The excluded load series
has25 boundaries, maximum3.07373 and no completed eligibility receipt. All46
owned runtime/child shutdowns, framework receipts and resource observers pass.
Validation verifies frozen binaries, restored accepted production source/build
and all four untouched pending runtime files. Only the expanded overlap oracle
and this report are retained. All F01–F16 and native120 acceptance remains open.


## 2026-11-04: lazy background mesh preparation rejected at the TUI p95 gate

`out-perf/dlls-lazy-background-mesh-01`, source `b53871d77`, tests avoiding mesh
setup for empty and singleton background rows. The prior opaque mesh queried
Qt's renderer interface for every dirty row and reserved vertex storage even for
one rectangle. The fixed-load fixture writes plain ASCII in background panes
and one colored marker rectangle in its primary pane; these source facts motivate
removing unnecessary work, not a claim that it caused the preceding regression.

The candidate stores the first rectangle/color in a local optional. An empty row
never queries the backend. A singleton emits the original QSGSimpleRectNode when
the row finishes, without constructing mesh vertices. A second rectangle triggers
the existing opaque-byte-color eligibility and overlap-safe mesh logic in original
order; precision, alpha and software fallbacks remain unchanged. This trades more
local stack state for less preparation/allocation work in sparse rows. It does not
retain cached geometry across rows or frames.

Accepted GUI `bc55d0e8`, runtime `1f1849d1`, helper `87beebb0` and original Qt are A;
B GUI is `e3c4c895712a534b7a734e052f0822f2258fb8b894f6fab8c4f8926761225001`.
The independent sparse oracle reuses actual/reference scenes through background
counts0→1→1→2→1→0→2, including byte-opaque, higher-precision and translucent
colors, widths9/9.2/9.1 and parent opacity1/0.5:42 independent captures per backend.
A negative variant drops the pending singleton and fails this oracle. A and B
pass it on software/Metal, and B passes all49 scene cases on each backend.

Initial lint finds excessive test nesting, missing designated/default member
initialization and a redundant production private specifier. Flattening the
configuration table and fixing those declarations preserves all cases. Production
and final oracle lint pass. The last default-initializer edit reproduces both
already-tested scene executables byte-for-byte, verified in final-test-identity.json;
it also reproduces the same A/B production GUI hashes. No native measurements
precede these checks. ARM disassembly resolves the singleton destructor's312-byte
allocation, original rectangle constructor and append through indirect symbols;
mesh append/flush remain separate. Actual-TU x86 baseline/v3 compile passes. These
checks establish generated paths, not executed allocation totals or whole-GUI
x86/Linux behavior.

`/tmp/telar-perf-lazy-background-pixels-01` qualifies six TUI/single/split PNGs,
byte-exact against A and accepted references. `...-tui-01` qualifies six alternating
ordinary100-input pairs after20 warmups, unchanged optical JBM15 and1600×1000/scale2,
82×21 cells. No own builds, tests or diagnostic instrumentation overlap timing.
The frozen co-primary gate still requires at least5/6 improvements for both TUI
p95 and GUI CPU; the previous rejected mesh is never substituted for A.

| TUI metric | Accepted A | Lazy mesh B | B lower pairs |
|---|---:|---:|---:|
| p50 ms | 28.836 | 26.727 | 6/6 |
| p95 ms | 37.490 | 37.377 | 3/6 |
| p99 ms | 44.393 | 45.562 | 4/6 |
| Maximum ms | 47.198 | 46.495 | 4/6 |
| GUI CPU ms/input | 5.149 | 4.150 | 6/6 |
| GUI peak RSS MiB | 218.414 | 212.930 | 4/6 |
| Runtime CPU ms/run | 99.667 | 98.499 | 4/6 |

Both p50 and CPU improve in every pair, but p95 improves in only three. The
co-primary target therefore fails and B is rejected. Tail behavior's cause is not
established; neither lower CPU nor the favorable p95 median overrides pair counts.
No further ordinary regression controls are run after this failure, so this pass
also does not establish whether lazy preparation fixes the prior load regression.
Memory is not the rejection reason. Runtime windows include GUI setup/warmup/final
readback and exclude runtime startup/shutdown and child CPU; they are not added
to GUI CPU. Full runtime instructions/cycles remain in table.json.

Pixels pass14 host boundaries, maximum load1=3.03369; TUI passes26, maximum2.53271.
All18 owned runtime/child shutdowns, framework receipts and resource observers
pass. Frozen binaries, restored accepted production source/build and all four
pending runtime files are verified unchanged. Only the sparse transition oracle
and this report are retained. All-flow complete-stack and native120 acceptance
remain open; the persistent objective stays active.

A source-backed next lead is repeated cell color resolution within a row.
`cellRun` resolves foreground/background and applies inverse/selection/faint for
each cell, while the TUI fixture emits one RGB style for most cells in each row.
A row-local cache keyed by complete style and selection could skip repeated
conversion without changing scene-graph organization. Theme lifetime, semantic
CellColor equality, selection boundaries and faint application need independent
oracles; executed work and native timing remain unmeasured for this hypothesis.


## 2026-11-04: row-local resolved-color cache rejected

On source `68914a599`, `out-perf/dlls-row-color-cache-01` tests a row-local cache
of resolved foreground/background colors. Accepted GUI `bc55d0e8`, runtime
`1f1849d1`, helper `87beebb0` and original Qt remain A. Final B GUI is
`0c53bf227d4e513385cc398f6c8b5475449fb650458984eed0903bc1de650383`.
No background-mesh changes are included. The candidate keeps the original scene
nodes and drawing order and keys the cache by complete semantic CellStyle plus
selection. Misses retain the original resolve→inverse/selection→faint arithmetic.
The cache is constructed anew for each paintRow, so theme changes cannot reuse
an entry from a previous frame. The text fallback uses the same row-local cache.

The new independent scene oracle resolves each cell without caching, then builds
a reference row using explicit palette colors and no inverse/faint/selection.
Reference palette indices differ per cell, preventing the same cache hit from
masking an error. It covers default, RGB, palette, indexed cube and indexed gray
colors; repeated styles; precise translucent palette values; faint and inverse;
three selection states crossing equal-style neighbors; and palette changes across
five row variants. Standard and optical text modes each compare15 captures per
backend,30 total. The negative variant omits selection from the cache key and
fails both text modes on Metal. A and final B pass the oracle on software/Metal;
B passes all51 scene cases on both backends.

Initial lint leads to a simpler uncached reference helper and explicit expression
parentheses. Before any native timing, the candidate interface is also revised to
return resolved colors directly, avoiding initialization followed by overwrite
and the empty designated-initializer lint diagnostics. All final production and
oracle lint pass, followed by repeated complete scene checks and negative control.
Initial source/build/log variants remain separate and contribute no native timings.

ARM disassembly confirms a hit tests validity/selection and calls semantic style
equality, then skips the resolution block. Both A and B already call cellRun out of line; B additionally calls semantic
style equality on the hit path. Avoided conversion does not imply free lookup.
Actual-TU x86 baseline/v3 compilation succeeds. These are generated-code findings,
not executed hit counts, CPU attribution or whole-GUI x86/Linux validation.

`/tmp/telar-perf-row-color-cache-pixels-01` qualifies six native TUI/single/split
PNGs, byte-exact against accepted references. `...-tui-01` qualifies six alternating
100-input pairs after20 warmups, unchanged optical JBM15,1600×1000/scale2 and82×21
cells. No own builds/tests/profiles overlap ordinary timing. The frozen co-primary
TUI p95 and GUI CPU gate still requires at least5/6 improvements in each.

| TUI metric | Accepted A | Cached B | B lower pairs |
|---|---:|---:|---:|
| p50 ms | 28.825 | 28.829 | 3/6 |
| p95 ms | 36.932 | 37.808 | 1/6 |
| p99 ms | 41.579 | 41.732 | 1/6 |
| Maximum ms | 44.101 | 48.210 | 1/6 |
| GUI CPU ms/input | 5.061 | 4.960 | 4/6 |
| GUI peak RSS MiB | 222.742 | 217.617 | 5/6 |
| Runtime CPU ms/run | 99.472 | 99.287 | 4/6 |

Both primary targets fail; p95, p99 and maximum latency also regress consistently.
B is rejected and further ordinary regression controls are not run. The cause is
not established. Added helper calls are an observed codegen difference, not a
proven explanation or a placement exemption. Lower RSS is not the rejection reason.
Runtime CPU covers setup/warmup/final readback as before, excludes runtime startup,
shutdown and child CPU, and is not summed with GUI CPU. Full instructions/cycles
remain in table.json.

Pixels pass14 host boundaries, maximum load1=2.44434; TUI passes26, maximum4.07813.
All18 owned runtime/child shutdowns, loaded-Qt receipts and resource observers
pass. Frozen binaries, accepted production source/build and the four pending
runtime files are unchanged. Only the independent color oracle and this report
are retained; all F01–F16/native120 acceptance remains open and the goal is active.

A separate next lead avoids dynamic cache lookup entirely: the accepted ARM
cellRun listing contains runtime vector RGB normalization divisions. The scalar
color divisions in paintRow belong to its underline path. Color::rgb
normalizes each byte by255. A compile-time256-entry float table would use1KiB of
read-only storage to precompute that finite domain while retaining exact division
results. Exhaustive channel-bit equivalence, alpha preservation, cross-architecture
lowering and fresh native timing are required before treating it as an optimization.
No such table is implemented or accepted in this pass.

## 2026-11-04: exact RGB normalization table rejected

On source `fc1dfb0e2`, `out-perf/dlls-rgb-channel-table-01` replaces Color::rgb's
three byte-to-float divisions with a constexpr256-entry table generated using the
original division. Alpha and indexed-theme arithmetic remain unchanged. The table
occupies1KiB of read-only storage, with no dynamic initialization or allocation.
Accepted GUI `bc55d0e8`, runtime `1f1849d1`, helper `87beebb0` and original Qt remain
A. Final B GUI is `0a1e81c052882b99a5e284151bfbc417d3b04fd78adce3f9e86189ee009b0c8c`.
All scene nodes, ordering and drawing formulas are otherwise unchanged.

The new reusable gui-color oracle compares every channel value in all three
positions, plus4096 deterministic packed inputs, against uncached volatile runtime
division. Each input uses eight alpha bit patterns: positive/negative zero,
minimum subnormal,0.5,1,positive/negative infinity and a quiet NaN payload.
All38,912 comparisons require identical bits, including the ignored high RGB byte
and unmodified alpha. Compile-time evaluation and aggregate/size/trivial-copy
properties are also checked. Coverage assumes round-to-nearest; it does not claim
all alpha patterns or other rounding modes. A deliberate reciprocal-multiplication
table fails the compile-time assertion at channel52; an independently compiled
negative control with only that assertion removed also fails the runtime oracle.

Final A/B standalone oracles pass on ARM and Rosetta x86 baseline/v3; B also passes
ASan/UBSan. Actual TerminalScene translation units compile for both x86 targets.
Final production/oracle lint, gui-color/gui-theme and all51 B scene cases on both
software and Metal pass. The initial qualification stopped on test lint, was
corrected, and was rerun before native measurements; its files remain separate.
The accepted GUI is restored byte-identically before ordinary timing.

Kernel assembly replaces ARM's vector division and x86's two division instructions
with three indexed float loads; all B kernel listings contain exactly256 floats.
The linked B GUI has one channel-table symbol. Actual cellRun uses the table on
RGB paths; indexed conversions remain unchanged. These facts establish codegen,
not executed savings or a full-GUI x86/Linux performance result. This report also
corrects the preceding row-cache listing interpretation: A already called cellRun
out of line; paintRow's scalar color divisions are its underline path.

`/tmp/telar-perf-rgb-channel-table-pixels-01` passes all six native TUI/single/split
PNGs byte-exactly against both A/B and accepted references. `...-tui-01` qualifies
six alternating100-input pairs after20 warmups, optical JBM15,1600×1000/scale2 and
82×21 cells. No own builds/tests/profiles overlap ordinary timing. The frozen
co-primary p95/GUI CPU gate still requires at least5/6 lower pairs for each metric.

| TUI metric | Accepted A | Table B | B lower pairs |
|---|---:|---:|---:|
| p50 ms | 28.856 | 28.846 | 5/6 |
| p95 ms | 37.458 | 38.297 | 0/6 |
| p99 ms | 43.904 | 45.142 | 2/6 |
| Maximum ms | 47.999 | 50.626 | 2/6 |
| GUI CPU ms/input | 5.093 | 5.107 | 3/6 |
| GUI peak RSS MiB | 220.891 | 218.188 | 4/6 |
| Runtime CPU ms/run | 99.614 | 99.871 | 4/6 |

B is rejected: p95 loses every pair and the CPU target also fails. Cause is not
established. Neither fewer divisions nor lower median RSS overrides native timing;
memory is not the rejection reason. Further regression controls are not run after
this primary failure. Runtime windows include setup/warmup/final readback, exclude
runtime startup/shutdown and child CPU, and are not added to GUI CPU. Instructions
and cycles remain in table.json.

Pixels pass14 host boundaries, maximum load1=3.81836; TUI passes26, maximum4.60986.
All18 owned runtime/child shutdowns, framework receipts and resource observers pass.
Frozen stages, accepted production source/build and the four pending runtime files
are verified unchanged. Only the independent color oracle/CMake registration and
this report are retained. All F01–F16/native120 acceptance remains open.

## 2026-11-04: accepted TUI CPU profile refreshed

`out-perf/dlls-current-tui-cpu-profile-01` runs the accepted stack through400 measured
TUI inputs after20 warmups. The private driver samples only its identity-verified
GUI for8 seconds at1ms nominal intervals, beginning after trace sequence25 and
ending at135. This excludes startup and warmup and stays within active input work.
`/tmp/telar-perf-current-tui-cpu-profile-01` contains the source, stack sample and
receipts. Final sequence420 text validation, Qt identities, resource observer and
owned runtime/child cleanup pass. All four host boundaries qualify, maximum
load1=1.74951. Timings from this perturbed run are diagnostic only.

The short sample contains80 inclusive observations below QSGRenderer::renderScene
and45 below TerminalScene::synchronizeNode. Within the latter,18 observations sit
at paintRow's background-child removal call site; the accepted ARM listing maps
that return PC to the loop over row.background children. Qt's nodeChanged,
nodeWasRemoved and shadow-node hash operations appear below it. Counts include
nested work and waits, are not additive CPU percentages, and cannot establish a
causal bottleneck from one sample. Sampling also captures text shaping and probe
readback work; allocation/copy/conversion remains a hypothesis, not a proved cause.

A distinct source-backed lead is to detach a row's background container once,
rebuild its children while disconnected, and reinsert it at the same sibling
position. Current clearSceneChildren removes each rectangle separately while
attached; pinned Qt6.12 handles each through nodeChanged. Qt recursively removes
and adds a detached subtree, so the proposal would retain per-descendant shadow
work but avoid repeated attached-tree notifications. It would preserve individual
rectangles and their order, without merging or retaining them. The previously
rejected attached-text and retained-background variants are different operations.
This lead is unimplemented and unmeasured here; visual equivalence and paired
native controls are still required. The persistent objective remains active.

## 2026-11-04: detached background reconstruction rejected

`out-perf/dlls-detached-background-update-01`, source `b1364f66f`, tests the preceding
profile lead. A private scope guard disconnects a nonempty row background container,
lets the existing rectangle-removal/recreation loops run while disconnected, then
reinserts the container before its saved next sibling, or at the end. Empty
containers stay attached. Rectangles, color arithmetic and drawing order remain
unchanged; this neither merges rectangles nor retains them. Three stack pointers/
references replace repeated notifications through the full attached ancestor chain.
Pinned Qt still recursively removes/adds every shadow descendant, so this does not
eliminate descendant work or prove an allocation reduction.

Accepted A remains GUI `bc55d0e8`, runtime `1f1849d1`, helper `87beebb0`, original Qt.
B GUI is `f33e7506bb6daf857a2760db436e020a9265c90ea2b564a83193b9e67866be36`.
B passes production lint and all51 existing scene cases on software and Metal,
including the independent background/color/overlap/transition oracles. Deliberately
omitting reattachment fails the background-transition oracle. The actual translation
unit compiles for x86 baseline/v3. ARM code adds a conditional container-removal call,
retains the child loop and restores the saved sibling position. These are codegen
facts, not executed callback counts or whole-GUI x86/Linux validation.

The existing multirow scene probe had only default backgrounds, so it could not
exercise this candidate. The reusable `--colored-backgrounds` option now emits
changing RGB row backgrounds with default-color gaps. Full/sparse/retained schedules
continue to control which rows change, and the JSON receipt identifies the option.
The comparator forwards and validates it. Four offline controls verify propagation
and reject missing/mismatched receipts. A separate native capture proves that the
flag actually changes pixels (maximum channel difference38 versus default), rather
than merely changing its receipt. Initial full-tool lint exposes a QStringLiteral
include diagnostic; explicit QString construction resolves it. Final full-tool lint
passes; failed attempts remain archived and contribute no measurements.

`/tmp/telar-perf-detached-background-scene-pixels-01` passes all six A/B comparisons:
full/sparse/retained × standard/optical text, colored backgrounds,5 updates after
3 warmups, scale2, with rendering between updates. All3600×2214 final captures are
pixel-exact. This checks final visible pixels after the schedule, not every
intermediate drawable. All26 host boundaries qualify, maximum load1=1.93994.

`...detached-background-pixels-01` additionally passes six full-application
TUI/single/split PNGs byte-exact against accepted references. `...-tui-01` qualifies
six alternating100-input pairs after20 warmups, optical JBM15,1600×1000/scale2,
82×21 cells. No own builds/tests/profiles overlap ordinary timing. Co-primary
TUI p95 and GUI CPU still each require at least5/6 lower pairs.

| TUI metric | Accepted A | Detached B | B lower pairs |
|---|---:|---:|---:|
| p50 ms | 28.777 | 28.851 | 2/6 |
| p95 ms | 37.248 | 37.425 | 2/6 |
| p99 ms | 43.140 | 43.347 | 2/6 |
| Maximum ms | 47.244 | 45.722 | 3/6 |
| GUI CPU ms/input | 5.039 | 5.051 | 3/6 |
| GUI peak RSS MiB | 232.062 | 227.812 | 4/6 |
| Runtime CPU ms/run | 99.430 | 100.738 | 3/6 |

Both primary targets fail. B is rejected; cause is not established. The short
pixel-qualification timings are not acceptance evidence. Neither fewer attached
notifications nor favorable peak-memory medians overrides the ordinary pairs.
Further regression controls are not run after primary failure. Runtime windows
include setup/warmup/final readback, exclude runtime startup/shutdown and child CPU,
and are not summed with GUI CPU. Full counters remain in tables.json.

Application pixels pass14 host boundaries, maximum load1=1.86475; TUI passes26,
maximum2.62549. All18 owned runtime/child shutdowns, Qt receipts and resource
observers pass. Frozen binaries, accepted production source/build and all four
pending runtime files are unchanged. Only the colored-background probe/comparator
and this report are retained. No complete flow or native120 requirement is closed;
the persistent objective remains active.

## 2026-11-04: exact text-projection reuse has limited tab-switch coverage

On `68ee64e1a`, `out-perf/dlls-text-projection-census-01` investigates skipping
geometry work when ChromeScene's text revision and complete raw projection are
unchanged. Private instrumentation in chrome_text_scene.cpp records standard and
optical scene calls, exact numeric projection matches, equal foreground, mesh
calls and glyph visits. It compares all origin/anchor/area/fade/scale fields without
Qt's fuzzy point equality. No rendering, geometry update or dirty notification is
omitted. Atomic counters and a diagnostic previous-projection value add overhead;
all timings are excluded from acceptance. Counts span startup,20 warmups,100
measured inputs and the rest of the GUI lifetime, not just measured inputs.

The instrumented build passes all51 Metal scene cases. After staging it, source
and configured GUI restore byte-exactly to accepted `bc55d0e8`; runtime `1f1849d1`,
helper `87beebb0`, original Qt and the four pending runtime files stay unchanged.
The first pixel qualification uses the wrong working-directory basename: both A/B
render the same shorter workspace/tab labels, but differ from accepted references.
It is incomplete and excluded. The corrected entire six-capture series in
`/tmp/telar-perf-text-projection-pixels-02` passes single/splits/tabs byte-exactly.
All14 host boundaries qualify, maximum load1=3.54492.

The first activity census reuses an archived tab observer lacking the newer
loaded-image receipt. Its native content/rate/phase checks pass but framework
verification fails closed; the complete series remains invalid. A fresh observer
built by tools/build_tab_switch_probe.py repeats all three cases in
`/tmp/telar-perf-text-projection-census-02`. All native, tab phase/rate/content,
Qt-framework and resource checks pass. All eight host boundaries qualify,
maximum load1=1.76416. The analyzer passes a positive accounting control and rejects
ten missing/duplicate/impossible counter mutations. All14 owned runtime/child
shutdowns across valid and invalid attempts complete.

| Qualified diagnostic lifetime | Standard mesh calls | Exact-state reusable mesh calls | Standard glyph visits | Reusable glyph visits | Optical glyph visits | Reusable optical visits |
|---|---:|---:|---:|---:|---:|---:|
| Single typing | 139 | 66 | 1150 | 272 | 1 | 0 |
| Four-split typing | 320 | 143 | 3535 | 349 | 1397 | 0 |
| 100 tab switches | 10560 | 1504 | 145207 | 2256 | 55800 | 0 |

In the switch workload,1504 of10570 standard scene paints have both an unchanged
revision and equal raw projection;1484 also have equal ink. Most eligible meshes
are small: they account for only2256 of201007 total standard/optical glyph visits,
about1.12%. No optical scene has an unchanged revision. This is not a CPU fraction
or proof that every matching projection permits reuse across arbitrary texture
implementations. A broad projection cache is deprioritized before implementation,
not rejected by native timing. No projection-cache change is retained.

A separate source-backed lead is material invalidation. GlyphMesh::paint always
assigns foreground and marks DirtyMaterial along with DirtyGeometry. Pinned Qt's
nodeChanged checks material compatibility even when the color remains equal;
that can call AlphaMaskMaterial::compare, including texture queries. Geometry
changes do not imply color changes. The following private census distinguishes
same-color newly created meshes from previously painted meshes before selecting
a production variant. All F01–F16/native120 requirements and the goal remain open.

## 2026-11-04: text material invalidation census

`out-perf/dlls-text-material-census-01` extends the preceding private observation
with same-foreground counts and a per-mesh already-painted flag. Counts distinguish
constructor-initialized materials from previously rendered meshes. No assignment,
geometry computation, draw or dirty notification is skipped. The accepted GUI,
runtime/helper/Qt and pending runtime source remain the same. This diagnostic also
passes all51 Metal scene cases and six single/splits/tabs PNGs byte-exact against
accepted references in `/tmp/telar-perf-text-material-pixels-01`.

`/tmp/telar-perf-text-material-census-01` qualifies100 measured plus20 warmup inputs
for single typing, four splits and previous-tab switching with four30Hz producers.
The current tab observer includes loaded-image receipts. All content/phase/rate,
framework, resource and cleanup checks pass; no own builds/tests overlap these
runs. Pixel/activity host boundaries are14/8, maximum load1=2.79395/2.27539. All
nine owned runtime/child shutdowns complete. Fourteen negative counter mutations
are rejected. As before, instrumentation covers the whole GUI lifetime and its
timings are not acceptance evidence.

| Tab-switch diagnostic lifetime | Mesh paints | Foreground already equal | Equal on previously painted meshes |
|---|---:|---:|---:|
| Standard interface text | 10595 | 10557 | 5757 |
| Optical terminal text | 1146 | 1146 | 886 |
| Combined | 11741 | 11703 | 6643 |

These counts support testing conditional DirtyMaterial notification separately
from geometry caching. Newly created materials require their own first-render
correctness checks; equality is not by itself proof that notification is dispensable.
No material optimization is accepted by this census. The next isolated experiment,
`out-perf/dlls-unchanged-text-material-01`, keeps every geometry computation,
DirtyGeometry flag and foreground assignment, while adding DirtyMaterial only
when foreground differs. It adds no persistent storage. The unchanged five-of-six
CPU/p95 target and native regression controls will decide adoption, after color
transition/first-render oracles and codegen review. The goal remains active.


## 2026-11-04: conditional text material notification rejected

On source `68ee64e1a`, `out-perf/dlls-unchanged-text-material-01` freezes accepted
GUI `bc55d0e8` and candidate `52bbd1f1`, with the same accepted runtime/helper/Qt.
GlyphMesh::paint retains all geometry calculations, DirtyGeometry and unconditional
foreground assignment. It adds DirtyMaterial only when the four foreground
components compare unequal. There is no new persistent storage or allocation.

The first missing-assignment negative unexpectedly passes the cell-color oracle:
that comparison does not expose this retained material transition. The attempt
is archived under initial-insufficient-oracle and no timing uses it as proof.
The existing independent face-raster oracle is suitable: both regular and
emphasized NativeChromeText labels change white→red→white without changing text.
Accepted A passes; the missing-assignment negative fails both at the red transition
(chrome_text_test.cpp:588). B passes all51 scene tests on both software and Metal
and the full chrome-text Metal suite. Production clang-tidy and actual translation
unit compilation for x86-64 baseline/v3 pass. Production source and configured GUI
are restored byte-exactly before any native runs.

ARM64 adds an out-of-line foreground getter and four float comparisons, selecting
DirtyGeometry alone or both flags; the unconditional setter and176-byte stack
frame remain. x86 baseline uses cmpeqps/movmskps, v3 uses vcmpeqps/vtestps. Pinned
Qt's material branch checks blending and batch material compatibility; geometry
invalidation is still performed and can already invalidate the batch. These are
code paths, not a measured CPU saving or a placement exemption.

All six TUI/single/splits application PNGs in
`/tmp/telar-perf-unchanged-material-pixels-01` match each other and accepted
references byte-for-byte. Their short timings are not acceptance evidence.
The first native tab series (`...-tabs-01`) is discarded in full after run1-B:
load1=5.60205 exceeds the unchanged5.0 limit. All three owned runtime/child
shutdowns complete. No result from this interrupted series is used. A complete
six-pair repeat starts in `...-tabs-02` after load returns below the limit; no own
builds, tests or profiles overlap native timing.

The repeated series completes six alternating pairs,100 measured plus20 warmup
native previous-tab inputs per run, four30Hz producers,1600×1000/scale2 and82×21
cells. Same accepted optical JBM15 configuration and current tab observer are used.

| Qualified native tab switching | Accepted A median | Candidate B median | B lower |
|---|---:|---:|---:|
| p50 ms | 37.956 | 37.423 | 3/6 |
| p95 ms | 42.129 | 41.842 | 4/6 |
| p99 ms | 43.507 | 42.447 | 4/6 |
| Maximum ms | 44.666 | 43.385 | 4/6 |
| GUI CPU ms/input | 28.090 | 27.656 | 3/6 |
| GUI peak RSS MiB | 207.211 | 204.883 | 5/6 |
| Runtime CPU ms/run | 391.190 | 394.296 | 3/6 |

Both co-primary targets fail the frozen five-of-six rule. B is rejected, cause
not established; no placement exemption is claimed. Favorable medians and lower
RSS do not override the ordinary paired result. Additional regression controls
are not run after primary failure. Runtime resources cover setup/warmup/measurement
and differ from the GUI measured interval; CPU is not summed across them.

Pixel/repeated timing series pass14/26 host boundaries, maximum load1=2.52441/
4.07129. All18 qualified runtime/child shutdowns and all three from the invalid
attempt complete; content/producer rate/phase, loaded Qt images and resource
receipts pass. Frozen stages, production GUI/source and all four pending runtime
files verify unchanged. Tables, validation, assembly review and decision are in
the experiment prefix. Only this report is retained. No complete flow or native120
requirement is closed, and the goal remains active. Next investigation: measured
allocation sites during tab switching, distinguishing framework/model conversion
and text rebuild work before selecting another reuse algorithm.

## 2026-11-04: tab-switch heap samples identify ancestor reconnection work

On `ef3281c42`, `out-perf/dlls-tab-heap-sites-01` extends the existing private
heap probe builder with `--workload tabs`, retaining typing as the default. It
reuses the current tab packet/phase/producer harness and the unchanged six-API
heap observer. Both counts-only and sampled libraries pass exact API totals,
errno, stack-site, disabled-sampling, fork exclusion, threading and capacity
controls. The typing build remains supported and the three report tests pass.
The accepted GUI `bc55d0e8`, runtime `1f1849d1`, helper and Qt are not rebuilt.

The first capture attempt fails during warmup, before observation begins. The
live-switch capture sentinel remains on tab0, making its packet undecodable on
return. This is an unsupported harness combination, not a product regression or
heap measurement. Deterministic ordinary four-tab captures with the same observer
instead pass exactly against the accepted reference. The first100-switch sampled
run at1/256 records8192 stacks and overflows by2077; its partial attribution is
excluded. Both initial attempts and successful owned shutdowns are retained.

The final configuration uses1/512 sampling with the unchanged8192-record/24-frame
bounds. All four final libraries (typing/tabs, counts/sampled) pass the control
program. `/tmp/telar-perf-tab-heap-pixels-03` passes both deterministic captures;
`/tmp/telar-perf-tab-heap-sites-02` completes two diagnostic100-input runs after20
warmups, four30Hz producers,1600×1000/scale2,82×21, optical JBM15. Native content,
producer rate/phase, loaded Qt images, resource observations and all nine owned
shutdowns across the attempts pass. Final pixels/sites each pass six host
boundaries, maximum load1=2.58057/2.36035. No own build/test overlaps collection.

| Measured interval diagnostic | Counts-only | Sampled |
|---|---:|---:|
| Successful observed allocation calls | 2,628,813 | 2,618,220 |
| Requested bytes, cumulative | 886,699,766 | 885,420,133 |
| Recorded allocation stacks | 0 | 5,052 |
| Stacks reaching depth24 | 0 | 3,141 |

These are API-request totals, not live memory, CPU attribution or timing wins.
Instrumentation serializes observation and includes native-probe/framework work;
no difference between the two runs estimates an optimization benefit. Source,
stages, configured GUI and the four pending runtime files verify unchanged.

Inclusive sample categories overlap:2157 contain QV4,1884 QVariant-map operations,
1046 Metal binding batches,427 ListModel,220 Application::refresh,186 ChromeScene,
180 TerminalScene and178 TextScene. Limited stack depth prevents exhaustive
ancestor attribution. First non-wrapper allocation sites include1133 QArrayData
allocations and1121 map-node insertion samples. No rejected typed-tab, retained
pane or Qt binding variant is revived by these counts.

A distinct application lead has564 samples through AncestorGeometry::observe:
515 arrive via its ancestor parentChanged callback,33 from NativeChromeText's own
parent change,9 from NativeTabActivity and7 from NativeRoundedRectangle. Recorded
stacks show QQmlObjectCreator/Repeater hierarchy construction. Source currently
disconnects all eight signals for every ancestor and reconstructs the entire
chain on each such callback, even when the nearest part of the chain remains
unchanged. This establishes repeated reconnection allocation, not its CPU share.
The next isolated hypothesis retains connections for the unchanged near-ancestor
prefix and rebuilds only the changed suffix. It needs lifecycle/reparenting and
pixel oracles before ordinary timing; the full goal remains active.

## 2026-11-04: retained ancestor connection prefix rejected

`out-perf/dlls-retained-ancestor-prefix-01`, based on `1fa2f5cf4`, tests retaining
the unchanged near-ancestor prefix in AncestorGeometry::observe. Candidate
`9d81668fa4c854027eb943d4f5267aa9aa58db2956134ca81f2ae976697fd457`
stores guarded QPointer identities beside the same eight connection handles,
disconnects only the obsolete suffix and connects only newly reached ancestors.
It preserves all geometry/parent signals and item updates. Accepted GUI remains
`bc55d0e8`, runtime `1f1849d1`, helper/Qt unchanged.

Two reusable chrome-text oracles are added first. One checks all eight signal
receiver counts after direct/indirect reparenting, ancestor deletion, item detach
and item destruction. The other compares rendered text against independent face
rasterization through several ancestor changes and fractional positions. A passes;
negative controls omitting ancestor refresh or disconnection both fail the count
oracle. B passes the full18-case chrome-text Metal suite, both51-case software/Metal
scene suites, and icon, rounded-rectangle, tab-activity, pane-attention and chrome
component tests. ASan/UBSan instruments AncestorGeometry and the chrome-text test
with candidate headers, and passes the full suite; other GUI/MOC/Qt code remains
unsanitized and leak detection is disabled. Three initial lint attempts find
missing direct includes and initializer spelling issues; archived failures are
not validation. Final production/oracle clang-tidy and actual-TU x86 baseline/v3
compilation pass.

ARM64 linked assembly retains a guarded ancestor walk before suffix disconnection;
matching ancestors bypass reconnection. Its observe stack subtraction increases
160→224 bytes. Clang layout reports the outer object unchanged at32 bytes; each
ancestor's64 bytes of connection handles becomes an80-byte observation including
a16-byte QPointer. This excludes list capacity/header and possible shared Qt weak
reference control storage. Extra memory is permitted; it is not a rejection reason.

Eight application PNGs in `/tmp/telar-perf-retained-ancestor-pixels-01` match A/B
and accepted single/splits/tabs/TUI references exactly. Source and configured GUI
restore byte-exactly before native timing. `/tmp/telar-perf-retained-ancestor-tabs-01`
completes six alternating100-input/20-warmup pairs with four30Hz producers,
1600×1000/scale2,82×21 and the same optical JBM15 configuration.

| Ordinary native tab switching | A median | B median | B lower |
|---|---:|---:|---:|
| p50 ms | 38.855 | 38.534 | 4/6 |
| p95 ms | 42.604 | 41.464 | 4/6 |
| p99 ms | 43.183 | 42.068 | 4/6 |
| Maximum ms | 44.995 | 43.636 | 4/6 |
| GUI CPU ms/input | 28.010 | 28.622 | 4/6 |
| GUI peak RSS MiB | 204.953 | 204.906 | 3/6 |
| Runtime CPU ms/run | 392.227 | 396.877 | 3/6 |

Both co-primary targets fail the frozen5/6 gate. B is rejected; cause is not
established and no placement exemption is claimed. CPU median and paired win
count summarize different aspects of the rows. No further regression controls
are run after primary failure. Runtime counters span setup/warmup/measurement,
not the GUI's measured interval, and are not summed with GUI CPU.

Pixels/timing pass18/26 host boundaries, maximum load1=3.35986/3.16895. All20 owned
shutdowns, content/producer rate/phase, Qt and resource checks pass. No own
build/test/profile overlaps timing. Frozen stages, production source/build and all
four pending runtime files verify unchanged. A separate subsequent heap diagnostic
checks whether the intended allocation reduction occurred; it cannot reverse the
ordinary rejection. Only the new oracles and findings are retained.

`/tmp/telar-perf-retained-ancestor-heap-01` then runs A/B counts-only and B/A sampled
observers for100 measured switches each. The unchanged1/512 observer and counters
remain diagnostic, including native-probe work. All four native/rate/phase/Qt/
resource checks and shutdowns pass; ten host boundaries qualify, maximum2.73438.
Neither sampled run overflows. Production, stages and pending runtime source are
rechecked unchanged afterward.

| Allocation diagnostic | A | B |
|---|---:|---:|
| Counts-only successful calls | 2,619,924 | 2,431,455 |
| Counts-only cumulative requested bytes | 885,371,625 | 874,977,981 |
| Sampled successful calls | 2,618,629 | 2,404,414 |
| Sampled cumulative requested bytes | 885,194,862 | 871,573,323 |
| Recorded stacks | 5,053 | 4,625 |
| Depth-limited stacks | 3,067 | 2,690 |
| Inclusive AncestorGeometry stacks | 543 | 147 |

Counts-only calls fall about7.2%; samples support less ancestor reconnection work.
These are separate diagnostic runs, not exact per-site population counts, live
memory, CPU attribution or timing acceptance. Other inclusive categories still
include QV4 (2089/1968), QVariant-map operations (1850/1714) and Metal binding batches
(1033/1067); rows overlap. The allocation reduction does not override rejection.
The next investigation targets repeated QML value/map conversion work and must
remain distinct from previously rejected scalar roles and stable QObject tab
presentations. All F01–F16/native120 requirements remain open; the goal is active.

## 2026-11-05: positioned-tab value representation rejected

`out-perf/dlls-tab-layout-value-01`, based on `15676f658`, tests a Q_GADGET value
containing the four positioned rectangles, three flags and the original semantic
tab map. A new `visual` model role supplies this value to TerminalTabs.qml; the
legacy `record` role constructs its map lazily. Keyed reconciliation, layout
calculations, ordering and semantic tab consumers remain equivalent. This differs
from the rejected scalar roles and stable QObject presentations: it has one owned
value per row, no row QObject, and no per-property notification policy.

Pinned Qt source supports the hypothesis, without establishing its CPU cost.
`qqmlvmemetaobject.cpp` converts a var property's previous value back to QVariant
when comparing updates. Detached VariantAssociationObject instances reconstruct
their native map through `ExecutionEngine::variantMapFromJS`, which enumerates
properties. The candidate avoids the outer map construction and association
conversion; it does not remove the inner semantic map or all QML value work.

The private component oracle compares 2,048 seeded reconciliations against
ListModel, including moves, removal, unchanged rows, notification counts,
persistent indexes and the 64-row bound. Another runs 240 QML updates with Unicode,
custom progress values, independent copies, nested mutations and garbage
collection. An initial destructor assertion fails: both accepted ListModel and
the candidate retain an Instantiator delegate after model destruction, even after
event processing. The corrected comparative lifecycle oracle verifies explicit
row retirement, safe retained values after model destruction, delegate retirement
when its owner dies, and surviving independent snapshots. All component tests pass,
including ASan/UBSan over the model, value, generated MOC and test; Qt remains
unsanitized and leak detection is disabled.

A separate counts-only component diagnostic uses four rows, 100 warmup updates,
1,000 measured geometry updates and matching QML property bindings. Two alternating
executions of each representation produce identical counts: 218,067→101,016
successful allocation calls and 18,717,688→5,588,432 cumulative requested bytes.
These six-API observations include framework work and omit uncovered allocation
APIs; they are not live memory, CPU attribution or native performance acceptance.
`sizeof(TabLayoutValue)` is 144 bytes versus 8 for the map handle, whose external
tree nodes and QVariant storage are excluded from that size. No memory tradeoff
is rejected merely for using more inline storage.

Candidate GUI is
`2971081aaf4a2ccb283b603bd04f5c7ace31fdd680e84bf92815ad786fdc5f3c`;
accepted GUI remains `bc55d0e8`, runtime `1f1849d1`, helper and Qt unchanged.
Final clang-tidy passes after adding a direct include and removing a redundant
local. Actual-TU ARM64 and x86-64 baseline/v3 compilation passes. ARM64 rebuild
removes nine per-tab map insert call sites and associated QVariant construction;
counter and semantic-map work remains. Its total fixed stack frame falls
6,416→6,128 bytes. Linked B confirms the new lowering. No timing conclusion is
drawn from instruction or stack size alone.

B passes the 16 chrome, 51 scene, 18 chrome-text and 11 tab-activity-scene cases
on both software and Metal. Native quick tests cover switching, split/close,
drag reorder, Escape, source closure, viewport/modal interruption and hidden
counter reveal/drop. The focus-loss case initially fails while another graphical
suite runs; it passes in isolation. Both results are retained; interference is
a hypothesis, not a demonstrated cause of that initial failure.

Two complete pixel series are discarded by the unchanged host gate at load1
5.56152 and 5.86377. All ten owned shutdowns pass. After cooldown,
`/tmp/telar-perf-tab-layout-value-pixels-03` qualifies: eight single/splits/tabs/TUI
PNGs match A/B and the accepted references byte-exactly, with 18 host boundaries
and maximum load1 2.92139. `/tmp/telar-perf-tab-layout-value-tabs-01` then completes
six alternating 100-input/20-warmup native pairs, four 30 Hz producers,
1600×1000/scale2, 82×21, optical JBM15 and identical accepted runtime.

| Ordinary native tab switching | A median | B median | B lower |
|---|---:|---:|---:|
| p50 ms | 37.814 | 37.670 | 3/6 |
| p95 ms | 42.665 | 42.878 | 3/6 |
| p99 ms | 43.687 | 43.935 | 2/6 |
| Maximum ms | 44.232 | 45.206 | 1/6 |
| GUI CPU ms/input | 27.732 | 27.519 | 4/6 |
| GUI peak RSS MiB | 205.922 | 205.422 | 3/6 |
| Runtime CPU ms/run | 394.445 | 394.169 | 4/6 |

Both frozen co-primary requirements, p95 and GUI CPU winning at least 5/6,
fail. Maximum latency also loses consistently. Reject B; cause is not established
and no placement exemption is claimed. Additional regression controls are not
run after primary failure. All 26 timing host boundaries qualify, maximum load1
3.04541; content, producer rate/phase, resources, Qt identity and all 12 shutdowns
pass. No own builds, tests or profiles overlap ordinary timing. Runtime CPU spans
setup/warmup/measurement and is not summed with the GUI's different interval.

A subsequent diagnostic, `/tmp/telar-perf-tab-layout-value-heap-01`, checks the
actual application's allocations; it cannot reverse rejection. The unchanged
counts-only and 1/512 sampled observers both complete 100 native switches per
variant, with no sample overflow. All four content/rate/phase/Qt/resource and
shutdown checks pass; ten host boundaries qualify, maximum load1 3.30859.

| Application allocation diagnostic | A | B |
|---|---:|---:|
| Counts-only successful calls | 2,625,292 | 2,556,624 |
| Counts-only cumulative requested bytes | 887,536,396 | 869,941,712 |
| Sampled successful calls | 2,582,548 | 2,569,991 |
| Sampled cumulative requested bytes | 880,712,286 | 871,890,284 |
| Recorded stacks | 4,980 | 4,961 |
| Depth-limited stacks | 3,032 | 2,982 |
| Inclusive map-operation samples | 1,783 | 1,351 |
| Inclusive association-wrapper samples | 1,269 | 899 |
| Inclusive value-type-wrapper samples | 123 | 494 |
| Inclusive QV4 samples | 2,102 | 2,116 |

The observed counts-only reduction is about 2.6% across the application diagnostic,
much smaller than the isolated component's reduction. Overlapping sampled groups
show less map/association work and more value-wrapper allocation; their counts
are not CPU percentages or exact population estimates. This supports examining
how much presentation work can be avoided, rather than treating allocation count
alone as a proxy for speed. It does not revive earlier rejected cache/retention
variants or establish the cause of B's latency result. Production source is
restored. Initial restoration retained stale CMake autogen/raw-QML resources;
explicit reconfiguration and regeneration of the owned resource reproduce the
accepted GUI byte-exactly. The restored chrome suite passes, all four pending
runtime files verify unchanged, and all 34 owned shutdown receipts pass, including
the discarded pixel attempts. Only findings are committed; the rejected candidate
and component oracles stay archived privately. All F01–F16/native120 acceptance
remains open and the persistent goal stays active.

## 2026-11-05: discrete native scrollback baseline and row-work lead

`out-perf/dlls-scroll-qualification-01`, based on `0456cdc93`, adds reusable partial
F06 support without changing either application. Accepted C++ GUI remains
`bc55d0e8`, runtime `1f1849d1`, helper `87beebb0`, pinned QtGui `abd4bdf7`;
independent Zig remains `6ccf7948`. All four pending runtime files verify unchanged.
The setup is optical JBM15, 1600×1000, scale2 and an 82×21 terminal on the same
M1 Pro host. The persistent all-flow/native120 goal remains active.

The new fixture populates 4,096 stationary ASCII rows with unique identity/CRC
packets, then acknowledges terminal parsing with DSR. Its 894,730-byte payload has
SHA256 `022fb8f538cfc698f2a7d8874edcf219432add59acc905ebc07c6f7b9cb7908a`.
The first visible row is 4,076. Each direct native AppKit discrete-wheel dispatch
moves three rows upward; the native Metal readback requires the exact new top-row
packet on a drawable with a positive presentation timestamp. It retains the
ordinary focus, geometry, VSync and timeout checks. This is not physical-device
input, precise/momentum scrolling, selection, return-to-live or continuous cadence.
The parser validates the corpus receipt, owner, grid, origin, every expected and
observed row, and monotonically ordered input/presentation timestamps.

Five new fixture/validator tests and six existing packet tests pass, including
stale/wrong/repeated rows, malformed geometry/identity, timestamps and checksums.
Native negative controls in `/tmp/telar-perf-scroll-negative-01` suppress wheel
dispatch or offset the expected row by one. Both fail at the intended two-second
input watchdog with no accepted GPU/presentation samples; both owned shutdowns
pass. Six host boundaries qualify, maximum load1 1.96436. The final generated CLI
also completes both stacks, verifies matching grids, emits `scroll` aggregates and
records the native wheel input method. Its two shutdowns pass and seven host
boundaries qualify, maximum load1 1.29639. Unsupported workloads fail before launch.

`/tmp/telar-perf-scroll-baseline-01` completes six alternating 100-input/20-warmup
pairs with the v2 native probe. The inherited result case label was still `single`;
`interaction=scroll_up`, `input_method=native_discrete_wheel` and the external exact
row validator establish the distinct workload. Later builder changes correct CLI
labels, aggregation and source receipts, integrate validation, and reject other
workloads; they do not change the native event/readback path. Validator type
hardening and builder edits during the series did not modify the already loaded
validator or frozen native probe. No own builds, tests or profiles overlap timing.

| Discrete upward scroll, independent stacks | Zig median | C++ median | C++ lower |
|---|---:|---:|---:|
| p50 ms | 37.175 | 30.874 | 6/6 |
| p95 ms | 45.920 | 40.529 | 6/6 |
| p99 ms | 48.659 | 44.841 | 6/6 |
| Maximum ms | 49.697 | 46.102 | 5/6 |
| GUI CPU ms/input | 5.032 | 5.008 | 5/6 |
| GUI peak RSS MiB | 132.078 | 205.172 | 0/6 |
| Runtime CPU ms/run | 77.999 | 84.337 | 0/6 |

All 12 native row sequences, grid/resource/Qt identity checks and shutdowns pass.
All 26 host boundaries qualify, maximum load1 2.74902. Runtime CPU includes GUI
launch, corpus population, warmup, measured input and GUI exit; it excludes runtime
startup/shutdown and child CPU. It cannot be attributed to scroll input alone or
summed with the GUI's narrower interval. The memory difference is reported, not an
automatic rejection of a faster algorithm. These observations are a bounded
baseline, not complete F06 acceptance or a new optimization win.

Separate 240-input/20-warmup diagnostics in
`/tmp/telar-perf-scroll-profile-01` collect ten-second GUI/runtime `sample` profiles
for both stacks after corpus readiness. All four sample commands succeed. Both
native sequences/resources/Qt identities/shutdowns pass; six host boundaries
qualify, maximum load1 2.44580. C++ profiles contain `TerminalScene::paintRow`, Qt
scene rendering/upload, and runtime terminal projection. Runtime application
samples are sparse; their inclusive counts do not establish CPU shares or explain
the wider runtime CPU difference. Profiling does not contribute acceptance timing.

`/tmp/telar-perf-scroll-pixels-01` captures the initial viewport before upward input.
All 21 row packets match their expected identities, including the explicit gray
capture witness on the initial top row. The complete terminal rectangle
(120,84)–(1596,924) is pixel-exact across stacks. The full windows differ at 4,732
pixels with maximum channel difference141, outside that terminal rectangle; no
full-window parity claim is made. Both subsequent native sequences and shutdowns
pass; six host boundaries qualify, maximum load1 2.22412. This static capture does
not certify intermediate scrolling body pixels. Raw PNG hashes and all final
checks are in the private `final-validation.json`.

The next algorithmic lead is reusing displaced terminal rows. A three-row movement
in this 21-row viewport leaves 18 rows with the same content at different positions.
The current scene uses position-based revisions and rebuilds changed rows;
scrolling forces runtime projection and supplies changed positional contents.
A bounded previous-cell snapshot could prove exact overlap and permit row-node
reuse, trading memory and comparisons for less text/background reconstruction.
This differs from the rejected same-position snapshot revision and whole-pane
retention candidates. Before implementation, it needs an independent fresh-scene
pixel oracle covering translations, clipping, styles, Unicode, selection, cursor,
appearance, resize and unrelated pane snapshots. Transform/shader behavior and
actual saved work remain to be demonstrated. No production change is accepted by
this baseline, and all complete-flow/native120 requirements remain open.

The follow-on `out-perf/dlls-scroll-row-reuse-01` prepares the oracle before the
production candidate. `scene_test.cpp` now compares a persistent scene against a
scene destroyed and freshly constructed for each update. Both standard and optical
text cover 14 viewport positions: upward/downward movement, large jumps and live
bottom, combining and wide characters, box glyphs, styles, selection/cursor,
palette changes, clipped columns and oversized raster height. The fixture now
supports multiple rows. The initial test incorrectly gave a hidden cursor nonzero
coordinates; the protocol correctly rejects it. Correcting that fixture produces
pixel-exact results. Both complete scene suites pass 53 cases on software and Metal.
After the final enum-storage lint fix, both new cases are rerun on both backends.

Full actual-TU clang-tidy reports three existing diagnostics, independently
reproduced on the frozen pre-change test with its own generated MOC: uninitialized
BackgroundRectangle scalar members, the earlier Qt `_data` method's required
suffix, and its non-const QFETCH variable. The final additions introduce no further
diagnostics; the profile and thresholds are unchanged. This is not a clean whole-TU
lint claim. Raw attempts, builds and baseline/final lint outputs remain private.

Source inspection confirms a constraint on the proposed optimization:
`TextProjection::quad` intersects glyph ink with the terminal clip before writing
geometry. Moving an already clipped mesh cannot recover discarded ink. Row reuse
therefore needs proof of unclipped original/destination ink and exact pixel
translation, or a different representation that preserves it. A private contract
records bounds, exact cell comparison, pane/appearance/grid invalidation, row order,
selection/cursor and cache lifetime controls still required. No row-reuse candidate
is implemented or accepted yet. The production GUI remains byte-exact `bc55d0e8`,
and the four pending runtime files remain untouched. Work continues from this oracle
with all complete F01–F16/native120 acceptance open.


### Displaced scroll-row reuse: rejected after complete native target pairs

On `cpp-stack-perf-dlls-20261103` at `1b950e3a8`, the private experiment
`out-perf/dlls-scroll-row-reuse-01` implements the preceding proposal. It rotates
retained row nodes with scroll displacement, compares exact style/width/text cells,
and translates only rows whose original and destination glyph ink remain unclipped
and whose physical translation is exact. Pane/grid/appearance changes, selection,
cursor and unproven fallback ink force repaint. Original painted coordinates avoid
accumulated transform drift. Snapshots are taken only while viewing history.
The candidate is **rejected**, and all six production renderer files are restored.

The fresh-scene oracle now covers 20 positions, adding same-offset cell mutation,
shifted changed cells, unrelated-pane replacement and grid shrink/restore. Candidate
B passes all 53 scene and 18 chrome-text cases on software and Metal. B2 changes
only cell comparison iteration to const; its complete 53-case scene suites pass
with coherent project ASan/UBSan on both backends. Production-TU clang-tidy is
clean; the three previously reproduced test-TU diagnostics remain. Following
restoration, both expanded scroll cases pass on software and Metal. The expanded
oracle is retained as reusable source.

Sanitizer qualification required correcting the diagnostic build, not suppressing
checks. Mixing three sanitized renderer objects with normal project libraries first
reported a vector container overflow; that partial build was not accepted as a
coherent check. A fresh configuration accidentally triggered a different managed
Qt bootstrap and its owned process tree was stopped. The complete project build
then exposed AppleClang21 C objects linked to LLVM23 C++ ASan. The successful private
build preserves the frozen Qt bootstrap and explicitly overrides the generated
C compile/link rules to LLVM23; its executed commands and override are recorded.
ASan container checks remain enabled, UBSan halts on errors and leak detection is
disabled. Qt, prebuilt Ghostty and system frameworks are not fully instrumented.
The earlier failures are retained privately; the mixed-build report is not assigned
a proven root cause.

A separate source-counter run, `/tmp/telar-perf-scroll-row-reuse-census-01`, confirms
exactly 3 painted and 18 reused rows for each of 100 measured inputs: 300 and 1,800
in total. Warmup and out-of-range epochs contribute zero. The uninstrumented B2
negative control reports zero source events. Peak cached cell-element capacity is
85,344 bytes; each CellValue is32 bytes and each cached Row is120 bytes. Those bytes
exclude allocator/container headers and GPU resources. Bounded extra memory was
permitted; fewer paint calls alone are not performance acceptance.

The private full-drawable observer captures the final positively presented frame
only after its exact top-row packet is accepted. In
`/tmp/telar-perf-scroll-row-reuse-body-02`, A and B2 have zero differing pixels over
the whole window and match the prior fully validated capture: all21 row packets,
first row4007, cell18x40, origin120,84 and drawable86. The full PNG hash is
`ec87ced6f6c97b8de5057ed62eefa1b98970cc34c066c40db8381bd85e1f164d`.
Readback/capture and source-counter runs are diagnostic, excluded from timing.
This final-frame check does not certify intermediate native scrolling pixels.

`/tmp/telar-perf-scroll-row-reuse-pairs-01` completes six alternating pairs with
100 measured inputs and20 warmups, the ordinary scroll probe, Metal/VSync and the
same82x21 terminal in a1600x1000 drawable. A GUI is `bc55d0e8`, B2 is `db0d82f8`;
both use runtime `1f1849d1`, helper `87beebb0` and the same loaded Qt receipt
(QtGui `abd4bdf7`). All26 host boundaries qualify, maximum load1 4.09814, and all12
native/resource/owned-shutdown checks pass. No builds or profiles overlap timing.

| Discrete upward scroll | Accepted A median | Candidate B2 median | B2 lower |
| --- | ---: | ---: | ---: |
| p50 ms | 29.98598 | 30.19647 | 3/6 |
| p95 ms | 37.69570 | 38.11767 | 2/6 |
| p99 ms | 42.79601 | 41.80585 | 3/6 |
| maximum ms | 44.18100 | 44.99523 | 4/6 |
| GUI CPU ms/input | 4.699145 | 4.607935 | 3/6 |
| GUI peak RSS MiB | 191.6875 | 198.1016 | 2/6 |
| Runtime CPU ms/run | 81.48163 | 83.18367 | 1/6 |

Both target primaries fail the predeclared minimum5/6. No regression-control or
independent-Zig timing is used to rescue this variant. Runtime CPU brackets setup,
warmup, measured input and GUI exit; it is not per-input CPU and must not be summed
with the differently scoped GUI interval. Increased process RSS cannot be assigned
entirely to the measured cell capacity.

Actual TUs compile for ARM64, x86-64 baseline and x86-64-v3. Const cell iteration
removes copy-on-write growth call sites from the comparison on all three targets;
mutable iteration need not have allocated when uniquely owned. Mach-O disassembly
of the linked B2 reuse/comparison confirms style comparison, memcmp and matrix
updates, with no cell-list growth call. Cross codegen is not x86/Linux execution.
Four separate ten-second GUI/runtime profiles in
`/tmp/telar-perf-scroll-row-reuse-profile-01` complete with qualified host boundaries
and cleanup. They show less row synchronization work while Qt rendering remains
visible; sparse inclusive samples do not establish CPU proportions or explain the
failed paired target. The cause of the inconsistent whole-application gain remains
unestablished.

The restored GUI hashes exactly to accepted `bc55d0e8`; the four pending runtime
files remain byte-identical. The displaced-row implementation and all raw evidence
remain private for future investigation. All complete F01-F16 and native120
acceptance stays open; saving row reconstruction did not meet this experiment's
whole-application criterion.


### Runtime scroll projection overlap: four rejected component variants

At `7490b13d2`, `out-perf/dlls-runtime-scroll-projection-01` investigates work
before GUI rendering: `Terminal::refresh` reprojects every row for a forced
attachment viewport. Delivery subsequently returns Ghostty to the live bottom
without refreshing, so `dirty_` alone does not identify the last projected viewport.
The candidate moves overlapping ScreenCell rows and converts only newly exposed
rows. Row revisions, flags, metadata capture, cursor/modes and wire preparation
retain their original behavior. All production changes stay in private Clang VFS
overlays; the checked-out Terminal implementation is unchanged.

The initial proof uses content revision plus color invalidation. Exposing a mutable
Ghostty handle permanently disables reuse, including mutation through a retained
handle after later refreshes. Reuse is also refused for changed total row counts
or displacements beyond the grid. Failed refreshes invalidate the proof before
partially mutating cached cells. V1 checks the reusable interval in the ordinary
row loop; v2 separates specialized loops; v3 branches to a separate scroll-only
refresh while preserving the original ordinary loop; v4 replaces the saved
revision with an explicitly invalidated flag beside existing flags. V4 invalidates
before feed, pending-control resume, resize and color configuration. None is adopted.

The reusable `scroll_projection_probe.cpp` populates 4,096 rows in an 82x21 grid.
Its verifier emits full wire snapshots, raw cells, row revisions and incremental
frames, validating decoded frames before acknowledgment. Reference and all four
variants match all 1,144 records and 17,243,839 bytes exactly, SHA256
`1c97691c376ef90c89d74d3d53024bebccd5444c76ada5982640292267106ed1`.
Coverage includes bidirectional/repeated/large-jump scroll, styles, combining/wide
text, links, configured and OSC colors, resize, new output, alternate screen,
scrollback clearing and reset through a retained handle. The public builder's
reference and overlay builds reproduce the same complete stream.

Separate v1/v4 source counters report 21,000 row conversions for 1,000 reference
inputs versus 2,991 for stationary ASCII or links. New output, resize, exposed handle
and live-output controls retain 21,000 conversions. Counts exclude 100 warmups; their
instrumented elapsed values are not used for acceptance. The algorithm adds an
in-place memmove of the overlapping cells rather than a separate cell cache.
For a three-row movement, 18x82x32=47,232 bytes are moved. V4 and the reference both
have `sizeof(Terminal<SystemAllocator>)=49,144` on ARM64.

Four independent series, `/tmp/telar-perf-runtime-scroll-projection-pairs-01` through
`-04`, each complete seven alternating pairs across six cases, 84 runs and 170 host
boundaries. All host checks qualify, with maximum load1 per series listed below.
No builds, sanitizers or profiles overlap timing. Each run uses 100 warmups and
100,000 measured operations, except resize with 2,000. The interval includes refresh
and incremental frame preparation/ack; corpus construction, verification decoding
and binary output are excluded. Returned observed frame totals match in every pair.

| Variant | ASCII wins | Links wins | Output wins | Resize wins | Exposed wins | Live wins | Maximum load1 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| v1 | 7/7 | 7/7 | 0/7 | 5/7 | 1/7 | 0/7 | 2.66846 |
| v2 | 7/7 | 7/7 | 0/7 | 1/7 | 0/7 | 0/7 | 2.11084 |
| v3 | 7/7 | 7/7 | 0/7 | 5/7 | 5/7 | 0/7 | 2.29883 |
| v4 | 7/7 | 7/7 | 3/7 | 3/7 | 2/7 | 1/7 | 1.85156 |

The last variant's medians are:

| Component ns/operation | Reference | v4 | v4 lower |
| --- | ---: | ---: | ---: |
| ascii | 7724.118 | 5000.516 | 7/7 |
| links | 14187.165 | 11065.344 | 7/7 |
| output | 7194.493 | 7205.331 | 3/7 |
| resize | 246500.729 | 246383.166 | 3/7 |
| exposed | 7734.775 | 7741.500 | 2/7 |
| live | 7012.748 | 7066.754 | 1/7 |

Each variant wins both targets 7/7, but at least one control loses consistently
(0-1 wins). V4's smaller live-output difference still fails the unchanged rule.
These component gains cannot justify a production change, a native latency claim
or skipping controls. There is no native accepted-runtime or independent-Zig timing
for these rejected variants. The cause of the remaining control losses is not
established; source changes, extra state maintenance and code placement have not
been separately attributed.

V2, v3 and v4 pass the complete stream under ASan/UBSan with the probe TU and its
Terminal/frame templates instrumented. Runtime-core, Ghostty and system libraries
remain uninstrumented; this is scoped coverage. Container checks stay enabled,
leak detection is disabled and UBSan halts on error. Existing `testTerminal` cases
pass against v2 and v4. Actual refresh kernels for v2-v4 compile at the configured
Release flags for ARM64, x86-64 baseline and x86-64-v3. The assembly confirms
separate reusable/ordinary loops in v2, an early fast-path call in v3/v4 and memmove
for overlap. These are codegen checks, not x86/Linux native execution.

`tools/build_runtime_scroll_probe.py` compiles the reusable fixture from an existing
Ninja compile database and links its existing libraries without rebuilding the
runtime. It records commands, source/header/overlay inputs and library hashes,
rejects existing destinations and supports private overlays. The four pre-existing
pending runtime files remain byte-identical; no candidate header is installed.
The final public reference/overlay helpers reproduce the complete stream and all
six observed frame totals; timing continues to refer to the frozen private builds,
not these subsequently cleaned-up CLI builds. An optional broad clang-tidy audit
reports diagnostics in unchanged runtime headers and the test fixture; the normal
runtime lint target excludes tests. No whole-TU lint-clean claim is made.
All complete F01-F16/native120 requirements remain open. A next distinct lead is
encoding content-versus-viewport dirtiness in the existing dirty state, avoiding
separate validity updates; it needs its own oracle and measurements before use.

### Dirty-state viewport projection — 2026-11-05

A successor to the four rejected overlap variants replaces the existing dirty bool
with clean/content/viewport states. Pending content invalidation survives successive
viewport changes. Content-mutating operations invalidate before mutation; an exposed
Ghostty handle permanently disables reuse. The viewport path updates Ghostty state,
reuses overlapping cells with memmove, converts only entering rows and preserves row
revisions, metadata and frame bytes. There is no separate cell cache or validity stamp;
ARM64 `sizeof(Terminal<SystemAllocator>)` stays 49,144. The experiment is isolated in
`out-perf/dlls-runtime-scroll-state-01`; production sources are not changed by it.

The reusable scroll oracle now exercises clean refresh idempotence, pending content
across several viewport changes, partial/completed control input and color invalidation
across viewport changes. Reference and candidate produce the same 1,176 records and
17,725,074 bytes, SHA-256
`38dbabbf71791d93c960bdddda26e8bb3db8a76bac1d013b8f4416f9a147baa8`.
The expanded stream passes scoped ASan/UBSan with the probe TU and instantiated
Terminal/frame code instrumented; reused libraries remain uninstrumented. Existing
Terminal tests pass. Actual refresh kernels compile for ARM64, x86-64 and x86-64-v3;
linked ARM64 disassembly confirms overlap memmove. These are codegen checks, not
x86/Linux execution.

Seven alternating component pairs per case complete 84 runs and 170 qualified host
boundaries in `/tmp/telar-perf-runtime-scroll-state-pairs-01`. Both targets win 7/7;
none of the four controls has a consistent loss. Controls with mixed wins are not
claimed as improvements. Source counters are separate from ordinary timing.

| Component ns/operation | Reference | Candidate | Candidate lower |
| --- | ---: | ---: | ---: |
| ASCII | 7786.840 | 4995.438 | 7/7 |
| Links | 14212.488 | 11093.719 | 7/7 |
| Output | 7267.343 | 7261.710 | 3/7 |
| Resize | 247153.459 | 246605.167 | 5/7 |
| Exposed handle | 7784.423 | 7785.768 | 4/7 |
| Live output | 7119.458 | 7124.134 | 4/7 |

Native reference `1f1849d1881f…` is byte-exact to the accepted runtime. Candidate
`eb7778965dd6…` uses the same GUI `bc55d0e84d76…`, helper and Qt frameworks. Private
main-TU overlays include accepted HEAD delivery/client/history definitions, excluding
the pre-existing pending pacing edits. Runtime-core dependency receipts show that no
reused object includes the modified Terminal header. Full final-window readback is
pixel-exact between A/B and the prior packet-validated capture (PNG SHA-256
`ec87ced6f6c97b8de5057ed62eefa1b98970cc34c066c40db8381bd85e1f164d`).
This qualifies the final drawable, not every intermediate pixel or native120 cadence.

A separate diagnostic runtime `c96a0b09dca4…` records successful reuse with PID,
mach time, offset, row count and terminal purpose. The first attempted census is
invalid: the ordinary harness correctly filters inherited TELAR_ variables. A private
harness explicitly delivers the trace path per run. The repeated census in
`/tmp/telar-perf-runtime-scroll-state-census-02` qualifies host, packet, presentation,
Qt, resource and cleanup checks; uninstrumented B writes no trace as a negative control.

The initial expectation of one projection per input is false. Within the 100 measured
input-to-presentation windows, there are 100 three-row movements and 104 same-position
refreshes. PID/time/packet joins require exactly one movement per input and only the
previous position before it or the expected position afterwards. The successful paths
reuse 3,984 rows and convert 300. This is an instrumented candidate work census, not
a measured reference work delta; its timings are excluded. Repeated preparation of an
unchanged viewport is a distinct lead for reducing work further.

Six alternating native pairs complete in
`/tmp/telar-perf-runtime-scroll-state-native-pairs-01`, with 100 measured inputs and
20 warmups per run, 26 qualified host boundaries and maximum load1 4.90723. No
builds, tests or profiles overlap timing. Native packet/presentation, geometry, Qt,
resource and owned-process cleanup checks pass. The predeclared primary gate requires
both p95 and runtime CPU/run to improve in at least 5/6 pairs.

| Native metric | Reference | Candidate | Candidate lower |
| --- | ---: | ---: | ---: |
| Input-to-present p50 ms | 31.17794 | 31.61602 | 0/6 |
| Input-to-present p95 ms | 37.93948 | 40.33196 | 2/6 |
| Input-to-present p99 ms | 44.47142 | 42.53031 | 4/6 |
| Input-to-present maximum ms | 48.64990 | 46.86290 | 5/6 |
| GUI CPU ms/input | 4.85024 | 5.05419 | 2/6 |
| GUI peak RSS MiB | 191.38281 | 191.44531 | 3/6 |
| Runtime CPU ms/run | 82.50671 | 80.53177 | 4/6 |
| Runtime instructions/run | 414017269.50000 | 384012150.50000 | 6/6 |

Runtime counters cover GUI setup, warmup, measured inputs and GUI exit, excluding
runtime startup/shutdown and child CPU. They are not per-input runtime counters.
The candidate reduces runtime instructions in 6/6 pairs, but p95 wins only 2/6 and
runtime CPU 4/6. P50 loses consistently (0/6). It therefore fails the primary gate
and is rejected; no independent-Zig promotion or broad regression suite is justified.
The cause of the native latency differences is not established. Reduced projection
work is real, but does not demonstrate improved whole-application responsiveness.
No production Terminal change is installed; the four pre-existing pending runtime
files remain byte-identical. Only the expanded reusable oracle and this report are
retained in Git. All complete F01-F16/native120 acceptance remains open.

A further source lead is `Runtime::handle(SetPaneViewport)`, which requests a full
snapshot for every viewport change, while attachment delivery restores the live
bottom after preparing a historical frame. Avoiding redundant projection/preparation
or using an acknowledged delta could save more work. This is unproven and requires
multi-client, outstanding-ack, viewport-return and output-during-scroll equivalence
before any timing or adoption; it is not a reason to accept the rejected overlap path.

### Viewport requests with acknowledged deltas — 2026-11-05

At `2be534899`, a separate experiment targets complete snapshots requested by every
`SetPaneViewport`. It does not include the rejected Terminal overlap path or pending
pacing edits. A private FrameSync viewport-pending flag triggers immediate delivery
without invalidating the acknowledged cell baseline. Explicit recovery requests,
initial frames, changed dimensions and oversized-delta fallback still send snapshots.
Pending viewport requests survive blocked/wrong ACKs; an unchanged viewport still
receives a frame. Attachment delivery preserves the former snapshot request's pacing
priority. ARM64 FrameSync size stays 408 bytes, with no new buffers.

`out-perf/dlls-viewport-delta-01` holds the overlays, source receipts and frozen builds.
The new viewport oracle applies actual wire frames through the GUI's Screen type and
compares canonical reconstructed cells, row flags, headers, link runs and URIs after
each publish. Raw delta wire bytes are intentionally not required to equal a full
snapshot; full reference snapshots and runtime cells/revisions are also emitted.
The expanded 35,313,351-byte stream is identical between A3 and B3, SHA-256
`26ea0604a61e0b6cba1d9651cc024e34ee395f061ae53883d2448e03d6ac28db`.
It covers ASCII, styled Unicode/links, opposite and repeated scroll, output while
awaiting ACK, multiple pending viewport requests, wrong/stale ACKs, explicit recovery,
resize with an outstanding frame, colors, partial controls and retained raw handles.

Within that verification workload, ASCII wire payload falls from 541,956 to 108,780
bytes and encoded cells from 262,402 to 23,910; rich text falls from 706,958 to 221,248
bytes and cells from 262,402 to 17,544. Snapshots fall from 153 to 6 in each case.
These totals describe the verification fixture, not native input windows. A separate
real AttachmentDelivery/socket-pair oracle serves two clients at different historical
positions, including pending credit, new output, explicit recovery, a live return and
pacing priority. Both variants deliver 71 frames; snapshots fall from 70 to 3. The
candidate also passes existing FrameSync and client-delivery tests.

Scoped ASan/UBSan reproduces the complete canonical stream. Probe/template code and
the GUI Screen are instrumented; reused runtime-core, Ghostty and system libraries
are not. Leak detection is disabled and UBSan halts. Actual prepare kernels compile
for ARM64, x86-64 and x86-64-v3. ARM64 assembly and the linked runtime show the
separate pending-viewport byte, preserved outstanding-ACK early return and ordinary
acknowledged-damage path. Cross codegen is not execution on x86/Linux.

Seven alternating pairs per component case complete 84 runs and 170 qualified host
boundaries in `/tmp/telar-perf-viewport-delta-pairs-01`, maximum load1 3.41455. No
builds/tests/profiles overlap timing. Each operation includes refresh, viewport-request
preparation and acknowledgment; construction and GUI frame application are outside the
measured loop. Repeated byte totals are deterministic; smaller encoded payloads are
expected and independently qualified by the decoded-state oracle.

| Component ns/operation | Full-snapshot reference | Viewport delta | Delta lower |
| --- | ---: | ---: | ---: |
| ASCII | 13812.165 | 7797.665 | 7/7 |
| Links | 20810.988 | 14399.568 | 7/7 |
| Output during scroll | 14058.677 | 7276.007 | 7/7 |
| Resize | 247357.792 | 245885.750 | 5/7 |
| Exposed handle | 13799.828 | 7817.490 | 7/7 |
| Live output | 7183.162 | 7163.018 | 5/7 |

Native A is the frozen accepted runtime `1f1849d1881f…`; B is `e9b83f9b08f1…`.
Both use GUI `bc55d0e84d76…`, the same helper and Qt frameworks. Only the main TU
requires recompilation: saved runtime-core dependencies include none of the three
candidate headers. Final drawable readback in `/tmp/telar-perf-viewport-delta-body-01`
is byte-exact between A/B and the prior packet-validated PNG, SHA-256
`ec87ced6f6c97b8de5057ed62eefa1b98970cc34c066c40db8381bd85e1f164d`.
This is a final-image check, not a continuous-cadence claim; its timings are excluded.

Six alternating native pairs in `/tmp/telar-perf-viewport-delta-native-pairs-01`
complete 100 measured inputs plus 20 warmups per run. All packet/presentation,
geometry, Qt, runtime-resource and cleanup checks pass; 26 host boundaries qualify,
maximum load1 4.03760. Builds, tests and profiles do not overlap this series.

| Native metric | Accepted C++ | Viewport delta | Delta lower |
| --- | ---: | ---: | ---: |
| Input-to-present p50 ms | 30.90023 | 32.25276 | 2/6 |
| Input-to-present p95 ms | 41.43966 | 39.14854 | 6/6 |
| Input-to-present p99 ms | 45.60351 | 43.58869 | 4/6 |
| Input-to-present maximum ms | 48.27817 | 46.97731 | 3/6 |
| GUI CPU ms/input | 4.86735 | 5.02749 | 3/6 |
| GUI peak RSS MiB | 191.55469 | 198.18750 | 2/6 |
| Runtime CPU ms/run | 82.28087 | 79.79671 | 5/6 |
| Runtime instructions/run | 412289394.00000 | 398210176.50000 | 6/6 |

The predeclared p95 and runtime-CPU gates pass (6/6 and 5/6). P50 and GUI CPU
have worse medians with mixed wins, so they are not claimed as improvements. GUI
peak RSS also rises by median. Runtime CPU/instructions bracket GUI startup,
warmup, measurement and GUI exit; they are not per-input CPU counters. This first
native gate permits further qualification, not adoption or complete F06 acceptance.
The public oracles in `74a672281` rebuild through the reusable builder and reproduce
the frozen canonical stream and both delivery counts; component timings refer to
the earlier frozen A3/B3 probes. Final TUI/single/splits/tabs diagnostic captures in
`/tmp/telar-perf-viewport-delta-control-pixels-02` match A/B and prior reference PNGs
byte-for-byte, with eight runs and qualified host boundaries. Attempt `-01` failed
before launching a workload due to a stale controller filename in its input receipt;
no measurement from it is used.

The broader accepted-runtime regression series
`/tmp/telar-perf-viewport-delta-controls-01` completes six alternating pairs for each
of TUI, single, splits and tabs: 48 runs, 98 qualified host boundaries, maximum load1
4.60938. All workload/native/Qt/resource and owned-cleanup checks pass. Each run has
100 measured inputs and 20 warmups. No builds, tests or profiles overlap timing.

| Control | p95 ms, A → B | B lower | GUI CPU ms/input, A → B | B lower | Runtime CPU ms/run, A → B | B lower |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| tui | 37.32038 → 39.20412 | 1/6 | 5.18507 → 5.14295 | 4/6 | 101.38283 → 103.28871 | 2/6 |
| single | 32.98042 → 31.14206 | 6/6 | 3.90169 → 3.82429 | 3/6 | 86.58279 → 85.21794 | 2/6 |
| splits | 32.92222 → 33.20230 | 1/6 | 4.19602 → 4.20122 | 3/6 | 102.46627 → 107.02273 | 2/6 |
| tabs | 33.00271 → 33.02919 | 2/6 | 3.96407 → 3.81998 | 4/6 | 100.77935 → 98.92423 | 5/6 |

TUI p99 rises from 41.60674 to 46.82503 ms and maximum from 45.97817 to
50.03500 ms, each only 1/6 lower. Splits p50 rises from 25.06810 to 25.78181 ms
and p99 from 35.65148 to 38.56552 ms, each 1/6 lower. TUI and splits therefore
regress consistently under the unchanged rule. **The candidate is rejected**, despite
passing its target scroll gate. The cause of these control losses is not established;
the extra state checks, code placement and scheduling effects have not been separately
attributed. There is no promotion to live-tab or independent-Zig timing and no claim
that the candidate improves the complete F06 flow or native120 cadence.

Source inspection also confirms that the Zig client's viewport commit preserves its
applied frame ID and its admission path accepts matching-base deltas, with explicit
snapshot recovery for mismatches. This is not a mixed-stack execution qualification.
A portable FrameSync test was prepared for Rosetta but not built/run after the native
control rejection; no x86 execution claim is made. All candidate production changes
remain in ignored overlays. The four pending runtime files remain byte-identical.
The reusable decoded-state/delivery oracles and builder extension are committed in
`74a672281`; they remain useful despite rejection. A possible follow-up is encoding
pending snapshot/viewport state in one discriminator, to avoid a second flag check
in ordinary frame preparation. That is a new hypothesis, not an established cause
or permission to overlook the observed regressions.

## 2026-11-05: compact viewport state rejected; native work savings confirmed

`out-perf/dlls-viewport-state-01` replaces the previous candidate's two flags with
one `Pending` discriminator (`none`, `snapshot`, `viewport`). Snapshot recovery has
priority over later viewport requests; delivery retains the old immediate-update
policy. The ARM64 FrameSync object remains 408 bytes. All variants are private
VFS overlays over accepted headers, excluding the four unrelated pending pacing
files. No candidate production change is adopted.

The decoded-state oracle is extended in `1054b684d` to issue another viewport
request after explicit snapshot recovery, including while an acknowledgment is
outstanding. A negative implementation that overwrites snapshot priority fails the
intended snapshot-count assertion. Both enum variants preserve the 35,313,351-byte
canonical stream, SHA256 `26ea0604a61e0b6cba1d9651cc024e34ee395f061ae53883d2448e03d6ac28db`.
The real two-client delivery oracle and existing FrameSync/delivery tests pass.
Scoped ASan/UBSan checks pass on the probe and instantiated runtime/GUI templates;
reused libraries are uninstrumented and leak detection is disabled. A separate
portable fixture executes existing FrameSync tests and 120 decoded GUI frames on
ARM64 and under Rosetta for x86-64 and x86-64-v3. This does not qualify Linux or
native x86 GUI performance. All three target lowerings are inspected.

The first component attempt is deferred before any workload: load1 is 7.24902.
No partial result is retained as timing evidence. The fresh seven-pair series
`/tmp/telar-perf-viewport-state-pairs-02` completes 84 runs with 170 qualified host
boundaries, maximum load1 4.15820. The early pending-state guard wins all seven
ASCII, links, output-during-scroll and exposed-handle pairs, but loses all seven
resize pairs (244419.854 → 246935.146 ns/operation). **Reject this variant.**
The resize regression's cause is not established.

A separate late-guard variant checks the pending discriminator only after finding
empty damage, unchanged metadata and an equal header. Actual ARM64 linked code
confirms that ordinary modified frames bypass that additional load/check. The
seven-pair series `viewport-state-pairs-03` completes 84 runs and 170 qualified
boundaries, maximum load1 2.20996. No own builds/tests/profiles overlap either series.

| Component ns/operation | Accepted algorithm | Late guard | Candidate lower |
| --- | ---: | ---: | ---: |
| ASCII | 13796.784 | 7759.860 | 7/7 |
| Links | 20748.967 | 14411.757 | 7/7 |
| Output during scroll | 14064.221 | 7292.182 | 7/7 |
| Resize | 246166.313 | 247764.542 | 2/7 |
| Exposed handle | 13793.386 | 7783.731 | 7/7 |
| Live output | 7150.838 | 7162.816 | 3/7 |

The predeclared component rule passes: at least six target wins, no control with
zero or one win. Resize/live medians are worse and are not claimed as improvements.
Native B is this late-guard implementation, SHA256 `502ecb20d838…`; A remains
`1f1849d1881f…`, with identical GUI `bc55d0e84d76…`, helper and pinned Qt.
Final drawable pixels match both A/B and the earlier reference PNG exactly
(`ec87ced6f6c9…`). The capture is diagnostic, not timing or continuous-motion evidence.

`/tmp/telar-perf-viewport-state-native-pairs-01` completes six alternating pairs,
100 measured inputs plus 20 warmups each, and 26 qualified host boundaries,
maximum load1 2.38135. Native packets, geometry, Qt identity, runtime resources and
owned cleanup pass. No builds/tests/profiles overlap ordinary timing.

| Native metric | Accepted C++ | Late guard | Candidate lower |
| --- | ---: | ---: | ---: |
| Input-to-present p50 ms | 30.50110 | 31.34176 | 1/6 |
| Input-to-present p95 ms | 38.61426 | 39.19399 | 2/6 |
| Input-to-present p99 ms | 45.47522 | 42.18634 | 4/6 |
| Input-to-present maximum ms | 45.72871 | 44.41252 | 3/6 |
| GUI CPU ms/input | 4.90073 | 5.16635 | 2/6 |
| GUI peak RSS MiB | 200.85156 | 198.25000 | 4/6 |
| Runtime CPU ms/run | 81.23002 | 83.49288 | 3/6 |
| Runtime instructions/run | 410592737.5 | 397976601.5 | 6/6 |
| Runtime cycles/run | 175051826 | 173851016 | 5/6 |

**Reject the late-guard variant.** Both primary gates miss five wins, and p50
regresses consistently. The private summary initially omitted p50 from its control
predicate; it now includes every latency percentile, preserving all raw results
and the already failed primary decision. No broad controls or independent-Zig
promotion follows. Runtime counters cover setup, warmup, inputs and GUI exit,
not just input processing; CPU and cycles are not interchangeable acceptance metrics.

A separately instrumented native census in `viewport-state-census-01` records ten
uint64 fields at successful frame preparation: mach ticks, runtime/pane/frame/base
IDs, scroll offset, payload bytes, encoded cells and grid. Actual timebase conversion
maps records into each input-to-positive-presentation interval. Every measured
input has exactly one frame with the expected row, runtime identity and 82×21 grid.
Across 100 inputs, A prepares 100 snapshots, 172,200 cells and 479,692 payload bytes;
B prepares 100 acknowledged deltas, 26,561 cells and 146,618 payload bytes. These
are prepared payload bytes, not socket/syscall totals. The uninstrumented candidate
receives the same trace environment but creates no trace file, as required by the
negative control. All three native sequences/resources/cleanup and matching geometry
pass; eight host boundaries qualify, maximum load1 2.17871. All census timings are
excluded. The work savings are real, but do not override native rejection.

Descriptive decomposition of the ordinary series finds input-to-GPU-callback p50
9.18822 → 9.54460 ms (3/6), command-buffer interval p50 0.23196 → 0.23458 ms
(2/6), and signed presentation-minus-callback p50 21.74869 → 21.75435 ms (4/6).
The callback clock is not hardware GPU completion; the command buffer includes
observer readback. The residual does not establish a queue depth, refresh count
or causal buffering delay. Prior drawable-pool and display-link diagnostics above
already investigated related hypotheses. Qt currently uses two frame slots while
the observed drawable pool has three; these are distinct mechanisms. No new Qt
buffering change is justified by this decomposition. The next coverage gap is
continuous native scroll: the current discrete input oracle cannot certify 120 Hz
motion, reverse scrolling, selection or return to live output. All F01–F16 gates
remain open and the persistent goal stays active.

## 2026-11-05: continuous scroll exposes repeated viewport targets

`out-perf/dlls-scroll-cadence-01` adds a private continuous-scroll diagnostic on the
accepted complete stacks, following the discrete F06 probe. It first verifies 21
serial upward responses (20 warmups, one additional readiness response), then
injects 900 native discrete AppKit wheel events at a declared 120 Hz. Every event
moves three rows in the stationary 4,096-row corpus. The six-second observation
window follows one second of continuous warmup; input continues for another half
second, and completion requires the exact final row on a positive presentation.
The origin after serial input is row 4,013 and the final target is row 1,313.

The probe retains absolute scheduled/dispatch/return times, GPU callback and native
presentation times, decoded top-row packets and a separate Core Video reference.
It records all observed continuous frames, including invalid/zero/missing
presentation observations, before selecting the declared window. Content must map
to an already dispatched input without backward row progress. Half-second input
counts must meet the unchanged 5% offered-rate gate; the display reference keeps
its 5% stability and 0.25 ms native-interval residual tolerances. Geometry, display,
foreground, VSync, corpus owner and final-row checks remain mandatory. A synthetic
positive and 14 negative mutations pass the private validator. This is direct
synthetic discrete wheel delivery, not a physical trackpad, momentum, reverse,
selection or return-to-live workload. There is no paired acceptance timing.

`/tmp/telar-perf-scroll-cadence-qual-01` fails on accepted C++ after all 900 events:
the last observed row is 1,316 rather than 1,313. All 21 serial inputs pass. The
final-row watchdog correctly rejects the run after two seconds. Three recorded
host boundaries pass, maximum load1 1.41113, but the aborted controller leaves the
series pending/ineligible. Owned runtime/children/socket cleanup completes.
The first observer boxes a compound verification expression as JSON integer 1;
version 2 explicitly boxes BOOL. That reporting fix does not alter wheel dispatch
or the native final-row watchdog and cannot explain the missing three rows.

Version 2's independent Zig diagnostic, `scroll-cadence-qual-02`, reaches the exact
final row. All 12 offered-rate bins contain 60 inputs. Its six-second window has
720 observed frames, 714 changed rows and 119 changes per observation second.
The independent reference qualifies at 120.00060 Hz; six intervals span two
refreshes, with a longest changed-content gap of 16.66658 ms. Four host boundaries
qualify, maximum load1 1.63770. This is one diagnostic, not a paired Zig/C++ result
or complete native120 acceptance. Repeating accepted C++ with the corrected
observer in `scroll-cadence-qual-03` again ends at row 1,316 and fails the final-row
watchdog. Its three host boundaries pass, maximum load1 1.69385; the incomplete
series is ineligible. All serial/geometry/owner and cleanup checks pass.

A deterministic Session reproduction uses the actual current client headers,
codec and frame application: start at offset 100, issue two +3-row scroll actions,
and observe requests 97 then 94. Deliver a delayed frame for the first request
(offset 97), then issue the third action. The client requests 94 again instead of
91. `Screen::apply` adopts the incoming frame's scroll offset, while `Session::scroll`
uses that same field as its next input base. This demonstrates lost accumulated
input under a valid ordering, independently of Qt, Metal or host scheduling.
The initial private probe compile needed a missing namespace qualification; the
corrected ARM64 build/run succeeds and retains its commands and JSON result.
No production source is changed by this reproduction.

A separate runtime census instruments accepted frame preparation and every received
SetPaneViewport, retaining mach-clock ticks and runtime/client/pane identities.
Only the main runtime TU is rebuilt, using the accepted clean delivery/client
headers and corrected listener object. Its runtime SHA256 is `cdc016de4463…`;
GUI `bc55d0e84d76…`, helper and Qt remain unchanged. Instrumentation is private and
all of its times are excluded. `scroll-cadence-census-01` receives exactly 921
viewport requests: 21 serial and 900 continuous, exactly one in each continuous
input interval. Every record identifies the owned runtime/client/pane. Continuous
inputs 7 and 17 repeat their predecessor's requested offsets, 3,994 and 3,967,
instead of advancing another three rows. All other adjacent requests advance by
three. The last requested offset is 1,318 and visible row 1,319; the expected final
row is 1,313. The final-row watchdog rejects the sequence. Three recorded host
boundaries pass, maximum load1 2.58789; cleanup completes. Frame preparation records
are retained alongside requests, but do not timestamp client frame application.
This directly locates duplicated targets upstream of runtime viewport handling;
the deterministic Session test establishes a matching client-side loss mechanism.
It does not prove an exact client callback ordering from runtime timestamps alone.

`scroll-cadence-trace-control-01` forwards the same trace environment to the
uninstrumented accepted runtime. Neither trace file is created. This run happens
to reach the correct final row and observes 720 changed rows over six seconds,
with 719 one-refresh intervals and no missing opportunity between those changes.
Its reference qualifies at 120.00060 Hz, longest gap 8.34158 ms, and all offered-rate
bins contain 60 inputs. Four host boundaries qualify, maximum load1 2.26318.
This positive control is retained alongside all failures: the defect is ordering
sensitive, not evidence of a fixed 60 Hz ceiling. Selecting this run as a C++ win
would be invalid. All five diagnostics preserve exact serial input/corpus identity,
1600×1000 scale-2 geometry, 82×21 fixture size and owned cleanup; loaded C++ Qt
identities are verified, including failed sequences.

The next implementation target is separating pending scroll intent from the
viewport described by an arriving frame, with a bounded delivery/coalescing policy.
An offset-only acknowledgment is ambiguous when direction reverses or unrelated
frames arrive, so a simple "clear pending when offsets match" flag is not yet a
proven solution. A correction needs an asynchronous reference model covering
multiple inputs before replies, reversed directions, coalesced responses,
output/scrollback eviction, resize, copy-mode ownership, keyboard return to live,
transport failure and detach/reconnect. Only then should native scroll and the
broader latency/CPU controls qualify it. The four unrelated pacing files remain
unchanged, no candidate is adopted, and all complete-flow gates remain open.

## 2026-11-05: retained per-attachment scroll intent candidate

`out-perf/dlls-scroll-intent-01` investigates the repeated SetPaneViewport targets
exposed by continuous native scroll. The runtime retains the raw absolute request
in each attachment; each delivery clamps that request against current terminal
bounds without overwriting the attachment's request. Detach destroys that state.
A private real-Ghostty probe passes 49 checks across seven requested offsets,
resize/restore, alternate-screen entry/exit, output growth and history clearing.
This supports retaining one optional requested offset in the GUI pane, resetting
it on a new attachment/disconnect and clamping it only when deriving a new input.
It does not require an offset-based acknowledgment or an additional IPC message.

The bounded FIFO/ACK/resize model rejects clearing pending input merely because an
incoming offset matches the latest target: a matching older frame can precede a
resized intermediate frame. Three input events suffice for a counterexample.
Persistent intent and a serial single-inflight alternative pass this scoped model;
serializing input is unnecessary for the existing runtime contract. This is not a
proof of every output, eviction, selection or multi-client interleaving.

Candidate B separates the incoming Screen metadata from the retained requested
offset. Wheel/key scroll routing and keyboard return to live use the latter;
successful sends update it, failed sends do not. Copy viewport requests use the
same state. B passes the initial eight real Session cases but an expanded copy-exit
case rejects it: an older frame can already show the entry offset, causing the
copy planner to omit the restoration although a newer target is still requested.
Candidate C synthesizes missing viewport messages for copy navigation generally;
a horizontal-motion negative control rejects this because it replaces a pending
vertical target with a stale frame's offset. Neither B nor C is adopted.

Candidate D limits that additional restoration to leaving keyboard copy mode.
The nine-case real Session oracle covers delayed and reversed inputs, ambiguous
matching/resize frames, pre-request frames, bounds and temporary clamp/restore,
integer extremes, failed transport, keyboard return, copy exit, horizontal copy
motion and attachment/disconnect reset. It passes ARM64, x86-64 and x86-64-v3
(Rosetta), plus scoped ARM64 ASan/UBSan. The sanitizer scope is the test TU and
AwakeClock, not the system libraries or the entire native application. These runs
do not establish Linux or emulated-platform performance.

The existing Session test's alternate-scroll fixture initially fails B because
it injects offsets unrelated to its last request. A private copy adds explicit
scroll setup before three such responses, retaining all existing assertions;
both accepted A and D pass this request-consistent fixture. This adjustment is
recorded, not treated as an unmodified-suite pass. Broader pre-existing copy-frame
reconciliation heuristics remain outside this correction.

The private full-GUI build recompiles all 48 production objects dependent on the
changed pane layout/session headers, replaces the corresponding members in a
private archive and relinks against unchanged Qt and other libraries. Its relink
control differs from accepted A in 47 bytes, all within LC_UUID/ad-hoc signature;
all file-backed code/data sections match. D GUI SHA256 is `f49f721f25f8…`, paired
with unchanged accepted runtime `1f1849d1881f…` and helper `87beebb065f0…`.
No pending runtime pacing changes enter these executables. Production GUI source
remains unchanged during qualification.

Actual Pane<SystemAllocator> grows from 576 to 584 bytes, alignment 8, on all three
macOS targets. The getter lowers to scalar loads, saturation and conditional
selects on ARM64 and x86-64; it has no allocation or function call. The existing
per-input send remains; no per-event allocation is introduced by the retained
field. The first isolated layout compile lacked the SystemAllocator namespace;
the corrected build and assembly listings are retained separately.

`/tmp/telar-perf-scroll-intent-D-six-01` completes all six fresh native sequences:
21 serial inputs then 900 continuous inputs, each ending at the exact expected
row 1,313. All content, offered-rate, positive-presentation, native geometry,
foreground, Qt and independent active-display reference checks pass. Every
half-second offered-rate bin has 60 inputs. The six windows contain 713, 718, 717,
713, 718 and 718 changed frames, or 118.8333–119.6667 changes per observation
second; missed refresh opportunities are 7, 2, 3, 7, 2 and 2. The reference is
120.00060 Hz. Fourteen host boundaries qualify, maximum load1 2.31299; every owned
runtime/child/socket cleanup completes. This qualifies the exercised content and
cadence observations, not a paired speedup or complete F06/native120 acceptance.

A separate D GUI/instrumented accepted-runtime census,
`/tmp/telar-perf-scroll-intent-D-census-01`, receives exactly 921 requests, all
advancing three rows with no repeated target. Each of the 900 continuous input
intervals contains exactly one request for the owned client/pane/runtime; the last
requested offset is 1,312 and the visible final row 1,313. Four host boundaries
qualify, maximum load1 1.74854, and cleanup completes. Its independent display
reference changes cadence/phase or misses coverage, so it is explicitly ineligible
for cadence/performance use. Message-count evidence is retained; instrumentation
times are excluded. The prior uninstrumented negative trace control remains part
of the instrumentation provenance.

The first full-drawable A/D diagnostic uses 100 measured inputs plus 20 warmups.
Both final PNGs match byte-for-byte, SHA256 `60df36e00a01…`, at row 3,716. Six host
boundaries qualify, maximum load1 1.82861; cleanup completes. An initial assertion
incorrectly compares this against the historical three-sample capture at a
different final viewport; its failure is retained. It is not a candidate visual
difference. Matching historical-workload capture and paired regression controls
are recorded below. No diagnostic readback times count as gains.

A refined model keeps the incoming displayed offset separate even while intent is
pending, matching D's Screen behavior. Persistent intent passes 4,311 visited
states/32 terminal states; the serial alternative passes 3,347/28. Both finish at
maximum depth 25 within a limit of 28. Latest-offset retirement still fails with
the same three-input counterexample (4,743 visited states before rejection).
The original simplified model remains alongside this refinement.

The native linked assembly shows that LLVM now outlines Session::scroll, which
was inlined into Application::scroll in A. The D body retains the original pane
search and transport send, adds scalar target selection/clamping and stores the
optional target only after the send returns. It introduces no direct allocator
call. This is an actual code-generation change, not evidence of identical code
placement, and is evaluated by the native controls rather than assumed free.

`/tmp/telar-perf-scroll-intent-D-pairs-01` completes six alternated discrete-scroll
pairs with 100 measured inputs and 20 warmups per run. All 26 host boundaries
qualify, maximum load1 2.58398; content/grid/Qt checks and owned cleanup pass.
Medians of per-run summaries, with D wins out of six:

| Measurement | Accepted A | Candidate D | D wins |
| --- | ---: | ---: | ---: |
| p50 latency, ms | 31.38000 | 31.29343 | 4 |
| p95 latency, ms | 40.04587 | 38.18860 | 5 |
| p99 latency, ms | 45.49539 | 42.97747 | 4 |
| maximum latency, ms | 46.12931 | 48.39829 | 3 |
| GUI CPU, ms/input | 4.95628 | 4.80911 | 3 |
| GUI lifetime peak RSS, MiB | 193.61719 | 205.38281 | 2 |
| runtime CPU, ms/run | 80.60527 | 80.33633 | 3 |
| runtime instructions/run | 412,898,923 | 411,342,473 | 5 |
| runtime cycles/run | 173,965,171 | 176,316,122.5 | 4 |

The runtime interval includes startup of the GUI, warmup and measured inputs,
excluding runtime startup/shutdown and child CPU; it is not the GUI input interval.
There is no consistent latency/GUI-CPU/runtime-CPU regression under the frozen
0–1-win rejection rule, but no CPU improvement is established. The 8-byte object
layout increase does not explain or bound the observed GUI peak-RSS variation.
This is a correction's regression control, not a complete-flow performance claim.

The matching three-sample/20-warmup drawable diagnostic now also reproduces the
historical SHA256 `ec87ced6f6c9…` exactly for both A and D (six host boundaries,
maximum load1 2.05469). Separate single-pane typing, TUI, splits and tabs captures
all match A and their historical PNG references byte-for-byte. Their 18 host
boundaries qualify, maximum load1 2.87695, and owned cleanup completes.
The D-linked existing Session-effects and attachment-layout tests pass; offscreen
scene tests pass 53/53 and chrome tests 16/16. All affected test objects are rebuilt
with the D overlay and the private D GUI archive; accepted artifacts are untouched.

`/tmp/telar-perf-scroll-intent-D-controls-timing-01` completes all 48 native
regression-control runs: six alternated A/D pairs for single-pane typing, TUI,
splits and tabs, 100 measured inputs plus 20 warmups. All 98 host boundaries
qualify, maximum load1 2.51318. Workload/content/grid/Qt qualification and owned
cleanup pass. Values below are A → D medians, followed by D wins out of six.

| Case | p50 ms | p95 ms | p99 ms | max ms | GUI CPU ms/input | runtime CPU ms/run |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| single | 24.86140 → 24.97690 (2) | 32.85720 → 33.00579 (1) | 34.19188 → 37.01535 (2) | 37.26302 → 37.74548 (2) | 3.85167 → 3.85618 (4) | 82.92840 → 84.36046 (2) |
| tui | 28.76651 → 28.85579 (1) | 39.25639 → 37.48366 (4) | 44.30740 → 42.64514 (4) | 49.74215 → 51.96944 (3) | 5.05746 → 5.31697 (1) | 99.00958 → 104.95290 (1) |
| splits | 25.30016 → 24.95348 (4) | 32.90199 → 33.13572 (2) | 37.73429 → 37.29795 (3) | 38.79102 → 38.69088 (2) | 4.05729 → 4.01741 (4) | 101.12565 → 100.59106 (4) |
| tabs | 24.90782 → 24.88828 (3) | 33.04641 → 33.07689 (3) | 37.20786 → 37.04139 (4) | 37.68819 → 41.17440 (1) | 3.81388 → 3.91812 (3) | 99.29573 → 99.06081 (2) |

| Case | GUI lifetime peak RSS MiB | runtime instructions/run | runtime cycles/run |
| --- | ---: | ---: | ---: |
| single | 202.773 → 204.781 (3) | 89859269.500 → 90636787.500 (1) | 140557860.000 → 141236578.000 (2) |
| tui | 218.359 → 220.664 (3) | 180442303.000 → 179927698.000 (4) | 182457101.000 → 185873444.500 (1) |
| splits | 199.945 → 199.156 (3) | 131375991.500 → 130792877.000 (3) | 179699159.000 → 177609818.500 (5) |
| tabs | 205.984 → 204.758 (3) | 132073909.500 → 131330243.500 (4) | 179669050.000 → 177660050.500 (4) |

D is **rejected**, despite fixing the exercised scroll-input loss. Consistent
losses are single-pane p95 (1/6), TUI p50 (1/6), TUI GUI CPU (1/6), TUI runtime
CPU (1/6), and tabs maximum latency (1/6). TUI GUI CPU rises about 5.13% and runtime
CPU about 6.00%. The cause is not established; no identical-code-placement
exception is asserted. Neither these results nor the successful target-scroll
p95 can justify adoption. No additional repeated timing series selects away the
regressions.

A separate TUI census uses the same instrumented accepted runtime with A and D,
plus an uninstrumented A negative control under the same forwarded trace variables.
`/tmp/telar-perf-scroll-intent-D-tui-census-01` qualifies eight host boundaries,
maximum load1 2.71387; content/grid/Qt checks and owned cleanup pass. Neither
instrumented variant receives any SetPaneViewport request. Across the whole
session, including initialization and warmup, A emits 139 frames/5 snapshots,
228,694 payload bytes and 97,041 encoded cells; D emits 138 frames/5 snapshots,
230,979 bytes and 98,105 cells. Initialization includes intermediate grids before
the qualified 82×21 workload. These are not measured-input-only counts and do not
explain CPU causally. The negative control creates neither trace file. All census
times are excluded. More viewport requests and a simple increase in total frame
count are not supported as explanations in this diagnostic.

Source review also identifies a separate live-output parity gap. Zig CellSync
tracks a viewport pin and clears it when returning to the bottom; accepted C++
retains a raw absolute offset and re-applies it before later frame refreshes.
An isolated real-Terminal/Ghostty reproduction starts with 100 output lines,
requests the then-current bottom (offset 80), restores the shared terminal to
bottom as delivery does, appends 25 lines, and re-applies the retained request.
It observes offset 80 although the new bottom is 105; explicit scrollToBottom
observes 105. This is a component/source reproduction, not a native full-flow
claim or proof of the TUI regression. It motivates a separate end-to-end oracle
for live following and history anchoring before changing attachment semantics.
A permanent GUI absolute target would need revisiting if runtime viewport
ownership changes; the current D experiment only mirrors the existing contract.

The four pending runtime-pacing files remain byte-identical to their pre-pass
hashes. No GUI production change is adopted. Accepted GUI `bc55d0e84d76…`, runtime
`1f1849d1881f…`, helper and Qt remain the baseline; all F01–F16 complete-stack gates
stay open and the persistent objective stays active. The next work is a narrower
correction with retained input ownership, targeted cost attribution, and explicit
live-output/anchoring oracles, not acceptance of D or blanket removal of RAII.
