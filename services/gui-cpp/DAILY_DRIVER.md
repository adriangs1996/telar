# C++ daily adoption milestone — OPEN

The complete functional, visual and equal-or-better performance objective remains
open. Only the command/quick-navigation palette and notifications/sounds may be
deferred for daily adoption; existing implementations stay available.

## Remaining daily clearance and final acceptance

- Daily: confirmed fresh plugin-reference keyboard-focus failure; macOS native
  shutdown retention (sanitizer gate failed/open); physical suspend/resume untried.
  Both SDKs pass final static/editor qualification.
- Final parity: complete styling/fitting/accessibility/native ownership, remaining
  interaction states and paired visual/comparative performance acceptance.
- Zig retirement: own-Zig generators/font metadata and bundled runtime/CLI,
  shared non-Zig sources, third-party Ghostty toolchain and test oracles remain
  separate dependencies. Removal requires an audited clean build; see ZIG_RETIREMENT.

## Current candidate: Preview24; stable panel/pick actions through Lua renders

`out-adoption/Telar C++ Preview 24.app` preserves widget focus and held clicks when
Lua re-declares the same panel/pick destination. A mutated action cannot redirect
an old gesture; activation consumes its validated destination once and rejects
expired sources. From the worktree root:

```sh
open -n "services/gui-cpp/out-adoption/Telar C++ Preview 24.app"
```

Finder opens the separate app after another preview closes. Return by closing it
and opening `~/Applications/Telar.app`. No installation/replacement/migration.
GUI SHA256 `200c986cb3467aa926fcb64255d967c1683036e4f6aef921242e68f25d7382c6`.
All1739 hashes/121 Mach-O/deep signatures, eight exact daily scopes and twenty
normal-loop tab/split/group/Lua-reload cycles pass; sixteen captures inspected.
Both SDKs pass Release49/recorded19. LinuxASAN49 exits0; Mac49 assertions pass but
exit1 reports850052B4746alloc, without address/UB errors or suppression. Both SDKs pass broad3/editor5/format5/module lint; all five portable source hashes
match.
See [closed destination evidence](measurements/component-semantic-action-focus.md).
A fresh plugin-action reference still loses focus in a directed native probe;
that separate daily scope is now confirmed/open.
Physical sleep/native retention/full parity/retirement remain OPEN. Preview23/22/8,
installed Zig/configuration/runtime remain preserved.

## Preserved candidate: Preview23; retained widgets through caption changes

`out-adoption/Telar C++ Preview 23.app` retains keyboard focus and in-flight clicks
when widget captions change with the same action identity, including periodic Lua
bars. Actions/source replacement still retires the control. From the worktree root:

```sh
open -n "services/gui-cpp/out-adoption/Telar C++ Preview 23.app"
```

Return by closing it/opening `~/Applications/Telar.app`. No installation/replacement/
migration. Exact GUI SHA256
`ec27242ae7b63716d9ad172badbc0f7c6a6d57493cb09726b0700db19c2dfff0`.
Both SDKs pass Release42/recorded15 and broad/editor/format/module lint; two portable
hashes match. LinuxASAN42 exits0; Mac42 assertions pass/exit1 for769347B4467alloc,
no address/UB or suppression. Exact1739 hashes/121 Mach-O/signatures, eight daily
scopes and twenty normal-loop cycles pass; sixteen captures inspected. A fresh
Lua open-panel reference for an unchanged destination remains a confirmed separate
focus blocker under investigation. See [retained widget evidence](measurements/component-refresh-focus.md).
Physical sleep/native retention/full parity/retirement remain OPEN. Preview22/8,
installed Zig/configuration/runtime remain preserved.

## Preserved candidate: Preview22; custom-action capture survives refresh safely

`out-adoption/Telar C++ Preview 22.app` retires a held mouse gesture if Lua changes
its action, while retaining an unchanged action through redraw. Buttons/groups,
changed-away-and-back actions and reload while pressed have native coverage.

```sh
open -n "services/gui-cpp/out-adoption/Telar C++ Preview 22.app"
```

Close it/open `~/Applications/Telar.app` to return. No installation/replacement/
migration. Exact GUI SHA256
`8558110df3cf43d02593e4300a8d96082ef45b1441adec84f5b72e40995469b0`.
All1739 hashes/121 Mach-O/signatures and eight exact daily scopes pass; thirteen
captures inspected. Mac Release40/recorded13 pass; ASAN40 assertions pass/exit1
for842155B4785alloc. Broad2 TUs/editor4 files pass unchanged profiles. Linux Release40/ASAN40/recorded13 and broad2/editor4/format/module lint pass; all
six portable source hashes match. See
[action capture evidence](measurements/component-action-lease.md). Physical sleep,
native retention and full parity/retirement remain OPEN. Preview21/8 and installed
Zig/configuration/runtime remain preserved.

## Preserved candidate: Preview21; groups, More and predictable terminal focus

`out-adoption/Telar C++ Preview 21.app` adds keyboard actions/focus for custom
groups and More, preserves chrome focus through sidebar changes, and restores
terminal input after current-tab clicks, tab/split changes, Lua reload and Escape.
Preview20 is preserved but was not offered: its stronger standalone Escape actor
failed; the same actor passes21. From the worktree root:

```sh
open -n "services/gui-cpp/out-adoption/Telar C++ Preview 21.app"
```

Finder opens the separately named app after another preview closes. Return by
closing it/opening `~/Applications/Telar.app`. No install/replacement/migration.
GUI SHA256 `ba035451933ac0a078c24a912f365d3247616d65900636d91761114898bfc93a`.
All1739 hashes/121 Mach-O/signatures and eight exact schema87/88 Finder/login/
runtime/plugins/bars/windows/client-pause, SSH, Vim, panel, activity and keyboard
scopes pass. Eleven packaged/four native captures inspected. Both SDKs pass
Release38/recorded12 and broad2/editor2/format2/module lint; nine hashes match.
LinuxASAN38 exits0. MacASAN38 assertions pass, exit1 for846129B4486alloc, no address/
UB or suppression. Four rebuilt domain CTests pass in Release/ASAN on both SDKs;
the prior intermittent native192B4alloc failure is preserved and not proved resolved.
A stale external window acknowledgement is corrected only in a private test-helper
copy, with an identical-binary negative/positive pair and unchanged assertions/
deadlines. See [group keyboard evidence](measurements/component-group-keyboard.md).
Preview19/8, installed Zig, configuration/runtime remain preserved. Physical sleep,
native leaks/stability, final parity and own-Zig retirement remain OPEN.

