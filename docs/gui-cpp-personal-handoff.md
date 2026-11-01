# Personal: C++ daily adoption and complete parity — OPEN

Continue working after checkpoints. This document replaces the accumulated status
log; its complete previous text is retained in the shared-overflow evidence archive
and Git history. Read `AGENTS.md`, `services/gui-cpp/DAILY_DRIVER.md`, the current
`PARITY.md` summary and its Remaining functional work table before further changes.

## Requirements and scope

Implement `services/gui-cpp` with Qt Quick, complete functional/visual parity and
measured equal-or-better performance against the original Zig GUI. The complete
objective remains open. First deliver a usable daily candidate; that milestone
also stays open until its remaining acceptance gates are met. Adrian's latest
priority overrides the original machine-first/performance-first order.

Only command palette/quick navigation and notifications/center/sounds may defer
for daily adoption. Preserve existing implementations. Every other daily area is
required: terminal/Unicode/interactive apps; tabs/rename/move/drag; splits/resize/
fullscreen; projects/workspaces/sidebar; worktrees; agents/tasks/plans/peek; SSH/
switching/reconnection; complete history; suggestions/paths; selection/clipboard/
copy mode; links/previews; images/attachments; Lua/shortcuts/reload; appearance/
fonts/blur; statusbar; plugins/custom bars/widgets/panels; multiple windows/
restoration/suspend-resume. This is not a minimal-terminal milestone.

Work ONLY in this worktree and its existing owned Linux verification mirror.
No other agents, publishing, pushing, merging, installations, session migration,
broad runtime rewrite or premature Zig deletion. Preserve installed Zig, preview
bundles, user configuration and runtime processes. Never read, touch or stage
`services/gui-cpp/measurements/personal-frame-delivery.md` (unrelated user file).
Send meaningful Spanish updates at most 60 seconds apart. Code/commits are English.
Commit reviewed checkpoints locally, then continue; a checkpoint is not completion.

Keep application/domain code separate from native macOS/Linux code. Reuse existing
components. Follow runtime-cpp's explicit allocators, concepts/templates and concrete
compile-time dependency selection, including test implementations, without added
virtual dispatch. Components should be independently usable/testable. Descriptive
names, single-line signatures, at most five arguments, braced conditionals, blank
lines between logical blocks; no magic constants or redundant comments. Apply
`docs/zig-source-layout.md` before any Zig layout/import changes.

Keep the broad clang-tidy profile/thresholds and `.clangd` unchanged. No suppressions,
weaker assertions or longer deadlines. Use meaningful targeted checks; central
session changes warrant their affected regression groups. Preserve failed evidence
and prior immutable manifests. Pixel microbenchmarks/microkernels are not adoption's
critical path unless they expose a real daily-use blocker.

## Protected processes — verify identities before source changes

| Role | PID | Last observed start |
| --- | --- | --- |
| User installed schema87 runtime | 35801 | Tue Oct27 10:45:44 2026 |
| User Preview8 GUI | 52865 | Sun Nov1 09:45:51 2026 |
| Owned verification QEMU | 7158 | Fri Oct30 14:55:50 2026 |
| Guest existing Sway | 9469 | Fri Oct30 14:31:48 2026 |

All four remained unchanged after Preview12 qualification. Do not signal them.
A voluntary user preview switch can change the GUI identity; identify its new
executable/start instead of restoring the old process. Old Zig GUI87625 was already
absent before this work; do not restart it or claim we stopped it. Private test
children are separate and must be cleaned up by their owning helpers only.

## Available candidate: Preview13 (2026-11-01)

