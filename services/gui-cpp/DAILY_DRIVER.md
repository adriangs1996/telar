# C++ daily adoption milestone — OPEN

The complete functional, visual and equal-or-better performance objective remains
open. Only the command/quick-navigation palette and notifications/sounds may be
deferred for daily adoption; existing implementations stay available.

## Current candidate: Preview 7; daily qualification remains open

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

## Current development qualification

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

## Daily adoption blockers

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