The [extended component stability scope](measurements/component-focus-stability.md)
now passes100 cycles/202 checks plus38 general/12 recorded-link cases on both SDKs
with a stronger settled-geometry precondition before mouse input. The original
assertions/deadlines remain. Broad/editor/format pass the one changed test TU per
SDK; Linux module lint also passes. The GUI/package bytes are unchanged; all1739
hashes/121 objects/signatures are reverified. Mac38/202-case ASAN exits remain1
(786079B4395alloc and591683B3604alloc); Linux exits0. Earlier failed runs and native
retention remain open. Visual descendant counts stay constant; malloc reservation
plateaus during a short diagnostic, but long-run RSS/leak freedom is NOT proved.
In-flight component geometry/pointer equivalence stays in PARITY.md. No production
input-polish prototype was shipped. Preview21 remains the same offered candidate.

The unchanged Preview21 also passes twenty private-state tab/split/group-keyboard/
automatic Lua-reload cycles under its normal Qt event loop, exits0 without QML
warnings and retains370 visual descendants. Reserved malloc bytes plateau during
this short observation. This does not clear native sanitizer failures, long-run
stability or physical sleep. See [normal-loop evidence](measurements/component-event-loop-stability.md).


## Preserved candidate: Preview19; keyboard actions and retained panels

`out-adoption/Telar C++ Preview 19.app` adds Tab/Space/Return actions for custom
panel buttons, keeps panels/picks through sidebar/layout changes, and restores
an invoking panel button after closing/selecting a nested pick. Lua reload and
machine changes still retire old surfaces. From the worktree root:

```sh
open -n "services/gui-cpp/out-adoption/Telar C++ Preview 19.app"
```

Finder opens it after another preview closes; use its separate name if copied.
Return by closing it and opening `~/Applications/Telar.app`. No installation,
replacement or session migration. GUI SHA256:
`7dbd630dcdff3b0ef9dca2303588d01625b3a587c3bc4ac42dd2845a94ea4249`.
All1739 hashes/121 Mach-O/deep strict signatures and seven exact relocated schema87/
88 Finder/login/runtime/plugin/bar/window/client-pause, SSH, Vim, custom panel,
project/task/plan and actual keyboard flows pass. Eight captures inspected, private
cleanup/configuration unchanged. Private keyboard/panel actors finally use only
bundled Qt and are injected only into the GUI; setup failures are retained.
The activity scope uses controlled protocol fixtures, not AI agents or Git.
Mac Release29 and dedicated recorded-link10 cases pass. Mac ASAN29 assertions pass
but exits1 for744541B3862alloc; ASAN domain CTest also fails for native192B4alloc.
No address/UB error or suppression; both sanitizer gates remain OPEN. Linux Release/
ASAN29 and recorded-link10 pass/exit0. Broad4 TUs/editor5 files/format5/module lint
pass on both SDKs; all8 portable hashes match. The final explicit weak-pointer
comparison fixes a Qt6.8-only linter rejection without suppressions. Rebuilt Release/
recorded test binaries on both SDKs and the Mac GUI are byte identical; final ASAN
29-case runs are repeated. Existing lint warnings are retained.
See [panel keyboard evidence](measurements/component-panel-keyboard.md).
Preview18/8, installed app/configuration/runtime remain preserved. Daily adoption,
physical system sleep, native leak/stability acceptance, full parity and Zig
retirement remain OPEN. This is fresh build9 plus increments, not a no-own-Zig
clean build. Only palette/notifications may be deferred for daily adoption.

## Preserved candidate: Preview18; widgets retain their clicks

`out-adoption/Telar C++ Preview 18.app` fixes a tab capture that could swallow custom
widget clicks after reloading/moving configured bars. Capture now requires the same
live tab at the window point; existing tab reorder/cancel/selection behavior remains
covered. It preserves Preview17's action-before-URL behavior. From the worktree root:

```sh
open -n "services/gui-cpp/out-adoption/Telar C++ Preview 18.app"
```

Finder opens it after another preview closes. Copy under its separate name if
desired; no installation/replacement/migration was performed. Return by closing
the preview and opening `~/Applications/Telar.app`. GUI SHA256:
`e8cc5c4480bdf38f817e351dc9acbc82a2fe62216f43d1df106787812abac031`.
All1739 hashes/121 Mach-O/strict signatures pass. Six exact relocated schema87/88
Finder/login/runtime/plugins/bars/windows/client-pause, SSH, Vim, configured panel
and task/plan scopes pass; captures inspected, config unchanged and private state
removed, no QML warnings. Panel actor invokes real activateComponent with full
identity/anchor; native tests use actual press/release. Activity uses controlled
protocol fixtures, not another AI agent or Git checkout. Mac/Linux Release21 cases
pass; dedicated recorded-URL builds26 pass each and are never packaged. LinuxASAN
21 pass/exit0; Mac21 assertions pass/exit1 for713702B3910alloc, no address/UB or LSAN
suppression. Broad analysis, actual editor and changed-range format pass both SDKs;
three portable hashes match. Fresh9 plus increments, not a no-own-Zig clean build.
Preview8/17/installed app/config/runtime remain intact; four protected identities
unchanged. See [stale tab input evidence](measurements/component-tab-capture.md).
Physical sleep and shutdown-leak attribution below remain open.

## Daily adoption blockers