`services/gui-cpp/out-adoption/Telar C++ Preview 13.app` is frozen, qualified and
already offered to Adrian. GUI SHA256
`cb3c71e61984fb05efc463ee8e59c7be9f3b00336cc7a2a520f3ffca00673bf6`;
raw `0ed3c6acbb7ea1458ced8f13517cd6595a8b7ac60998b2f115b6b2c28052e2d8`.
All1739 hashes/121 Mach-O/deep-strict signatures pass. Exact relocated schemas87/88
with native blur/login/Finder/config/runtime/plugins/bars/two windows/client pause,
realSSH, VimUTF8, full custom panel/bars and task/worktree/plan survival all pass.
Five daily captures plus schema87 direct were inspected; zero QML warnings/private
cleanup. Callback/controlled-anchor panel actor and protocol-fixture activity have
the same limits as12 below. Raw GUI remains byte-identical after portable null
checks; no repackaging/new clean build is claimed. Open-n/rollback as below with13.
Preview8/12 and installed app/config/runtime are preserved. Daily and final goals
stay OPEN; physical sleep is still untried. See DAILY_DRIVER.md and builtin report.

## Preserved candidate: Preview12 (2026-11-01)

`services/gui-cpp/out-adoption/Telar C++ Preview 12.app`

GUI SHA256 `14ccb0a854bbbb9258a885811168be4650ae2e4973137c7436c116f19b172c27`.
Raw GUI SHA256 `d0c0e8e29d94d38ece98ba3d0bbdcc082e341e36d085c1e8364ffba01fdf1bf5`.
It is frozen, separately packaged, qualified and offered to Adrian. It uses the
fresh Preview9 build baseline plus recorded increments, not a new full clean
build or an own-Zig-retirement gate. Never overwrite/repackage an existing bundle.

All1739 hashes/121 Mach-O objects/deep-strict signatures pass. Exact relocated
schema87 AND88 Finder/LaunchServices/login/config/default-runtime/plugin/bar/
two-window/owned-client-pause smokes pass with adopted opacity.98/blur20. Exact
realSSH, Vim exactUTF8, full custom panel/bars and task/worktree/plan/survival flows
pass; zero QML warnings, configuration unchanged and disposable states removed.
All five daily captures plus schema87 direct capture were inspected. Panel actor
uses an owned callback/controlled anchor rather than OS pointer; activity reports
are controlled protocol fixtures, not another AI agent or Git checkout. Finder's
GUI exit is unavailable through `open`; the healthy final marker is checked.

From the worktree root: `open -n "services/gui-cpp/out-adoption/Telar C++ Preview 12.app"`.
Finder can open it after another preview is closed. Copy under its separate name
to Applications if desired; nothing is installed/replaced automatically. Return by
closing the preview and opening `~/Applications/Telar.app`. Preview8/11 remain intact.

Adrian confirmed Preview8 normal interface and found no daily blocker so far.
Physical sleep with Preview9: "Aún no lo he probado". No unanswered question remains;
do not ask again, wait on this answer, or suspend the host automatically.

## Latest implementation and evidence

Local commits `03cfd7f62` (first-command diagnostic,243 entries) and `15e383dc2`
(hidden action replaces overflow menu,124 entries) are complete. Their historical
verifiers pass without current-source checking after later edits. Previous scoped
checkpoints/artwork/panel/group/global-fitting evidence remain in measurements.

Shared-overflow source work and Preview12 are committed locally in `c91aca988`:
CMakeLists, ComponentFit.js, ComponentSlot.qml, StatusBar.qml, NavigationBar.qml,
QuickTest, plus new ComponentOverflow.qml. Original BarRow positions include legacy
`top.right` as the fourth bottom-row source: it now appears there once, with one
shared overflow budget/control and a More panel (original300 width/26 rows). All
three source actions retain source/generation/revision, exact panel title/content,
Escape and menu reuse. Closed overflow has no panel-map polling/connection. Existing
per-tree overflow remains reusable outside the shared row. Builtin metric/machine
priority and full styling/fit/pixel/performance acceptance remain open.

A valid negative fails three controls vs one. Another catches cached failed output
losing its diagnostic width when hidden: each source now reserves errorWidth8.
Mac100ms command failures exposed a700ms tooltip delay that could not finish under
repeated surface notifications. Stable `pointer.hovered && root.errorWidth>0`
visibility passes; reverting ONLY that binding reproduces the failure. Delay,
cadence, assertions and deadlines are unchanged. Diagnostic-only C++ guard is
removed; its source/log/image are retained. Final source has the stable binding.

