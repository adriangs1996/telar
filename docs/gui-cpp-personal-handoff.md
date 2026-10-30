# Continue Telar C++ Qt Quick GUI parity on Personal

## Personal continuation checkpoint

### Terminal-session continuation after `413b8cfef`

The next checkpoint after handshake implements the terminal runtime receive-loop
boundary; see `services/gui-cpp/measurements/terminal-session.md` and its archived
verifier/manifest. Four window negatives and a parser negative fail before the
change. A separate reentrant negative proves that the old read tail can close a
replacement handshake; connection generation now fences it. RuntimeConnection
finishSession/resumeSession retain the last connected chrome without automatic
retry, stop frame consumption immediately and resume on explicit selection.
Application handles RuntimeStopping, last-tab and closed-workspace endings,
including hidden sources; ordinary network loss remains retryable.

Six affected Release groups pass, with 12 adapter and 32 window entries; two
Qt-free sanitizer groups pass. Current native Quick passes 88 without warnings.
Strict broad lint and actual editor checks pass. The first parser nesting/direct
include lint failures are retained and fixed without profile changes. Adapter
sanitizers pass/exit zero; window assertions pass 32 but exit leaks remain:
224,996 bytes/912 allocations. Qt logs retain the runtime's three 120-byte
`*_fetchInitializingClassList*` suppressed allocations, with no LSAN_OPTIONS or
local suppression. Do not call the Qt exit wholly unsuppressed clean.

Paired real owned SSH runtime stops/restarts retain Local isolation, destination
identity and restore pane 1 generation 2. All owned exits/master cleanup are
normal. Controlled metrics preserve repeatable CPU history; RuntimeStopping and
restart are real. The pre-fix Qt outage picker differs by 1,779 pixels. The fixed
full picker, two terminal regions and two footers now match original Zig exactly.
Full windows retain 8,435/10,282 header/sidebar differences. Local data is
`live-terminal-session-*` and `terminal-session-paired-*`; accepted Qt GUI SHA256
is `33fdd6f392fc48fb20e9c09ca08d1e1fa912e5bee44d71680cbe47f56fe4f5ec`.

Continue workspace/worktree navigation/history, including selectWorkspace and
openWorktree cache-miss behavior against original handoff procedures, then the
remaining PARITY.md gates. Optional pointer/15-pixel investigations below are
still unqualified. Serialize all native/offscreen UI runs; do not edit C++ during
active builds. Keep old manifests historical. The persistent goal stays active,
unbudgeted and incomplete; a checkpoint is not finalization.

### Runtime handshake continuation

The latest preceding local commits are `1978ec6be` (runtime link/offline input)
and `e17e2b6df` (retained metrics/modal alpha). The next implementation adds
bounded handshake/refusal parity; read
`services/gui-cpp/measurements/runtime-handshake.md` and its verifier/manifest.
Original-source Release/core sanitizer comparisons match 79,367 cases. Two
policy and three prefix negatives fail before their respective fixes. The
socket/parser enforce 18-byte receive capacity before allocation, then upgrade
on acceptance; pipelined 20 KiB data passes. Six affected Release groups pass,
two Qt-free sanitizer groups pass, and the Qt adapter passes 11 entries. Broad
lint and actual Neovim diagnostics are clean. Current native Quick passes 88
without QML warnings. Window sanitizer passes 28 assertions but exits with
259,104 leaked bytes/1,004 allocations. It and the successful Qt adapter print
the runtime's 3-allocation/120-byte `*_fetchInitializingClassList*` suppression
table despite no LSAN_OPTIONS/local suppression; Qt-free stderr is empty.

Accepted real owned SSH schema/capacity runs cover both GUIs. Discovery remains
unaltered; only the GUI bridge receives controlled ServerReject bytes. Each
schema run observes one refusal and no automatic retry for >=2.6 seconds after
repair; Enter retries. Each capacity run observes five automatic refusals before
repair and explicit immediate retry. Offline input is discarded, Local remains
isolated, and original remote pane/generation and stable window identity return.
All owned GUI/runtime/sshd exits and SSH master cleanup are normal. Each failure
pair matches three full terminal regions, three footers and the full picker.
Whole offline windows retain 15 status-glyph pixels; outage/recovery retain
7,587/10,291 header/sidebar pixels. The first Qt schema fixture accidentally
altered endpoint discovery, entered setup and timed out; it is rejected and
retained. No assertion/profile/threshold is weakened. Global gates remain open.