The reported custom-group/More keyboard blocker is closed in scoped Preview21
checks, including Escape back to the terminal. Remaining full fitting/styling and
accessibility/physical ownership cases stay in PARITY.md.

- Retain focus for freshly regenerated Lua open-panel/pick actions naming an
  unchanged destination. Preview23 fixes caption updates with stable action
  identities; a directed probe confirms fresh reference IDs still retire focus.
- Triage recorded macOS sanitizer exit leaks without suppressing the failures.
  A standalone CoreText reproducer explains part of the retention, not the entire
  GUI report.
- Validate physical system sleep with the candidate. This remains outside the
  successful private process-pause and window-close survival checks.

Full visual and comparative performance acceptance and audited removal of own
Zig remain separate final gates. Palette and notifications are the only daily
areas allowed to be deferred.

One/five surface-replacement cycles pass their four/twelve assertions; both still
exit one for LSAN, with about 730/710 KB reported. A private recoverable-check
probe also reports retention before and after UI destruction and at final exit.
The apparent stall was slow symbolization; it finished within the original
runner deadline. See [surface-stability.md](measurements/surface-stability.md).
This short observation does not establish leak freedom or long-run RSS stability.

A standalone Qt Quick window also reproduces shutdown retention without Telar,
QML engine or runtime; a combined window/font control reports487923B2465alloc.
This extends partial attribution and does not clear the sanitizer gate. See
[native-window-exit-retention.md](measurements/native-window-exit-retention.md).

## Required adoption checklist

Checked rows record implemented behavior and scoped automated evidence. They do
not certify complete visual parity or every native device/provider state. The
complete Cocoa regression covers both protocols; the exact package adds Finder,
plugins/surfaces, SSH, Vim and project/task/plan navigation. The latter uses a
controlled reporter, without another AI agent or Git checkout; see
[its evidence and inspected captures](measurements/daily-activity.md).

- [x] Terminal Unicode, styled output, interactive apps and input/IME.
- [x] Tabs: rename, move, drag; splits, resize and fullscreen.
- [x] Projects, workspaces, sidebar and worktree navigation/actions.
- [x] Agents, tasks, plans and peek.
- [x] SSH selection, switching and reconnection.
- [x] Complete History, suggestions and path insertion.
- [x] Selection, clipboard/copy mode, links and previews.
- [x] Images and attachments.
- [x] Lua, shortcuts and reload, retaining the last valid configuration.
- [x] macOS appearance, fonts, blur and statusbar; final visual/platform gaps remain in PARITY.md.
- [x] Plugins and custom bars/widgets/panels/picks.
- [x] Multiple windows, restoration, owned-client pause/resume and task survival after window close.
- [x] Exact Release bundle: deployed dependencies, login environment and isolated smoke.
- [ ] Physical system suspend/resume.
- [ ] Close macOS sanitizer shutdown-leak triage.

## Final parity and Zig retirement

`PARITY.md` retains full visual, native-input, sanitizer and comparative performance
gates, including existing failed evidence. Pixel microbenchmarks are not the
adoption critical path unless they expose a daily-use defect.

The preview still bundles the original Zig runtime/CLI. CMake also reads own Zig
sources for themes, bindings, actions and tables; it compiles shared non-Zig
C/Objective-C from `src/gui`. Ghostty has its own toolchain. Original-source
oracles are test dependencies, distinct from production code. Deleting own Zig
requires a dependency audit and a clean build without those sources, followed by
acceptance. Starting this GUI does not meet that gate. No broad runtime rewrite
is part of the adoption milestone.

The initial dependency inventory and clean-build gate are in
[ZIG_RETIREMENT.md](ZIG_RETIREMENT.md).

## Preserved candidate: Preview17; configured action dispatch

`out-adoption/Telar C++ Preview 17.app` fixes widgets that define an action and a
URL together: the action takes precedence as in Zig. Both bar/panel regressions
fail on old source and pass after correction; stale generation/revision guards
remain inert. From the worktree root:

```sh
open -n "services/gui-cpp/out-adoption/Telar C++ Preview 17.app"
```

Finder opens it after another preview closes; copy under its separate name if
desired. Close it/open `~/Applications/Telar.app` to return. No install/replacement/
session migration. GUI SHA256:
`69648dc941e7e4a9c28a949063f539fe69ec6181dca2f8b8dfabc9c06018a45b`.
All1739 hashes/121 Mach-O/signatures and six exact schema87/88 Finder/login/runtime/
plugin/bar/window/pause, SSH, Vim, action+URL panel and task/plan scopes pass. Six
captures inspected; private cleanup/config unchanged/no QML warnings. Native15
and three configuration CTests pass per variant/SDK; LinuxASAN0, Mac assertions
pass/exit1 for678400B3701alloc without address/UB or suppression. Broad/editor/
format pass three TUs on both SDKs; hashes match. Preview8/16/user config/runtime
remain intact. Fresh9 plus increments, not a clean/no-own-Zig build. See
[action dispatch evidence](measurements/component-action-precedence.md).

## Preserved candidate: Preview16; configured groups

`out-adoption/Telar C++ Preview 16.app` adds original group padding/child gaps and
mark widths, including fitted and empty groups. Existing panel actions, metrics,
overflow, tabs and splits remain qualified. From the worktree root:

```sh
open -n "services/gui-cpp/out-adoption/Telar C++ Preview 16.app"
```

