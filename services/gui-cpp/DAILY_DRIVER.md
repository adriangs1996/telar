# C++ daily adoption milestone — OPEN

The complete functional, visual and equal-or-better performance objective remains
open. Only the command/quick-navigation palette and notifications/sounds may be
deferred for daily adoption; existing implementations stay available.

## Candidate

Local separate bundle: `out-adoption/Telar C++ Preview.app` (relative to
`services/gui-cpp`). Packaging and exact-candidate smoke verification are pending.
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

## Daily adoption blockers

- Isolated plugin execution, capability enforcement and custom bars, widgets,
  panels and picks remain incomplete. Catalog and activation do not close this.
- Deploy Qt/QML and verify the exact relocated Release bundle from Finder with
  disposable state and a sparse desktop environment.
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
- [ ] Exact Release bundle: deployed dependencies, login environment and isolated smoke.

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