Next implement/qualify the intentional RuntimeStopping connection/status gap:
original GuiAdapter.handle returns to Local but retains its last connected
summary; current Qt later marks the hidden source lost and retries. Read the
original runtime_messages/Client/runtime I/O lifecycle before choosing the
transport/session transition. Keep network loss retryable and preserve explicit
remote re-selection/recovery. Then continue other PARITY.md gates; checkpoints
are not completion. Goal remains active and unbudgeted.

An optional `--chrome-pointer` diagnostic is still unqualified. Its Qt-1 capture
freshness fails; Qt-2 adds owned actor PTY output after movement but still sees a
presented drawable older than pointer input. Both GUI fixture waits abort; owned
cleanup succeeds. Preserve ignored `live-chrome-pointer-qt-{1,2}` and investigate
frame/input ordering without relaxing freshness. No Zig pointer pair has run.
A rejected straight-alpha icon experiment leaves the same exact 15 pixels;
`chrome-icon-blend-*` source/metadata and live comparison retain it. The product
icon implementation is restored. Serialize all native/offscreen UI runs.

Personal now has its own pinned Ghostty, FreeType and HarfBuzz dependencies,
LLVM 23/Qt 6.12 Release build in `services/gui-cpp/out`, core sanitizers in
`out-core-sanitizers` and native sanitizers in `out-native-sanitizers`.
`gui-editor` is built and the actual Neovim configuration attached clangd to
the machine registry header without diagnostics. The local reference runtime
is `services/gui-cpp/out-dependencies/reference-runtime/bin/telar`. Build it
with `DEVELOPER_DIR=/Library/Developer/CommandLineTools`, the repository's
`packaging/macos/sdk-libc.sh` output and `-Dtarget=aarch64-macos.13.0 --libc ...`:
the active Xcode 27 SDK failed while building Zig's libc++ (`INFINITY`). All
artifacts stay inside this worktree, and the separate main checkout is intact.

The bounded machine registry/picker checkpoint is commit `45e322f0`, with an
8,091-operation original-source comparison and archived validation. The later
window adapter extracts one allocator-owned `qt::MachineClient` per admitted
slot, retaining shared window resources. It validates two framed socket
connections, hidden presentation settlement, cached summaries and origin
isolation for frames, held keys, notification callbacks, sounds and pending
external links. Its expanded oracle covers 7,360 operations with remote
selection and the original stopped phase. Read
`services/gui-cpp/measurements/machine-window.md` and its validation manifest
for the current scope. Earlier reports and manifests remain historical.