Finder can open it after another preview closes. Copy under its separate name if
desired. Close it/open `~/Applications/Telar.app` to return. No install/replacement/
session migration. GUI SHA256:
`76ca4aa6fcc7ed5b1bc50402cca3e6137f3d6fd55a38a5ee31b835cf8f44232d`.
All1739 hashes/121 Mach-O/signatures and exact relocated schema87/88 Finder/login/
config/runtime/plugins/bars/windows/pause, realSSH, VimUTF8, panel and task/plan flows
pass. All six direct/daily captures inspected. Native15 broader plus final4 checks
and three configuration CTests pass both SDKs; LinuxASAN0, Mac assertions pass but
shutdown exits1 (final487550B2840alloc), no address/UB or suppression. Broad/actual
editor/format pass both SDKs; five sources match. Separate7 native copy/selection/
close-reopen checks pass each at factors1.25/2 with private clipboard unchanged.
Footer validation already exists in shared runtime-cpp; earlier truncation claim
is withdrawn. Next action+URL precedence finding awaits a directed regression.
Daily/full goals, physical sleep, Mac leak/stability, full fitting/styling/ownership/
paired pixels/performance and audited Zig retirement remain OPEN. Preview8/15/user
config/runtime are intact. Fresh9 plus increments, not a clean/no-own-Zig build.
See [configured-group evidence](measurements/component-group-spacing.md).

## Preserved candidate: Preview15; default theme ink

`out-adoption/Telar C++ Preview 15.app` is separately packaged/qualified and already
offered for normal-use assessment. It adds a text-color correction to Preview14:
machine phase glyphs remain visible when green=default resolves to foreground.
Explicit no-color profile dots keep their original transparent behavior.

From the worktree root:

```sh
open -n "services/gui-cpp/out-adoption/Telar C++ Preview 15.app"
```

Finder opens it after another preview closes. Copy under its separate name if
desired. Close it/open `~/Applications/Telar.app` to return. No installs, replacements
or session migration; Preview8/14/config/runtime remain intact. GUI SHA256:
`2e55047d76ab005463ece74db5104c77e3166a39ed0fcbf0d5b9fa05158b81da`.

All1739 hashes/121 Mach-O/deep-strict signatures pass. Exact relocated schema87/88
Finder/login/config/runtime/plugin/bar/two-window/client-pause, realSSH with machine
bar AND green=default, VimUTF8, panel/bars and task/worktree/plan survival pass with
zero QML warnings and disposable cleanup. All daily/direct/native captures were
inspected. Four targeted native checks pass per SDK; LinuxASAN exits0, Mac assertions
pass/exit1 for986300B3607alloc, no address/UB or suppression. Broad/actual editor/format
pass both SDKs; two sources match. Linux editor-owned on-disk TMPDIRs are removed
after clangd exits. Preview14's broader14+6 qualification stays preserved. Physical
sleep, Mac shutdown leak/stability, full fitting/styling/ownership/paired visuals/
performance, daily acceptance and audited own-Zig retirement remain OPEN. Fresh9
plus increments, not a new clean/no-own-Zig build. See
[default machine ink evidence](measurements/component-machine-default-ink.md).

## Preserved candidate: Preview14; live machine facts

`out-adoption/Telar C++ Preview 14.app` is separately packaged and qualified for
normal-use assessment. Machine components show original phase/attention glyphs,
active bold labels and connected-only CPU, including hidden local/remote samples.
Existing selector/segment controls remain available. The view participates in the
shared priority fit and retains width while hidden without visual-row allocation.

From the worktree root:

```sh
open -n "services/gui-cpp/out-adoption/Telar C++ Preview 14.app"
```

Finder can open it after another preview closes. Copy under its separate name to
Applications if desired. Close it and open `~/Applications/Telar.app` to return.
Nothing is installed/replaced/migrated; Preview8/13, config/runtime and all four
protected identities remain intact. GUI SHA256:
`071087e9069edeed91b847c8fd16a8da85fe0bfa50d30f06cb25df32d4b6127d`.

All1739 hashes/121 Mach-O/deep-strict signatures pass. Exact relocated schema87/88
Finder/login/config/runtime/plugin/bar/two-window/client-pause smokes, genuine SSH
with the machine bar enabled, VimUTF8, custom panel/bars and task/worktree/plan
survival pass with zero QML warnings and private cleanup. Five daily captures plus
schema87 direct and native Mac/Linux machine facts were inspected. Panel actions
use the controlled actor and activity uses official-protocol fixtures, as before.

Both SDKs pass14 native Quick+6 machine checks in Release and the two affected full
CTest targets. Linux ASan/UBSan also exits0. Mac assertions pass14+6; shutdown exits1
for638351B3956alloc and1073208B4036alloc, no address/UB error or suppression. Broad,
actual-editor and changed-range format pass both SDKs; seven portable sources match.
An initial SSH setup hit a full VM tmpfs due to43 inactive clangd PCH caches; verified
cache cleanup and a new SSH attempt pass, with the failure retained. Physical sleep,
Mac shutdown-leak/stability, remaining fitting/native ownership/paired visuals and
comparative performance, daily acceptance and audited own-Zig retirement stay OPEN.
This is the fresh Preview9 baseline plus increments, not a new clean/no-Zig build.
See [machine-facts evidence](measurements/component-machine-facts.md).

## Preserved candidate: Preview13; builtin bar priorities

`out-adoption/Telar C++ Preview 13.app` is separately packaged and available for
normal Finder launch. It adds original-priority fitting for the builtin metric
and machine sources; CPU/memory/battery yield before a configured high-priority
widget. Machine controls have a measurable width and retain it while hidden,
without hidden click records. Existing metrics, controllers and custom menus
are reused. Full machine-fact glyph/CPU presentation and final styling remain open.

From the worktree root:

```sh
open -n "services/gui-cpp/out-adoption/Telar C++ Preview 13.app"
```

Finder can open it after another preview closes. It can be copied under its separate
name to Applications. Close it and open `~/Applications/Telar.app` to return. No
installation/configuration/session is replaced or migrated; Preview8/12 are intact.
GUI SHA256: `cb3c71e61984fb05efc463ee8e59c7be9f3b00336cc7a2a520f3ffca00673bf6`.

All1739 hashes/121 Mach-O checks/deep-strict signatures pass. Both exact relocated
schema87/88 Finder/login/config/runtime/plugin/bar/two-window/client-pause smokes,
realSSH, Vim exactUTF8, custom-panel/bar composition and task/worktree/plan survival
flows pass with zero QML warnings and disposable cleanup. Five daily captures plus
schema87 direct were inspected. Panel actions use an owned callback/controlled
anchor; activity is an official-protocol fixture, not an AI agent/Git checkout.

