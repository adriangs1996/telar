# GUI parity — OPEN

## Authorized phase

Adrian's 2026-11-02 instruction replaces older ordering and gates for this phase:
(1) finish Preview26, (2) close concrete graphics/attachment differences,
(3) match native blur, (4) benchmark the full Release clients. Do not resume the
older backlog automatically after delivering these four steps. Full functional,
visual and equal-or-better performance parity remains open; so does Zig retirement.

| Step | Verified state | Remaining in this phase |
| --- | --- | --- |
| Preview26 | Separate deployed Release; exact-bundle daily smokes, plugins/bars/panels, schema87/88 and 20 normal-loop cycles passed | None; preserve the bundle |
| Graphics/attachments | Existing image/attachment flow retained; hidden Wayland resource release corrected; native paste/modal and runtime Kitty regressions passed | Comparative observations completed; no new graphics functional failure found |
| Blur | Linux optional compositor protocol reused; macOS numeric radius/cache/reset/fallback aligned; native policy/protocol controls passed on both SDKs | None; shipped in Preview27 |
| Performance | Exact Preview27 and original Zig frozen; alternating native presentation runs, CPU/RSS collection and negative controls | Benchmark executed; measured regressions keep the equal-or-better gate OPEN |

## Existing functionality and evidence limits

The client implements terminal/Unicode and interactive input; tabs and splits;
projects/workspaces/worktrees/sidebar; agents/tasks/plans/peek; machine selection,
SSH/recovery; history; suggestions/paths; selection/copy/clipboard; links/previews;
images/attachments; Lua/keybindings/reload; fonts/appearance/statusbar; plugin
bars/widgets/panels; and multiple-window restoration. These are existing features,
not a list of missing subsystems. Disposable daily smoke coverage passed for the
packaged candidate; it does not prove every interaction or physical suspend/resume.

History error-caption shaping and entrance animation already have implementations
and passed checkpoints. `sidebar_footer`, drawn by neither GUI, is not a parity gap.
Unreviewed interaction states are unknown, not confirmed missing functionality.
No new general inventory is authorized in this phase.

## Confirmed qualifications and open findings

Graphics: release on hidden surfaces restores correctly on show; real Sway/Vulkan
image ASan regressions passed 22 checks, and native Kitty/attachment regressions
passed. Image budgets, cancellation/request generations and replacement limits
remain enforced. The attachment shelf retains at most four previews / 32 MiB
encoded, with independent source/PNG/pixel limits. C++ currently requests inline
image transport; the original can use shared memory. This is a measured performance
risk, not absent image support.

Blur: optional Linux protocol absence/withdrawal/reappearance and native lifetimes
are handled by the platform adapter. macOS applies numeric radius where supported
and uses the existing material fallback otherwise; the content remains above it.

Sanitizers: native macOS shutdown checks remain failed, despite passing assertions
and no observed address/UB error. Latest blur CTest exit8 reports 345,961 bytes /
1,985 allocations. Linux Qt-only controls reproduce the protocol fixture's shutdown
retention (client 96 bytes / one allocation; compositor 136,407 bytes / 1,750).
No suppression was introduced. General framework exit-retention triage is deferred;
actual memory/security/data-loss errors directly found in the scoped flows require
attention. Retention totals alone do not establish ongoing growth.

## Release benchmark — measured regressions, gate OPEN

Native macOS Apple M3 / 32 GiB / AC, macOS26.6.2. Frozen original Zig SHA256
`4e021bbda7586d16f887dd04a1ded3a806ba60940179129838165d75a0c23e11`
(Mach-O SDK15.4) versus exact deployed Preview27 GUI SHA256
`eeb50140eb6387a1d211ffa8f1dd7c6d25ad8d4540e480c7513d0f7034ad1617`
(Qt6.12 / LLVM23.1.2). Same bundled JetBrains Mono15, configuration/theme,
1600×1000 physical viewport / DPR2, terminal grid, marker and pane geometries.
Six alternating pairs per row; 100 inputs/run after20 warmups. Values are medians
of run quantiles/counters. C++ wins0/6 p50 pairs in every row.