The admission checkpoint loads saved profiles and starts enabled SSH clients
in the normal executable. The later [machine UI](../services/gui-cpp/measurements/machine-ui.md)
checkpoint wires all 29 catalogue actions, the picker, cyclic selection,
rename/remove, two-step forms and local setup command tabs. Prompt geometry
matches 5,329 original-source hosts in Release and sanitizers. Paired native
captures use an own Zig GUI reference, built unchanged with the installed
macOS 15.4 SDK (newer SDKs fail the CoreFoundation cimport). Its binary is
`services/gui-cpp/out-dependencies/reference-gui/bin/telar`. A native capture
caught the macOS physical-Control mapping bug; the picker now uses the existing
keyboard adapter, and its tests use the platform modifier. Read the new report
and manifest for qualified runs and pixel differences. The subsequent
[real SSH checkpoint](../services/gui-cpp/measurements/machine-live.md) exercises
the production GUI with an owned OpenSSH server on loopback and two isolated
original runtimes. Remote/local/remote switching preserves separate input and
pane contents, and GUI/runtime/server cleanup succeeds. Its private fixture
keys are not archived. Further host platforms, live failure/recovery, setup
installation and source composition remain open. The subsequent
[initial-machine launch](../services/gui-cpp/measurements/machine-launch.md)
checkpoint wires `--remote`/`--machine`, local-label selection, disabled/temporary
pinning, remote home/command adoption and the original 64-argument startup limit.
Five selected Release and sanitizer groups pass, and real SSH runs cover both
selectors. Fourteen profile-window cases include initial-file failure, capacity,
slot reuse and launch arguments. A first current Quick suite has one
notification-focus failure; traced sequence/full runs pass, but its cause is
unproven and its gate remains open. Keep that failed run and the traces. Continue
source composition, live recovery/setup and all remaining PARITY.md gates.
The later [notification retirement](../services/gui-cpp/measurements/notification-retirement.md)
checkpoint adds a deterministic real-protocol focus regression and queues
restoration after a disabled control retires, fenced by window, machine, pane
and attachment identity. Current Cocoa/Metal Quick has 85 passes and no QML
warnings; two selected Release CTests pass. Both corresponding sanitizer suites
pass assertions but fail exit leak detection (213,024 bytes/817 allocations and
174,444 bytes/870 allocations); preserve those full reports, with no local
suppression. The earlier pointer-close failure's exact timing remains unproven.
The later [global machine activity](../services/gui-cpp/measurements/machine-activity.md)
checkpoint supplies all live replicas to the shared sidebar, with cached source
versions and owned action targets fenced by admission/client/connection and
agent session or command workspace. Five Release groups and three core sanitizer
groups pass; five new window cases cover hidden metadata, coordinator nesting,
colliding IDs, canonical waits, cancellation and restarted revisions after a
real socket reconnect. Profile-window sanitizer exit passes; machine-window has
13 assertion passes but fails exit leaks (247,716 bytes/907 allocations in the final run; the earlier 268,712-byte/932-allocation failure is retained).
Real loopback SSH captures of both GUIs prove remote-card input isolation and
normal resource cleanup. They expose missing machine chrome: the sidebar row
shifts activity by 23 logical pixels; diagnostic alignment leaves 15 pixel
errors but actual-position acceptance is OPEN. The current full native suite is
84 passed/1 failed in routed notification-focus retirement. Its diagnostic's
focusedPane=0 means root keyboard ownership, not a missing session pane. Keep
that failure and investigate with actual focus/pane transition observations.
The subsequent [delivered notification removal](../services/gui-cpp/measurements/notification-removal.md)
checkpoint reproduces that routed failure with an attached pane and visible
terminal: removing the focused delivered card can skip its disabled-record hook.
The overlay now captures matching focused ownership on rowsAboutToBeRemoved,
then uses the same deferred numeric origin guards. A still-enabled-card
regression fails when that new connection alone is removed and passes with it.
Keep the first default-lifetime ablation, which was a false positive after
expiry, and the corrected longer-lived negative control. Current full native
Quick has 86 passes/0 failures/0 skips/0 QML warnings, and two Release groups
pass. Native sanitizer assertions pass (13 and 8 entries), but both exit leak
checks fail: 268,712 bytes/932 allocations and 170,884 bytes/838 allocations.
Temporary probe logging was removed; raw sources and logs are archived. The
older pointer failure's exact timing remains unproven. The subsequent
[machine chrome](../services/gui-cpp/measurements/machine-chrome.md) checkpoint
integrates the original sidebar MachineSwitcher and top-bar MachineSegment.
The native shade Retina switcher/segment regions match exactly (18,156 and
8,320 pixels); cards now occupy their actual original coordinates, with 15
remaining differences in 154,056 pixels. Actual segment/sidebar clicks and
remote-card input isolation pass through loopback OpenSSH, with normal cleanup.
Keep the first chrome-navigation exit-wait failure: its harness timed out before
the existing 45-second smoke timer, after input isolation had passed. Original
widget/layout geometry matches 4,728 controlled hosts after correcting floored
fold centering; the pre-fix comparison has 1,389 differences and is archived.
Written machine colors match 47,646 original cases. Both comparisons and core
tests pass ASan/UBSan with leak detection. Three Release groups pass; current
native Quick retains 86 passes and zero QML warnings. Instrumented window has
sixteen assertion passes but fails exit leaks (203,128 bytes/859 allocations).
Offscreen controls retain a roughly 600 ms missing Sans Serif alias warning,
also seen in pre-existing notification controls; native runs do not emit it.
Read the new report/manifest. The subsequent
[agent peek checkpoint](../services/gui-cpp/measurements/agent-peek.md) adds
secondary agent activation, bounded per-session recent text, source/window/agent
session fences and the original open/stop/diff/prompt commands. Real SSH proves
remote prompt isolation and actual focused/blocked refusals (codes 12/9), without
terminal input on rejection. Scoped shade Retina wide/narrow modals match
1,624,320 and 309,600 pixels; the retained card hover perimeter and blocked
refusal region match 5,216 and 177,472 pixels. A resize regression caught cached
QML geometry retaining an editor after C++ reduced its height to zero; shared
post-settlement peek notification fixes it, with the failing probes retained.
The first blocked Qt check read only AXLabel; a diagnostic shows the native
Dismiss notification AXButton in AXTitle, and the corrected harness checks both
attributes plus the role. Keep both failed harness invocations. Original command
and last-lines bodies match 2,527 cases in Release and ASan/UBSan; eight adjacent
session groups also pass both builds. Two Release groups pass with 21 window
entries. Native Quick passes 86 entries with zero QML warnings, after an earlier
85/1 configuredBindings equality failure; its exact cause stays unproven, and
the assertion now retains full differing screens. Window sanitizer assertions
pass all 21 entries but exit leak detection fails (235,304 bytes/1,004 allocations).
Keep the full report unsuppressed. The subsequent
[real SSH recovery checkpoint](../services/gui-cpp/measurements/machine-recovery.md)
validates loss and automatic recovery of an owned OpenSSH bridge in both Qt and
the unchanged Zig GUI. The runtime stays alive; its GUI client disappears during
the cut and reconnects with a new id/generation while retaining window identity.
Local receives input during the outage and the same remote pane/generation
receives input after reconnect. Both complete resource cleanups exit zero. The
native outage picker retains five differing pixels in 1,187,840 (two boundary
and three single-channel hint pixels); no masking/alignment is used. Only the
measurement harness changes; C++ binaries remain identical to the qualified
peek checkpoint. The subsequent
[native setup checkpoint](../services/gui-cpp/measurements/machine-setup.md)
validates missing-build picker/real declined confirmation in both GUIs and an
actual managed OpenSSH installation through the original development build's
`--binary` path, with agents/config/logins explicitly skipped. The executable's
SHA256 and 0755 mode match; repeat returns ready=true/changed=false. Both windows
observe the profile's managed-program update, admit it without manual reload and
execute input in its remote shell. Local/installed runtimes, GUIs, sshd and SSH
masters all exit zero. The managed-terminal region matches 2,336,768 pixels; the
missing-build picker retains three one-level green-channel hint differences in
1,187,840. The first Qt fixture polls a retired setup pane for final output and
its injected helper aborts; recovered read-only history proves n/exit-zero. The
corrected live fixture checks that history plus unchanged profile/installation.
Keep the failed run and recovery provenance. Affirmative GUI release downloads,
agent/config/login setup, other platforms and complete visuals stay open. Read
the new report/manifest. The subsequent
[palette hint opacity checkpoint](../services/gui-cpp/measurements/palette-hint-opacity.md)
replaces QColor-encoded hint alpha with inherited Qt item opacity, preserving
the original float32 scalar. The independent control measures 0.649999976158
versus QColor's 0.650003790855. The full setup picker now matches 1,187,840 pixels.
For the recovery pair, both actors clear their initial fixture command echo;
this removes differing underlying contents at two rounded-boundary pixels,
without alignment/masking or changes to captured images. The full controlled
outage picker also matches 1,187,840 pixels. The managed terminal remains exact,
all real setup/recovery cleanup exits zero and current native Quick passes
86 entries, but emits one DelegateModel::cancel index-out-of-range warning in
historyGeometryAndFocusSurviveInspection. The verifier caught it; keep the raw
log and investigate its cause, without filtering/suppressing it or inferring it
from a subsequent passing run. Keep the earlier three/five-pixel comparisons.
Other translucent roles, themes/densities, native exit leaks and comparative
performance remain open. The subsequent
[history delegate retirement checkpoint](../services/gui-cpp/measurements/history-delegate-retirement.md)
reproduces that warning with paused incubation and an actual ListView flick;
an empty reply yields index-out-of-range 24/0 and fails the controlled test.
HistoryPanel now disconnects before rows are removed and reconnects after Qt's
structural notifications finish. Its original row structure is preserved; the
intermediate loader/record-cache prototypes and failures are archived. Empty and
uniquely filtered one-row replies, visible counts, finished incubations and
wide/narrow inspection focus/geometry pass. Current native Quick has 88 passes
and zero QML warnings. Clang-tidy and actual Neovim clangd are clean. Five native
sanitizer entries pass without warnings, but exit leaks remain (554,436 bytes in
2,808 allocations). The first sanitizer exit observation is interrupted by an
external AeroSpace query timeout; do not claim its exit result. The accepted
controller only admits the initial owned window and then observes process exit.
The older configuredBindings timing failure remains unproven. The subsequent
[intentional runtime-stop checkpoint](../services/gui-cpp/measurements/runtime-stop.md)
returns to Local on remote stop/last-workspace closure and closes only for local
terminal status. Four pre-fix policy checks fail; 27 final window entries pass.
Both actual owned OpenSSH runtime restarts return outage input to Local, then
restore a new remote shell/pane generation with stable window identity and normal
cleanup. The first Zig driver incorrectly expected the outage input to be
ignored; retain that failed contract and the pre-fix Qt behavior. Two initial
window fixtures lacked valid dimensions, and an early lint saw a stale generated
moc; retain those failures without counting them as product negatives. Current
native Quick passes 88 entries without QML warnings. Window sanitizers pass
27 entries but exit leaks remain (256,632 bytes/984 allocations). The actual
outage picker retains 1,804 status pixels: Zig holds its old connected CPU sample
while Qt reports unreachable. Complete stop-status/retry policy stays open; do
not infer full visual acceptance from successful input recovery. Read the new
report/manifest. The subsequent
[actual permanent SSH failure checkpoint](../services/gui-cpp/measurements/ssh-permanent-failures.md)
passes authentication and host-key rejection/recovery in both GUIs through real
OpenSSH, keeping strict trust. Owned ControlMasters are stopped before fresh
checks. After repairing fixture keys, no new SSH invocation appears during the
bounded 2.6-second observation; native Enter retries, retains window identity and
routes text to the original remote pane/generation. Local input stays isolated.
All four complete cleanups exit zero. Both complete controlled outage pickers
match 1,187,840 pixels each. Binaries are unchanged from runtime-stop; no product
rebuild/test is used to infer these SSH results. Keep stop-status pixels and
native exit leaks open. The subsequent
[peek labels/native action checkpoint](../services/gui-cpp/measurements/peek-labels-actions.md)
compares the unchanged original facts/title body and Agent/WorktreeRow methods
against production PeekLabels: 7,456 cases match in Release and clean core
ASan/UBSan, including 1,502 full-capacity facts. Both native /open and /stop pass
through owned OpenSSH in Qt and Zig, isolating text/SIGINT to the inspected remote
pane; stop has its actual correlated protocol acknowledgment. All four complete
cleanups exit zero. Both before/after modal-coordinate rectangles match
1,624,320 pixels each for each action. Clang-tidy and actual Neovim clangd are
clean; GUI binaries remain unchanged. Native task/plan projection/rendering and
actual /diff stay open at that checkpoint. The subsequent
[task workspace handoff checkpoint](../services/gui-cpp/measurements/task-peek-handoff.md)
reproduces a real cross-workspace /open failure in Qt while Zig succeeds. Qt now
detaches before opening, retires screens only after accepted target delivery,
repairs partial departures, fences busy requests and falls back once for a gone
pane. Six new regressions pass; ten core groups pass Release and clean ASan/UBSan.
An old session fixture needs its previous canonical snapshots completed before
generation replacement; all old assertions remain. Keep that nine-pass/one-fail
run and the lint failures (swappable optionals and complexity 26/25).
Actual task-with-plan /open and /diff now pass in both GUIs over owned SSH, with
original argv, real Git patch, new shell input and normal cleanup. Keep the
pre-fix Qt failure and the first diff driver's incorrect created=true expectation:
original addTab returns false for an existing workspace. An early read-only
catalog query inherits the harness cwd; its optional mixed external catalog is
excluded with hash/reason, and the final collector uses its own repository.
Both full native modals match 1,624,320 pixels, and the entire terminal after
each action matches 2,336,768 pixels. Current Release window/native Quick pass
27/88 entries with no native QML warnings; instrumented window assertions pass
27 but exit leaks remain (256,632 bytes/984 allocations). Actual Neovim clangd
and final lint are clean. Continue complete navigation/task-state/source matrices,
remaining build/protocol failures, active transient offline input, native
open/stop/diff, full task/plan peek, exit leaks/performance and all remaining
PARITY.md gates. Complete
theme/density/Linux visuals, native exit leaks and comparative performance stay
open. The subsequent
[runtime-link checkpoint](../services/gui-cpp/measurements/runtime-link.md)
adds original bounded UTF-8 failures/headlines, capped exponential retry and the
centered workbench dim/status. Text/backoff matches 4,988 source cases and status
geometry matches 5,536 in Release and clean ASan/UBSan. Keep the first saturated
counter prototype's 84 differences, the initial synchronous-failure observation
fixture failure, both no-test CTest selections and all initial lint findings.
Active transient and actual authentication-failed SSH scenes discard offline
input, keep Local isolated and restore the same remote pane/generation. Their
entire offline terminals match 2,336,768 pixels each; all owned cleanup exits
zero. The original keeps a cursor on its stale screen; removing attachment from
the paint-only cursor policy removes 720 differences without enabling input.
Disabled cards also retain Qt hover after losing their hit target: a controlled
regression fails before an enabled gate and passes afterward. The final transient
whole window still differs in 2,705 pixels: 15 card and 2,690 metric-footer pixels.
Original link loss retains metrics while Session.disconnected clears them;
continue that projection and the older runtime-stop status gap. Current native
Quick passes 88 entries without warnings, and 8 card/36 scene/27 window entries
pass. Three link/transport groups pass Release and clean native ASan/UBSan;
window assertions pass 27 but exit leaks remain (257,028 bytes/988 allocations).
Final lint and actual Neovim clangd on the model/controller/adapter test are
clean. Read the report, archived verifier and manifest. Continue remaining
handshake/build failures, full connection/navigation/task matrices, metrics,
theme/density/Linux, native exit leaks and measured performance. No global gate
is closed. The subsequent
[retained metrics checkpoint](../services/gui-cpp/measurements/retained-metrics.md)
keeps host samples, CPU history and proxy status during loss, then clears them
at replacement adoption. It also notifies metric bindings on machine selection
and active reconnect. Both pre-fix core/window regressions fail. Three affected
groups pass Release and clean ASan/UBSan. Its optional owned framed proxy passes
all requests and other messages unchanged, replacing only the first metric per
connection with distinct Local/Remote revision-one values and withholding later
metrics for deterministic visual history. Actual SSH loss/input isolation and
restored actor identity still pass in the final corrected fixture. Keep the first
three controlled runs' cleanup failure: the proxy moved the local endpoint and
the collector missed its SSH master socket, which the verifier rejects as a
missing control_stop receipt. An exact-ControlPath/PID audit terminates only
those three owned orphans and records disappearance with unknown exit status.
Final collection visits both owned socket directories and confirms master exit
before deleting proxy endpoints. All final resources finish normally. Offline and
recovered complete footers match. The dimmed Local footer initially differs in
136 one-level pixels: QColor encodes 0.25 as 0.250003814697. Giving CommandDialog's
black backdrop item opacity preserves original 0.25 and makes all three complete
footers match 122,720 pixels each. All three terminal rectangles match 2,336,768
pixels each, and the full picker matches 1,187,840. The offline whole window
retains 15 card pixels; Local-picker/recovered full scenes retain 7,587/10,291
header/sidebar pixels. Continue these actual-position differences and the older
intentional-stop status gap. Current native Quick passes 88 entries without
warnings, and window suites pass 28 assertions. Instrumented exit still leaks
261,084 bytes/1,011 allocations; keep the initial 259,472-byte/1,002-allocation
report too, without suppression. Final lint and actual Neovim clangd are clean.
Read the report/manifest/verifier. Remaining handshake/build failures,
navigation/task states, Linux/theme/density scenes, native exit leaks and measured
comparative performance remain open. No global gate closes at this checkpoint.
The window-adapter checkpoint records 82 Cocoa/Metal scale-1
passes, before the transport/profile changes, after the
owned-window focus/geometry barrier; twenty selected regressions pass.
Native sanitizer assertions pass, but exit leak acceptance remains OPEN.
An independent Qt-only font-metrics control also reports leaks. Retain failed
runs; do not suppress them or infer that every GUI leak is explained by that
control. The standalone opener and expanded registry oracle pass sanitizers
with leak detection enabled.