Final MacRelease13pass0; LinuxRelease+ASAN13pass0 each with leak detection/private
cleanup. MacASAN13assertionspass but exits1 for681802B/4055alloc, no address/UB and
LSAN_OPTIONS absent. Broad analysis and actual delivered empty editor diagnostics
pass BOTH SDKs; changed-range formatting passes; seven portable hashes match.
Old12 +new7 directed Node controls pass (functional, not Qt/oracle/performance gates).
Final Mac/Linux menu+cached-error captures were inspected. No build/native/quality/
packaging/smoke jobs remain active. Raw `out-dependencies/component-shared-overflow-1`.

The shared-overflow report/archive/verifier and local commit are complete. CONTINUE
actual PARITY; do not repeat completed Preview12 qualification without new changes.

## Latest qualified source: builtin fitting; continue machine facts next

Raw `services/gui-cpp/out-dependencies/component-builtin-fit-1`; frozen report/archive/
verifier `measurements/component-builtin-fit`. Original priority40 group/CPU/memory/
battery and machine nodes now use the common tree. Metrics retain existing renderers,
6px group/leading-child/child spacing and controller-free behavior. Machine switcher
width0 is corrected; hidden lists/segments retain measurement without click records.
Shared-menu body typography falls back to small for standalone StatusBar. Portable
explicit QPointer comparisons satisfy Qt6.8/6.12 with identical Mac raw GUI bytes.

Five new/19 prior directed controls pass. Mac Release14native0, Linux Release+ASAN
14native0 each; four affected CTest suites pass. Final portable-null machine-window
suites pass MacRelease and LinuxRelease+ASAN. Mac ASAN14assertionspass/exit1 for623226B
3639alloc, no address/UB or suppression. Broad/actual-editor/format pass BOTH SDKs;
all14 portable hashes match. Linux actual editor OOM is retained; two retries use
-j=1/no background index/disk PCH and deliver empty diagnostics within the same60s
limit. Broad/profile/project .clangd/assertions/deadlines unchanged. Negative metric-
projection, machine-width/hidden-width, first-sample admission and initial quality/
formatter failures are retained. No heavy checks or private smokes remain running.

Next functional work: original builtin machines show phase glyphs plus connected
CPU values rather than the existing switcher adapter's visuals. Original reference
src/gui/widgets/BarRow.zig:112 suppresses facts for <=1 machine, then shown slots in
slot order. inline_nodes.zig:529-600 uses machine gap12/part gap5, phase/attention
palette, active bold label, CPU only when connected+present. MachineRow already owns
phase/cpu_percent and machine_controller.cpp summarize emits machinesChanged for
hidden clients too; no runtime rewrite is needed. Research only so far, no facts
source changes. Finish local review/commit of this qualified checkpoint, then
CONTINUE actual implementation; a checkpoint is not full completion.

## Remaining gates: keep these separate

Daily acceptance: physical system sleep remains unverified; Mac shutdown-leak
attribution/stability remains open. Release Preview12 is available for daily
assessment. Do not equate private SIGSTOP/SIGCONT with physical system sleep.

Final parity: complete builtin-machine facts, full fitting/styling and combined
menu's wider interactions, native ownership/accessibility, complete paired visuals
and measured comparative performance. PARITY.md retains detailed known failures,
including other densities/platforms and existing comparative losses. Do not infer
whole-client superiority or full coverage from thirteen selected native cases.

Zig retirement: CMake still reads own Zig for themes/bindings/actions/tables; the
previous explicit production graph audit found nine generator inputs plus two
font-metadata inputs on both SDKs. It also compiles shared non-Zig C/ObjC from
src/gui. Packaging reads build.zig.zon for version and still bundles original
runtime/CLI/plugin-worker support plus diagram renderer. Ghostty's toolchain is a
separate dependency; original-source oracles are test dependencies. The inventory
is not a complete header/runtime/packaging closure. Audit and clean-build without
own sources before removal. No own Zig was removed or no-Zig build claimed; see
ZIG_RETIREMENT.md. Do not refactor the whole runtime to pursue the adoption change.