Native fitting qualification passes14 checks per SDK, including Linux sanitizers;
Mac sanitizer assertions pass but shutdown leak acceptance remains open. Four
affected CTest suites also pass. Final broad/actual-editor/format checks pass both SDKs; all14 portable sources
match. Two private Linux editor probes limit clangd concurrency/background indexing
after a kernel-confirmed OOM, without changing diagnostics/profile/deadline. The
final Mac raw GUI remains byte-identical to this package's recorded input. Physical system sleep remains untried. Daily adoption,
complete paired visuals/performance and audited own-Zig retirement remain OPEN.
This uses the fresh Preview9 baseline plus increments, not a new clean/no-Zig build.
See [builtin fitting evidence](measurements/component-builtin-fit.md).

## Preserved candidate: Preview12; shared custom-bar overflow

`out-adoption/Telar C++ Preview 12.app` is separately packaged with deployed Qt/QML.
It includes Preview11's corrections plus one shared overflow menu for the configured
bottom sources and legacy `top.right`, whose widgets now follow the original bottom
row. Hidden actions retain their source and replace the menu with the correct panel.
Failed commands keep visible diagnostics even when cached content is hidden; a700ms
macOS tooltip delay now completes under100ms failed refresh without reducing either.

From the worktree root:

```sh
open -n "services/gui-cpp/out-adoption/Telar C++ Preview 12.app"
```

Finder can open it after another preview closes. It can be copied under its separate
name to Applications. Close it and open `~/Applications/Telar.app` to return. No
installation, configuration or session is replaced/migrated; Preview8/11 remain intact.
Bundled GUI SHA256: `14ccb0a854bbbb9258a885811168be4650ae2e4973137c7436c116f19b172c27`.

All1739 hashes,121 Mach-O checks and deep/strict signatures pass. Exact relocated
schema87/88 Finder/login/config/runtime/plugin/bar/two-window/client-pause smokes,
realSSH, Vim exactUTF8, full custom panel/bars and task/worktree/plan survival flows
pass with zero QML warnings and disposable cleanup. Five daily captures plus schema87
direct were inspected. The panel actor uses an owned callback/controlled anchor;
activity is a protocol fixture, not another AI agent or Git checkout.

Thirteen native checks pass per SDK; Linux ASan/UBSan exits zero. Mac assertions pass13
but shutdown exits1 for681802B/4055alloc, no address/UB and no suppression. Final broad/
actual editor diagnostics/format pass both SDKs; seven portable hashes match. Physical
system sleep remains untried; owned-client pause is a distinct check. Those acceptance
gates, builtin priority and complete visuals/performance/own-Zig retirement remain open.
This uses the fresh Preview9 baseline plus increments, not another full clean build.
See [shared overflow and exact candidate evidence](measurements/component-shared-overflow.md).

## Preserved candidate: Preview 11; usable custom bars and panels

`out-adoption/Telar C++ Preview 11.app` is a separate Release app with deployed
Qt/QML. It includes the verified blur/artwork corrections, the original callout
card and inline action, eight-line panel paragraphs, separate meter details and
priority fitting across configured bottom-bar content. Long low-priority
children no longer hide useful actions or starve a short right slot; tabs use
the remaining space. Open from Finder after closing another preview, or force
this exact app from the repository root:

```sh
open -n "services/gui-cpp/out-adoption/Telar C++ Preview 11.app"
```

The bundle can be copied under its separate name to an Applications directory.
No installation is replaced automatically. To return, close the preview and
open `~/Applications/Telar.app`; runtime processes keep running. Preview8/10,
configuration and existing sessions are preserved.

Bundled GUI SHA-256:
`e86de8539934de232eec20ece2eb9033eb432e9391c1e5aae811953e883c3300`.
All 1,739 file hashes, 121 Mach-O dependency checks and deep/strict signatures
pass. The build uses the fresh Preview9 baseline plus recorded incremental
corrections; it is not another full clean build or a Zig-retirement qualification.

Both exact relocated schema-87/88 smokes pass with adopted opacity 0.98/blur20,
Finder/login-shell/config/default-runtime discovery, actual plugins, command
bars, two distinct windows and owned-client pause/resume. Configurations remain
unchanged, QML warnings are empty and disposable states are removed. The exact
bundle also passes real SSH, Vim saving exact UTF-8 bytes, full custom-panel and
left/right-bar composition, and task/worktree/plan navigation with task survival
after closing its window. All five daily captures plus the schema87 direct
capture were inspected. Finder application exit is unavailable through `open`;
the healthy final marker is checked. The panel actor calls an owned callback at
a controlled anchor; task reports are controlled protocol fixtures.

Nine native checks pass in macOS Release and Linux Release/ASan/UBSan. They
retain actual component clicks/picks and verify split/tab operations, tab drag
release and fullscreen-strip restoration. Linux sanitizers exit zero with leak
detection. Mac sanitizer assertions pass nine, but the process exits one for
661,696 leaked bytes in 3,887 allocations, with no address/UB diagnostic. Broad
analysis, actual delivered editor diagnostics and changed-range formatting pass
on both SDKs. No suppression, profile, assertion or deadline is weakened.

Adrian found no daily blocker so far in Preview8 and has not yet tried physical
sleep with Preview9. Physical sleep and Mac native-leak triage stay open. Builtin
metric/machine priority, the original combined overflow presentation, complete
visual/performance parity and audited own-Zig retirement remain open. Only
palette and notifications may defer for daily adoption. See
[component-slot-fit.md](measurements/component-slot-fit.md),
[group fitting](measurements/component-group-fit.md),
[meter composition](measurements/panel-meter-layout.md) and
[panel text](measurements/panel-text-lines.md).

