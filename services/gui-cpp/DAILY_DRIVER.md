# C++ daily adoption milestone — OPEN

The complete functional, visual and equal-or-better performance objective remains
open. Only the command/quick-navigation palette and notifications/sounds may be
deferred for daily adoption; existing implementations stay available.

## Current preview with plugin execution

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

## Daily adoption blockers

- Isolated plugin execution and capability enforcement have functional coverage
  in preview 2; the final shared-copy quality correction is verified in the
  newer source revision.
  Custom bars, widgets, panels and picks remain incomplete.
- Resolve or qualify the retained macOS pointer-selection regression and verify
  window restoration/suspend-resume and all flows below on this candidate.

## Required adoption checklist

- [ ] Terminal Unicode, styled output, interactive apps and input/IME.
- [ ] Tabs: rename, move, drag; splits, resize and fullscreen.
- [ ] Projects, workspaces, sidebar and worktree operations.
- [ ] Agents, tasks, plans and peek.
- [ ] SSH selection, switching and reconnection.
- [ ] Complete History, suggestions and path insertion.
- [ ] Selection, clipboard/copy mode, links and previews.
- [ ] Images and attachments.
- [ ] Lua, shortcuts and reload, retaining the last valid configuration.
- [ ] Appearance, fonts, blur and statusbar.
- [ ] Plugins and custom bars/widgets/panels/picks.
- [ ] Multiple windows, restoration and suspend/resume.
- [x] Exact Release bundle: deployed dependencies, login environment and isolated smoke.

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
