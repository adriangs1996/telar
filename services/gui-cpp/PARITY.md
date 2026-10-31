# Port acceptance status

The C++ Qt Quick client is an experimental implementation, not a completed
replacement for the Zig GUI. Functional parity, visual parity and
equal-or-better performance remain acceptance requirements.

The [UTF-16 codec compatibility evidence](measurements/utf16-codec-policy.md)
adopts the installed Qt encoder's invalid-surrogate byte count once, preserving
a single allocation-free bounded scan in the independent component. An unchanged
controller regression retains 140 bytes against the 128-byte limit on Qt6.8
before the correction, then passes on both SDKs. All-code-unit field comparisons
also close the earlier 188292/190338 mismatch. Both SDKs pass eight-unit broad
analysis, actual editors, ten field entries and eleven affected native entries.
Native ASAN exits remain 1 on Mac (477585/2887 leaked bytes/allocations) and Linux
(147982/148); the Mac field suite exits8 with256024/838. A first reordered test
list's notification-cooldown failure remains raw evidence. Other Qt versions,
native leaks/latency, complete appearance and full-client performance remain open.

The [History entrance motion evidence](measurements/history-modal-motion.md)
adds the original 220 ms cubic modal/inspector reveal to the shared window clock.
Both SDKs match 527 sequences/32,802 original samples and pass five lifecycle
entries. Synchronized native observations start at opacity 0 and preserve the
inspector divider; settled modal regions match 1,471,968 and 2,919,488 pixels.
Both Linux builds and Mac Release pass 22 native entries. Mac ASAN passes 22 but
exits 1 with 601,242 bytes/3,033 leaks. All four-unit broad checks and actual
editors pass. Seven clock-consumer suites pass 86 assertions on Mac, retaining
ASAN leak exits; Linux passes 85 and exposes an unchanged UTF-16 conversion
mismatch with Qt6.8. The earlier canceled-composition stale drawable remains
required despite an exact instrumented replay. Intermediate animated pixels,
UTF-16 compatibility, native leaks/latency and full-client performance stay open.

The [native History scroll evidence](measurements/history-native-scroll.md)
keeps Cocoa finger phases and fractional deltas before Qt normalization, and
retires the previous terminal wheel recipient when History consumes scroll.
The126820-pixel momentum and4218-pixel discrete negatives become exact across
1471968modal pixels. A causal terminal-handoff regression differs in7827pixels
before the recipient correction and then matches all1519104workbench pixels.
A scale2 catppuccin control matches2919488modal pixels. These controlled public
Qt dispatcher/native-view inputs do not qualify WindowServer queued delivery.
Both SDKs pass37components; Linux passes18native checks in both builds and Mac
Release passes18. Mac ASAN passes17 and fails the unchanged10s selection deadline
(11.45s), then exits1 with640162bytes/3264allocations. Final six/four-unit analysis
and actual editors pass. Earlier failures, native leaks, full appearance/platform
coverage, latency and comparative full-client performance remain open.

The [History event-loop observation](measurements/history-event-loop-observation.md)
adds a bounded two-thread test trace and a native-loop held-pointer regression.
An identical manual/native control reproduces a13.35s manual timeout while native
readiness stays under200ms; reversing order passes both with slower manual waits.
No product clock change follows. Final native suites pass11 assertions on each
SDK/build, but ASAN exits1 on Mac(538134bytes/2772allocations) and Linux
(192bytes/two wl_display_read_events allocations). Broad analysis and actual
editors pass both SDKs. The old test body remains unchanged and all earlier
presentation, latency, leak and full-parity failures remain required evidence.

The [presented History inspector hover evidence](measurements/history-inspector-hover.md)
adds namespace-correct inspector targets from cached physical button geometry.
The 5,709-pixel Copy negative becomes exact across all 24,696 inspector-button
pixels, including a real away/return transition. An initial actual-motion capture
rejected a stale drawable; its cause remains open alongside a successful unchanged
repeat. Original-source 874/35157 and three regression oracles pass Mac/Linux
sanitizers. Both SDKs pass 37 components. Linux and Mac Release pass ten native cases;
Mac ASAN first passes nine and fails the unchanged10s card-selection deadline
(12.7s reported), then an unchanged-binary repeat passes ten. Both raw results
remain required; Linux exits0 and Mac component/native ASAN exits remain8/1. Final seven-unit broad
analysis and 14 real editor checks pass both SDKs. Footer/filter and retained
release regions remain exact. Full input, inspector content, additional visuals,
native presentation/leaks/latency and full-client performance remain open.

The [History footer/inspector action identity evidence](measurements/history-action-identity.md)
corrects retained captures when enter labels change and keeps inspector Copy,
Delete and Visit identities independent of choice. Three source-correct negative
slots become passing checks within 35 component cases on both SDKs. A new actual
pointer path verifies four presented mode changes against runtime output alongside
the four unchanged unpresented-mode guards. Initial native Cocoa/Sway Release
runs pass 10 and exit 0; native sanitizer leak exits remain recorded. Four browse/
inspect pairs retain 21,164 footer, 567,296 result and 24,696 inspector-button pixels.
Final explicit test-tag conversions, broad analysis and actual editors pass both
SDKs. Native Mac ASAN ten-case exit remains 1 with 601,910 bytes/3,034 allocations;
Linux final ASAN exits 0 but its earlier 147,982/148 composition failure is retained.
Full modal input, inspector hover/content, config adoption, leaks,
latency and comparative performance remain open.

The [presented History filter hover evidence](measurements/history-filter-hover.md)
extends the semantic map to all eight header actions, with direct bounded geometry
projection in the original draw order. The retained 6,943-pixel Workspace negative
becomes exact across all 39,584 chip pixels, including actual-motion Workspace,
Agents and Failed controls. Seven native Cocoa pairs preserve the qualified
result/footer regions and old-release/fresh-click behavior. Mixed original-source
777/34794 and footer/row/card regressions pass Mac/Linux sanitizers. Both SDKs pass
32 component cases; Linux ASAN and Release native pass five and exit0, and Mac Release
native passes five and exits0. Mac native ASAN passes five but exits1 with
514559bytes/2791 leaked allocations; final component ASAN exits8 with252992/1068.
Final seven-unit lint and actual editors pass on both SDKs. Complete modal input, enter-runs activation, other
platform/theme/density pixels, latency/leaks and full-client performance stay open.

The [presented History footer hover evidence](measurements/history-footer-hover.md)
adds namespace-correct footer identities, with selection/revision only on submits.
A7778-pixel details-hint negative becomes exact in initial and actual-motion native
controls; all21164 hint pixels and567296 result pixels match, and the held-card
control retains744576 exact pixels. New original-source659/34344 and legacy552/33926
oracles pass Mac/Linux sanitizers. Projection31 cases and final seven-unit lint
plus real editors pass both SDKs. Native Linux Release/ASan pass five cases and exit0;
Mac repeats pass five, but an initial10000ms middle/right-selection deadline failed
and remains an open latency observation. Native Mac ASan exits1 with469617/2660
leaks; component ASan exits8 with268052/1099 despite31 passing assertions. No timeout,
assertion or leak check is relaxed. Header/filter hover, enter-runs activation
identity, complete input/visual/performance and native latency/leaks remain open.

The [History semantic hover and selection motion evidence](measurements/history-semantic-hover-motion.md)
replaces scoped row-admission gates with presented row/card identities and the
original140ms transition. Original-source hover552/33926 and motion530/32819
sequence/sample comparisons pass in Mac/Linux sanitizers. Six guarded Cocoa pairs
match567296 or744576 result pixels, including consumed old release and fresh-click
recovery. Shared-clock six-group checks pass72 assertions on both systems; Linux
sanitizer components exit0. Final native Release passes five cases and exits0 on
both systems. Native Mac ASan passes five cases but exits1 with549106bytes/2805
leaked allocations; Linux native ASan passes five but exits1 with the separately
isolated Qt6.8.2 composition leak147982/148. Broad lint and real editor diagnostics
pass. Cocoa and Carbon clipboard routes are now independently checked and the
real general board change counter is guarded; earlier Cocoa-only isolation was
unqualified for Qt Carbon writes. Footer/filter hover, intermediate animation hit
geometry, other themes/platforms, leaks and full-client performance remain open.

The [self-owned Wayland clipboard correction](measurements/clipboard-wayland-owned.md)
rejects Qt's stale local PNG after registry retirement, including fresh monitor
construction against a surviving retired Qt seat. A dedicated single capture
executor avoids a reproduced GUI stall behind the global pool. Three alternated
pairs preserve bytes and outcomes while reducing the scoped heartbeat gaps from
1506080–1522059µs to13450–14760µs. Final80 capture observations, XCB16 and external
Wayland6 pass in their qualified scopes. Native macOS4 assertions pass but exit
leaks remain537405bytes/2726allocations, without local suppression. The separate
stock Wayland overflow leak and all global parity/performance gates stay open.

The [Wayland selection lifecycle](measurements/clipboard-wayland-lifecycle.md)
releases removed registry state, restores seat/manager bindings and matches the
original16-offer bound and overflow recovery. All61 raw protocol observations
pass. Stock Wayland1.23.1 sanitizer receivers still exit1 with96bytes leaked each;
pristine/patched diagnostic dependency controls identify a lost queued-event
reference with the same receiver binary. The diagnostic library is not shipped.
Qt-self-owned clipboard seat retirement, stock sanitizer acceptance and all global
parity gates remain open.

The [single-paint icon pass](measurements/icon-single-paint.md) removes duplicate
mesh preparation before the existing outer update. Final seven alternated pairs
improve all six rebuild cases8.8–13.9% with seven wins each and no consistently
losing control. Three complete final native SSH windows preserve10,195,200pixels
byte for byte against the previous Qt client; no original visual gain is claimed.
Final native Icon7/Scene37, unchanged broad lint and delivered Neovim diagnostics
pass. Sanitizer assertions pass but exit leaks remain651112/1668912bytes, with no
local suppression. This is a component CPU result, not full-client performance.
The separate [bounded UV investigation](measurements/glyph-uv-bounds.md) retains
all rejected or unaccepted variants. Original Metal4 quads expose a common-atlas
oracle limitation; native original-UV probes still differ. No shader, UV policy
or packed vertex change is adopted. Full functional, visual, platform and
equal-or-better full-client performance gates remain open.

The [activity hover correction](measurements/spatial-activity-hover.md) validates
delivered card geometry and clipping, rejects unrelated exits and permits the
accepted owner's late/detached exit. Four controlled negatives fail before their
corrections; final directed4, native Window36, Quick88 and software Window36/Card9
entries pass. Broad lint3 and delivered Neovim diagnostics4 pass. Corrected AppKit
tracking-owner delivery exposes an earlier verifier limitation: the previous
client and final candidate both have23/11/11 whole-window differences, with exact
visited terminals/footers and12 picker glyph pixels. Earlier physical-cursor
checks alone did not prove Qt received a move. No69608-pixel product improvement
is claimed. Final native ASan/UBSan assertions pass36 but exit1 with1519013bytes
in9279 leaked allocations; no local suppression is used. Full visuals, native
focus/leaks and comparative full-client performance remain open.

The [retained row text pass](measurements/row-text-retention.md) preserves ordinary
row roots and updates compatible chunks in place while retiring surplus nodes.
All 37 original component frames and synchronized node counts match; a stale
revision negative changes 16 states. Seven alternated pairs per variant reject
two earlier candidates. Final decorated rows improve 16.8–17.5% with seven wins
at each of three widths and no consistently losing control. This is a component
CPU result, not full-client or Zig performance acceptance. Release scene/text
suites pass 37/14 entries; guarded original/private/production Quick each pass
88 without warnings. The guard fixes a test's retired-pointer formatting crash
and waits for the exact enabled notification identity. Native final ASan/UBSan
assertions pass but exit leaks remain (1637390/730686 bytes); no local suppression
is used. Full platform visuals, cache-pressure bounds, native leaks and comparative
performance remain open.

The [glyph atlas margin investigation](measurements/glyph-atlas-margins.md)
identifies replicated Qt gutters outside otherwise identical GPU glyph masks.
Transparent borders and standard sampling match all four scoped Metal probes,
but specialized candidates consistently lose component CPU controls and remain
rejected. Complete native pickers improve, while whole-window glyph differences
persist. Identical-path and recorded physical-pointer controls also reproduce an
activity hover error with an earlier native actor. The separate hover pass above
corrects late owner retirement and verifies actual tracking delivery. No renderer
change or global acceptance gate is closed by the margin investigation.

The [workspace navigation checkpoint](measurements/workspace-navigation.md) uses
canonical OpenPane handoffs, bounded original history/saved-layout policies and
root-before-tree restoration. Its 4,922 original-source operations match in
Release and clean core ASan/UBSan; 16 navigation cases, 33 window entries and
88 warning-free native Quick entries pass. Real owned SSH round trips preserve
client identity, pane routing and Local isolation. Delivered activity hover
removes the large reflow differences; both terminals and three footers match
Zig, while complete scenes retain 23/35 glyph pixels and the picker retains 12.
Instrumented card/window assertions pass but exit leaks remain (275,036/224,920
bytes), with the observed Qt runtime suppression table and no local suppression.
In-flight geometry, remaining states/platform visuals, leaks and measured
comparative performance stay open.

The [restored geometry follow-up](measurements/restored-geometry.md) adds two
full-Main cases for visible and hidden restored roots while a window/sidebar
resize is in flight. Both pass Cocoa/Metal without warnings, and the full window
suite has 35 passing assertions in Release and ASan/UBSan. Production is
unchanged; native exit leaks and the global acceptance gates remain open.

The [terminal-session checkpoint](measurements/terminal-session.md) stops the
receive loop at RuntimeStopping/terminal workspace status while retaining the
last connected machine summary. Explicit selection resumes a fresh session;
a read generation discards the previous callback's tail. Four window negatives,
a parser negative and a reentrant socket negative fail before their fixes.
Six Release groups and two Qt-free sanitizer groups pass; the adapter/window
have 12/32 passing entries. Current native Quick passes 88 without warnings.
Real SSH runtime restart keeps Local isolated and restores the remote identity
and new pane generation. Its complete picker, two terminals and two footers match
Zig, removing 1,779 status pixels; whole scenes retain header/sidebar differences.
Native window exit leaks remain (224,996 bytes/912 allocations), with the observed
Qt runtime suppression table and no local suppression. Navigation/history, full
visuals, leaks and measured comparative performance stay open.

The [runtime handshake checkpoint](measurements/runtime-handshake.md) enforces
original 18-byte negotiation storage before allocating, expands on acceptance
and preserves schema/capacity error text and permanent/transient policy. Its
79,367 original-source cases match in Release and clean core ASan/UBSan. Five
socket negatives fail before the changes; all 11 final adapter entries pass.
Both GUIs recover from controlled bridge refusals over real owned SSH, discard
offline input and retain pane/identity isolation. Six full terminal regions and
footers plus two complete pickers match native Zig; whole scenes retain known
15/7,587/10,291 pixel differences. Native Quick passes 88 without warnings.
Instrumented window assertions pass 28 but exit leaks remain (259,104 bytes in
1,004 allocations); Qt runs also report a runtime 120-byte suppression table,
with no LSAN_OPTIONS/local suppression. Intentional-stop status, remaining
navigation/task/platform visuals, leaks and measured performance stay open.

The [retained metrics checkpoint](measurements/retained-metrics.md) keeps the
sample, CPU history and proxy status through outage, clears them at adoption and
notifies machine-selection/reconnect bindings. Both pre-fix regressions fail;
three affected groups pass Release and clean ASan/UBSan. Controlled SystemMetrics
over actual owned SSH give three exact 122,720-pixel footers, three exact
2,336,768-pixel terminal regions and an exact 1,187,840-pixel picker. Modal item
opacity preserves the original 0.25 and removes 136 dimmed-footer differences.
Current native Quick passes 88 entries without warnings; window assertions pass
28, while final exit leak detection fails (261,084 bytes/1,011 allocations).
The complete offline scene retains 15 card pixels; other complete scenes retain
header/sidebar differences. Intentional-stop status, other failure/navigation/
task states, full platform/theme/density visuals, exit leaks and measured
performance stay open.

The [runtime-link checkpoint](measurements/runtime-link.md) adds the original
bounded failure/headline state, capped exponential retry, healthy-session reset
and centered workbench dim/status. Its 4,988 text/backoff and 5,536 geometry
comparisons match original source in Release and clean ASan/UBSan. Real SSH
transient/authentication-failure scenes discard active offline input, retain
Local isolation and restore the original remote pane. Each complete offline
terminal matches 2,336,768 pixels. A controlled disabled-card hover regression
fails before its fix. Current native Quick passes 88 entries without warnings;
8 card, 36 scene and 27 window entries pass. Instrumented window assertions pass
27 but exit leaks remain (257,028 bytes/988 allocations). The final transient
whole window retains 2,705 differences (15 card and 2,690 metric-footer pixels).
Retained metric projection, stop-status chrome, remaining build/protocol failures,
complete platform/theme/density scenes, exit leaks and measured performance stay
open. This does not close any global gate.

The [machine components](measurements/machine-components.md) have standalone
profile and remote-protocol comparisons against the original Zig sources on
macOS and Linux, including sanitizers. These original component comparisons do not establish live SSH, profile
filesystem, switching or visual parity; the later machine-UI checkpoint below
now wires the four machine actions.

[Machine profile persistence](measurements/machine-storage.md) now has standalone
domain, native filesystem and Qt worker validation. The later admission
checkpoint below integrates the window and the machine-UI checkpoint adds
actions; live SSH and complete native visual acceptance remain open.

[Machine session presentation](measurements/machine-presentation.md) now supports
metadata-only hidden sessions, deferred layout restoration and releasing pane
screens without closing runtime processes. The window adapter now owns separate
allocator-backed client/session/connection slots while sharing window resources.
The later profile-admission checkpoint below connects saved rows and SSH
clients. The machine-UI checkpoint adds actions; complete visual acceptance
remains pending.

The [window machine table and picker](measurements/machine-registry.md) now
retain bounded owned rows, destination admission generations, event-driven
summaries and the original disabled-row ranking and submission decisions.
The original-source comparison matches 8,091 stateful operations on Personal
in Release and ASan/UBSan. The later window integration extends the oracle to
7,360 operations including remote selection and the original stopped phase.
The later machine-UI checkpoint below wires the four machine actions.

The [multiple-client window adapter](measurements/machine-window.md) has two
framed socket fixtures with colliding pane/frame/attachment identifiers. Hidden
clients settle presentation after each event, cached summaries avoid hidden
model scans, and window presentation, physical key ownership, notification
callbacks, sound completion and queued link completion retain their origin.
Twenty selected regressions and a complete Cocoa/Metal scale-1 run pass.
That checkpoint initialized only the local client; the profile-admission
checkpoint below now connects saved rows to the window. Native sanitizer assertions
pass, but the unsuppressed exit leak gate remains open. A Qt-only font control
also reproduces leaks; this does not establish ownership of every GUI leak.

The [SSH transport adapter](measurements/machine-transport.md) now performs
bounded discovery, uses the original managed SSH arguments and commands, and
adopts a native stdio socket pair into the existing framed `RuntimeConnection`.
Controlled subprocess tests cover duplex messages, permanent failures,
cancellation and destination replacement. Both standalone transport suites pass
ASan/UBSan with leak detection enabled. This does not establish a live SSH-host
comparison. The later profile-admission checkpoint below connects the
transport to saved machines; the later machine-UI checkpoint adds actions.

