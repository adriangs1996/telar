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

## Available candidate: Preview15 (2026-11-01)

`services/gui-cpp/out-adoption/Telar C++ Preview 15.app` is frozen, qualified and
already offered to Adrian. GUI SHA256
`2e55047d76ab005463ece74db5104c77e3166a39ed0fcbf0d5b9fa05158b81da`;
raw `a14a4ea70fbf0b6f0c8fa9153424b6f68f9a8f79af5e3be24e5334684d296e6b`.
All1739 hashes/121 Mach-O/deep-strict signatures pass. Exact relocated schemas87/88
native blur/login/Finder/config/runtime/plugins/bars/two windows/client pause,
realSSH WITH machine bar AND green=default, VimUTF8, custom panel/bars and task/
worktree/plan survival pass; zero QML warnings/private cleanup. Five daily captures
plus schema87 direct and native Mac/Linux default ink were inspected. Panel actor
is an owned callback/controlled anchor; activity uses protocol fixtures, not AI/Git.
Fresh9 plus increments, not a new clean/no-own-Zig build. Launch from repo root:
`open -n "services/gui-cpp/out-adoption/Telar C++ Preview 15.app"`. Finder can open
it after another preview closes; copy under a separate name if desired. Rollback:
close preview/open `~/Applications/Telar.app`. No installs/replacements/migrations.
Preview8/13/14 and installed app/config/runtime are intact. All previews share bundle
identifier; use open-n for the exact one while8 runs. Adrian confirmed Preview8
normal/no daily blocker so far. Physical sleep: "Aún no lo he probado"; no question
is pending. Don't ask again or suspend the host. Daily/full goals stay OPEN.

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

## Latest qualified source: default machine text ink; continue API validation

HEAD7dfeb17c6 commits inline facts/Preview14 and275 frozen entries. The later scoped
ink correction is qualified; finish its review/local commit then continue PARITY.
Raw out-dependencies/component-machine-default-ink-1; report/archive/verifier under
measurements/component-machine-default-ink. Production delta is factRecord text ink
using toQColor(theme.chromeColor(role)), preserving fill semantics for no-color
profile dots. Old source negative has#00000000 vs expected#ffffffff on both machines.
Same fixture retains lost-link/no-CPU/activation/hidden-width assertions. Four native
checks pass per variant/SDK; LinuxASAN0, Mac4assertionspass/exit1 for986300B3607alloc,
no address/UB or suppression. Broad/editor/format pass both SDKs; two sources match.
Linux editors use OWN on-disk TMPDIRs, removed AFTER clangd exits; no tmpfs PCH buildup.
Preview15 exact qualification is complete/offered; no heavy jobs remain. Earlier14
broader14+6 and whole machine/geometry CTests remain preserved, not claimed rerun.

Footer audit: both GUI renderers omit sidebar_footer (original BarRow.positions4;
Sidebar.draw no footer draw site), while configuration/state exposes those slots.
Do not add a phantom row as GUI parity. Next concrete API gap: original
Generation.zig:1200 rejects footer count>3 and any tabs; C++ Definitions currently
truncates/accepts them. Verify/fix diagnostic and validation parity, then group/menu/
fitting behavior. No validation source edits yet. Don't redo passing15 checks without
new changes/failures. Previous verifiers default to archives after source changes.

## Latest qualified source: inline machine facts; continue footer composition

Local checkpoint c4a7f490f already commits builtin fitting/Preview13 and557 frozen
entries. New inline-facts sources/report are qualified; finish their local review/
commit, then continue actual PARITY. Raw out-dependencies/component-machine-facts-1.
Original BarRow skips facts for<=1 machine, then shown slots in slot order. Pure
presentation/machine_facts.hpp follows inline_nodes glyph/ink/attention, active bold,
connected-only optional CPU and12px machine/5px part gaps. MachineChromeLayout has
an exclusive inlineFacts mode; existing controls remain. Mode changes retire rows,
facts activation is inert, hidden measurement creates no visual QVariant rows.
Phase/CPU use MachineRow summaries/events for hidden clients; runtime is unchanged.

Both SDKs pass14 native Quick+6 machine checks in Release, both full machine-window/
geometry CTests, broad/all3TUs, actual editor and changed-range format. Linux ASAN
also exits0/cleanup0 with leak detection. Mac14+6 assertions pass but exits1 for
638351B3956alloc and1073208B4036alloc; no address/UB error or suppression. Seven
portable sources match. Linux editors retain one worker/no background index/disk
PCH and original60s delivery deadline/profile/project .clangd.

Failures retained: old-source missing inlineFacts; BoundedText.empty compile mistake;
include/designated-init/trailing-comma diagnostics; first Cocoa transient connecting
phase due to an open fake listener plus white fixture background. Fixture now closes
its OWN listener and adopts panelBackground; same glyph/CPU assertions and5000ms.
First exact SSH fails BEFORE Popen because VM/tmp tmpfs is full.43 inactive generated
clangd PCH files total2033341664B; verified no live compiler/editor, open FD or mapped
preamble, recorded UID/inode/hash/size/time, removed only those caches. /tmp free1.9G,
Sway unchanged; empty failed setup removed with no-runtime/socket/history guards.
SSH retry in NEW output2 passes. Keep failure1 and cache receipt. Future editor
probes need an OWNED on-disk TMPDIR and own-PCH cleanup AFTER server exit; don't
recreate the tmpfs pressure or change project diagnostics. No heavy checks remain.

Next functional review: sidebar footer composition/fitting across its configured
sources, then remaining group/menu behavior. Do not redo passing Preview14 tests
without new changes/failures. Previous immutable verifiers default to archives;
--check-current is only for that checkpoint's source. A checkpoint is not full
completion. Preserve the unrelated user measurement file.

## Remaining gates: keep these separate

Daily acceptance: physical system sleep remains unverified; Mac shutdown-leak
attribution/stability remains open. Release Preview15 is available for daily
assessment. Do not equate private SIGSTOP/SIGCONT with physical system sleep.

Final parity: remaining fitting/styling and combined
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