Source work after Preview11 also preserves the error target when a command bar
fails before producing its first nodes. Final native Release checks pass both
SDKs and Linux ASan exits zero; Mac shutdown leak acceptance stays open. The
[frozen diagnostic evidence](measurements/component-command-error.md) retains
initial fixture/drag failures. This correction is not in the frozen bundle11.

A second source correction makes a configured panel opened from a hidden bar
action replace its overflow menu. Native clicks and menu reuse pass both SDKs;
see [the source-bound qualification](measurements/component-overflow-action.md).
It also follows frozen Preview11 and does not replace that bundle.

## Preserved candidate: Preview 10

Preview10 remains frozen at `out-adoption/Telar C++ Preview 10.app`, GUI SHA256
`18fc75b32bdacabca3ef6a07defbd7946431896a1174dee1b6bf24043fbe58f8`.
Its separate exact-bundle qualification is preserved in the panel-text archive.
It predates the later meter, group and global-slot corrections now in Preview11.

## Preserved candidate: Preview 8; normal launch confirmed

Adrian confirms: **"Sí, ya aparece la interfaz"** after opening Preview 8 with
his usual configuration. This closes the reported blank-window launch blocker;
it does not close daily-flow acceptance or the complete parity objective.

`out-adoption/Telar C++ Preview 8.app` fixes the native blur covering the Qt
Metal content. The visual effect now sits behind the Qt content view, preserving
that view and its input/rendering ownership. Open from the repository root:

```sh
open -n "services/gui-cpp/out-adoption/Telar C++ Preview 8.app"
```

Bundled GUI SHA-256:
`e97bba076a5f50715663b7ac56251aaa49bac2cc2b0785ccb991221d4ef17ac5`.
All 1,739 manifest files and 121 Mach-O dependency checks pass; the separate
bundle passes deep/strict signature verification. The exact relocated schema-87
smoke passes with opacity 0.98 and blur 20 explicitly adopted: Finder, login
shell, configuration/runtime discovery, plugins, command bars, tabs, splits,
history, two windows and owned-client pause/resume. No QML warnings, configuration
unchanged, disposable state removed. The matching schema-88 smoke also passes
with the same blur settings and zero QML warnings. Evidence:
`out-dependencies/preview7-blank-1/preview8-schema87-smoke-1/result.json`.

The native regression fails against Preview 7's source and passes after the
fix, including actual Qt frame presentation, resize, titlebar changes, reload
and blur disable/re-enable. The changed native code and regression pass their
functional assertions under ASan/UBSan. A first default-environment probe exited
zero but did not explicitly enable macOS leak detection; it does not qualify
that gate. The corrected run explicitly enables the leak check and exits one:
335,945 leaked bytes in 1,939 allocations, without address/undefined-behavior
diagnostics. No suppression is used. Full-GUI Mac exit leaks remain open.
Broad analysis and actual editor diagnostics pass for all three changed native
or C++ files. The existing window suite passes.

The focused terminal/workspace/selection/custom-surface suite passes seven
checks. A four-case layout sequence exposed a cleanup expectation also failing
in the old frozen binary: closing selects the adjacent tab in both Zig and C++,
whereas fixture cleanup assumed the tab that was active before creation. Cleanup
now explicitly selects its retained source after verifying closure, retaining
the original final assertions and deadlines; all six checks pass. The complete
new native suite reports **105 passed, one pointer-selection/clipboard failure**
while Cocoa geometry changes are queued. That failure remains open, with the
raw log retained. The follow-up test-only native admission correction now waits
for the runner's acknowledgement of the recreated AppKit window, before frame
and pointer checks. The complete suites then pass **106 checks with schema 87
and 106 with schema 88**, with all original selection assertions and deadlines.
The matching final Linux subset passes eight checks each in Release/ASan/UBSan.
See [native-readiness.md](measurements/native-readiness.md). Daily user-flow
confirmation, physical system sleep, Mac leaks, remaining qualification and
final parity remain open. The preceding Linux subset passes ten checks each.
The changed portable fixture also passes broad analysis and actual editor
diagnostics against Linux Qt 6.8; source-bound receipts are exported locally.

Preview 7 remains preserved as a historical artifact. Close the preview and
open `~/Applications/Telar.app` to return to the installed app, keeping runtime
processes alive. App packaging does not retire Zig or its build dependencies.

## Historical candidate: Preview 7; normal-launch failure

**DAILY BLOCKER (2026-11-01):** Adrian opened Preview 7 with his normal
configuration and reported an entirely blurred blank window. The application
remains responsive. Its configuration enables opacity 0.98 and native blur 20.
The preceding disposable-state smokes do not establish normal-config usability;
their internal Qt screenshots cannot validate native compositor overlays.
Preview 7 is not accepted for daily use. Preview 8 fixes this composition defect;
the original bundle remains preserved with its failure evidence.

`out-adoption/Telar C++ Preview 7.app` is the current separately named Release
bundle, available in Finder. It includes the Qt 6.8/6.12 transport scheduling and
native command-helper portability corrections. Open from the repository root:

```sh
open -n "services/gui-cpp/out-adoption/Telar C++ Preview 7.app"
```

GUI SHA-256:
`ed71b3323f406eff139c6d189c7f903455f2cb250542d261ec0ca0bb4c938264`.
The package linkage audit has no failures. Both strict relocated schema-87/88
smokes pass with zero QML warnings, direct and concurrent GUI exits zero,
configuration unchanged and disposable state removed. They cover login-shell
and default endpoint discovery, Finder launch, actual plugins, the bundled custom
bar helper, two distinct window identities and owned-client pause/resume while
its private runtime remains responsive. LaunchServices does not expose the GUI
exit status; the final healthy marker and screenshot are also checked.
The exact package additionally passes genuine SSH to an isolated runtime in the
owned Linux VM and a real Vim edit saving exact UTF-8 bytes. Existing runtime,
Zig GUI, VM and guest Sway remain unchanged. The schema-87 direct screenshot was
visually inspected with correct Latin, Greek and CJK glyphs. Evidence:
`out-dependencies/component-content-3/preview-7-schema{87,88}-smoke-1/result.json`,
`preview-7-real-ssh-smoke-1/result.json` and `preview-7-vim-smoke-1/result.json`.