The following transport checkpoint adds `qt::RemoteBridge` and
`RuntimeConnection::openRemote`: bounded discovery and stderr, cancellable
request generations, managed SSH options and a native socketpair carrying the
existing framed connection. Read `measurements/machine-transport.md` and its
manifest. Controlled process suites pass Release and ASan/UBSan with leak
detection enabled; actual SSH-host validation remains open. An earlier fixture
that reused the Qt-linked test executable failed discovery because its child
exited with a CoreFoundation leak; the retained independent control reproduces
64 bytes. The accepted fixture is a separate protocol-only executable with no
Qt linkage, instrumented in sanitizer builds. No suppression or disabled leak
check was introduced.

Saved-profile admission is now implemented in `qt/machine_profile_controller.cpp`.
Read `services/gui-cpp/measurements/machine-admission.md` and its manifest. It reconciles stable
IDs, program/destination incarnations, pinned temporary rows, retirement to
local and destination-scoped identities derived from the local window lease.
Discovery gives the session its owned home/shell defaults. Managed runtime
location and secure directory preparation have independent coverage. Four
profile-window cases run through the production source and subprocess path;
six selected Release and five ASan/UBSan CTests pass, including the window
cases, with leak detection enabled. The normal Cocoa/Metal executable also
opens a shell on an isolated owned reference runtime. Its first smoke fixture
contained an invalid local label; preserve the rejected capture and the later
valid one. The later machine UI wires the four actions. Continue actual SSH, setup
installation, source composition and remote CLI launch, then all remaining
PARITY.md gates.