The [saved-profile window adapter](measurements/machine-admission.md) now loads
`machines.json` in production, admits enabled SSH clients in the background,
reconciles stable IDs and returns to local before retiring a visible machine.
Remote launch defaults and destination-scoped window identities are connected.
Six selected Release CTests and five ASan/UBSan CTests pass with leak detection
enabled, including the profile-window cases. A production Cocoa/Metal smoke
opens a shell on an isolated reference runtime. This checkpoint had 25/29
catalogue actions; the later machine-UI checkpoint below adds the remaining four.

The subsequent [delivered notification removal](measurements/notification-removal.md)
checkpoint captures keyboard ownership before the delivered list removes a
focused card, including removal without an intermediate disabled record. A
controlled ablation fails; the final current native suite passes 86 entries with
no QML warnings, and two selected Release groups pass. Both native sanitizer
suites pass assertions but retain exit leaks (268,712 bytes/932 allocations and
170,884 bytes/838 allocations). Full native qualification and global gates stay
open; the older pointer failure's exact timing remains unproven.

The later [global machine activity](measurements/machine-activity.md) composes
all live replicas with cached source revisions and origin-owned targets. Five
Release groups and three core sanitizer groups pass; profile-window sanitizers
also exit cleanly, while machine-window passes 13 assertions and fails exit
leaks (247,716 bytes/907 allocations in the final run; the earlier 268,712-byte/932-allocation failure is retained). Paired real SSH/native scenes prove that a
remote card routes text only to its own pane despite colliding IDs. The actual
card-region comparison retains 60,849 differing pixels because Qt lacks the
23-logical-pixel machine-switcher row; diagnostic alignment leaves 15 errors and
is not visual acceptance. The current complete native suite has 84 passes and a
routed notification-focus failure. Machine chrome, alternate/peek navigation,
full activity/native qualification and all global parity gates remain open.

The subsequent [machine chrome](measurements/machine-chrome.md) checkpoint adds
the sidebar switcher and top-bar segment, with bounded folding, profile colors
and source attention. The native shade Retina controls match 26,476 pixels
exactly; activity cards now occupy their original coordinates with 15 remaining
pixel differences. Actual native segment/sidebar clicks and remote-card input
isolation pass over loopback OpenSSH. Original widget/layout geometry matches
4,728 hosts after correcting floored fold centering, and written colors match
47,646 cases; both also pass ASan/UBSan with leak detection. Three Release groups
and all 86 native Quick entries pass. Instrumented window assertions pass but
exit leak detection fails (203,128 bytes/859 allocations). Full chrome visual
qualification, alternate/peek navigation, setup installation, live recovery and
all global acceptance gates remain open.

The [task workspace handoff checkpoint](measurements/task-peek-handoff.md) fixes
opening an uncached task pane while the old workspace remains attached. Six
regressions cover order, canonical arrival, busy requests, fallback and failed
partial departures. Ten affected core groups pass Release and clean ASan/UBSan.
Actual native task/plan /open and /diff pass in both GUIs through owned SSH, with
real Git patch output and input reaching the new task shell. The full task/plan
modal matches 1,624,320 pixels and each entire following terminal matches
2,336,768 pixels. Current window/native suites pass 27/88 entries; native Quick
has no warnings. Window exit leaks remain (256,632 bytes/984 allocations).
Complete task states, navigation/history, visuals and performance remain open.

The [peek labels and native action checkpoint](measurements/peek-labels-actions.md)
compares task/provider titles and bounded facts against unchanged original Zig
methods/body: 7,456 cases match in Release and clean core ASan/UBSan, including
1,502 full-capacity facts. Actual native /open and /stop pass in both GUIs through
owned OpenSSH, isolating input/signals to the inspected remote pane. All cleanup
exits zero. Both before/after modal-coordinate rectangles match 1,624,320 pixels
each for both actions. Product binaries stay unchanged. Native task/plan
projection/rendering, actual /diff, complete visuals and global gates stay open.

The [actual permanent SSH failure checkpoint](measurements/ssh-permanent-failures.md)
qualifies real OpenSSH authentication and host-key rejection, strict trust and
explicit native retry in both GUIs. After repairing only fixture keys, a bounded
2.6-second observation sees no automatic retry. The original agent pane receives
restored remote input; Local remains isolated. All cleanup exits zero. Both
complete controlled failure pickers match 1,187,840 pixels each. Product binaries
remain identical to the runtime-stop checkpoint. Additional hosts, physical
network/keepalive timing, other build/protocol failures, full visuals, native exit
leaks and comparative performance remain open.

The [intentional runtime-stop checkpoint](measurements/runtime-stop.md) returns
from a remote terminal status to Local, closes on local terminal status and keeps
transient network loss on the selected remote. Four pre-fix policy assertions
fail; all 27 final window entries pass. Paired owned OpenSSH runtime restarts
route outage input to Local and new input to the restored remote shell with a
new pane generation and stable window identity. Cleanup exits zero. Current
native Quick passes 88 entries without warnings. The outage picker retains
1,804 status pixels; instrumented window assertions pass but exit leak detection
fails (256,632 bytes/984 allocations). Complete connection policy, visuals,
permanent SSH failures, native exit leaks and performance remain open.

The [history delegate retirement checkpoint](measurements/history-delegate-retirement.md)
retires pending ListView delegates before result rows lose their indices, then
reconnects after Qt finishes structural notifications. A controlled flick with
paused incubation reproduces the original cancellation warning and fails before
the change. Empty/one-row replies and inspection geometry pass afterward. The
current native suite passes 88 entries without QML warnings. Five sanitizer
assertions pass but exit leak detection fails (554,436 bytes/2,808 allocations);
the interrupted first exit observation and all prototypes remain retained.
Complete visual/performance and native exit-leak gates remain open.

The [palette hint opacity checkpoint](measurements/palette-hint-opacity.md)
preserves the original float32 transparency through Qt item opacity. It removes
the three measured selected-hint pixels: complete shade Retina setup and
controlled outage pickers now match 1,187,840 pixels each. The managed terminal
also remains exact; current native Quick passes 86 entries with one history
delegate warning whose cause remains unproven.
Other translucent roles, themes/densities, exit leaks and performance remain open.

The subsequent [native machine setup checkpoint](measurements/machine-setup.md)
validates the missing-build picker and real declined setup confirmation in Qt
and Zig, followed by actual managed SSH installation through the original
`--binary` development-build path. Repeat installation is idempotent, both GUIs
admit the updated profile and remote terminal input executes. The managed terminal
matches 2,336,768 pixels; the picker retains three differences. Affirmative GUI
release installation, complete visuals, exit leaks and performance remain open.

The subsequent [real SSH recovery checkpoint](measurements/machine-recovery.md)
validates loss and automatic recovery of an owned bridge in Qt and the unchanged
Zig GUI. Local input remains usable during the outage; the same remote agent
receives input after the connection generation changes. All owned resources
exit normally. The native outage picker retains five differing pixels in
1,187,840. Runtime restart, permanent SSH failures, setup installation, complete
visuals, native exit leaks and comparative performance remain open.

The subsequent [agent peek checkpoint](measurements/agent-peek.md) adds secondary
agent activation, source-owned recent text and the original open/stop/diff/prompt
commands. Scoped native shade Retina wide/narrow modals and a blocked refusal
card match exactly. Real SSH validates isolated prompt delivery and both refusal
policies. Native Quick passes all 86 entries; an earlier bindings equality
failure remains retained with unproven cause. Instrumented window assertions
pass all 21 entries but retain exit leaks. Complete visuals, setup/recovery,
native exit leaks and comparative performance remain open.

The [machine UI](measurements/machine-ui.md) now exposes all 29 catalogue actions,
cyclic machine selection, disabled-row enabling, toggles, rename/remove, two-step
add forms and local setup command tabs. Original-source prompt geometry matches
5,329 hosts in Release and ASan/UBSan. Native AppKit capture caught and corrected
a physical-Control mapping error on macOS. Scoped paired captures cover the
picker and three prompt states, retaining their exact pixel differences.
A later [real OpenSSH run](measurements/machine-live.md) validates the production
GUI against an owned loopback SSH server and two isolated original runtimes.
Remote input, return to local, independent local input and return to remote
retain separate pane contents despite matching pane IDs. Both runtime stops,
the GUI smoke exit, SSH server and master cleanup succeed. Additional host
platforms, live failure/recovery, setup installation, source-composed activity,
Linux integration, complete native visuals and comparative performance remain
open. The [initial-machine launch](measurements/machine-launch.md) now wires
`--remote` and `--machine`, local-label selection, temporary/disabled pinning,
remote home/command adoption and the original 64-argument startup limit. Five
selected Release and sanitizer groups pass; real OpenSSH runs cover both CLI
selectors. A first current native suite has one notification-focus failure;
traced sequence/full runs pass, but the failure's cause remains unproven.
The later [notification retirement](measurements/notification-retirement.md)
checkpoint fixes a deterministic real-protocol case: retiring a focused control
left keyboard ownership on the root item. Deferred, origin-checked restoration
now returns it to the terminal. Current Cocoa/Metal Quick passes 85 cases without
QML warnings, and two selected Release suites pass. Both corresponding sanitizer
suites pass assertions but fail exit leak detection; that gate remains open.

Two initial Cocoa/Metal runs each recorded 81 passes and one failure: editor terminal
focus in the first, history inspection geometry in the second. The editor case
passes alone and in three repetitions of its preceding sequence. The
[presentation report](measurements/machine-presentation.md) retains both full
logs and the focus trace. A [later investigation](measurements/native-window-control.md)
reproduces external window-manager interference and records two complete runs
with 82 passes after preparing the owned window's geometry and focus. This is
Cocoa/Metal scale-1 regression evidence; the window-adapter report retains an
82-case run from before the transport and profile-admission changes. Complete visual acceptance remains open.

## Visual acceptance remains open

The Zig GUI is the visual reference. Implementing the same actions or parsing
the same theme values does not establish visual parity. The current Qt Quick
chrome is provisional and differs in layout, labels, controls and interaction
presentation. It is not an accepted redesign.

The [paired captures](measurements/visual-parity/README.md) retain the initial
and updated expanded/collapsed states, their exact fixture inputs and hashes,
the corrections reproduced during capture, and the visible differences still
open. Sidebar regions, project rows, workspace marks and navigation context now
follow the original layout. Covered chrome labels now use the original glyph
masks and original fitted ellipses for covered right-elided labels. Complete
text behavior, tabs, footer, active-agent cards and other
surfaces remain provisional.

Acceptance requires captures of both clients with equivalent runtime state,
configuration, font source, viewport and display scale. Compare the terminal,
navigation, expanded sidebar and collapsed rail, tabs, split and fullscreen
panes, status bar, dialogs, history, previews and overlays. Include selected,
hovered, focused, disabled, loading, error and agent activity states. Check
geometry, spacing, colors, type size and weight, icons, borders, corner radii,
clipping and scrolling on macOS and Linux, at baseline, fractional and doubled
display scales, in both theme modes and in narrow and wide windows.

The first common Metal probe reproduced a single-pane difference at 1600x1000:
Zig exposed 171x46 cells, while Qt exposed 170x45. Qt incorrectly reserved its
pane header and border for a single tiled pane. The shared layout predicate
now removes that reservation in both QML and split-recovery sizing. Regression
tests reproduced the original failure before the correction. This specific
correction does not establish visual parity for the other surfaces or exact
multi-pane cell geometry.

The earlier [pane-header pair](measurements/visual-parity/pane-headers.json)
exposed 70x44 cells per pane in Zig and 72x45 in Qt. The later
[two/four-pane pairs](measurements/visual-parity/pane-grid.json) close that
specific grid/marker mismatch. Each complete focused marker pane matches
596,160 RGBA pixels, including frame and header. Later terminal-cell,
fullscreen-strip and attention-ring captures extend that scoped coverage.
Other theme/density scenes and complete-window acceptance remain open.

A later [qualified Metal capture](measurements/text-scene-performance.md)
matches the complete 1600x1000 single-pane render target, including chrome.
Single/split/tab workbench regions match 3,576,960 RGBA pixels. The capture
waits for a dedicated marker color in the completed GPU readback; an earlier
split pair exposed a 42-pixel capture-order difference in its witness letter.
The corrected capture repeats that letter exactly. Split/tab complete targets
still contain different live CPU/RAM footer values between launches. Native
window controls, other states, themes and densities remain outside this result.