Normal launch reads the usual configuration and discovers the existing runtime;
validation used disposable state and did not attach to user sessions. Close
Preview and open `~/Applications/Telar.app` to return, keeping the runtime alive.
No installation is replaced; the separate bundle may be copied under its own
name. Previews 1–6 remain frozen.

Current-source native Cocoa/Metal regression passes 106 checks with schema 87
and another 106 with schema 88, with no failures or omissions. The machine/peek
suite passes 40. Private clipboard cleanup succeeds and the general pasteboard
change count stays 954. A preceding workspace test had restored a stale window
size even when it had not resized it, leaking Cocoa geometry transitions into
selection; it now only waits for the expanded layout it actually exercises.
All pointer and clipboard assertions and deadlines remain unchanged. Earlier
intermittent failures and the unsuccessful native-size helper experiment remain
in the evidence; that helper was removed. No production selection code changed.

Both Linux native variants pass 12 selected checks, including workspace followed
by selection, custom surfaces, tab drag, fullscreen and restoration. Broad
analysis and actual editor checks pass for the changed sources on both SDKs.
The current native Mac sanitizer surface run passes all six assertions but exits
one for 676,587 leaked bytes in 3,729 allocations. No suppression or analysis
profile is relaxed. A standalone Foundation/CoreText-only reproducer also exits
one for about 58 KB with balanced Core Foundation releases; this explains part
of the report, not the entire GUI shutdown failure. Full leak triage and physical
system sleep remain open, separately from the successful private-client pause.
Daily acceptance and the complete parity objective remain open.

## Preserved candidate: Preview 6

`out-adoption/Telar C++ Preview 6.app` is the latest separately named, signed
Release bundle. Open it in Finder or from the repository root:

```sh
open -n "services/gui-cpp/out-adoption/Telar C++ Preview 6.app"
```

GUI SHA-256:
`a304bd528c9acfaecc924b82b6a618692dcef3c3d1b04bf2a2e626cca3d314f7`.
All 121 Mach-O dependency/signature checks pass. The exact relocated bundle
passes strict isolated smokes against both schema 87 and 88: default endpoint
and configuration discovery, deployed Qt/QML, real plugin execution, custom
bar command, two distinct window identities, and pause/resume of an owned GUI
while its private runtime remains responsive. Both runs have zero QML warnings
and remove their private state. Evidence is under
`out-dependencies/component-content-3/preview-6-schema{87,88}-smoke-1/result.json`.
The schema-87 direct PNG was visually inspected: `á λ 漢字 ✓` renders correctly.

Preview 6 fixes first-Escape handling during pick IME composition and validates
native font candidates with the client's rasterizer before accepting them.
Unreadable system font candidates no longer hide a usable later fallback. The
previous native API remains available to the original GUI. Twelve public font
checks pass in Release; all twelve assertions also pass with sanitizers, whose
process still exits with a recorded macOS/CoreText leak report (1,529,695 bytes /
6,964 allocations). No new suppression is used. A frozen native Cocoa suite
passes 106 checks with schema 87 before the font correction and another 106
with schema 88 afterward, including the new pick IME regression. Their private
pasteboards are cleared and the general pasteboard change count stays unchanged.
The native machine/peek suite passes 40 checks. The exact packaged GUI also
passes a real SSH connection to a private runtime in the owned Linux VM; its
screenshot shows the remote Unicode marker. A real Vim run saves exact UTF-8
text and renders it after tab selection. Both disposable runtimes/files are
removed, and existing host processes and guest Sway remain unchanged. Read-only
preparation also accepts the real user configuration without connecting to a
runtime or changing the configuration/trust files. Current Linux source quality
and native qualification and the known Mac shutdown-leak triage remain open. This is a usable, separately launchable candidate; the daily
milestone and final parity acceptance are not marked complete.

The audited client policy accepts only schemas `876b480d` and `886b480d`;
schema 87 differs by the absent `hold_tab` message, which this GUI does not use.
Unknown schemas still fail closed, and `hold_tab` cannot be sent to schema 87.
A handshake-only production-transport probe also succeeds against the existing
user runtime without subscriptions or session changes. The bundled CLI remains
schema 88: GUI compatibility does not imply every CLI command supports schema 87.

Normal launch uses the usual configuration and existing runtime. No GUI test
has attached to the user's active runtime. Preserve the current Zig app and
runtime. Return by closing Preview and opening `~/Applications/Telar.app`,
without stopping or migrating the runtime. Packaging does not install or replace
either app; the separate bundle can be copied under its own name. Previews 1–5
remain frozen diagnostic artifacts.

Preview 5 passes both isolated schema smokes but predates the IME/font fixes.
Preview 4's isolated schema-88 smoke passed, but it cannot connect to schema 87.
Physical system sleep, full visual coverage and comparative performance remain
open independently of the private client-pause smoke.

## Preserved Preview 4 with custom surfaces

`out-adoption/Telar C++ Preview 4.app` is a preserved schema-88 diagnostic
candidate. Its launch below is historical; it cannot attach to schema 87.

```sh
open -n "services/gui-cpp/out-adoption/Telar C++ Preview 4.app"
```

The exact relocated bundle passes deployed Qt/QML dependencies, signatures and a
121-object Mach-O audit with no missing/external dependencies. GUI SHA-256:
`f94721de92e29c5859edbcfc6a1084b05ee48b2489f77c2da2bedb2d14123dbf`.
Its strict smoke passes default runtime/configuration discovery, Unicode, tabs,
split/resize/fullscreen, sidebar, Lua reload, History, real plugin execution,
custom widgets/bar command via the bundled native helper, and two simultaneous
clients with distinct window identities. It reports zero QML warnings. An exact
owned GUI child is paused/resumed while its private runtime executes a command;
the resumed GUI exits healthy and its PNG was inspected. Physical system sleep
is outside that scoped test. Direct and concurrent GUI exits are zero;
LaunchServices exits zero but does not expose its GUI exit status. Private test
state is removed. No existing app/runtime/configuration is replaced or migrated.