The sections below describe the transfer baseline; prefer this checkpoint and
the latest window-adapter report where the implementation has since advanced.

The user explicitly requested moving the ongoing implementation to their saved machine Personal. Continue implementation here until the complete objective is met. This is a continuation, not a new GUI or a redesign. Keep this task active across checkpoints. Use available goal facilities to pursue the complete objective if supported. Do not declare completion from an incremental checkpoint.

## Objective and user requirements

Implement services/gui-cpp as the C++ Qt Quick version of Telar's current Zig GUI. Achieve complete functional and visual parity and equal-or-better measured performance. The Zig GUI is the reference. Keep application/domain code separate from native platform code for macOS and Linux. Reuse project components before adding anything. Explicit allocator parameters and concepts/templates follow runtime-cpp; dependencies are selected at compile time, including test implementations, without added virtual dispatch. Components should be usable in tests/experiments without constructing the whole GUI. Keep names descriptive, signatures on one line, at most five arguments, braces on ifs, blank lines between logical blocks, no magic constants, and no explanatory comments where expressive code suffices. Speak Spanish to Adrian and send substantive progress updates at least every 60 seconds. Code, identifiers and commits are English. Read AGENTS.md. Keep the broad existing clang-tidy profile and thresholds unchanged; do not add suppressions or weaken tests. Maintain the existing .clangd configuration and actual editor usability.

