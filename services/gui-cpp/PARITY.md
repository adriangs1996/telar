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
| Graphics/attachments | Existing image/attachment flow retained; hidden Wayland resource release corrected; native paste/modal and runtime Kitty regressions passed | Finish comparative resource/performance observations; address any directly discovered functional failure |
| Blur | Linux optional compositor protocol reused; macOS numeric radius/cache/reset/fallback aligned; native policy/protocol controls passed on both SDKs | None; shipped in Preview27 |
| Performance | Exact Preview27 and original Zig frozen; alternating native presentation runs, CPU/RSS collection and negative controls | Validate comparable pairs, reject invalid loads/dimensions and report results; equal-or-better gate is not met by preliminary data |

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

Performance: input-to-visible endpoints require verified marker pixels and positive
presentation of that same drawable, plus initial readiness, focus, geometry and
VSync checks. An acknowledgement is not presentation. Twelve preliminary rows
labelled 4K actually used 1024² and are rejected for 4K; a corrected size receipt is
mandatory. Fixed-rate background-output runs missing the existing 5% bound are
rejected. Linux VM results establish correctness only, not native Linux speed.
Report GUI/runtime CPU and RSS separately with sampling/peak limitations.

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