| Flow | p50 Zig / C++ ms | p95 Zig / C++ ms | GUI CPU Zig / C++ % | GUI peak RSS Zig / C++ MiB |
| --- | --- | --- | --- | --- |
| Terminal | 24.29 / 30.75 | 29.12 / 41.04 | 3.70 / 4.96 | 122.67 / 186.12 |
| 4 splits | 24.34 / 29.57 | 32.11 / 41.05 | 3.62 / 5.26 | 122.86 / 190.05 |
| 4 tabs | 24.29 / 30.97 | 29.00 / 41.03 | 3.79 / 6.91 | 129.26 / 197.45 |
| Images1024² | 37.98 / 54.06 | 48.90 / 72.40 | 9.80 / 21.60 | 138.45 / 208.26 |
| Images3840×2160 | 53.97 / 124.86 | 65.61 / 137.36 | 11.20 / 45.90 | 250.74 / 345.60 |

The latency endpoint is verified marker pixels on a drawable with a positive native
presentation timestamp, after qualified initial readiness and with focus/geometry/
VSync checks. It is not an acknowledgement or physical photon/scanout measurement.
CPU100% means one core, measured after warmup. Peak RSS includes startup, viewport
negotiation and probe buffers; it is not settled application-only memory.

Idle terminal: two valid pairs, exact GUI CPU0.32% / 0.70%, sampled settled GUI
RSS116.43 / 180.73MiB (Zig/C++). Idle1K images: three pairs, CPU0.33% / 0.84%,
settled RSS124.89 / 195.06MiB. The100ms external sampler clips inside the recorded
window; idle bounds are estimated from first-input minus native idle duration.
Its raw CPU fields were mislabelled nanoseconds: actual Mach ticks use125/3 ns,
validated against a200ms getrusage control (<0.01% error); CPU reanalysis is corrected
without rewriting raw samples. Native GUI getrusage/RSS values are independent.

For actual4K, sampled runtime CPU10.42% / 13.75% and runtime settled RSS22.42 /
88.18MiB are separate from GUI measurements; never sum shared RSS. Three native
attachment paste/modal pairs passed and general clipboard count stayed unchanged.
Whole-GUI CPU through the presented modal was0.562 / 0.808s, peak RSS132.41 /
194.72MiB; script waits are included, so these are not first-image latency figures.

Rejected:24 wrong-size4K rows from two earlier collections,12 fixed-rate text-load
rows missing the unchanged5% bound, one idle drawable failure and its unpaired C++
partner. Initial-negative controls reject before input (error4, not an isolated
zero-timestamp assertion); missing presentation-record/VSync/dropped controls reject
with19/20/21. No invalid row becomes accepted because its outer driver exits0.
Linux VM qualification is correctness coverage, not native Linux performance.

Read-only4K profiles identify inline socket/chunk copies and RGBA premultiplication
in texture upload as active work; they do not isolate each contribution to the total
regression. Earlier basic-loop/update-idle experiments showed no accepted gain.
No production optimization was accepted. Performance parity remains unfulfilled;
do not declare full parity or Zig retirement complete, or resume the old backlog.
All raw outputs/helpers remain ignored local files, never versioned evidence.

## Deferred and later gates

Outside this phase: further terminal/IME/history/activity work, limit-title naming,
more accessibility, palette/notifications, exhaustive visual matrices, physical
suspend/resume and general native-retention triage. Preserve existing behavior;
these deferred validations are not additional blockers for the scoped delivery.

Full visual parity and sustained daily stability are not declared complete.
Own-Zig retirement needs a separate audited clean build and runtime/CLI/plugin-worker
replacement; see [ZIG_RETIREMENT.md](ZIG_RETIREMENT.md). Keep genuine tests/fixtures
and runners; store benchmark artifacts only in ignored outputs, with concise status
and figures here or in the delivery documentation.