Common Metal captures also reproduced a 32-pixel displacement below the native
title bar. The terminal's advertised dimensions matched, but its actual scene
origin did not, and the footer fell outside the viewport. The Qt root now uses
`Window`, because Telar already positions every chrome band explicitly.
This avoids `ApplicationWindow`'s automatic safe-area padding without requiring
properties introduced after the supported Qt 6.7 minimum. The native regression
checks both terminal corners in scene coordinates. See Qt's
[safe-area behavior](https://doc.qt.io/qt-6/qml-qtquick-controls-applicationwindow.html#safe-areas).

## Implemented behavior and focused coverage

- Current wire handshake, bounded stream decoding, kernel peer authentication,
  reconnection and stable window identities with exclusive slot leases.
- Owned terminal snapshots and deltas, stale/base-frame rejection, row damage
  revisions, text metadata and copied hyperlink storage.
- Workspace and tab projection, pane creation/attachment, splits, directional
  focus, split resizing, fullscreen, tab selection/reordering, closure and
  saved layout restoration. Snapshot reconciliation removes vanished tabs;
  late attach replies cannot recreate a closed tab.
- Qt-independent workbench geometry supplies complete launch sizes for new
  tabs and workspaces instead of inheriting the last resized child. Split
  planning accounts for headers, borders, gaps, fullscreen and the current
  physical cell grid before sending a provisional source resize and child
  creation. Delivery, runtime and allocation failures restore current source
  geometry and release pending ownership. Late confirmations retain surviving
  membership without selecting an inactive tab or recreating a removed tab;
  duplicates cannot detach a represented pane. Routed creation/closure commands
  report failure when no request was admitted. Standalone regressions reproduce
  the original launch-size error and a fractional-scale fitting error that
  dropped a complete column. A native case checks the full grid and real PTY
  dimensions after nested splits and subsequent tab creation.
- Independent pane-header geometry reproduces original text/progress reservation,
  compact fallback and attention priority. Original pane status and progress
  labels match across 14,506 records, including working ages beyond a day and
  every byte percentage. The Qt component uses resident text/shapes and the
  shared window clock; pane chips do not pulse. Projection uses the foreground
  program and exact attachment identity rather than an OSC title or directory.
  Display indices follow tree order and survive fullscreen without a second
  scan per tiled pane. A first-pane program band has scoped native pixel
  acceptance; complete pane decoration and cell geometry remain open.
- Unfocused blocked/failed panes retain the original attention ring and linear
  360 ms fade. The bounded fade table and physical geometry are independent of
  Qt; an opaque attachment key preserves all integer bits through QML. One
  window clock samples every observer and parks after settling or hiding.
  [Attention validation](measurements/pane-attention-validation.json) records
  145,690 byte-exact original operations and 27,480 ring paints. Forty-eight
  original-shader layouts at four timestamps match Metal exactly at three
  display scales; Vulkan remains within one channel level per shape. Native
  [two/four-pane captures](measurements/visual-parity/pane-attention.json) match
  2,401,200 RGBA pixels over the complete pane workbench. Regressions also cover
  window destruction, first exposure, hidden-window retention, shared identity,
  focus, fullscreen, generation changes and pruning. Pane chrome now compares
  the agent's runtime generation rather than the local attachment counter.
  Split replies that omit their generation request authoritative tab descriptors
  while preserving layout and focus. The complete QML sanitizer run retains the
  previously reproduced 240-byte Qt/libcrypto leak. Five adjacent targets and
  six non-QML attention cases pass with leak detection; no suppression is used.
- Fullscreen panes now retain the original bottom strip: application marks,
  tree-order indices, the focused program and status chip, hidden-pane focus
  targets, progress and the leave-fullscreen control. Names compact before the
  visible window moves around the focused entry. `FullscreenStripGeometry`
  needs no Qt or allocator; it uses bounded storage for all 64 pane entries.
  QML creates the component only while fullscreen is visible. An 8,016-frame
  oracle executes the unchanged original strip and dot painters with injected
  advances, plus the original first-visible function. Native component and
  runtime checks pass on Metal and Vulkan at requested factors 1, 1.25 and 2.
  Three native pairs cover two panes, four panes with real foreground-job
  progress and a narrow compact strip. Their complete fullscreen-pane regions
  match 2,591,640 RGBA pixels. [Validation](measurements/fullscreen-strip-validation.json)
  retains the scopes and initial failures. A discovered attachment race now
  reconciles a viewport changed while OpenPane was pending; rejected resize
  admission preserves the last delivered size and remains retryable.
- Routed layout get/apply uses the shared snapshot codec, with a byte-exact
  token checked against the Zig encoder. Applying a token validates tab and
  pane membership before mutation and rejects in-flight layout operations.
  It restores focus and fullscreen while preserving current sidebar
  preferences, as the Zig tab-layout command does.
- The legacy workspace-list collapse preference remains available through the
  command palette, the default `Ctrl+B, w` binding, routed commands and retained
  layouts. As in the original native GUI, it does not hide the expanded sidebar's
  project rows. Repeating a command preserves layout ownership without another
  retention request.
- Independent sidebar geometry and rail selection reproduce the original
  margins, section heights, project-region cap, centered overflow window,
  nearest-hidden selection and incremental floating-point placement. Workspace
  marks reproduce the original first-scalar handling, ASCII uppercasing and
  FNV-1a hue selection. The differential runner extracts the original Zig
  implementations, including the rail draw loop; 92,351 records matched
  byte-for-byte on macOS and Fedora. Standalone QML tests need no application
  controller or runtime and instantiate only the visible rail marks.
- Physical display metrics now resolve chrome roles, window bands and sidebar
  rows before conversion into Qt logical coordinates. One allocation-free
  snapshot serves workbench sizing, sidebar projection and notification
  placement. The original physical geometry matches 17,520 differential frames
  over eight densities. Complete root cards match at backing scales 1 and 2;
  the projects/header rectangle matches at scale 1. These regions total 221,575
  exact RGBA pixels. The scale-2 project rectangle retains six different pixels
  in U+2387. Child age ordering, full-window rendering and performance remain open.
- Focused completed agents are acknowledged on committed snapshots and attachment
  reconciliation, without another click. The independent one-identity policy
  matches 6,505 original operations. Session regressions cover generation reuse,
  duplicate/stale snapshots, another tab and repeated focus. The acknowledgement
  uses the committed snapshot generation rather than stale pane metadata.
- Contextual tab captions follow the original precedence: manual label,
  non-placeholder focused-agent session title, then directory and application.
  Directory names preserve root separators, reject invalid UTF-8/control bytes
  and keep complete scalars within 48 bytes. Caption composition uses borrowed
  views and caller-owned fixed storage; fullscreen adds the original suffix.
  Workspace snapshots retain the selected foreground before attachment, and
  reports update only that remembered pane. Confirmation preserves metadata
  discovered before its reply, including across injected allocation failures.
  Configurable window titles use the same application resolver. The original
  directory/caption/application code matched 75,111 differential records on
  both platforms; Qt projection tests cover all four title states, location
  matching, first-match precedence and manual/fullscreen behavior. The
  [caption captures](measurements/visual-parity/README.md#contextual-captions)
  retain the remaining differences in tab geometry, icons and truncation.
- Tab-strip fitting now follows the original selected-width share, inactive
  cap, staged caption/chip compression, bisection, farthest-tab hiding and
  nearest-hidden counter. It uses fixed arrays and matches 26,800 records
  byte-for-byte against the extracted original calculation. The Qt adapter
  packs from the left, preserves delegates by key, freezes its anchor while
  hovered and recenters when a new selection would be hidden. Standalone
  component tests check packing, hover stability, a hidden selection, counter
  delivery and destruction of a previously bound model. Pills and chips use
  the original sizes, radii and alpha; ordinary terminal/editor/git marks use
  their Nerd Font glyphs. Native caption masks fade by each clipped glyph's
  center, following the original `OpacityEdge`; other labels retain the Qt
  path when unsupported. Tab agent dots, eight-step working rings, compact
  terminal progress and hidden-counter attention now have independent value,
  scheduling and component coverage. Two live determinate-progress captures
  match the complete selected pills and tab bands. Pane header progress,
  hidden-counter native pixel comparisons, drag/motion, complete text behavior
  remain open. Chrome bands and sidebar/card rows now resolve in physical
  pixels before Qt projection; full physical-density equivalence is unproven.
- Tab application marks now use the original embedded provider atlas, theme
  tint selection and inactive alpha, with terminal/editor/git glyph fallbacks.
  Built-in process aliases are shared with the C++ runtime; matching strips one
  executable suffix and preserves the original case rules for display/tool
  names. The differential runner uses the original icon functions, table
  lookup and executable matcher, and imports the original image filters.
  It matched 12,589 records, including 1,445 premultiplied RGBA images, on macOS
  and Fedora; the Fedora comparison also passed under ASan/UBSan. Classification
  and resampling run without Qt or a GUI controller. This does not establish
  complete composited pixel equality or cover the unported fullscreen band,
  agent cards and other consumers of application marks.
- Tab chips show global one-based numbers while the keyboard prefix is pending,
  retaining the same geometry and hidden-tab counter. Prefix notification does
  not rebuild the session's tab model. Standalone tests cover a compressed
  64-tab strip showing number 33, and native integration checks waiting,
  execution, Escape and cancellation by another action. Component and binding
  cases run with Metal and Wayland/OpenGL at scales 1, 1.25 and 2.
  [Application-mark validation](measurements/application-mark-validation.json)
  records the source hashes and validation scope. The Qt sanitizer target still
  fails on the previously reproduced 240-byte `libcrypto` allocation; no leak
  suppression or disabled detector is used.
- Incremental Qt list models, input encoding, shell output rendering, IME
  handling, local selection, clipboard paste, mouse reporting and viewport
  scrolling. The native integration tests cover keyboard input and output;
  they do not cover every key mode or input method.
- A Qt-independent fixed-buffer semantic key encoder matched the original
  Zig implementation byte-for-byte across 448,936 records on macOS and Linux.
  Coverage includes every five-bit Kitty flag combination, modifiers, phases,
  cursor modes, modifyOtherKeys, Unicode boundaries, control characters,
  alternate codepoint fields, associated text and invalid shifted scalars.
  Synthetic bindings use this encoder directly, including NUL and non-BMP text.
- The Qt key adapter has compile-time Apple and standard keyboard conventions.
  Both conventions run in a standalone test without a window or application.
  Physical releases retain the press's semantic character and modifiers.
  A native integration test checks the complete Kitty bytes through a raw PTY
  after Control has been released, and suppresses an unbound Super function key.
  Function keys outside the original semantic key type retain the shared
  desktop encoder; their complete equivalence remains unverified.
- The 43 default binding descriptors are generated from the Zig source.
  Custom prefixes, global/prefixed sequences of up to five keys and profile
  overrides compile into a bounded keymap. Conflicts replace defaults;
  duplicate or ambiguous configured sequences are rejected before adoption.
  Palette hints use the effective bindings. Unported actions still fail
  explicitly rather than acquiring their original subsystem's behavior.
- A Qt-independent template router owns 64 physical leases, prefix cancellation,
  global-sequence replay/timeout, repeat eligibility and lease inheritance.
  Its decisions and state matched the original Zig router byte-for-byte for
  29,152 deterministic/random transitions, including five-key sequences,
  Unicode, saturation, reload, clock bounds and exclusive capture.
- Retained configuration generations support Lua closures, immutable callback
  contexts, action batches and `consume`, `forward`, `keys` and `paste` input
  expressions. Callback budgets match the original 100,000 instructions and
  100 ms deadline. Tests cover rejected mutation, recursion, exhausted budgets,
  recovery and obsolete references. Batches are validated before execution;
  a batch containing an unsupported action applies no effects.
- Native tests load callback modules after configuration evaluation, use a
  custom prefix after waiting beyond the former Qt timeout, check global
  sequence misses and expression bytes through a real PTY, suppress unwanted
  repeats, and preserve physical ownership while replacing the configuration.
- Configured and callback `command-tab` actions preserve separate argv entries,
  inherit the focused attached pane's directory, focus the runtime-confirmed tab
  and remove an empty tab after the command exits. Tab operations share one pending
  owner and recover after delivery or runtime failure. Confirmation reconciles
  metadata-only tabs discovered before the correlated reply without replacing a
  live tab. Allocation-failure injection checks atomic adoption and cleanup.
  Closure preserves surviving focus or selects the next, then previous neighbor.
  The shared packed pool has compile-time runtime/GUI storage policies: runtime
  validation keeps 80 KiB and 768 rows; the GUI adds 64 KiB and 256 recent rows.
  Direct typed action references preserve all epoch bits and reject malformed
  row IDs or foreign generations. Callback references survive later invocations
  until recycling, while fixed rows survive recent clearing. Rendering refuses
  excess rows without expiring earlier rows in the same render. The original Zig
  pool oracle matched 5,590 transitions, including 49 bounded refusals, on macOS and Linux.
  Custom bars, widgets, panels and picks still need their own execution surfaces.
- Kitty chunked RGBA uploads, image replacement and deletion, retained texture
  caching, image layers, source geometry, virtual placements and Unicode
  placeholders. Tests include actual rendered image pixels. Shared-memory
  graphics transport is not enabled.
- Keyboard copy mode supports cursor movement, Vim word/paragraph motions,
  character/line selection, search, match cycling, copying, cancellation and
  entry-viewport restoration. The default binding, command palette and routed
  `client_copy_mode` action enter the same model. Copy-owned physical keys stay
  quarantined after mode exit. A real-runtime test searches and copies a match
  and checks that a retained exit key cannot repeat into the PTY.
- Copy navigation, selection, pointer primitives and frame reconciliation
  matched the original Zig model in 32,241 transition records on macOS and Linux.
  Plans keep the match buffer separate from the copied navigation state.
  Full prompt/focus behavior remains incomplete. The copy cursor's `o`
  command now uses the original text-only link extraction policy.
  Native integration preserves keyboard-copy ownership when an editor opens
  and receives focus in the same tab; its exit key returns to the copy model.
- Pointer selection shares the keyboard copy model, including double-click
  word selection, triple-click lines, dragging, automatic copy and retained
  highlighting. Independent gesture ownership quarantines late releases
  after resize, detachment or keyboard input. Core tests inject a failed copy
  request and verify recovery without retaining a borrowed pane.
- Click timing, copy-pointer routing and wheel quantization matched their
  original Zig functions in 22,440 records on macOS and Linux. Recording stubs
  replace widget interception and external effects in that oracle. Fractional
  scrolling respects phase resets and the original 32-line event limit;
  a line scrolls three viewport rows or sends one child mouse report.
- Native integration checks selection, lost-grab recovery, copy-owned wheel
  suppression, Shift-forced selection and complete child mouse bytes through
  a raw PTY. Keyboard releases, mouse input and focus reports preserve the
  original viewport policy. Complete chrome interactions and native pointer
  equivalence remain open.
- A Qt-independent `ChildMouseGesture` owns a button's stable pane identity,
  attachment generation, tab location, geometry and last sample. Three slots
  in the window's Qt `PointerDispatcher` preserve other buttons when one
  releases, including when their recipients are different panes. The
  dispatcher delegates fresh-press admission to Qt, preserves captures while
  Qt transfers its exclusive grab, and forwards local view gestures with
  separate held-button masks. Child state lives outside the terminal item;
  hidden or replaced views retain geometry while their pane stays attached.
  Pane focus changes preserve acquired captures; window deactivation, pane
  detachment and lost grabs finish them. Native regressions first reproduced
  incorrect simultaneous button reports and premature cancellation on pane
  focus changes. Their
  raw-PTY checks now compare the complete stream, including cancellation and
  late releases. Capture setup waits for matching presented geometry as well
  as the terminal frame. A two-PTY regression reproduced premature release
  when a second pane acquired Qt's grab. Complete streams now verify both
  retained recipients, independent releases and cancellation across panes.
  Another native case hides an attached view during a retained drag.
  Closing the pane with Qt's current grab preserves the other pane's capture;
  its raw-PTY stream also checks that the closed pane's late release is not
  redirected to the surviving pane.
- Child mouse projection matched the original retained clamping code,
  `pane_mouse_inputs.encodeReport` and `keyinput.tracked` in 81,680 byte-exact
  records. Geometry fixtures replace application admission; the original
  projection and encoding code is extracted or imported directly. Coverage
  includes protocol modes, modifiers, mouse phases, cells/pixels, clipped and
  empty grids, scales and exterior coordinates. Ownership identity and hidden
  geometry have separate standalone tests. The Qt bridge follows the Zig
  policy of reporting child mouse input only with SGR enabled; a raw-PTY case
  verifies that legacy tracking does not emit mouse or wheel bytes.
- Configured `navigate-*` actions preserve the original Neovim policy:
  the exact reported executable name `nvim` receives Control+H/J/K/L through
  the semantic key encoder; other processes use directional pane focus.
  Explicit focus remains independent. Core tests cover all four directions
  with legacy and Kitty input, plus case-sensitive detection. Native tests
  execute both a declarative navigation binding and a Lua callback batch.
- Focused scroll bindings use a Qt-independent session method. Core tests
  cover SGR report bytes, retained highlighting, a scrolled viewport,
  alternate-screen literal arrows under Kitty mode, history away from the
  bottom, disabled SGR and detached panes. Deltas clamp before subtraction,
  including both signed 64-bit extrema; unchanged offsets send no request.
  Keyboard copy mode retains exclusive viewport ownership. Native raw-PTY
  coverage includes the default scroll binding in the mouse report stream.
- URI, Markdown and prose-path recognizers matched the original `urlscan`
  functions in 198,338 records on macOS and Linux. The corpus covers every
  byte in representative token positions, UTF-8, ports, punctuation, length
  boundaries, path positions and deterministic random input.
- Logical cell traversal matched the original `cells.matchGrid` and
  `LinkGrid` functions in 44,798 records on both platforms, comparing complete
  target bytes and absolute cell intervals. Tests cover soft wraps, hard
  newlines, wide cells, padding, viewport truncation and bounded traversal.
  Separate core tests check OSC 8 precedence and prevent incomplete metadata
  from authorizing a URI-shaped label as its destination.
- An independently testable `ExternalLinkOpener<Host, Observer>` uses an
  asynchronous Qt process with the original five-second deadline, separate
  4096-byte output limits and last-pending-target queue. Its template host
  selects the native command; observer validation happens after the type
  is complete, including on Clang 21. The dispatcher composes a QObject for
  event lifetime instead of using virtual template methods.
- The copy cursor, detected pointer links and routed `client_open_link`
  commands share external opening. Unsupported schemes are rejected before
  admission. A separate build injects a recording host at compile time and
  checks exact targets, including Unicode and shell punctuation.
- Qt-independent hit identity, gesture ownership, pointer policy, hover
  presentation and region iteration support plain URLs, Markdown, guessed
  paths and OSC 8 destinations. Alt removes the target; paths require the
  native link modifier. Right click copies displayed targets. Ordinary left
  clicks share selection; child mouse tracking retains them unless Shift
  overrides it. Any drag cancels activation, including motion within a cell.
- Gesture ownership and hit equality matched the original private
  `WindowModel.LinkGesture` and `LinkHit.eql` in 108,875 transitions on macOS
  and Linux. The oracle checks every identity field, every version field,
  complete returned targets, missing hits, cancellation and restored states.
  Separate session tests check that frames and pane metadata preserve the
  context while actual focus, viewport, chrome and configuration changes
  invalidate it. This does not establish complete native pointer equivalence.
- Pointer hover caches the cell, screen revision, view revision, geometry
  and modifiers. Immutable hit snapshots use the injected allocator on the
  GUI thread; render synchronization borrows them without allocating link
  storage. One bounded frame queue publishes captured targets and preview
  coverage, rejecting obsolete attachment generations. Input under a drawn
  preview remains covered until its clearing frame is presented.
- A standalone Qt preview layout bounds wrapping and ellipsis to twelve
  rows. Transient underlines enumerate visible spans, including every run of
  an OSC 8 identity, without invalidating retained terminal text. Native
  integration checks modifier-only hover changes, Markdown destinations,
  right-click copy, child tracking, within-cell drag cancellation and target
  or chrome changes followed by restoration during a click. Opening waits
  for the matching presented frame; core tests exercise superseded snapshots
  and delivered preview coverage.
- File URI decoding, prose-path locations, environment expansion and editor
  arguments matched the original Zig functions in 47,275 records on macOS
  and Linux.
  The resolver rejects non-local file hosts, malformed escapes, queries,
  credentials, ports and NUL paths before editor dispatch. Expanded relative
  paths use the source directory; absolute file paths remain literal.
- Configured/profile editor executables override the process's EDITOR value.
  The session sends the existing OpenEditor request to check the file and
  reuse a reachable editor, or creates a sibling pane when reuse is unavailable.
  A source without runtime identity launches directly; a sourceless absolute
  file creates a tab. Editor argv entries preserve spaces, Unicode and shell
  punctuation as literal data. Matching replies may focus the reused pane;
  stale pane, attachment or location identities cannot apply a fallback.
  Standalone tests cover duplicate replies, transport failure, retry and
  capacity. A duplicate attachment confirmation preserves the current view
  identity; an actual reattachment allocates a new generation.
- Command palette, workspace/tab name dialogs, history query ordering,
  notification toasts and agent cards. Runtime commands supported by the core
  include workspace/tab selection, tab creation, pane creation/splitting,
  focus, resizing, closure, fullscreen, scrolling and sidebar visibility.
  Unsupported routed commands receive an explicit failure response.
- CLI-routed history opening and forced configuration reloads pass through
  an injected template/concept handler while the core owns validation,
  correlation and completion. Tests cover a real second runtime client,
  unchanged-file reloads, rejection without a loaded configuration, invalid
  reload retention and recovery.
- History defaults and profile overlays support human/agent filtering,
  fuzzy/FTS matching and paste/run preferences. Enter and Shift+Enter use
  canonical entry identities without depending on a rendered delegate.
  Input rejects loading/failed queries, missing or truncated captures,
  malformed UTF-8 and ASCII/C1 controls. Newlines and tabs require bracketed
  paste; execution appends Enter after its closing marker. Query truncation
  preserves UTF-8 scalar boundaries.
- A separately testable `HistoryBrowser<Memory>` owns history state without
  Qt, sockets or a complete session. It preserves insertion boundaries across
  pages, retires stale requests, limits pending operations, and stages new rows
  before publication. Allocation failures preserve the previous page and
  prevent its submission; output failures remain local to inspection.
- Independent history modal geometry now follows the original physical panel,
  header, results, inspector, bottom search and footer. The original source
  matches 12,480 frames on both systems, including Linux sanitizers. Opening
  details and replacing a page preserve the input position; narrow inspection
  replaces the list. Filter chips and the search/close band use the existing
  native text/icon components and can run without an application controller.
  [History validation](measurements/history-modal-validation.json) retains
  47-entry software integration runs, native history and independent controls
  at three scales, scoped editor/lint checks and fixture corrections. Captures
  support inspection; this revision does not establish paired history pixels.
- History labels and row fitting now have separate original-source probes.
  Bounded date, time, age, duration and status formatting matches 64,092 records;
  six physical row rectangles match 14,304 frames across eight densities.
  `HistoryRow` runs without an application controller and uses the original
  closed-row fact priority, native labels, terminal cell text, status colors
  and continuation marks. The page projects day headings and shares one
  calendar sample. A reproduced double-click submission now preserves selection
  and the open dialog. [Row validation](measurements/history-rows.md) records
  the actual scope; complete cards, wrapping/matching, compact paths, group
  admission/scrolling and paired history pixels remain open.
- Selected history commands now wrap by words without splitting graphemes.
  Independent value components bound visible lines and their remainder, derive
  the original steady card height and metadata placement, and preserve fuzzy
  query progress across visible cells. The original methods match 19,738
  records on both systems and Linux ASan/UBSan. The Qt row uses complete selected
  commands, clips to its frame and repositions selection after its height
  changes. [Card validation](measurements/history-card.md) retains the original
  one-line failure, a native capture that exposed a partially hidden selection,
  final viewport containment, component/integration checks and remaining gates.
- Bounded path compaction, ordered metadata labels and card action/keycap fitting
  now have an original-source probe with 18,952 exact records on both systems
  and Linux ASan/UBSan. Reusable metadata/hint components preserve selection,
  pointer actions and native keyboard conventions. Actual paired Cocoa/Metal
  captures exposed incorrect material, list/search insets and combined ring
  passes; the final selected card matches all 269,760 RGBA pixels in one case.
  [Metadata validation](measurements/history-facts.md) records that scope, the
  remaining full-window differences and the open native sanitizer leak gate.
- The footer now shares card keycap rendering and uses independent bounded
  label/fitting components. Original footer methods match 14,888 records on
  both systems and Linux sanitizers. Browse and inspect captures each match
  all 161,856 footer RGBA pixels in one theme/density. Standalone input checks
  and actual application clicks cover its actions. [Footer validation](measurements/history-footer.md)
  retains the scope, original failures and unresolved native leak; other
  states/themes/densities and complete-window acceptance remain open.
- Footer submit actions now carry the displayed revision and require the matching
  delivered choice, dialog generation and paste/run mode. Changing semantic
  identity retires a captured press. The browser validates choices without Qt;
  the adapter reuses its existing frame-delivery path. [Choice validation](measurements/history-choice.md)
  retains the original-source reference, failed regression, state-machine and
  native input coverage, paired visual regressions and remaining gates.
- Row clicks now validate delivered content identity independently of view
  changes. Selection and inspection visibility update the view version without
  invalidating the content revision, matching the original row-selection guard.
  Hints and rows share capture retirement; semantic footer actions retain their
  identity. The final component fixture has clean native sanitizer shutdown at
  three scales, and test headers now have their own clangd context.
  [Target validation](measurements/history-targets.md) records this correction to
  the preceding revision assumption, retained failures, native/visual coverage
  and the remaining input-lifecycle and sanitizer scope.
- History filter geometry and labels now use reusable, allocation-free policies.
  Selected workspace/directory values, terminal-font hints, group fitting and
  separate failure rings follow the original methods. The original-source
  comparison matches 18,864 records on both systems. Six Cocoa/Metal scenes
  match complete header pixels; native component and integration checks pass
  at three scales on both platforms. [Filter validation](measurements/history-filters.md)
  retains the failed fixtures, directory-change check, exact pixel regions,
  tooling coverage and remaining theme/density/Linux-pixel gates.
- The history query now uses a reusable bounded editor and physical form-field
  policy, with a separate Qt input/IME adapter. Cell-positioned font spans keep
  unsupported glyphs in the resident chain. The original snapshot editor path
  matches 106,511 transitions; seven actual Cocoa/Metal search bands match all
  pixels. Final seven-entry form components pass native input at three scales
  on both platforms, including Linux sanitizers with leak detection enabled.
  [Search-field validation](measurements/history-search.md) retains the original
  persistent-scroll crash, failed fixtures and pixel limits. Raw controller
  queries now synchronize with the visible field; unchanged page/filter updates
  preserve selection and composition. Query overflow uses the existing limit
  ledger and a reusable allocation-free UTF-16 prefix policy. Two overflow search
  bands and a visible warning region match the original Cocoa/Metal pixels.
  [Query validation](measurements/history-query.md) records both regression
  failures, final platform checks, capture-event corrections and the unresolved
  intermittent standalone Cocoa composition failure. The later
  [composition revision](measurements/form-composition.md) adds first-Escape
  cancellation in results and inspection, a separate Qt surrounding-text
  snapshot and a Cocoa-only native cancellation bridge. Reproduced focus loss
  explains one diagnostic variant; the historical unexpected commit remains
  unexplained. Complete physical IME lifecycle and full-window visual/performance
  parity remain open.
- History inspection now uses the original command/facts/output line sequence,
  cell-based scrolling, physical text geometry and action buttons. Its formatting
  and iteration run independently of Qt or allocation; the Qt view creates only
  visible line delegates and keeps query focus. A shared adapter translates
  terminal and inspector wheel events into the existing bounded accumulator.
  [Inspector validation](measurements/history-inspector.md) retains the exact
  captured regions, failed fixtures and the outstanding input checks at that
  revision. The later live-metadata check covers renaming and pane closure;
  complete physical input remains open. This does not establish complete
  history or window parity.
- History inspection now follows canonical tab renaming and pane closure while
  retaining the query, command, rows and content revision. A bounded tab-name
  cache extends notification admission without rebuilding result rows.
  Removing the visit action retires a held press without reading a missing
  QML record. [Live metadata validation](measurements/history-live.md) retains
  the failed regressions, standalone and runtime-backed native checks, and the
  complete modal's 241-pixel continuation-glyph mismatch. Other metadata
  transitions and full-window visual/performance acceptance remain open.
- History wheel input now belongs to the complete presented modal. The independent
  policy checks dialog generation and row revision, accumulates fractional input
  in delivered row or inspection-cell units, and bounds each event to 32 steps.
  The application stops selection movement when it starts a page request.
  [Scroll validation](measurements/history-scroll.md) records the unchanged Zig
  handler comparison, native input checks and remaining parity limits.
- Empty history pages now show the original initial-search, failed-query,
  new-history and filtered-empty messages, with scope recovery that preserves
  the editor. Replacement queries retain their page, delay the cue for 150 ms
  and share the window clock for the loading band. Independent formatting and
  geometry use no Qt or dynamic storage. Both Qt Shift+Tab forms cycle authors.
  [State validation](measurements/history-states.md) retains scoped original-source,
  native rendering and lifetime checks, including the Qt-only leak reproducer.
- Standalone page storage keeps 512-byte UTF-8 previews, a contiguous 768 KiB
  long-command cache and a separate selected-command buffer capped at 64 KiB.
  Exhausting the cache triggers an exact-entry read for the selected command.
  Identity checks, stale-reply rejection, local read/allocation failures and
  complete-byte copy/paste are covered by core and session tests. A native
  test imports seventeen 48 KiB commands, copies an uncached selection and
  checks the complete command in the QML inspector. Page swaps reject different
  allocator instances before transferring storage.
- History scope/author/failed filters, the `!` prefix, paging, output inspection,
  copy, confirmed deletion and navigation to an existing pane are connected to
  a dedicated QML panel. Newest entries sit at the bottom, Up/PgUp select older
  history, and Escape first closes an open inspector. Keyboard routing includes
  alternate submission, inspection, copy, deletion and scope/author cycling.
- Captured output uses a bounded scanner matched byte-for-byte against
  `src/core/plain_text.zig` on 398,218 deterministic/random records. Its
  standalone differential tool does not require a GUI or runtime process.
- Routed pane copy uses inclusive full-history coordinates, validates decimal
  widths and separators, and forwards the existing runtime `CopySelection`
  request. It preserves focus and uses the runtime's asynchronous clipboard
  response. Parser and session tests cover malformed and overflowing ranges.
- Routed sidebar resizing uses the original semantic column bounds and named
  command failures. Changed widths reach runtime-retained layout state;
  repeated widths and rejected requests leave it unchanged. Visibility stays
  independent. The GUI supplies its measured terminal host columns to the
  Qt-independent policy. The initial and restored semantic widths now respect
  the original minimum of 42 columns. Semantic CLI columns remain independent
  of the GUI's disposable logical pixel width, matching the original split.
- Configured window titles retain profile overlays and support the four
  original tokens: workspace, tab, pane title and hostname. The default is
  `Telar`. The standalone formatter uses a bounded value, preserves literal
  unknown tokens, filters controls and keeps complete UTF-8. Session tests
  verify manual labels, foreground discovery, workspace renaming, focused pane
  changes and ownership of earlier rendered values. A real OSC title change
  reaches the Qt window; configuration reload and failure retention use the
  same template. The formatter and extracted original sidebar clamping code
  match 155,464 differential records on both platforms. Foreground snapshots now
  supply automatic tab tokens before a pane report arrives; a regression
  reproduced the previous `shell` fallback before the correction. Machine-label
  overrides and held-limit suffix delivery remain open.
- Routed runtime-section configuration queries read a typed snapshot retained
  with the adopted generation. The existing runtime reader applies root and
  selected-profile fields; queries do not execute Lua, reopen files or change
  the running runtime. They preserve nullable paths, integer precision, host
  ordering and the 4096-byte command bound. Callback mutation and rejected
  replacements leave the active snapshot intact. Standalone tests cover query
  allocation ownership, partial construction failure, complete custom-agent
  identifiers and the runtime's Unicode icon validation. The common provider
  enum now states the valid custom endpoint, and manifest admission guards its
  capacity before assigning those identifiers.
  The extracted original serializer matches 4,126 synthetic typed JSON records
  byte-for-byte on both platforms, including 1,633 bounded failures. Expanded
  control-heavy fixtures reproduced and fixed longer JSON escapes that rejected
  valid replies accepted by Zig. This comparison covers serialization, not the
  full configuration loader. Monitor and real-runtime tests cover failed reload
  retention, replacement, named errors and routed replies without applying the
  queried paths to the runtime.
- GUI and input configuration queries serialize their adopted values without
  executing Lua or touching host resources. GUI serialization receives the
  native titlebar default from the platform adapter. Input replies count
  configured bindings, preserve key union payloads and encode the complete
  UTF-8 storage including its NUL padding. Floating preferences retain Zig's
  f32-to-f64 promotion and decimal formatting. Extracted original serializers
  and the original GUI/key types match 5,441 typed records byte-for-byte,
  including 650 bounded failures. The differential check reproduced and fixed
  a character-byte array being serialized as numeric elements instead of a
  JSON string. Standalone tests verify profile inheritance, callback mutation,
  allocation ownership and exact floating-point response capacity.
- Binding configuration queries preserve declaration order, prefix keys and
  complete action payloads. Allocator-owned typed descriptions retain semantic
  callback identities, immutable command references, notification values, sorted
  definition indices and plugin hashes. Profile replacement retains the root's
  callback identity range. Queries neither invoke Lua nor allocate command
  storage; borrowed views read the shared packed command registry.
  The original action/key types, command pool and extracted serializer match
  2,589 typed records byte-for-byte on macOS and Linux, including 227 bounded failures.
  This comparison reproduced and fixed missing implicit command labels.
  The corpus covers trailing POSIX separators, literal backslashes, invalid
  UTF-8 argv/labels, callback identifiers, every action shape and exact response
  capacity. Standalone, monitor and routed tests cover callback mutation,
  failed replacement, authority errors and bounds. This establishes typed
  serialization coverage; full parser equivalence and execution of actions
  belonging to unported subsystems remain open.
- Configuration adoption now reuses the shared `SnapshotReader` to validate
  root values and every profile, including profiles that are not selected.
  Unselected values do not replace the active runtime snapshot. Invalid client,
  GUI, theme, runtime and profile-name fixtures fail with balanced allocation
  ownership. Qt monitor tests retain adopted query values across a rejected
  replacement and adopt a later valid replacement.
- Client configuration queries combine adopted sound, notification-delivery
  and history policies with the session's live view: sidebar visibility and
  semantic columns, workspace-list collapse, pane gaps and the unexpanded title
  template. Requested source/profile bytes are cached outside the query path.
  Unchanged and failed reloads retain their generation identifier; successful
  adoption advances it without reusing identifiers after configuration is
  cleared. Negative indices are ignored for the client section, matching Zig.
  The retired `terminal` notification delivery preserves inherited policy.
  The original query body, title accessor, sound policy and delivery enum match
  2,799 typed records byte-for-byte on macOS and Linux, including 335 bounded failures.
  The pure serializer has no Qt, Lua or runtime dependency. Standalone, monitor
  and routed tests cover policy inheritance, callback mutation, relative source
  paths, replacement rejection, recovery and live window state. Reporting
  policy values does not implement the unported sound/notification effects.
- Complete theme values retain all sixteen chrome roles, terminal RGB values,
  ANSI palette, nullable cursor colors and fifteen optional syntax styles.
  Presets come from the original sources, preserving indexed/default colors and
  role-specific italics. Root and profile overlays retain independent light
  and dark inheritance. CLI locks outrank appearance variants. The headless
  reader, selector, renderer projection and query writer have no native or Qt
  dependency. Queries do not execute callbacks and retain the adopted values;
  an oversized reply fails without rejecting the configuration.
  The original preset implementation and extracted query/appearance resolver
  match 2,318 typed records byte-for-byte, including 929 bounded failures.
  All fifteen resolved syntax roles also match after palette and style edits.
  Every one of the 16,777,216 three-byte UTF-8 decisions also matches Zig, which
  controls whether RGB byte storage serializes as a string or numeric elements.
  This is typed-data coverage, not proof of complete Lua parser equivalence.
- The Qt appearance adapter observes color scheme changes and updates only the
  active theme. Tests preserve a callback's retained state, an in-flight prefix,
  the sidebar visibility and a user-adjusted width. CLI locks and rejected reloads
  preserve their values. Chrome text and panel colors are independent of the
  terminal's ink; explicit panels remain opaque over translucent windows.
  Source and routed Qt tests synthesize appearance signals. Physical OS events
  and comprehensive syntax rendering remain unverified or unported.
- Preset and custom theme colors, profiles, font preferences, cursor
  preferences, padding, sidebar width/visibility, pane gaps, chrome text scale,
  frame interval cap and configuration file replacement/reload.
- Configuration monitoring compares the main file and loaded local modules
  once per second, using file kind, size and nanosecond modification time.
  A standalone regression reproduced unwanted Lua reevaluation after creating
  an unrelated file before this change. Unused files now preserve the active
  generation and callback state; forced CLI reloads still reevaluate unchanged
  sources. Loaded modules in nested directories remain watched, including
  modules loaded by successful or failing callbacks after startup.
  Failed replacements preserve the active configuration and retry after a
  dependency changes. Fourteen standalone cases run without a window or runtime.
- Periodic metadata checks and replacement Lua generation preparation run on
  a worker. The Qt thread validates the font and adopts a complete result;
  immutable request snapshots never borrow the active Lua VM. One task and
  coalesced pending work bound the queue. Revision tokens reject late results
  after selection changes or forced reloads. Regressions cover event-loop
  progress while the pool is blocked, coalescing, stale failures, dependencies
  loaded by callbacks during a pending check, retained callback state after a
  failed reload, font validation failure and shutdown ownership. Shutdown
  waits for the active task and consumes its result before releasing the
  caller's allocator. Adoption consumes the prepared result before notifying
  observers; a regression destroys both the source and allocator from that
  notification.
- A terminal scene renderer driven by `TerminalPresentation`, without an
  application model, QML engine or runtime connection. Dedicated image tests
  verify opaque block cursors, inactive-window hollow cursors, hidden cursors
  in unfocused panes, configured cursor text colors, concealed text, original
  underline rules, selection damage on retained rows and transient link underlines.
  Preview layout tests check wrapping, ellipsis, pane bounds and insufficient
  or invalid cell geometry.
- Default terminal rows now use the existing allocator-aware `TextLayout`,
  FreeType synthetic styles, resident masks and alpha shader. Positioned text
  preserves terminal baselines, overhang and configured fallback cell bounds.
  Font discovery observes window generations and scans only changed rows before
  rendering. Qt text remains the emergency raster/cache fallback; native optical
  rendering remains selectable. Cursor text and preedit share this rendering
  choice, while cell decorations use physical cell geometry.
  [Validation](measurements/terminal-text-validation.json) retains 34 scene
  entries on native Metal/Vulkan at three requested scales, Linux ASan/UBSan
  with leak detection, original-source shaping/raster checks, editor contexts
  and six clean clang-tidy translation units under the existing 500 checks.
  The new mask comparison covers regular/bold/italic/bold-italic M glyphs;
  separate cases exercise oversized raster fallback and malformed UTF-8.
  The CoreText corpus now includes height 60, where the original can give
  identical masks for different smoothing strengths. Tests check optical
  selection and restoration without assuming every strength changes every mask.
  A selected Mac runtime invocation also exposed an unsynchronized external
  window-placement change: 34 rows instead of the test's earlier 42. Its failure
  is retained. A private startup barrier records the height changes before
  releasing the unchanged assertions, which then pass at all three requested
  factors. This does not close general live-window or earlier Mac input failures.
  [Two/four-pane native captures](measurements/visual-parity/terminal-text.json)
  match all 2,384,640 pane pixels, including text-bearing unfocused content.
  Full-window, broader text/fallback/IME, themes/densities, Linux paired pixels,
  cache-pressure equivalence and release-matched performance remain open.
- `TextRuns<Memory>` and `RowTextLayout<Memory>` now preserve the original
  ligature input/context reach, per-cell glyph placement, cursor boundaries,
  selection inversion and ink-style boundaries. Reusable allocator-backed storage
  and an ASCII glyph cache avoid rebuilding buffers for warm cursor/selection
  changes. These components have no Qt dependency. Terminal masks keep the
  original straight-alpha blend and pixel-center coverage; faint colors retain
  their original floating-point channels. Cell decorations preserve draw order
  and map every underline variant to the original single physical rule.
  Text clips to the pane so tall combining marks can cross row boundaries.
  Viewport changes exclude hidden cells from shaping, and cursor movement
  invalidates retained ligatures even while the cursor's blink phase is hidden.
  [Cell-text validation](measurements/cell-text-validation.json) and
  [paired captures](measurements/visual-parity/terminal-cells.json) retain the
  scoped evidence: 7,446 matching original-source row cases, including Linux
  ASan/UBSan, 36 scene entries on native Metal/Vulkan at three requested scales,
  ten clean clang-tidy translation units and two exact styled pane captures
  totaling 2,384,640 RGBA pixels. Installed fallback discovery, optical rows, atlas-pressure
  policy, wider visual corpora and comparative performance remain open.
- Native font matching reuses the original CoreText and Fontconfig adapters.
  CMake compiles the pinned FreeType 2.13.2 archive and source list used by the
  Zig build. `FontSource<Memory>` owns the bytes, `fonts::Face` borrows them and
  applies collection selection and variation coordinates, and `FontGrid`
  calculates the original integer physical cells and half-pixel baselines.
  Application and terminal geometry contain no native font calls. The Qt
  renderer and runtime resize reports use the same measured grid.
  A differential check imports the actual `FontSize.zig` functions and extracts
  `Renderer.measure` arithmetic; 240,073 records match byte-for-byte on both
  platforms. The supplied FreeType size records are synthetic, so this proves
  metric arithmetic rather than complete native matching or glyph parity.
  Standalone Qt cases cover allocator ownership, source reuse across
  scales, bounded cache eviction, failed-replacement rollback, bundled-name
  matching, collection index/PostScript selection and variable metrics.
  Renamed, licensed fixtures contain MVAR/HVAR changes and named instances;
  one check verifies the corresponding Qt glyph advance changes.
  These tests need no window, QML engine or runtime. Localized aliases, complete
  Qt/native face matching, source-file replacement and fallback/shaping
  equivalence remain unverified.
- `fonts::Face` now also shapes with the pinned HarfBuzz 11.0.0 sources used
  by Zig and rasterizes default grayscale masks with FreeType. Its eight
  resident sizes reuse `FT_Size` instances; eviction supports additional
  scale changes without exposing cached native handles. `ShapedRunView`
  borrows the face's reusable HarfBuzz buffer until its next shape call.
  `GlyphBitmapView` borrows FreeType's current glyph storage until another
  face operation replaces it. Callers retain copies through their allocator
  when needed. Metric-only consumers do not initialize HarfBuzz objects;
  shaping initializes them once on first use. No Qt application or native
  window is required by this layer.
  The standalone differential runner compares the actual original face and
  cold shaping procedures, and the original default glyph raster operations.
  Its corpus covers four bundled fonts, two variable-font instances, eight
  heights, four synthetic styles, combining sequences, embedded NULs and
  malformed UTF-8. Fonts that lack a requested character retain their own
  missing-glyph behavior; this is not a fallback-font test. Cache pressure
  tests separately check shaping and raster stability after size eviction.
  On macOS and Fedora, 27,498 cases with 790,272 glyphs match byte for byte;
  ASan/UBSan runs instrument the C++ face and probe, with normal dependency
  archives retained for both languages.
  [The validation record](measurements/font-shaping-validation.json) records
  commands, source hashes and platform results. Covered chrome labels and
  tab-caption measurements now use this foundation. The Qt integration keeps
  GUI and render-thread faces separate, retains mask textures in the public
  image atlas, shares alpha materials with terminal curves and follows the
  original baseline, integer glyph placement, clipping and per-glyph caption
  fade. Unavailable layouts use Qt text. [Chrome validation](measurements/chrome-text-validation.json)
  records focused image tests, component checks, regression evidence and
  paired captures. Full font fallback, optical chrome
  rasterization, complete density geometry, full-window visual parity and
  comparative performance remain open requirements.
  In the recorded four-tab Metal capture, twelve regions match exactly at
  their original coordinates: project/activity headings, project name/path,
  all four captions including inactive fades, and all four provider marks.
  The earlier inactive-mark displacement is absent in this workload.
  Strict glyph image, component, retained-curve and runtime-binding checks
  pass on Cocoa/Metal and Wayland/OpenGL at scales 1, 1.25 and 2. The mask
  material preserves physical density when Qt rounds the viewport extent.
  An uncovered-character component check retains measurable bounds even when
  the label starts at zero width. The recorded full windows
  still show different agent cards, footer and navigation icon.
- Base agent cards retain typed provider metadata, manifest/display names,
  workspace labels and blocked reasons through the session's injected
  allocator. Pure presentation helpers supply the original three rows,
  labels, base project/attention order and status/age semantics. Independent
  QML cards accept data/style properties and emit identity-based selection;
  the activity list creates visible delegates. [Card validation](measurements/agent-card-validation.json)
  records 49,521 original status/age/pulse/geometry calculations, native
  component checks on both platforms and the fixed fixture resize race.
  The later activity revision adds tracked tasks, commands and coordinator
  trees; remaining visual/interaction details stay open.
- Agent status ages advance between snapshots and retain fractional progress
  for the same complete pane identity, state and provider. `AgentReplica` stages
  validated metadata and clock changes in reusable allocator-owned buffers;
  rejected snapshots and allocation failure preserve the published state.
  A replacement runtime starts fresh intervals and may restart revisions.
  `NativeAgentStatus` transports nanosecond intervals through an opaque QML
  value and shares one timer per window. Visible statuses use one timestamp
  before scene synchronization; working glyphs follow the original 120 ms pulse
  and eight-bit rollover. Hidden, stopped and offline components park their
  timer. The platform clock uses the same awake source as Zig, selected through
  a compile-time dependency in headless session tests.
  [Clock validation](measurements/agent-clock-validation.json) records 94,464
  byte-exact original-helper operations, snapshot/reconnection/failure cases,
  warmed allocation counts and component rendering at three scales. These
  scoped checks do not establish paired original working-frame pixels, physical
  suspend/resume behavior or comparative whole-window performance.
- `WorkspaceReplica` separates projects from task workspaces while retaining
  worktree handles, complete coordinator references, diff counts, command
  outcomes and allocator-owned strings. Replacement is atomic across allocation
  failure. `ActivityOrder` reproduces original project/attention order,
  full/compact selection, exact coordinator ancestry across sources, creator
  fallback, cyclic-edge removal and orphan commands in caller-owned bounded
  storage. The GUI currently supplies only the local source.
  `TaskCard` and `CommandCard` share the agent frame, hover, selection and
  physical-pixel border; tasks add compact rows, facts, final messages and plan
  cells. Navigation selects the actual task workspace and highlights its source
  project. [Activity validation](measurements/activity-validation.json) records
  1,261 original replica/forest cases, 2,301 original task-label/plan cases,
  allocation-failure and no-allocation checks, and independent components on
  both platforms. A later [paired Metal capture](measurements/visual-parity/README.md#tracked-tasks-and-commands)
  verifies actual worktree/hook metadata, twelve exact regions and the selected
  frame's perimeter. That earlier revision uses the wrong whole-label font
  fallback for the branch symbol; the mixed-font revision below corrects it.
  The parent age differs across independent launches. Complete task pixels,
  favicons, peeks
  and task interactions remain open.
- Project rows include the original worktree/working/finished summary and
  waiting count. `ProjectActivity` reuses the existing replicas and shared
  attention priority with borrowed views and caller-owned bounded text.
  An oversized summary preserves the path without throwing for capacity.
  `ProjectRow` renders independently of the application, reserves only title
  space for attention and retains the detail line's full width, inactive ink
  and identity-based selection. `WorkspaceList` binds and updates those rows.
  [Project validation](measurements/project-activity-validation.json) records
  2,590 original-source text/color cases, independent component checks and
  paired original rows. Its recording adapter does not compare native font
  measurement. Remote source composition, favicons, previews and complete
  hover/selection/density/theme frames remain open.
- `TextFit` preserves the original grapheme estimate, decrement rule and
  256-byte fitted-output limit with a caller-supplied measurement dependency.
  A bounded prefix table avoids repeated scans through prefixes that cannot
  fit the output. `GraphemeCursor` uses Ghostty's segmentation with the
  original 16-codepoint window. Full labels remain borrowed and retain their
  implicit width while the Qt adapter caches fitted glyph runs separately.
  [Text-fit validation](measurements/text-fit-validation.json) records 32,136
  byte-exact original fitting/segmentation cases, invalid-input checks,
  independent component tests and native rendering at three scales. In the
  updated four-card capture, project labels join titles, status words and
  provider marks as sixteen exact card-content regions. Native icons, card
  corner pixels, footer, full fallback and whole-window parity remain open.
- Mixed-font chrome uses allocator-owned `TextLayout` runs and the resident
  preferred/primary/text/symbol order. Unknown clusters retain primary shaping
  until bounded asynchronous native discovery appends a validated monochrome
  face. Immutable collections keep role identities stable through scene
  lifetime; mutable faces remain thread-local. The shared run iterator,
  bounds and ink transform also serve icon rendering. Single-span labels
  avoid a span allocation, and warmed mixed layouts reuse their storage.
  [Cascade validation](measurements/font-cascade-validation.json) records
  12,132 byte-exact cases against the actual original atlas/font-set/run/fitting
  sources with real bundled fonts. This oracle covers resident and missing
  fonts, not native discovery, rasterization or performance. Component tests
  separately exercise discovery, configuration replacement, destruction and
  callbacks that destroy their window. Procedural/color fonts and installed
  fallback for icons/cell text remain open.
- Resident icon rendering uses the preferred Plex face before the configured
  primary, embedded text and symbol faces. `IconLayout<Memory>` and
  `IconPlacement` expose allocation-controlled ink geometry without Qt.
  Immutable font sources resolve before rendering; each thread owns separate
  mutable faces. The Qt adapter retains masks and geometry through movement
  and color updates, samples at twice the label size and uses the original
  ink fitting and nearest filtering.
  [Icon validation](measurements/chrome-icon-validation.json) records native
  component/binding/curve checks on both platforms at three scales, scoped
  sanitizer runs, source-crop provenance and the tested numerical policy.
  Metal crop checks are exact; software/OpenGL comparisons against the Metal
  crops allow one channel level for composition. A separate icon material
  stabilizes texel-boundary sampling. In the updated four-card capture,
  twenty-three content regions match exactly; five status-icon pixels and
  the rounded card edges differ in that earlier capture. The later rounded-shape
  captures below correct those edges. Complete installed/procedural icon
  fallback, optical chrome, density typography, footer and whole-window
  visual/performance acceptance remain open.
- The default footer now renders resident CPU/memory icons, nine-column CPU
  history, the decimal `GB` label and battery geometry with the original
  warning/danger roles. Missing samples and absent batteries are hidden;
  TLS and dismissible diagnostics reserve the row's right edge. Standalone
  QML components accept projected data and need no application controller.
  `HostMetrics` keeps newer revisions and a fixed 32-sample ring; its dedicated
  Qt change notification avoids invalidating unrelated models. Disconnect
  clears the replica for a replacement runtime's revision restart.
  [Footer validation](measurements/footer-validation.json) records the scoped
  original-source oracle and platform checks. Configured sources, complete
  fitting/overflow and complete widget density/theme states remain open.
- Prefix/copy mode layout follows the original chip, whole-token fitting and
  eight-action hint order. Hints come from the effective keymap and preserve
  the first configured one-key alias. `ModeBarLayout` owns fixed-capacity text
  without Qt; `CellTextLayout<Memory>` keeps grapheme runs in caller-allocated
  storage and applies terminal cell spacing and whole-cluster clipping.
  `NativeCellText` shares resident masks and the retained text scene with
  chrome text. Synthetic bold/italic variants occupy distinct cache entries.
  Packed UTF-8 key characters use one helper shared with the native adapter.
  [Mode validation](measurements/mode-bar-validation.json) records the 5,696
  original layout/format requests, scoped sanitizer/native checks and live
  prefix/copy captures. Text matches exactly at the captured scale. The later
  rounded-shape captures remove the 28 rounded-chip differences in each footer.
  Cell text now shares the window's bounded installed-font discovery and retains
  its own primary face. Immutable alternate-primary collections are reused and
  invalidated when the fallback set changes. A complete settled history modal,
  including its continuation arrow, matches all 2,868,448 pixels at macOS
  backing scale 2. [Cell-font validation](measurements/cell-font-fallback.md)
  retains the missing-glyph regression, notification-lifetime checks, native
  fractional-size control, rejected resize captures and sanitizer limits.
  [Native resize capture validation](measurements/native-resize-capture.md)
  corrects acceptance of an image presented before a size change and removes
  GUI-thread deferral of drawable adoption. Qt-only controls and repeated paired
  inspector captures pass; the earlier intermittent failures remain unclassified.
  [Window restoration validation](measurements/history-window-restore.md) adds
  runtime-backed frame-admission checks across real hide/show on both platforms
  and accepted Cocoa minimization at three scales. Linux ASan/UBSan checks pass;
  an accepted Linux minimization transition remains unverified.
  Full font-cascade, density and performance acceptance remain open.
- Rounded chips, badges, battery, sparkline and base card backgrounds use the
  original rounded-rectangle distance/coverage/color equations. The pure
  `RoundedRectangle` value allocates nothing. The retained Qt adapter stores
  per-shape data in vertices and shares a batchable material; the software
  adapter shades scanline spans without full-area cached images. Cards preserve
  separate fill/ring passes and a one-physical-pixel outline.
  [Shape validation](measurements/rounded-rectangle-validation.json) records
  an unchanged-original-shader atlas of 17 cases, exact Metal atlas pixels at
  scales 1, 1.25 and 2, and a one-channel-level-per-layer bound on software/Mesa
  OpenGL. Pixels outside shapes remain exact. Sixty component invocations and
  six scoped sanitizer tests pass across both platforms. Live prefix/copy
  footers and the four sampled selected-card borders match exactly at scale 1.
  Other surfaces, full theme/density coverage, same-backend Linux goldens and
  comparative performance remain open.
- Qt-independent Braille and block geometry uses fixed-capacity values without
  heap allocation for valid cells, with a shared Qt adapter for row ink and
  block cursors. Bare scalars fill their configured cell, including spacing and
  device scale; combining sequences retain font shaping. All eight Braille
  bits, block fractions, quadrants and shade coverage match the original
  painters. Image tests cover bold/italic invariance,
  blank Braille, shade/faint composition, inverse colors, concealment, selection
  and cursor repaint. Faint ink now uses the original renderer's 0.5 opacity.
  Scene rectangles keep all underline styles visible above procedural ink on
  Qt 6.10 and 6.12.
- macOS optical font smoothing reuses the desktop client's concrete native
  backend for terminal rows, block cursor text and preedit. Its configured
  strength changes optical weight without changing the cell or baseline;
  inactive strengths and Linux smoothing preferences leave output unchanged.
  Native font access remains outside the application model. The shared backend
  no longer uses virtual dispatch and can rasterize into a retained `QImage`
  without a window or complete GUI. A standalone comparison compiles the
  original native rasterizer and matches 360 complete images at matching
  physical origins, covering three bundled glyphs, five sizes, two scales,
  three strengths and all four synthetic styles. It reproduced and fixed
  differing bold clipping and lost italic overhang in the shared component.
  Separate coverage checks premultiplied compositing, retained snapshots,
  invalid geometry, cursor/preedit adoption and procedural ink invariance.
  This does not establish complete native font or fallback equivalence.
- Generated Unicode edge weights, cell-aligned light/heavy/double/dashed boxes
  and disjoint intersections. Rounded corners and diagonals use the original
  bounded alpha-mask rasterizer. The differential corpus matches 1,209,552
  parsing, geometry, error and mask records on macOS and Linux, including raster
  row padding and storage guards. `CurveCache<Payload>` is independent of Qt;
  regressions verify fixed admission, retained identities, saturation and
  memoized failures. Qt shares color-independent masks across row and cursor
  materials, with 56 exact entries, seven reserved fallback shapes and a
  256-pixel raster limit. Native nodes retain their masks across cache resets.
  Software nodes own their colorized textures. Image tests cover physical
  stroke scaling, bold/italic invariance, diagonal orientation, cursor tint,
  faint intersections, large-cell fallback and repeated resize with retained
  cursors. Box stroke thickness comes from the active FreeType face, including
  MVAR changes; standalone presentations without that metadata retain the Qt
  design-table fallback. Decorations use a physical cell-bottom anchor instead
  of following the font baseline. These checks do not establish complete glyph
  equivalence or comparative GPU performance.
- Conditional macOS and Linux window adapters; native code is outside the
  application model. macOS has an AppKit background effect and integrated
  window controls. Linux currently uses Qt window decoration flags.
- Native host effects use a template/concept session boundary. Exact-generation
  sound messages start the original serial/coalesced policy; configuration
  changes filter queued sounds. Independent Qt Core components execute the
  original platform command plans with three-second deadlines and bounded
  output, releasing admission after failure. Notice objects allocate through
  the caller's allocator and reuse completed storage; their concurrency upper
  bound matches the original 240-ticket inbox. The Qt service does not share
  that budget with other client jobs. Desktop failures remain best effort.
  Original-source command checks, process fault/lifetime tests, real Mac helper
  results and Linux private-D-Bus delivery have scoped coverage. Desktop pixels,
  suspend/resume, additional environments and comparative performance remain open.
- Window binding tracks destruction through a weak Qt pointer, disconnects
  previous window and screen subscriptions, and preserves an unchanged binding.
  Native dimension signals update the viewport without QML callbacks. Frame
  delivery requires the current binding generation and a terminal belonging
  to that window; replacing it, returning to it or rendering another empty
  window cannot authorize an earlier frame. A real-runtime regression first
  reproduced incorrect acknowledgements in both cases.
  Querying macOS control insets now leaves an uncreated window uncreated;
  creating native resources inside the property getter previously triggered
  QML binding loops when rebinding. A standalone native regression reproduces
  that failure before the correction.
- Live density changes update workbench geometry and independently mounted
  terminal items through public Qt notifications. Measurement, rendering,
  links and pixel mouse input use the effective Qt Quick ratio. Standalone
  tests use image-backed render targets without a QML engine or runtime.
  A Sway check reproduced unchanged 9x20 physical PTY cells at 125% in the
  previous C++ build. The corrected build reports 11x25 cells at 125%, 18x40
  at 200% and the original 9x20 after returning to 100%, read with
  `TIOCGWINSZ` in the child process. This covers one compositor's live changes;
  physical macOS display transitions remain unverified.

The [graphics recovery validation](measurements/graphics-recovery-validation.json)
records the per-pane pause path. The unchanged original pause table and recovery
functions match 13,535 operations, including bounded eviction, retry saturation,
focus acceleration, healthy restarts and successful/failed snapshots. The
unchanged original limit ledger matches 4,180 operations, including descriptions,
retained requested amounts, truncation, eviction, aggregation and report failures.
The C++ state uses fixed arrays and templated callbacks; neither model needs Qt.

The production graphics ingress now distinguishes resource limits from revision
resynchronization and malformed transfers. Replacements occupy one logical image
slot, superseded unreferenced incomplete transfers release their bytes, virtual
placement identity is independent of the image, and paused streams still accept
deletes. A failed critical request recovers the connection instead of leaving the
replica connected and incomplete. Diagnostic reports remain best effort and
retain unsent hits. These checks do not accept the complete retained-image or GPU
resource lifecycle, global CPU/GPU admission or comparative performance.

An independent local-socket fixture exercises the actual handshake, graphics
messages, session, pane projection, existing QML pause label, earliest-deadline
Qt timer and deferred connection recovery. It uses a controlled awake clock to
verify a retry without incoming runtime traffic. Native Metal and Vulkan runs
exercise the recovery fixture and existing header tests at 1, 1.25 and 2 scale.
They establish the tested routing and layout behavior, not paired pause-label
pixels or complete window equivalence.

The [graphics retention validation](measurements/graphics-retention-validation.json)
adds 49,809 byte-exact catalog observations against the unchanged original store:
retirement, referenced generations, initialized pixel prefixes, four-pane CPU
budgets, placement deletion, snapshots, detach and released credits. Non-limit
malformed errors share one outcome category. The reference uses the real image
and placement validators with a PaneId facade; live leases and shared-memory
mapping are not exercised.

The physical display box and stand-in sampling match 2,880 original records,
including saturated extents and rounded aspect ratios at five densities. The
renderer retains placement metadata independently of its newest uploaded texture.
The generic resource cache keeps the previous texture while loading or after an
adapter rejection, replaces a full cache slot without a blank frame, and invalidates
its resources on detach/reattach. Standalone scenes check changed dimensions and
source crops, placeholder fragments, RGB rows, straight alpha and oversized
textures. Native Metal/Vulkan scenes and the real-runtime Kitty case pass at
1, 1.25 and 2 scale.

Forty-eight cross-platform C++ capture pairs compare 430,080 pixels in the
fixture's declared image region at unchanged coordinates. The maximum channel
difference is two levels. Seven Linux full windows have extra black padding;
those size differences are retained in the results, with no alignment search or
rescaling. This comparison does not establish Zig/Qt image pixels or complete
window equivalence. The original configuration's `pane_mib` and `global_mib`
values belong to the runtime; the GUI's fixed CPU limits already match. Combined
CPU/GPU admission, asynchronous upload leases, shared-memory delivery and
comparative image performance remain unaccepted.

The later [lifetime and residency validation](measurements/image-residency-validation.json)
reproduces and fixes texture reuse after a catalog is destroyed and reconstructed
at the same address with the same image key and revision. Process-wide lifetime
identities replace address-based texture and scene invalidation. The pure cache
regression failed before the correction; the native case now verifies red pixels
becoming blue after reconstruction on Metal and Vulkan at all three scales.

The Qt-independent `ImageResidency<Resources>` policy matches 29,505 operations
against the original stable-handle table and unchanged allocation, eviction,
retirement, expiry and presentation functions, plus the original completion
transition block. The harness supplies validated metadata and retained-byte
totals and assumes pixel retention succeeds. Observations include admission,
resident bytes, in-flight limits, spare reuse, failed generations, dense row
order, release order, revisions and wakeup deadlines. The policy's native Qt
resource integration was still pending at that checkpoint; these observations
do not accept actual GPU memory use, asynchronous failure handling or lease safety.

Eight selected normal targets pass on macOS and Linux, including all 46 Quick
entries. Seven selected Linux targets and the residency oracle also pass with
ASan/UBSan and unsuppressed leak detection. The new native image scene has ten
Qt Test entries. Fifty-four Metal/Vulkan C++ image-region pairs compare 483,840
pixels with a maximum channel difference of two levels and none above two.
One full-window size difference retains black padding outside the declared image
item. These captures keep their original coordinates and sizes; they do not
establish Zig/Qt or complete-window visual acceptance. The unchanged clang-tidy
profile passes five affected translation units, and clangd checks pass all five
selected headers through the existing `.clangd` configuration.

The later [window resource validation](measurements/window-images-validation.json)
connects the policy to a shared table per Qt Quick window. All panes use the
same retained-CPU-plus-resident-RGBA admission credits. Views of the same catalog
share a texture and receive replacement notifications. Render nodes detach
before their backing texture is freed or rewritten. Same-size native spares
reuse their allocation; owned Qt staging pixels survive catalog replacement
without borrowing its allocator. The generic integer-resource cache remains
available to isolated tests and experiments.

The new scene cases exercise autonomous progress beyond four starts per frame,
two-view refresh, competing pane budgets, idle behavior and native spare rewrites.
They also reproduce and fix visible idle reuploads, a translated second view
losing its software-renderer transform, and premature release during temporary
Wayland render stops. A quota-blocked scene is checked for dormancy rather than
continuous repainting. Hiding or minimizing a window now releases its resources
immediately; a visible temporary stop preserves them. This hidden-window timing
differs from the original idle policy and needs comparative performance evidence.

Admission completes after native allocation and owned staging, before GPU
completion. The tested four-start bound is not proof of the original four
asynchronous transfers in flight. Staging copies are not charged to the semantic
quota. Native completion/failure handling, original upload leases, shared-memory
delivery, physical memory bounds and the original global draw limit remain open.
The new cross-platform captures still compare C++ Metal against C++ Vulkan;
broader paired Zig/Qt image pixels and whole-window acceptance remain pending.

Nine selected normal targets pass on both platforms; the standalone resource
scene has 18 Qt Test entries at each of scales 1, 1.25 and 2 on Metal and Vulkan.
The real-runtime Kitty fixture passes at each scale. Fifty-four C++ capture pairs
compare 483,840 image-region pixels with no channel difference above two levels.
Two full-window size differences retain black padding outside that region. The
unchanged 500-check clang-tidy profile passes nine affected translation units;
clangd passes six selected headers through the existing editor databases.

Eight selected Linux software-renderer targets pass with ASan/UBSan and
unsuppressed leak detection. The additional Vulkan run completes all 18 entries
but fails at exit on nine 96-byte Wayland allocations. An independent Qt-only
rectangle fixture creating 16 windows reproduces the same shared-library stacks
with ten 96-byte allocations; its single-window baselines were clean. Sources,
compile commands and failed logs are retained. No suppression or product
workaround was added, and native Linux leak acceptance remains open.

The separate [paired Kitty-image capture](measurements/visual-parity/kitty-images.json)
compares the original Zig client with the C++ client through the same original
runtime and configuration on macOS Metal. At effective scale 1 in the shade
theme, all 1,192,320 pixels in the previously declared workbench region match
exactly, without translation, alignment search or rescaling. Four inline images
in the unfocused second pane exercise RGBA, unaligned RGB rows, straight alpha
and a source crop. Each process receives four successful Kitty replies; fixed
placement-origin samples verify image presence. Native dimming remains in the
comparison. Both clients pass the unchanged geometry, focus, keyboard, marker
and GPU-completion checks, including all 21 warmup/diagnostic responses.

The first image corpus contained reds selected by the common marker predicate.
Its centroid moved into empty space, causing false input-timeout failures in
both clients. The failed captures reproduce that centroid exactly. The accepted
corpus limits opaque image reds while retaining straight alpha; the native probe
and its assertions are unchanged. The single post-warmup timing sample per
client remains diagnostic. This pair does not accept Linux image pixels, other
scales/themes, focused panes, dynamic image transitions or comparative performance.

The later [draw-budget validation](measurements/image-draw-budget-validation.json)
adds one 2,048-image-quad budget per window. Admission runs after synchronization
in actual scene-graph order, including scenes that did not rebuild. Each scene
constructs below-background placements, below-text placements, placeholder
fragments and above-text placements in the original order. Clipping adjusts both
destination geometry and source sampling; fully clipped placements use no draw
credit. Cached geometry includes its viewport dimensions in invalidation.

Native regressions exercise nine 256-placement views, hidden and reordered
retained views, 4,096 placeholder runs preceding an above-text image, and partial
clipping followed by viewport expansion. The full image scene now has 21 Qt Test
entries on Metal and Vulkan at scales 1, 1.25 and 2. Captures name nine semantic
states instead of relying on how often retry expressions evaluate. Eighty-one
cross-platform C++ pairs compare 1,666,560 pixels with a maximum channel
difference of two levels and black padding outside the declared item regions.
The repeated macOS Zig/Qt pair still matches 1,192,320 workbench pixels exactly.

The unchanged original `Renderer.pushImage` and `QuadList.clipQuad` bodies match
24,132 observations in the standalone probe on macOS, Linux and Linux ASan/UBSan.
Admission, cumulative counts, handles and destination values are exact. The
maximum normalized UV difference from rectangle/endpoint arithmetic is
0.00000011920928955078125. The adapter supplies finite rectangles, positive
source extents and sufficient quad storage; it does not exercise texture
readiness or native GPU work. The earlier 2,880 display-box/UV records still match.

Moving presentation accounting after synchronization exposed a retry loop under
a protected GPU quota. Retry decisions now exclude current visible references.
An additional regression showed that parked views did not wake when another
view hid its texture. Tracking the visible reference set now wakes them before
idle expiry, without forced test captures. The failing logs are retained.

Nine selected normal targets pass on both platforms. Eight selected Linux
software-renderer targets and the renderer probe pass with ASan/UBSan and
unsuppressed leak detection. The final native process completes all 21 entries
but fails on eleven 96-byte allocations with the previously reproduced Qt-only
Wayland stacks. This remains a failed native leak gate. Fifteen affected
translation units and the updated capture fixture pass the unchanged 500-check
clang-tidy profile; seven selected headers pass clangd.

The later [placement-selection validation](measurements/placement-selection-validation.json)
adds the fixed global heap before texture resolution. Priority is layer then
`z-index`, with placeholders always below text. Catalog views share placement
admission. Invalid source extents and empty display boxes do not compete.
Discarded placements neither request textures nor protect cached GPU references.
The GUI-thread snapshot is prepared after animation and during terminal polish;
synchronous standalone captures prepare it explicitly before rendering. Changed
selection membership updates retained views before scene synchronization.

The unchanged original `keep`, `paintsBelow`, `siftUp`, `siftDown`, `swapKept`
and display-layer functions produce byte-identical observations for 185 frames
and 479,532 candidates in the standalone selector probe. This establishes heap
behavior for identical traversal, including ties and placeholder priority.
It does not establish identical tie traversal between the original global hash
map and C++ per-pane stores. Entering overflow reports the original named limit,
requested count and noun through the shared session ledger. The existing runtime
and notification intervals, warning title and failed-report recovery are reused.
A nine-catalog regression exercises 2,304 placements, rejects an extreme-z
placeholder before any upload, restores it when a view hides, and records a
second entering reach when overflow returns.

Nine selected normal targets pass on macOS and Linux. The native image scene
passes 22 entries on Metal and Vulkan at scales 1, 1.25 and 2. Ninety C++ capture
pairs compare 2,392,320 pixels with a maximum channel difference of two levels
and black padding; the repeated macOS Zig/Qt workbench pair matches 1,192,320
pixels exactly. Seventeen translation units and the final two-unit polish
recheck pass the unchanged 500-check clang-tidy profile. Seven selected headers
pass clangd. Eight Linux software targets and the selector oracle pass ASan/UBSan
without leak suppressions. The native process passes all 22 entries and fails
on eleven 96-byte Wayland allocations with the previously reproduced Qt-only
stacks and identical library BuildIDs. Native leak acceptance remains failed.
The retained visual run has one diagnostic post-warmup timing sample per client;
it does not accept comparative performance.

Exact paired pixels for equal priorities at overflow remain open, as do
retained-node/staging bounds, native
completion/failure, upload leases, shared-memory delivery and comparative
performance.

The [clipboard shelf implementation](measurements/clipboard-images.md) now has
bounded native capture, allocator-aware retention, whole-row layout reservation,
preview modal, numeric/path marker learning and bounded dismiss input. Original
Zig comparisons include 16,384 catalog/marker lifecycle transitions with all
three deletion limits; selected private-pasteboard Cocoa checks pass five entries
and explicitly confirm Metal. Paired attachment pixels, Linux bounded provider
transfer, native leak acceptance and comparative performance remain open. The
expanded session run's notification fixture failure reproduces with HEAD; its
canonical protocol preparation is corrected and passes Release/ASan/UBSan.
This is not full attachment acceptance.

The subsequent [bounded Wayland transfer](measurements/clipboard-wayland.md)
replaces external GUI-thread PNG materialization with an owned pipe on the image
worker. Nine original-source Zig comparisons match bytes/error precedence under
clean C++ core ASan/UBSan; six private Sway provider cases pass, including a total
five-second stall with 501 GUI timer callbacks. Linux machine-window passes37;
Mac scene37 and selected native clipboard5 pass after shared-worker factoring.
All six native worker cases also exit cleanly with ASan/UBSan/leak detection in
an owned D-Bus session; no-bus Qt initialization leaks344bytes in both receiver
and no-worker control and remains recorded. An unequal source/PNG-cap negative
fails before its storage-bound correction. Final Mac Quick88 passes after
waiting for the exact delivered notification widget in the fixture; the earlier
86/2 failure is retained. Paired attachment visuals, seat/selection lifecycle,
XCB provider bounds, general native leaks and comparative performance stay open.

The [native attachment visuals](measurements/attachment-native-visuals.md) align
preview geometry and dimming to the original terminal-cell host. A paired native
negative exposes2,061,702 pixels before correction. Final five same-binary controls
match1,601,600 main-client pixels, including bare clicks, movement-before-click,
modal key consumption, restoration and subsequent motion. The complete modal
matches1,062,000pixels. Qt's extra move before a changed-position press requires
observing the raw window-system event while delegating delivery unchanged. The
isolated observer passes Release and native ASan/UBSan including destruction during
delivery. Native Window39/Quick88 and Linux ASan Window37 pass; final broad lint
and delivered Neovim diagnostics are clean. Native GUI sanitizer assertions pass5
but exit1 with593,028bytes in2,979 leaked allocations, without local suppression.
Complete-window differences, other themes/densities/platforms, remaining physical
ownership, provider lifecycle/bounds, native leaks and comparative performance
remain open. Regional matching does not close a global gate.

The [attachment pointer follow-up](measurements/attachment-pointer-ownership.md)
retains held backdrop ownership and closes only on a completed left click. A native
negative exposes Z leaking to the agent before release; a separate restored-close
hover negative exposes21,602 main-client pixels. Final six same-binary controls
match1,601,600pixels each, covering ×/backdrop close, interior hold, held input,
normal close hover and its restoration. Directed window4 and Linux Release/ASan
window37 pass, with clean broad lint and actual Neovim diagnostics. This scopes
additional pointer states; full physical ownership, full-window/platform visuals,
native leaks and measured comparative performance remain open.

The [bounded XCB image transfer](measurements/clipboard-xcb.md) adds asynchronous
normal/INCR selection reception through16KiB replies and a worker socket. Both
announced and actual source sizes are bounded; a published failure status rejects
valid PNG prefixes followed by protocol errors. The original synchronous XCB
control blocks the GUI for5s; the new receiver retains timer activity. A separate
retirement negative waits4.9s until cancellation before joining removes that wait.
Final provider and lifecycle qualification is recorded in the report. No original
Zig X11 backend exists, so this is scoped Qt XCB correctness and responsiveness.
Complete provider lifecycle, native visuals/leaks and measured full-client
performance remain open.

## Remaining functional work

| Area | Missing or incomplete behavior |
| --- | --- |
| Configuration and input | Execution of default/configured actions belonging to unported subsystems; complete configuration parsing and diagnostic equivalence; binding/callback limit reporting and held-limit title suffixes; comprehensive native normalization across layouts, function keys, IME, focus and physical ownership equivalence |
| Notifications | Desktop presentation and audio across additional environments and suspend/resume; comprehensive navigation/keyboard/accessibility equivalence; intermittent native Mac hover-test failures; paired focused/animated pixels; native Linux pixel acceptance and other themes/densities. Native host adapters, exact-generation audio routing, bounded native notice admission and the existing in-app center have scoped coverage. |
| Terminal | Complete styled/Unicode/fallback/IME and cache-pressure raster equivalence beyond the measured default-text scenes; remaining copy-mode prompt, focus and selection gestures; complete window-level pointer ownership with chrome, modal transitions and native devices; complete native/Qt face selection and source replacement; remaining cursor and decoration cases |
| Graphics | Native upload completion/failure and leases, shared-memory delivery, exact traversal of equal-priority global placement overflow; retained-node/staging-memory bounds; Linux/density/theme and dynamic paired image pixels; comparative allocation/latency evidence and native Linux leak acceptance. Shared window admission, global metadata selection and named reports, the draw bound, clipping, stand-ins, spare reuse, lifetime identity and covered idle/visibility transitions have scoped validation. One macOS shade/scale-1 static image pair matches exactly. |
| Pane chrome | Complete status/progress, Linux paired captures and other theme/density pixels. Graphics-pause routing now has a bounded recovery model, wire-level session coverage and an independent Qt header/timer fixture; the validation scope is recorded below. Attention rings/fades, the fullscreen bottom strip, cell-based views, prospective splits, focus, resizing, physical frame extensions, border focus and measured default/styled text scenes have scoped coverage. |
| Runtime control | Remaining routed CLI commands |
| History browser | Complete modal input lifecycle, additional hover lifecycles and remaining physical scheduling after selected-card replacement, inspector facts/content, exact day-group placement/scroll admission and older-row placement, expansion/leaving animation, remaining filter theme/density/hover and Linux paired pixels, remaining query notification/synchronization, additional loading themes/densities and physical scheduling, footer error-caption shaping, entrance animation and complete paired pixels; remaining focus, gesture and status behavior; comparative cache-pressure profiling. [Card action pointer capture](measurements/history-retained-actions.md) has original-source dispatcher and Cocoa/Sway Qt coverage; [retained row-hover admission](measurements/history-action-hover.md) corrects the observed geometry-driven hover after selected-card replacement, with a causal negative and two exact744,576-pixel Cocoa result regions; [keyboard-open row-hover admission](measurements/history-initial-hover.md) additionally matches two 567,296-pixel result regions under stationary and freshly moved pointers; the observed [asynchronous delegate retirement warning](measurements/history-delegate-retirement.md) is already closed. Physical panel/search/inspection geometry, compact paths, metadata/action and footer fitting, calendar/status labels, word wrapping, bounded card height/remainder, visible fuzzy matching, selection containment, row/footer revisions, capture retirement and reusable components have scoped coverage. One complete selected card, browse/inspect footers, six filter-header scenes and seven search bands match paired Cocoa pixels; other states/themes/densities and the complete window remain open. |
| Activity | Additional remote-source/task composition states; favicons and complete task/plan/native peek qualification; remaining density/icon pixels; complete scrolling, selection and task interactions; complete paired task/working frames on both platforms; physical suspend/resume validation. The generic bounded forest, coordinator ancestry, full/compact tasks, tracked commands, project progress/attention, plan cells and status clocks have original-source/component coverage. Scoped macOS live pairs verify worktree/hook projection and listed exact regions, including mixed-font task facts and project rows. |
| Navigation | Affirmative GUI release installation, additional SSH hosts, additional runtime-stop/failure states beyond the verified lifecycle and negotiation cases, complete machine switcher/segment visual qualification, complete task/plan state and source-composition qualification and full source-composed activity qualification, native focus qualification, additional workspace/worktree interaction states, remaining worktree management and nested picks. `goto-picker` opens a fuzzy native palette for contexts, current-context tabs and agents, with complete identities and query-preserving prefixes. The generated catalogue exposes all 29 actions, including the four machine actions. Initial `--remote`/`--machine` selection and remote command/home adoption are wired and have real loopback SSH coverage. The runtime path picker browses directories and inserts quoted relative or absolute paths; file-icon sampling, complete native path interactions, failure scenes and other theme/density pixels remain open. Suggestions use the runtime engine, retain retryable failures, discard stale replies and paste without Enter; returning to actions restores the query, selected row and editor selection. Leaving a linked worktree selects its project; cleanup only forgets gone rows without tabs. Bounded navigation history and canonical saved-layout restoration have original-source and live SSH round-trip coverage; visible and hidden restored roots follow a delivered in-flight window/sidebar resize. Machine picker/form actions have controlled coverage; a real OpenSSH loopback run also covers remote/local/remote input isolation. Four earlier palette panels, one empty path panel and eight suggestion panels have scoped exact Cocoa pixels; complete visual and interaction coverage remains open. |
| Extensibility | Plugins, custom bars, dynamic widgets, panels and picks; command-action integration with these surfaces |
| Footer | Configured bar positions/content, full priority fitting and overflow; exact diagnostic fitting and complete battery/badge/mode-chip density/theme geometry; complete mode-label font fallback. Default metrics, CPU history, TLS, dismissible diagnostics and prefix/copy hint layout are implemented. |
| Attachments and links | Complete clipboard/preview interaction and physical ownership qualification, paired pixels, Linux bounded provider transfer, native leaks and measured performance; diagrams and complete native link/preview equivalence. The image shelf, capture/retention, marker lifecycle, dismiss input and row reservation now have scoped implementation and correctness coverage. |
| Native behavior | Linux background blur, exact macOS blur strength and window behavior, desktop launch environment adoption, packaging and release integration |
| Interaction and accessibility | Tab drag/reorder gestures, context menus, complete keyboard-only navigation, focus/selection/scroll affordances and accessibility validation; current native Mac failures in window activation and link copying at fractional/doubled scales |

Some accepted configuration fields belong to these unported subsystems. They
are not evidence that the C++ client implements the subsystem.

## Performance acceptance remains open

The renderer retains unchanged rows, applies per-row frame damage, detaches
hidden panes and bounds CPU image storage. Those are implementation choices,
not measurements of superiority over Zig. Qt's text and texture allocations
remain outside the injected allocator's counters.

The [text scene control](measurements/text-scene-probe.md) now builds against
the current font-collection API. Nine native cases have matching Release/ASan
geometry, but sanitizer exit leaks remain. Four subsequent
[mesh retention experiments](measurements/text-mesh-retention.md) preserve all
30 intermediate geometry states and improve several rebuild cases, but each
consistently regresses another measured operation. None is adopted; their
complete paired results, storage negative and sanitizer failures are retained.

Optical smoothing reuses row buffers but rasterizes changed text and uploads
colored row textures. Its glyph clipping, rasterization and upload costs have
not been compared with the original glyph atlas.

The font cache retains one source and face across panes and eight bounded scale
entries. Tests verify unchanged injected allocations while changing scale or
optical weight preferences; they do not measure comparative performance.
Qt and FreeType internal allocations remain outside those counters. Cold font
lookup, file loading and validation still run on the Qt thread and have no
accepted paired measurement against Zig.

Frame acknowledgements follow `QQuickWindow::frameSwapped`. That endpoint
must not be equated to the original Metal probe's verified GPU completion.
A fair comparison needs equivalent visible grids and workloads, release builds,
alternated paired runs, input-to-visible-output latency, loaded frame
throughput, idle/loaded CPU and memory, and image/chrome stress cases. The
correctness oracle must account for the requested functional equivalence;
byte-identical render buffers are not applicable across these renderers.

The historical presentation experiments below used a runner with
`--mode telar`, `--cpp-gui`, `--endpoint presented` and capture support. Those
options are absent from the shared tools transferred to Personal; their current
probe stops at verified GPU completion. The historical large raw archives also
remain on the source machine, as recorded in the handoff. The old reproduction
commands do not describe the current shared runner.

The Personal continuation freezes a separate local harness and both current
Release binaries. Its diagnostic presentation probe joins marker verification
to the exact drawable's `MTLDrawable.presentedTime`, records native VSync and
drawable identities, and keeps GPU callback timings separate. Missing records,
disabled VSync, dropped presentation and mismatched geometry reject comparison.
These observations have no physical photon/scanout endpoint. Current comparative
acceptance remains open. A reproduced [fixture resize race](measurements/fixture-resize.md)
is corrected with a complete SIGWINCH transaction and five focused controls;
the corrected fixture epoch is recorded separately. Peak RSS still includes
startup, instrumentation and viewport negotiation.

The [native presentation experiment](measurements/frame-presentation.md)
retains 84 planned jobs and all thirteen failed controls. That historical Qt build loses
every valid unloaded p50 pair against Zig: six single, six split and seven tab
pairs. A private eager-delivery prototype wins seven of seven p50 pairs against
current Qt in each unloaded case, but still loses to Zig in single and tabs.
Only one loaded Qt/prototype pair is valid. The prototype is not adopted;
generic QPA timers and Wayland compositor callbacks require further work.
Its three static workbench captures match 3,576,960 RGBA pixels, without
accepting complete visual parity. The final report validator preserves all
71 valid and thirteen invalid job classifications, and nineteen focused Python
tests pass. This experiment does not add Linux performance acceptance or
close the existing native leak gate.

The later [guarded Cocoa experiment](measurements/cocoa-frame-policy.md)
qualifies the timer guard in an independent native control, but its five valid
Qt/candidate pairs do not meet seven-pair acceptance. Diagnostic mappings prove
input receipt and marker writes; further traces reproduce expected GPU pixels
with zero native presentation timestamps in both clients. One such Zig case
also records an awake display and unoccluded window. The cause remains open;
neither prototype adoption nor complete performance acceptance follows.

The [GUI pacing policy](measurements/frame-pacer.md) adds an independent,
fixed-storage port of Zig's cadence and per-pane input grace. Its original-source
oracle matches 32,174 stateful operations on macOS and Linux, including Linux
ASan/UBSan. Production runtime negotiation and the shared animation clock now
use its interval bounds; `max_fps` applies to animation loading/reloading and
clearing without restarting an attention fade. The pane-grace state machine
still needs native admission integration. All 22 Linux stages pass, while the
complete Cocoa attention suite retains five frame-wait failures. This closes
the scoped interval/cap regressions, not native frame delivery, full visual
acceptance or comparative performance.

The [terminal-admission correction](measurements/terminal-frame-admission.md)
records pane/frame/attachment and link preparations at actual node
synchronization. Window bindings retain independent allocator-owned snapshots.
New runtime regressions prevent hidden or unsynchronized content from being
acknowledged by an unrelated window frame; Metal and Vulkan checks pass, as
does complete Linux QuickTest under ASan/UBSan. A fresh complete inspector modal
matches 2,868,448 RGBA pixels. Frozen pre-change and current binaries both retain
native Cocoa hover/copy failures. A private trace sees rejected clicks ahead of
the prepared frame. Their dispatch cause, per-pane pacing admission, physical
presentation, complete visual parity and comparative performance remain open.

The [frame-wait investigation](measurements/gui-frame-waits.md) adds independent
Qt-only manual, application and local event-loop controls. Eight of 36 manual
updates miss the first approximately 100 ms preparation observation; neither
event-loop control does. Bounded local event-loop waits now serve the shared
frame and attention fixtures, while hover-copy waits passively on actual
terminal/link readiness. The production GUI binary is unchanged. Five selected
software suites pass on both platforms, affected Linux sanitizer runs pass,
and all twelve Vulkan jobs pass at factors 1, 1.25 and 2. The complete Metal
attention suite passes with exact original-shader phase images at each factor.
Initial Cocoa activation failures and a final isolated hover readiness failure
remain recorded and open. This test change adds no physical-presentation or
comparative performance acceptance.

The [window pacing adapter](measurements/window-frame-pacer.md) supplies deferred
Qt update delivery around the pure policy, with constrained clock/window types
and no application or runtime dependency. Seven Qt Core cases cover deadlines,
pane-scoped input, cadence replacement, hiding and destruction. Six final Metal
and twelve Vulkan controls deliver the final prepared generation across three
factors; Linux Release and ASan/UBSan checks pass. The initial native-window
fixture failures remain recorded. ARM64 and both x86-64 object configurations
compile, without an Intel execution claim. Application input/output hooks,
visible-pane admission and window-binding integration are still required;
the production GUI binary and complete parity gates are unchanged.

The [controller pacing integration](measurements/controller-frame-pacing.md)
now applies that adapter to visible model candidates and actual prepared-pane
commits. Successfully queued user input grants pane-scoped grace; protocol
reports and refused input do not. Output can wake a held update, and replacing
a binding returns the old request without transferring its pacing state.
The default observer performs no clock reads. Complete Metal suites pass all
74 entries at factors 1, 1.25 and 2; Vulkan assertions also pass, with Linux
minimization still declined. One final native sanitizer job fails on a 96-byte
allocation matching the prior Qt-only Wayland stack, so that gate remains open.
The record retains and diagnoses stale geometry and attachment-count assumptions
in test fixtures. A fresh inspector pair matches all 2,868,448 modal pixels.
Native preparation/dispatch coverage, physical input/presentation, complete
visual parity and comparative latency/CPU/memory acceptance remain incomplete.

The [native readiness comparison](measurements/native-presentation-readiness.md)
requires a verified initial drawable presentation before input. Its complete
84-job original/previous-Qt/current-Qt collection retains 73 valid jobs and
11 rejected controls: eight first-response failures and three offered-rate
failures. Current Qt loses every valid p50 pair against Zig in all four cases.
Against previous Qt, controller pacing wins five of five loaded p50 pairs and
one of six tab pairs. No comparison reaches seven valid pairs. Performance
acceptance remains open; production code, editor configuration and the broad
clang-tidy profile are unchanged by this measurement pass.

The later [Cocoa dispatch experiment](measurements/cocoa-update-dispatch.md)
completes 144 fixed attempts with 127 valid jobs and 17 failures retained.
Unloaded p50 wins against the preceding Qt executable are 12/12 for one pane,
11/11 for splits and 10/10 for tabs. Loaded splits regress consistently:
0/7 p50 wins and 1/7 p95 wins. The candidate is rejected; seven source/editor
files are restored and its two platform files are removed. All 122 preceding
production hashes match again. Its candidate tests and scoped inspector pixels
do not establish full parity, and its native dispatch change is not shipped.

The [native palette navigation](measurements/palette-navigation.md) adds the
real `goto-picker` route and reusable query, ranking, label and geometry
components. Its original-source probe matches 5,595 records. Empty navigation,
selected-tab and no-result panel pairs match 3,563,520 presented Cocoa pixels;
window differences remain outside those panels. Runtime-backed tests cover
tab navigation, stale choices, mode changes, composition and UTF-8 limits.
Complete Metal suites pass 77 entries at each tested scale. Vulkan assertions
pass, but final native sanitizer runs retain the unsuppressed 96-byte Wayland
leak. Full catalogue, machines, suggestions, paths, other visuals and
comparative performance remain open.

The [action catalogue and worktree flows](measurements/palette-actions.md)
extend the palette to 23 implemented actions in original order. Generation
reads the original 29-entry catalogue instead of keeping another label table.
The differential probe matches 15,936 records, including the unchanged
original action collector and both host key-label styles. Independent session
tests cover project handoff, safe cleanup eligibility, bounded correlations,
rejected delivery and concurrent runtime removal. Full functional, visual and
performance acceptance remains open; the action footer retains a reproducible
54-pixel arrow difference.

The later [fallback alignment correction](measurements/palette-arrow.md)
removes that arrow difference by applying the existing pixel-center coverage
and standard mask sampling to implicit fitted-text placement. Four complete
presented palette panels match 4,751,360 pixels. Complete Metal suites pass
78 entries at requested scales 1, 1.25 and 2; all nineteen Linux validation
stages pass, including Vulkan components, full integration and one native
ASan/UBSan run. Historical leak acceptance stays open. A separate macOS
form-component composition assertion fails with both original and changed
renderer controls; its cause remains unresolved. No comparative performance
acceptance follows from these results.

The [runtime path picker](measurements/path-picker.md) adds the 24th catalogue
action, directory browsing, quoted relative/absolute insertion, atomic paste
and the original 64-byte query limit. State, labels, placement and footer
fitting are usable without Qt. Its differential probe matches 9,989 cases
on macOS and both Linux variants. Complete Metal suites pass 80 entries at
three requested scales; final Vulkan suites pass 79 entries with one
unsupported-minimization skip. All eighteen final Linux stages pass with
leak detection enabled. Three actual clangd LSP opens and selected broad
clang-tidy checks pass. Four presented path panels retain 283 file-icon
pixel differences; the empty panel matches all 259,200 pixels. Failed window
manager and stale-cache attempts are retained. Historical sanitizer and
composition failures, remaining native path states, complete visual parity
and comparative performance remain open.

The [runtime suggestion palette](measurements/suggestions.md) adds the 25th
catalogue action, stale-reply handling, retryable failures and reviewed paste
without execution. State, labels, layout, wrapping and framing remain usable
without Qt. The original-source oracle matches 8,397 cases across macOS,
Linux Release and Linux ASan/UBSan. Eight final presented Cocoa panels match
all 6,389,760 compared pixels. Complete Metal integration passes 82 entries
at three scales; Vulkan passes 81 with one unsupported-minimization skip.
All 26 final Linux stages pass with leak detection enabled. The isolated
component exposed a terminal callback running during base destruction;
disconnecting its teardown subscriptions removes the reproduced invalid
font accesses. The same Valgrind control reports zero errors without
suppression. Failed hypotheses and harness attempts are retained. Four
machine actions, other native scenes, historical sanitizer gates and
complete functional, visual and comparative performance acceptance remain open.

The Zig ReleaseFast baseline and both original CPU benchmark targets now build.
The CPU GUI probe's obsolete `pane_images.finish()` call has been replaced with
CPU-only completion of the existing lease and residency fields, including
cleanup on early exit. Selected stream/echo and retained-image modes pass.
This repairs the reference tool; it does not establish comparative GUI performance.

The [text-scene experiment](measurements/text-scene-performance.md) removes a
duplicate vertex/material paint during mesh construction. Seven alternating
Release pairs on Mac and Fedora improve all six creation/rebuild cases with identical
ordered geometry and material digests. Retained repaint does not show an
accepted improvement, and its small case has a slower median. The independent
probe measures detached CPU scene nodes with warm caches. Complete-frame
latency, process CPU/memory and comparison against Zig remain separate gates.
No complete comparative performance result has been accepted for this port.
The same experiment completes seven valid unloaded pairs per single/split/tab
case against the original GUI. C++ loses all seven latency and peak-RSS pairs
in every case, and idle CPU also meets the consistent-regression rule.
Loaded cases retain only three/five valid pairs because six original-client
jobs miss the offered-rate control; they cannot establish seven-pair acceptance.
The causes of these differences require further experiments.

Configuration metadata polling and replacement Lua evaluation now execute on
a worker. In the [paired C++ adapter experiment](measurements/configuration-reload.md),
the Qt-thread occupancy and pending timer metrics won seven of seven pairs.
End-to-end completion and complete process CPU did not show an accepted
paired win. Process CPU includes startup and fixture work. This does
not establish comparative performance against Zig. Initial loading, font
validation and a callback's lazy module loading remain synchronous. Shutdown
can still wait for blocking filesystem work. Idle polling costs, small files,
slow filesystems and loaded terminal workloads remain unmeasured.

## Validation performed

Validation used the working tree based on `2ac4d6016dd23592e61d7f03a4c24d83aab7ba9f`
on 2026-10-26 and 2026-10-27. These results cover the selected test fixtures above.
Input fixtures synthesize Qt events and use Qt Test helpers. A native rendering
backend does not establish complete physical-device event normalization.

| Environment | Result |
| --- | --- |
| Fullscreen strip and pending viewport delivery, macOS and Fedora | [Validation](measurements/fullscreen-strip-validation.json) retains 8,016 exact original-source geometry frames on both platforms and Linux ASan/UBSan. Five selected CTest targets pass per platform; native component/runtime checks pass at requested scales 1, 1.25 and 2. Three Linux sanitizer targets pass with leak detection. Nine affected translation units pass the unchanged 500-check profile. Three Metal pairs match 2,591,640 complete fullscreen-pane RGBA pixels, including 56,340 nested strip pixels. Full-window, additional theme/density and comparative performance acceptance remain open |
| Cell-based pane geometry, macOS and Fedora | [Validation](measurements/pane-grid-validation.json) compares 5,700 unchanged original layout frames, including focus, minimum-preserving resizing, prospective splits, fullscreen and 64-pane trees. Native geometry/input checks, Linux sanitizers and scoped static/editor checks pass. Two/four-pane Metal pairs match all fixture PTY sizes and marker positions; the complete focused marker pane matches 596,160 RGBA pixels per scene. Text-bearing unfocused panes, fullscreen bottom chrome and comparative performance remain open |
| Pane headers, macOS and Fedora | [Validation](measurements/pane-header-validation.json) retains original-source geometry/status/progress records, independent Qt component and generation tests, native component scales, sanitizer results and scoped lint/editor checks. The focused program-label band matches 11,856 raw RGBA pixels. Its contemporaneous split-grid comparison failed; the later cell-grid entry records that correction. Fullscreen bottom chrome and comparative performance acceptance remain open |
| Original sound state and host payload filtering, macOS and Fedora | [Core validation](measurements/notification-effects-core-validation.json) records 10,943 byte-exact operations across both platforms and Linux ASan/UBSan with leak detection. It covers admission, coalescing, policy changes, scheduling failure and bounded byte filtering; native adapters have separate later coverage |
| Native sound and desktop-notice adapters, macOS and Fedora | [Validation](measurements/notification-host-effects-validation.json) records 2,384 original-source command frames, exact agent-generation routing, policy reload, allocator failure/reuse, cancellation and callback destruction. Real Mac helper requests and an isolated Linux D-Bus service exercise native integration. Fourteen selected CTest targets pass per platform, six Linux sanitizer targets pass and all six native Wayland/Vulkan invocations pass. The final Mac native suites retain link-copy and activation failures at scales 1.25 and 2; earlier ready-sound timeout, hover failures, CMake cycle and editor diagnostics also remain recorded. Whole-GUI and performance acceptance remain open |
| Physical sidebar metrics and focused completion, macOS and Fedora | [Validation](measurements/sidebar-density-validation.json) records 17,520 exact original geometry frames and 6,505 acknowledgement operations, including Linux ASan/UBSan. Thirteen selected CTest targets pass per platform; final native checks pass 12 Mac and 27 Linux invocations at scale factors 1, 1.25 and 2. Sixteen translation units pass the unchanged 500-check lint profile. Listed captures match 221,575 RGBA pixels; six scale-2 project-glyph pixels, earlier icon-reload failures, the general chrome leak and full parity remain open |
| Notification placement and interaction, macOS and Fedora | [Validation](measurements/notification-interactions-validation.json) compares 12,546 original-source preparation frames byte for byte, including Linux ASan/UBSan. It checks press activation, body/close hover precedence, Return/Enter/Space, native keyboard focus, physical underline ink and terminal focus restoration in the real workbench. Listed native hover regions match 256,208 additional RGBA pixels at backing scale 2; full visual and performance acceptance remain open |
| Notification actions and routing, macOS and Fedora | [Validation](measurements/notification-actions-validation.json) covers immutable configured values, callback-owned descriptions, obsolete/forged references, zero injected allocations across 100 retained lookups, semantic navigation, focus retention and real runtime publication/dismissal. Five focused Linux ASan/UBSan tests pass with leak detection; complete native Vulkan runtime suites pass all 44 entries at scales 1, 1.25 and 2 |
| Notification lifecycle and body wrapping, macOS and Fedora | [Validation](measurements/notification-validation.json) records 7,246 byte-exact original-source center operations and 30,888 wrapping cases. Both oracles also match under Linux ASan/UBSan. Eight focused Linux tests pass with leak detection; Apple sanitizer attempts retain their unsupported option and timeouts without claiming coverage |
| Stable notification cards, macOS Metal | [Three paired captures](measurements/visual-parity/README.md#notification-cards) match 206,048 complete card-and-shadow RGBA pixels. They cover all four levels, two simultaneous cards, fitted title/body, direct and fitted HTTPS host labels, a pane action and two sidebar widths. Other themes/densities, animated pixels, complete interactions and comparative performance remain open |
| Independent notification overlay and runtime integration | Software/native component checks pass at scales 1, 1.25 and 2 on both platforms. Fullscreen Wayland/Vulkan runtime suites pass all 43 entries at each scale. Initial tiled-window failures remain recorded: the compositor reduced available space, fitting the host label or hiding undersized cards. Thirteen macOS translation units pass the unchanged 500-check lint profile, and both new domain/Qt headers pass clangd checks |
| Tab activity and compact progress revision | [Validation](measurements/tab-activity-validation.json) retains 45 matching host/guest source and fixture hashes, 500-check clang-tidy results across 14 macOS translation units, editor checks and VM cleanup |
| Original tab activity, rings, capsules and motion, macOS and Fedora | 5,512 records match each platform's original byte-for-byte; Linux ASan/UBSan matches its native oracle too. Two original cosine fractions differ by one float ULP across platforms; the native policy preserves each original result |
| Independent tab activity, Cocoa/Metal and Wayland/Vulkan | Forty-eight component invocations pass across native/software rendering and scales 1, 1.25 and 2. The 120-pose Metal atlas is exact; Vulkan and software stay within the existing per-layer channel allowance. OpenGL retains 1,619 pixels outside that allowance; Linux now defaults to Vulkan |
| Live selected-tab terminal progress, macOS Metal | [Narrow/wide captures](measurements/visual-parity/README.md#terminal-tab-activity-and-progress) match both complete selected pills, 8,940 RGBA pixels, and both entire tab bands without normalization. The original runtime receives a real foreground worker's OSC report. Notifications and whole-window acceptance remain open |
| Tab activity lifecycle and memory | Twenty-four repeated callback-driven window destructions pass on macOS. Seven selected Linux software CTest targets pass with ASan/UBSan and leak detection. All 43 native Vulkan runtime-suite entries pass normally. The native atlas passes its assertions but retains an unresolved 96-byte Wayland allocation; general chrome retains its previous 240-byte libcrypto allocation. Neither leak is suppressed |
| Project progress and attention revision | [Validation](measurements/project-activity-validation.json) retains 17 matching host/guest source hashes, original-source and shared-helper regressions, component/editor/lint checks and cleanup receipts |
| Original project summary and attention drawing, macOS and Fedora | 2,590 byte-exact text/color cases match the unchanged original functions over the actual workspace replica and attention comparator; identical output passes with the C++ probe under Linux ASan/UBSan. Recording measurement does not prove native font geometry |
| Independent project rows, Cocoa/Metal and Wayland/OpenGL | Twelve component invocations per platform pass across software/native backends and scales 1, 1.25 and 2. Selected runtime cases pass, and five selected Linux CTest targets pass with sanitizers and leak detection. The separate general chrome test retains its unsuppressed 240-byte libcrypto leak |
| Paired project rows, macOS Metal | [Narrow/wide captures](measurements/visual-parity/README.md#project-progress-and-attention) match both complete project-row rectangles, 38,168 RGBA pixels total, including summary, waiting indicator and narrow ellipsis. Other row states/themes/densities, favicons, tab activity, notifications and whole-window acceptance remain open |
| Mixed-font chrome revision | [Validation](measurements/font-cascade-validation.json) retains 48 matching host/guest source hashes, original dependency/artifact hashes, component/lifecycle checks, editor results and remaining gaps |
| Original atlas, font set, runs, fitting and transform, macOS and Fedora | 12,132 byte-exact cases with real bundled faces and three configured primary fonts; identical outputs also pass with the C++ probe under Linux ASan/UBSan. This excludes procedural sources, installed-font discovery and rasterization |
| Mixed-font components, Cocoa/Metal and Wayland/OpenGL | Forty-eight invocations per platform pass across eight independent components, software/native backends and scales 1, 1.25 and 2; four selected live-runtime integration cases also pass on each native backend |
| Mixed-font lifecycle and memory, Fedora | Eleven selected CTest targets pass with leak detection and ASan/UBSan enabled, including worker replacement and callback-driven window destruction. The separate general chrome test passes its assertions but still exits 23 for the retained 240-byte libcrypto allocation; no suppression is used |
| Paired mixed-font task facts, macOS Metal | [Narrow/wide captures](measurements/visual-parity/README.md#mixed-font-task-facts) retain 22 exact regions, including the complete narrow selected parent card and both widths' facts lines. The branch symbol is visible in the wide pair. Project summaries, tab activity, notifications and whole-window acceptance remain open |
| Activity revision | [Validation records](measurements/activity-validation.json) retain current source and log hashes, original-source oracles, component/backend matrix, editor context and remaining acceptance gaps |
| Original workspace replica and activity forest, macOS and Fedora | 1,261 byte-exact cases, 43,559 nodes and depth up to 1,087; the full 17-source bound, coordinator aliases, stale references, cycles, dropped paths and UTF-8 tail boundaries are covered |
| Original task labels and plan cells, macOS and Fedora | 2,301 byte-exact cases cover bounded facts, all status variants, final-message lines, integer limits and zero/eight-cell plan boundaries; recording facades do not establish rasterization |
| Activity components, Cocoa/Metal and Wayland/OpenGL | Twenty-four invocations per platform pass across task cards, base agent cards, advancing clocks and chrome at scales 1, 1.25 and 2, including software rendering; these are independent component checks, not paired Zig captures |
| Paired live task capture, macOS Metal | Twelve unchanged-coordinate regions and 3,756 selected-card perimeter pixels match exactly with actual worktrees, hooks, coordinator references and a failed command. Both clients use 145x46 PTYs and marker [463,191] in 1600x1000 targets. Full-task facts expose whole-label Qt fallback for U+2387; project summaries, tab activity and notifications still differ |
| Activity revision, Fedora ASan/UBSan | Six affected CTest targets and both complete new original-source oracles pass with leak detection enabled. The additional chrome target passes its assertions but retains the single 240-byte libcrypto leak, reproduced again without Telar code; its sanitizer gate remains failed |
| Activity editor context and lint | Ten affected translation units pass the unchanged 500-check clang-tidy profile; QML lint passes. Generated domain-header flags prevent platform-only command inference; four final clangd checks report zero errors |
| Tab-strip revision | [Validation records](measurements/tab-layout-validation.json) retain final source/log hashes, the original fitting oracle, native/scaled interactions, font-resolution probe and remaining leak; [paired captures](measurements/visual-parity/README.md#tab-strip-geometry) retain one and four tabs |
| Original tab-strip fitting, macOS and Fedora | 26,800 records matched byte-for-byte, including widths, compression classes, visible ranges, nearest hidden tab and total footprint; the complete presentation runner matched 349,726 records on macOS |
| Tab-strip revision, macOS CTest | Thirty-two targets passed in normal and recording builds; seven independent chrome cases and two selected integration cases passed on Cocoa/Metal at scales 1, 1.25 and 2; final editor checks received zero clangd diagnostics for both new headers and the Qt implementation |
| Tab-strip revision, Fedora | Thirty-one normal targets passed; seven independent chrome cases passed on Wayland/OpenGL at scales 1, 1.25 and 2; full native and recording integration passed at scale 2, and recording chrome/integration CTest targets passed |
| Tab-strip revision, Fedora ASan/UBSan | Pure fitting/presentation passed. All seven chrome cases passed their assertions; process shutdown still reports the same single 240-byte libcrypto allocation. The sanitizer target remains failed, with leak detection enabled and no suppression |
| Contextual captions and foreground metadata | [Validation records](measurements/tab-caption-validation.json) retain source/reference/log hashes, both allocator-adoption paths, the window-title regression and stage-specific results; visual/performance acceptance remains open |
| Original directory, caption and application-name resolution, macOS and Fedora | 75,111 records matched byte-for-byte; the complete presentation runner matched 322,926 records on macOS |
| Caption revision, macOS | Thirty-two CTest targets passed in both normal and recording builds; 500 clang-tidy checks passed across 64 translation units, followed by the same checks on the two units affected by window-title consolidation; Neovim received zero clangd diagnostics for the new header |
| Caption revision, Fedora | Thirty-one normal CTest targets and three pure ASan/UBSan targets passed; the later window-title correction passed the full normal suite and sanitizer session target; independent chrome tests passed at scales 1, 1.25 and 2, and the complete Wayland/OpenGL integration suite passed at 2 |
| Caption projection and rename interactions, Cocoa/Metal | Four independent chrome cases and the rename/tab-lifecycle integration case passed at scales 1, 1.25 and 2 before the final window-title-only correction |
| Sidebar/navigation revision | [Validation records](measurements/sidebar-chrome-validation.json) retain stage-specific results, source/log hashes, the corrected native test precondition and the unsuppressed sanitizer failure |
| Updated paired Metal captures, macOS | Expanded and collapsed sidebar states retained beside their initial baselines; original project/path/activity placement, rail marks and navigation context now appear; text ink, tabs and footer still differ |
| Sidebar geometry, rail drawing, window range and workspace marks, macOS and Fedora | 92,351 byte-exact records matched the extracted original Zig code, including fractional coordinates, overflow counters, malformed initial fragments and hue identities |
| Sidebar component and native window tests, Cocoa/Metal | Three independent chrome cases, eight window lifecycle/density cases and two selected integration cases passed at scales 1, 1.25 and 2 |
| Sidebar revision, macOS CTest | Thirty-two targets passed in the native and recording-host builds; the affected chrome/window/integration targets passed after the scrollbar correction; the later visibility-fixture precondition passed native checks at all three scales and the complete recording suite |
| Sidebar revision, Fedora Wayland/OpenGL | Thirty-one normal CTest targets passed; independent chrome/window tests passed at scales 1, 1.25 and 2; complete integration passed at 1 and 1.25, then at 2 after requiring expanded geometry in the visibility fixture; updated chrome and visibility cases also passed at all three scales |
| Sidebar revision, Fedora recording host | Chrome/integration CTest targets and the complete native integration suite at scale 2 passed |
| Sidebar revision, Fedora ASan/UBSan | Pure presentation and window targets passed. All three chrome cases passed their assertions, but LeakSanitizer rejected process shutdown for a 240-byte OpenSSL allocation. A Qt Quick-only program with no Telar code reproduces the same allocation on Qt 6.10.3/OpenSSL 3.5.1; leak detection remains enabled and chrome sanitizer acceptance stays open |
| New presentation headers, Neovim | The user's real editor configuration received clangd diagnostic publications for sidebar geometry, rail geometry and workspace marks, with zero diagnostics; the checked-in `.clangd` and build-hook configuration hashes are retained |
| Paired Metal visual captures, macOS, baseline scale | Expanded and collapsed states retained with binary/configuration/probe/PNG hashes; both clients exposed 145x46 and 171x46 cells respectively, with identical marker positions; chrome remains visibly different and visual acceptance stays open |
| Single-pane scene origin, notifications and cross-pane pointer regressions, Cocoa/Metal | Six selected cases passed at scales 1, 1.25 and 2 after reproducing the header/border and safe-area failures; the current software integration suite also passed |
| Window root and notification cleanup, Fedora Wayland/OpenGL | Complete native and recording-host suites passed at scales 1, 1.25 and 2, with forty-one and forty-four cases respectively; three further pointer/focus cases passed at all three scales after waiting for the actual focused delegate |
| Common GUI comparison runner | Five standalone Python cases check exact fixture arguments, invalid modes, per-pane/grid/marker rejection, Zig reference selection and preserved Ghostty reference selection |
| macOS 26.6.2 ARM64, Clang 23.1.2, Qt 6.12.0, C++ runtime | Twenty-three core targets, standalone window lifecycle/density and font resolver tests, optical rasterizer, Qt key adapter, link opener and configuration monitor, terminal scene tests and Qt integration passed, thirty-one CTest targets total in both native and recording-host builds |
| macOS Cocoa, Qt Quick threaded RHI/Metal, Apple M3 | Complete native and recording-host integration suites and eight standalone window cases passed with `QT_SCALE_FACTOR` values 1, 1.25 and 2, with forty native and forty-three recording integration cases per run; earlier complete suites also passed at factors 0.5 and 0.625; twenty-nine terminal scene cases passed at 1x and 2x; eight earlier glyph/metric cases passed at 4x before the native font-grid change |
| Fedora 43 ARM64 VM, Clang 21.1.8, Qt 6.10.3, Zig runtime | Twenty-three core targets, standalone window lifecycle/density and font resolver tests, Qt key adapter, link opener and configuration monitor, terminal scene tests and Qt integration passed, thirty CTest targets total in normal, sanitizer and recording-host builds |
| Fedora Wayland/Sway, Qt Quick software backend | Thirty native integration cases and thirty-three recording-host integration cases passed before the title/sidebar changes; the current complete native and recording integration also passed with the offscreen software backend |
| Fedora Wayland/Sway, Qt Quick threaded RHI/OpenGL, software GL | Complete normal, sanitizer and recording-host integration suites passed at process scales 1, 1.25 and 2, with forty normal and forty-three recording cases per run; standalone window tests and real compositor density transitions passed in all three builds; twenty-nine terminal scene cases passed at 1x and 2x |
| Fedora Debug with ASan and UBSan | All thirty CTest targets and the complete native OpenGL integration suite at process scales 1, 1.25 and 2 passed with `ASAN_OPTIONS=detect_leaks=0`; native window lifecycle/density and live compositor transitions also passed; the pinned FreeType C target uses ASan |
| clangd 23.1.2 with the local `.clangd` | All twenty configuration headers passed when opened individually through the real Neovim configuration, along with the session, allocator, Qt application, physical grid, workbench geometry, allocation/window fixtures and both Objective-C++ adapters, twenty-nine files with zero error diagnostics |
| clang-tidy 23.1.2, macOS | 500 checks enabled, zero diagnostics across 65 translation units, including the tab-strip adapter, independent chrome tests, reload probe, Objective-C++, shared command-storage headers and shared optical/terminal-font implementations; the final adapter/test refinements also passed the same checks |
| Original CoreText glyph rasterizer, macOS | 360 byte-exact complete images at matching physical origins, covering regular, bold, italic and bold italic |
| Extracted original runtime-section JSON serializer, macOS and Fedora | 4,126 byte-exact typed records matched, including 1,633 bounded failures; control-heavy cases reproduced and fixed differing response admission |
| Extracted original GUI/input serializers with original GUI/key types, macOS and Fedora | 5,441 byte-exact typed records matched, including 650 bounded failures; original f32 promotion, UTF-8 character storage, every named key, modifiers and exact capacity checks passed |
| Original Zig theme presets, query body, appearance resolver and UTF-8 validator, macOS and Fedora | 2,318 typed theme/appearance records matched byte-for-byte, including 929 bounded failures; all 16,777,216 three-byte UTF-8 decisions matched |
| Qt appearance and routed theme queries, Cocoa/Metal and Wayland/OpenGL | New native and recording-adapter cases passed with synthetic appearance signals, retained prefix/geometry and complete query replies |
| Original Zig action/key types, command pool and extracted binding serializer, macOS and Fedora | 2,589 typed binding records matched byte-for-byte, including 227 bounded failures and POSIX basename/byte-array label cases |
| Original Zig packed command storage and lifecycle, macOS and Fedora | 5,590 byte-exact transitions matched, including 49 bounded refusals, complete labels and argv, fixed/recent identities, recycling and render admission |
| Command-tab execution and tab lifecycle, Cocoa/Metal and Wayland/OpenGL | Static and repeated callback commands passed in native and recording-host builds on both platforms and Linux ASan, checking literal Unicode/shell punctuation, source directory inheritance, focus, labels and automatic closure |
| Original Zig client query body, title accessor, sound policy and notification-delivery enum, macOS and Fedora | 2,799 typed client records matched byte-for-byte, including 335 bounded failures, complete policy-flag combinations and nullable byte metadata |
| Routed client queries, Cocoa/Metal and Wayland/OpenGL | The new case passed in native and recording-host builds on both platforms and Linux ASan, checking the default section, profile policy, negative indices and live view state |
| Routed binding queries, Cocoa/Metal and Wayland/OpenGL | The new case passed in native and recording-host builds on both platforms and the ASan Linux build |
| Standalone runtime configuration tests, macOS | Existing `runtime-cpp/tests/config_test.cpp` checks passed with the original 128 KiB command-registry allocation budget after adding compile-time fixed/retained storage policies and shared validation templates |
| Native-disabled CMake build, macOS | All twenty-three core targets built and passed; the pane-creation, command-tab and binding-query executables link only libc++ and libSystem, with no Qt dependency |
| Original Zig window-title module and extracted semantic sidebar clamping, macOS and Fedora | 155,464 byte-exact records matched, including invalid UTF-8 fragments, suffixes, host bounds and rejected widths |
| Original Zig font-size functions and extracted renderer metric arithmetic, macOS and Fedora | 240,073 byte-exact records matched; supplied FreeType size records are synthetic |
| Shared desktop terminal UI, macOS | Font settings, ligature spacing, optical strength and background opacity checks passed after extracting the common face setup |
| Previous/current C++ configuration adapters, Release, macOS ARM64 | Seven alternating pairs matched the sidebar/callback oracle; Qt-thread occupancy and pending timer metrics won 7/7, complete process CPU won 5/7, and reload completion won 4/7; this does not establish comparative Zig GUI performance |
| Original Zig scanner oracle, macOS and Fedora | 398,218 byte-exact records matched on each platform |
| Original Zig key-router oracle, macOS and Fedora | 29,152 byte-exact transition records matched |
| Original Zig key-encoder oracle, macOS and Fedora | 448,936 byte-exact result records matched, including rejected inputs |
| Original Zig copy-navigation oracle, macOS and Fedora | 32,241 byte-exact transition records matched |
| Original Zig pointer/click/scroll oracle, macOS and Fedora | 22,440 byte-exact result records matched |
| Original Zig retained child-mouse projection, tracking and encoding oracle, macOS and Fedora | 81,680 byte-exact result records matched |
| Original Zig link recognizer oracle, macOS and Fedora | 198,338 byte-exact recognition records matched |
| Original Zig cell-link oracle, macOS and Fedora | 44,798 byte-exact records matched, including complete targets and cell intervals |
| Original Zig pointer link-gesture oracle, macOS and Fedora | 108,875 byte-exact transition records matched, including complete hit identities and target bytes |
| Original Zig file/editor/path-expansion oracle, macOS and Fedora | 47,275 byte-exact records matched, including failure names and complete argv entries |
| Original Zig procedural scalar parsers, Braille, block and straight box painters and curve masks, macOS and Fedora | 1,209,552 byte-exact records matched, including invalid input, geometry, raster padding and storage guards |

The command-tab Linux matrix compared 1,137 source-file hashes with the host
before its normal, sanitizer and recording builds. The two final
direct-include fixes were then built and exercised in all three variants, with
a second matching source manifest and exported logs.
The launch-geometry matrix compared 1,140 source-file hashes after the physical
fitting and fixture changes. All nineteen configure, build, CTest, native-scale
and editor-build stages passed; their logs and matching manifest were exported
before shutting down the VM started for this work.
The window-lifecycle matrix compared 1,144 source-file hashes and passed all
twenty-five build, CTest, native-window, full integration, live-scale and editor
stages. Follow-up manifests preserved the same production code while validating
native resize waiting, explicit hover activation and fixture cleanup reporting.
All three Linux variants rebuilt and passed CTest, native window cases, focused
hover at three scales and real compositor transitions after those fixture edits.
The final test-activation adapter added three source files. The final manifest
compared 1,147 files; all twenty-five follow-up stages passed. Production C++
code was unchanged during those fixture corrections. Logs and manifests were
exported before stopping the VM owned by this work.

The integration executable also runs initialization and cleanup, so the current
software-backend suite reports forty-two passed entries for the native build
and forty-five for the recording-host build. The standalone window suite reports
ten entries. These counts include initialization and cleanup. Integration uses
`/bin/sh` explicitly rather than depending
on the test account's shell startup files. The scene executable reports
thirty-one passed entries, the font resolver reports nine, the standalone link
opener reports eight and the configuration monitor reports twenty-five, including
initialization and cleanup. Core coverage includes both 64-pane tree shapes,
routed copy ranges, Zig-compatible layout tokens, history replay authority and input
validation, and the shared temporary-directory cleanup on macOS and Linux.
The lint profile requires LLVM 23 or newer;
the installed Fedora LLVM 21 cannot run that profile.

Fractional-scale integration uses VT wrap and continuation flags to reconstruct
logical text and locate fixture rows. The physical screen dump remains available
for diagnostics. Raw-PTY mouse captures retain the complete binary stream in
a temporary file and compare every expected byte, independently of visible
scrollback. A 13-column pane at 2x reproduced loss of the capture's beginning
from the visible screen; reading only that screen could not validate the stream.
This changes fixture observation, not pointer admission or expected input bytes.
Scale runs set `QT_SCALE_FACTOR` before process creation. They do not cover
complete native window behavior. The separate Sway check exercises live output
density changes; physical macOS display transitions remain unverified.
A separate Cocoa `QWindow` probe measured effective window and screen DPR
values of 1, 1.25 and 2 under the matching factors. The Metal runs recorded
initial buffers of 1200x800, 1500x1000 and 2400x1600 pixels, respectively.

An initial Metal hover failure was followed by a confirmed inactive-window
failure after `requestActivate()`. The test now requires an exposed, active
window before hover. Its platform fixture also requests activation of its own
Cocoa application, then retains the window-active assertion. Qt 6.12's
[Cocoa window request](https://github.com/qt/qtbase/blob/v6.12.0/src/plugins/platforms/cocoa/qcocoawindow.mm#L1739)
only selects the first responder and key window. The fixture uses AppKit's
[application activation API](https://developer.apple.com/documentation/appkit/nsrunningapplication?language=objc)
outside production code. This addresses that observed precondition; it does not
prove that every earlier intermittent hover failure had the same cause.

One recording-host run and a later native Metal run missed the first
configured prefix callback. Isolated and subsequent full runs passed.
The native failure recorded one configuration notification, no focus changes,
no dialog and no active keyboard copy mode. That notification alone does not
prove a configuration reload. The cause remains unconfirmed; the passing
runs are not evidence that this intermittent issue is fixed.

The configuration monitor now filters unrelated filesystem changes. The
native prefix test creates an unused Lua file while the prefix is active and
checks that the pending sequence survives. This covers a reproducible
cancellation path; it does not prove that every previously missed callback
had that cause.

A later complete native Metal run failed the triple-click line-selection
assertion in `pointerSelection`; the isolated pointer/prefix run passed.
The subsequent complete Metal run also passed.
That input timing or presentation failure remains unconfirmed and is not
covered by the configuration-monitor fix.

An earlier recording-host Metal run failed `childMouseAcrossPanes` after the
interactive shell printed `child setpgid` with `Operation not permitted` inside
the displayed capture. The isolated case and subsequent complete suites passed.
The shell diagnostic's cause remains unconfirmed. Keeping raw input in a file
addresses viewport loss; it does not establish that this diagnostic is fixed.

The macOS ASan run was not accepted: the installed sanitizer runtime stalled
inside its own shadow-memory initialization before `main`. A process sample
showed a recursive sanitizer allocator initialization through dyld. Linux
sanitizer results provide the available memory instrumentation coverage;
they do not substitute for macOS sanitizer coverage or performance evidence.

During the visual work, a complete Cocoa run observed terminal input outside
the scripted sequence and lost native window activation. It remains a failed
run; the source of interference is not established. The subsequent software
suite and six selected native cases at all three scales passed, but those
targeted runs do not constitute a new complete Cocoa acceptance run.

A Linux image-pixel assertion was independently diagnosed from its captured
frame: the intentional missing-file notification from an earlier test covered
the red image sample. That earlier test now verifies dismissal through an
outside click. All six complete Wayland suites subsequently passed without
relaxing the pixel assertion. Three cross-pane tests also wait for the actual
focused terminal delegate after the model announces a split, rather than
assuming that QML focus has already updated.