Close Preview and open the existing Telar.app to return; keep the runtime
running. The bundle can be copied to a user-owned Applications directory under
its separate name; packaging does not install it. Current-source adoption and
final parity validation remain open, including Linux qualification and the
known macOS exit-leak gate.

Preview 3 remains preserved as diagnostic evidence: its protocol flows pass,
but its overflow indicator produces QML binding-loop warnings. It does not pass
the candidate quality gate. The correction is in Preview 4. Previews 1 and 2
below also stay untouched.

Reproduce the exact current bundle smoke:

```sh
python3 services/gui-cpp/tools/smoke_macos_bundle.py \
  "services/gui-cpp/out-adoption/Telar C++ Preview 4.app" \
  --discover-runtime --plugins --components --windows \
  --evidence services/gui-cpp/out-dependencies/my-preview-4-smoke
```

## Preserved preview with plugin execution

`out-adoption/Telar C++ Preview 2.app` is the newer separate Release preview.
The first preview below remains preserved. This second bundle deploys Qt/QML,
passes all signatures and an audit of 120 Mach-O objects with zero unresolved or
external dependencies. Its GUI SHA-256 is
`447bc66e98d8aec06e5aead3bf98e1e2c05fc9a5b452e8d9e5d13b0ab366deae`.

An exact relocated Cocoa/Metal smoke passes default configuration/runtime
discovery, Unicode, tabs, split/resize/fullscreen, sidebar, Lua reload, History,
and a private plugin executed by both ID and configured path through the bundled
CLI. Direct GUI and LaunchServices return zero; the GUI exit behind `open` remains
unobservable, so the final healthy marker and inspected PNG are required. Private
state is removed and no existing runtime/configuration/app is replaced.

Launch with Finder or:

```sh
open -n "services/gui-cpp/out-adoption/Telar C++ Preview 2.app"
```

Return by closing Preview and opening the existing Telar.app, without stopping
the runtime. This is available for testing; custom bars/widgets/panels/picks and
the remaining daily checklist still block declaring it a daily driver. Plugin
execution borrows the bundled original Zig `plugin-worker`; its retirement is a
separate dependency gate. The final shared-copy editor/portability correction is verified in the newer
source revision; this bundle stays unchanged.

Reproduce the exact bundle smoke with:

```sh
python3 services/gui-cpp/tools/smoke_macos_bundle.py   "services/gui-cpp/out-adoption/Telar C++ Preview 2.app"   --discover-runtime --plugins   --evidence services/gui-cpp/out-dependencies/my-plugin-preview-smoke
```

## First preserved candidate

Local separate bundle: `out-adoption/Telar C++ Preview.app` (relative to
`services/gui-cpp`). This local ARM64/macOS 26+ Release preview is packaged,
ad-hoc signed and verified after relocation. It is available for testing; the
daily adoption milestone remains open.
Its bundle identifier is `dev.telar.cpp.preview`. Nothing installs over Telar.app
or changes CLI symlinks. Build from this worktree with:

```sh
python3 services/gui-cpp/tools/package_macos.py \
  --runtime-prefix services/gui-cpp/out-dependencies/reference-gui
```

Finder or `open "services/gui-cpp/out-adoption/Telar C++ Preview.app"` launches
through the account's login shell. Normal launches read the usual Lua/machine
configuration and discover the existing runtime through the bundled CLI.
Do not use this launch for isolated verification: the smoke must supply a private
socket, config/data/history and working directory. Returning to the current app
means closing the preview window and opening the existing Telar.app; never stop
the user's runtime or migrate its sessions. Copying the separately named preview
to a user-owned Applications directory is optional; packaging does not do it.
The packager refuses an existing output; select a new `--output` for later builds.

Verified on the exact packaged GUI SHA-256
`34d13a476a3d637c2deddf57c466a3471cdbc0adc6cff422f9b428cf618a35e6`:
120 Mach-O objects have no unresolved/external dependencies; all leaf code,
frameworks and the app pass signature verification. A clean packaging repetition
produces the same GUI hash. Direct launch exits zero. LaunchServices reaches the
final healthy Cocoa/Metal marker and screenshot; `open` does not expose the GUI's
exit status. Two isolated successful runs cover Unicode output, tab rename/create/
move, split/resize/fullscreen, sidebar, Lua reload and History opening. The second
also verifies bundled CLI endpoint discovery and default XDG configuration with
no explicit socket/config arguments. All test runtime/config/data/home state is
disposable and removed. No user's runtime or configuration was used.

Reproduce that isolated smoke from this worktree:

```sh
python3 services/gui-cpp/tools/smoke_macos_bundle.py \
  "services/gui-cpp/out-adoption/Telar C++ Preview.app" --discover-runtime \
  --evidence services/gui-cpp/out-dependencies/my-preview-smoke
```

## Preserved Preview4 development qualification

Configured bars/widgets/panels/picks are implemented and included in Preview 4.
The complete Cocoa/Metal regression before the final overflow fix passes 106
checks without failure, omission or QML warnings. The final overflow fixture and
both custom-surface cases pass afterward. The exact Preview 4 bundle also passes
its strict smoke without QML warnings.

The independent controller covers filtering, selected/swatch metadata, literal
Unicode selection, cancellation, failures, refresh policy and obsolete runtime
completion. Four affected core/command CTests pass with ASan/UBSan. The new static
bar plugin regression proves disable/re-enable can reload while execution stays
blocked when disabled. Native Cocoa sanitizer assertions pass but exit leak
detection remains open: the latest two-surface run reports 544,451 bytes / 2,756
allocations; the selected configuration-source run reports 228,316 / 826. No new
suppression or weakened analysis profile was added. Final source quality and Linux
qualification continue independently of the preserved bundle.