## Snapshot and isolation

This worktree starts from a transfer commit built using an alternate Git index. The source machine's branch, HEAD and normal index were preserved. It includes the complete GUI program sources, all top-level measurement reports/manifests, the complete latest machine-presentation and native-window-control evidence directories, and 33 modified shared files identified from the built GUI's dependency graph. Those shared files are a required baseline; avoid unrelated changes. The other large historical raw capture directories remain on the source machine and were not transferred. They are not missing implementation. Do not rewrite old validation manifests because current sources later evolve. Request historical artifacts through the coordinator when actually needed. No build trees, VM disk, SSH keys, credentials or personal configuration were transferred.

## Current state

The port is substantial but experimental. Read services/gui-cpp/README.md and PARITY.md first. The action catalogue remains 25/29. The four machine actions machine_picker, next_machine, previous_machine and add_machine are still not wired. The running Qt window still has ONE local RuntimeConnection and GuiSession. Complete visual acceptance and comparative performance remain OPEN. Some scoped native pixel regions already have exact reference comparisons, but do not extrapolate them to other states/themes/densities. Existing comparative latency/RSS losses and historical native sanitizer gates remain open.

The machine domain foundation is implemented in machines/: exact saved profile/JSON semantics, stable IDs, validated SSH destinations/commands, remote discovery and SSH error policies. The original-source oracles cover 14,494 profile cases and 15,638 remote cases on macOS/Linux, including sanitizers. Profile persistence adds allocator-aware atomic transactions, owner-only native files, safe symlink handling and an independent Qt worker (qt/machine_profiles_source.*). It is not yet connected to machine navigation. Profile components have macOS/Linux Release and ASan/UBSan evidence. A Darwin O_CREAT race was reproduced independently and fixed following the original exclusive-create-then-open sequence. Do not regress it.