The standalone Qt Gui/Core/Foundation font control (no Telar/QML/window/runtime)
leaks in all four outer-pool/font-deregistration combinations; both proposed fixes
were rejected. Foundation/CoreText also retains below Qt. This explains part of
the report, not every GUI allocation. See font-exit-lifetime.md; don't repeat those
probes without a new hypothesis or suppress Mac failures.

## Local build and verification

Prepend `/Users/adriangonzalez/.local/bin:/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/ninja/bin:/opt/homebrew/bin:/usr/local/bin`.
Do not overwrite `/opt/homebrew/bin/ninja` or alter tap trust. macOS ARM64: LLVM23.1.2,
Qt6.12.0; Release `services/gui-cpp/out-adoption-build-9`, ASAN
`out-adoption-sanitizers-9`. Old `out` had stale68-byte QSB ABI despite equal struct
sizes; removing generated shaders fixed scoped checks, but use fresh9 for adoption.
No production renderer change was made for that diagnosis. Build/gui-editor and
actual Neovim checks use existing helpers/profile; preserve source-database usability.

Package with existing `tools/package_macos.py`, prefix `out-dependencies/reference-gui`
(the same runtime/hash/diagram helper used by Preview11), and a NEW output path.
`schema87-runtime` is the copied installed runtime for private compatibility tests.
The original main checkout `/Users/adriangonzalez/sandbox/telar` is untouched.
Transferred33 shared baseline files and eleven materialized LFS wallpaper assets
are intentional; don't discard them or change transport attributes as product work.

Linux: existing Debian13 VM, Qt6.8.2/Clang23,4GB/no swap, SSH55984. Use
`python3 services/gui-cpp/measurements/local/linux_clipboard_vm_exec.py 'COMMAND'`.
Mirror `/home/parity/telar/services/gui-cpp`; validate prior hashes before writes.
Never print its private key. No rg in guest; use Python. Serialize guest heavy
compile/native/tidy/editor jobs: earlier parallel checks hit confirmed OOM and
failed attempts remain evidence. Private Sway test displays are separate from9469.
Latest native helper and Linux quality driver are in shared-overflow raw evidence.

Mac native helper `out-dependencies/component-content-3/schema87_native_test_1.py`
uses owned Cocoa/Metal windows and private pasteboards; preserves general clipboard.
Set TELAR_GUI_TEST_REFERENCE_RUNTIME and TELAR_BIN_PATH to schema87-runtime/bin/telar.
ASAN_OPTIONS=detect_leaks=1, UBSAN_OPTIONS=halt_on_error=1, matching llvm-symbolizer,
LSAN_OPTIONS absent. Keep child exits/leak reports distinct from assertion totals.

## Machine and architectural invariants

Machine integration is implemented; don't restart the original transfer's unfinished
machine work. Preserve one shared Application/window and stable per-machine client/
session/connection. Fonts/window resources/input/notifier/sounds are shared, with
17 slots/local0. Refresh hidden summaries on events, not every frame. Preserve stable
IDs/admission generations through destination edits/reuse; namespace window leases
by destination and invalidate model/view identity even when pane IDs/revisions match.
Old async replies/notifications/sounds must not target a different/current machine.
Only local sockets use peer-UID authentication. Keep validated SSH/discovery/policies
and managed ControlPath SHA256 little-endian selection. Picker disabled rows, label
before destination scoring, stable ties, Add-last, Enter-enable/Shift-Enter-toggle
and inert local toggles are required. Hidden clients retain metadata rather than
screens; settle presentation after every client's events, preserving in-flight data.

Persistent Goal API still says blocked and offers get/create/update only, with no
resume operation; create refuses unfinished goals. Continue manually without
marking complete or re-blocking while progressing. User interruption was steering,
not cancellation. Never end the full objective at an incremental checkpoint.
