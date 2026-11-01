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

## Available candidate: Preview16 (2026-11-01)

`services/gui-cpp/out-adoption/Telar C++ Preview 16.app` is frozen/qualified and
already offered for normal-use assessment. GUI SHA256
`76ca4aa6fcc7ed5b1bc50402cca3e6137f3d6fd55a38a5ee31b835cf8f44232d`;
raw `81dca3f3d24dd9398fdce3f34c4217c437a640f85b310f0fdb50d1a7dba8993a`.
All1739 hashes/121 Mach-O/deep-strict signatures pass. Exact relocated schemas87/88
Finder/login/default-runtime/plugins/bars/two windows/client pause, realSSH with
machine bar+default ink, VimUTF8, custom panel and task/worktree/plan survival pass;
zero QML warnings/config unchanged/private cleanup. Six direct/daily captures plus
native Mac/Linux group captures inspected. Panel actor is owned callback/anchor;
activity uses protocol fixtures, not AI/Git checkout. Fresh9 plus increments, not
clean/no-own-Zig build. From worktree root:
`open -n "services/gui-cpp/out-adoption/Telar C++ Preview 16.app"`. Finder opens it
after another preview closes; copy under its separate name if desired. Rollback:
close preview/open `~/Applications/Telar.app`. No install/replacement/migration.
Preview8/15/installed app/config/runtime remain intact. All previews share bundle
identifier; use open-n for this exact one while8 runs. Adrian confirmed8 normal/no
daily blocker so far. Physical sleep: "Aún no lo he probado"; don't ask again or
suspend host. Daily/full goals stay OPEN.

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

## Latest qualified source: configured-group geometry and footer audit

Default ink/Preview15 is locally committed in d24e5e020 (175 frozen entries).
Current group-spacing source/report and exact Preview16 qualification are complete;
finish local evidence/review/commit, then continue actual PARITY. Raw evidence under
out-dependencies/component-group-spacing-1; report/archive/verifier under
measurements/component-group-spacing. Three QML files +two tests. Original group
chrome6/26, mark14, childgap6 and leadinggap6 now agree in measurement and placement;
nonempty bar groups retain6px edges, empty6/26. Panel groups add no extra bar padding.
Native negative reproduces missing12px. Both SDKs pass broader15 cases; later test-
only parentheses/default-init fixes leave production QML unchanged. Final4 native
checks+three config CTests pass per variant/SDK; LinuxASAN0, Mac assertionspass/exit1
for487550B2840alloc (broader645182B3749alloc), no address/UB/suppression. Broad/editor/
format pass both SDKs, five hashes match. QML lint targets0 retain existing dynamic-
property/qualification warnings; policy/profile unchanged. Linux own disk editor
TMPDIRs removed after compiler exit; /tmp free1.9G. Native/daily captures inspected.

Footer audit correction: neither GUI renders sidebar_footer. Shared runtime-cpp
BarsValidator ALREADY rejects >3 sources/tabs before Definitions.apply. Earlier
truncation claim examined Definitions alone and is withdrawn; diagnostic wording
still differs. New end-to-end base/profile rejection, valid inheritance/list
replacement/static content and allocator cleanup checks pass. No duplicate
production validator/runtime refactor. Failed old exact-diagnostic expectation
and corrected coverage retained in component-footer-validation-1.

Separate source-unmodified native audit in daily-native-links-1:7 checks pass0 at
factors1.25/2 (link hover/copy, selection, wheel/copy, keyboard copy-mode, close/
reopen same pane). Private boards cleared/general count954 unchanged. Initial
attempt selected3 optional custom-link-host methods absent from this build; retain
selection errors, don't call them product failures. External link-opening/device/
whole-client ownership gates remain open. No heavy jobs remain after exact16.

NEXT concrete functional finding: original src/client/input/bar_components.zig
prefers action over a coexisting URL; Qt activateComponent currently prefers URL.
Reproduce safely with an action and URL that LinkTarget rejects (https:// with
empty host, assert rejection before test to avoid external app launch), then fix
bar+panel dispatch and preserve generation/revision guards. Existing configured
GroupPriority/panel button tests can cover both; don't alter production until
protected processes are rechecked and group-spacing evidence is frozen/committed.
A checkpoint is not completion. Don't redo passing16 scopes without new changes.
Previous immutable verifiers default to archived sources after future edits.

## Preserved machine checkpoints

Local c4a7f490f commits original-priority builtin fitting/Preview13 (557 entries);
7dfeb17c6 commits inline phase/attention/CPU facts/Preview14 (275 entries);
d24e5e020 commits default text ink/Preview15 (175 entries). Their reports/verifiers
remain under component-builtin-fit, component-machine-facts and
component-machine-default-ink. Original control modes remain separate from static
facts; hidden client summaries update on events and no visual maps are built for
hidden measurement. Text default resolves foreground through chromeColor, while
no-color profile dots keep fill semantics. Full styling/performance remain open.

Original14 SSH attempt failed before Popen because43 inactive generated clangd PCH
files filled VM/tmp. UID/inode/hash/open-FD/maps guards proved caches unused before
removing2033341664B. Sway/protected processes stayed intact. Retry in NEW output2
passed. Preserve that failure/cache receipt and use owned on-disk editor TMPDIRs;
never recreate tmpfs pressure or change diagnostics. Prior failed native fixture
connecting-phase/readability controls remain in their immutable evidence. No need
to repeat completed candidate qualifications without new source changes/failures.

## Remaining gates: keep these separate

Daily acceptance: physical system sleep remains unverified; Mac shutdown-leak
attribution/stability remains open. Release Preview16 is available for daily
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