The latest production change is Session presentation in application/session.hpp: presented(), setPresented(bool), settlePresentation(). Hidden startup keeps metadata and defers initial panes/layout attachments. Hiding waits for tracked pane operations and canonical snapshots, releases input ownership, detaches without closing processes, destroys pane-owned screens/graphics, retains layouts and a focused-pane bookmark. Returning reopens that pane, with one source-workspace fallback when it is gone. Partial transport failure can retry committed detaches safely. Hidden snapshots do not reconstruct screens and hidden agents are not acknowledged. Deferred layout data is owned before decoder reuse. A future multiple-client adapter MUST call settlePresentation after each client's events, matching src/client/machines/machine_presentation.zig.

Thirteen presentation cases are in tests/machine_presentation_test.cpp. Sixteen selected session CTests pass in macOS Release, macOS ASan/UBSan, Linux Release and Linux ASan/UBSan, with leak detection enabled. All relevant source/binary hashes and logs are retained. The expanded suite exposed an old editor test fixture that attempted 64 horizontal panes in 80 columns; recompiling the previous source snapshot reproduced it. The fixture now computes sufficient width and verifies every split, retaining its capacity assertion. The owned Linux VM was stopped after evidence download.

The latest test-only change adds window/focus diagnostics to tests/quick_test.cpp and optional TELAR_GUI_TEST_WINDOW_READY. When set, initialization waits for a controller-owned ready file and then a synchronized frame. Production does not read that variable. Native tests ran under AeroSpace, which moved/resized their window during assertions. A matched binary failed in tiling and passed in floating mode; Cocoa traced 600 pixels being replaced by 880 without a Qt setGeometry request. A floating-only controller could still finish too late or leave the window inactive. A controller that prepares the owned window's floating layout AND focus before publishing the ready file passes two consecutive complete Cocoa/Metal scale-1 runs: 82 passed, 0 failed, 0 skipped each. It changes only the owned GUI PID's windows, no global WM policy. The original editor-focus failure lacked full state, so its exact cause is unproven. Do not blindly retry UI tests until green; inspect environment/state and retain failed attempts. Do not change product behavior to accommodate a local WM.

Latest validation manifests:
- machine-presentation-validation.json SHA256 170260a0ad3d09f4e9a15b78a34ab9870f6f5994d5e1f8a9e48ce5f5428253c0.
- native-window-control-validation.json SHA256 431d9c2f10e1cb91c82221fd9b2585227934c282c9bdfd2af92ae82311b7d0db.
Use the latest native-window-control verifier with --check-current-source at this checkpoint. Earlier current-source checks appropriately fail after later source changes; their archived evidence checks still have their own scope.

## Immediate next implementation

Integrate the machine components with the window and runtime connections. Study src/client/machines/Machines.zig, machine_presentation.zig, the machine picker source, workspace handoff and SSH connection/discovery sources before changing anything. Do not duplicate the whole Application per machine: fonts, window resources, input dispatch, notifier and sounds belong to the shared window. Extract one stable per-machine client/session/connection and route active presentation through the existing shared Application.

Important integration constraints: cached machine summaries are refreshed on events, not by scanning hidden models every frame. There are 17 slots, local slot zero; preserve stable IDs and admission generations, including destination changes and slot reuse. Prevent old async replies, notifications and sound completions from targeting a new/current machine merely because pane IDs match. Invalidate terminal/model view identity across machine switches even when remote pane IDs and revisions coincide. Window identity leases need a destination namespace for remote endpoints. RuntimeConnection currently uses QLocalSocket with framing/backpressure; consider a native socketpair plus QProcess SSH stdio bridge to retain one concrete framing transport. Only local sockets use peer-UID authentication. Follow the existing validated discovery/SSH policies rather than inventing commands or trusts. The original managed ControlPath hashes SHA256 destination with little-endian selection, not simply the first twelve hex characters.

The original picker includes disabled rows, prioritizes label scoring before destination fallback, preserves ties by slot, puts Add last, enables a disabled row on Enter, toggles on Shift-Enter, keeps local toggles inert, and has setup/rename/remove behaviors. Preserve those semantics AND native visual presentation. Inspect original sources for exact details. The future implementation must support local and remote runtime metadata while only the active client retains screens. Source profiles use qt::MachineProfilesSource independently; preserve owned strings, generation handling, reentrancy and cancellable lock waits.

Continue other acceptance gaps from PARITY.md after machine integration. Keep measurements paired to the original with exact fixtures. Do not claim global performance parity from theoretical improvements.

## Personal environment and setup

Personal is a separate ARM64 macOS host with an existing clean /Users/adriangonzalez/sandbox/telar checkout on main. Preserve that checkout. Codex 0.159.3 is installed at /Users/adriangonzalez/.local/bin/codex and login status is ChatGPT authenticated. LLVM 23.1.2 is at /opt/homebrew/opt/llvm/bin. CMake 4.4.3 is installed. The coordinator installed Qt 6.12.0, Ninja 1.13.2 and pkgconf 3.0.10. Homebrew's combined install returned 1 because /opt/homebrew/bin/ninja already existed; DO NOT overwrite that executable. Use /opt/homebrew/opt/ninja/bin/ninja or prepend /opt/homebrew/opt/ninja/bin to PATH. Ignore unrelated tap-trust suggestions; no new tap trust was authorized or needed. The runtime's PATH is minimal. Prepend /Users/adriangonzalez/.local/bin:/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/ninja/bin:/opt/homebrew/bin:/usr/local/bin before system paths for your commands.

No build artifacts moved. Follow README Build and run to build the pinned dependencies, including libghostty-vt, then configure this worktree's services/gui-cpp/out with LLVM 23 and CMAKE_EXPORT_COMPILE_COMMANDS. Never reuse absolute /tmp build paths from the source machine's evidence. Build gui-editor for Neovim, run targeted checks for your changes, and confirm progress in your agent session. Keep all work in this worktree. Do not publish or merge without user instruction. Commit useful reviewed checkpoints to this task branch so they can be fetched back. Avoid requiring the whole expensive suite for small changes, but central-session changes warrant the affected regression groups. Maintain factual status and continue implementation autonomously.

## Portable transport note

Telar refused the original transfer ref because this repository uses Git LFS. The final transport commit preserves history and materializes eleven existing wallpaper assets as ordinary Git blobs, verifying their sizes and SHA256 against the original LFS pointers. It changes .gitattributes only in this transfer lineage to make this checkout self-contained. The source checkout retains its original attributes and index. This transport accommodation is not a product change. Keep later implementation commits separate from the transport commits when bringing work back.
