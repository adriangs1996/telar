# C++ desktop client

CMake 3.28 or newer and Ninja 1.11 or newer build the C++23 desktop client.
Upstream LLVM Clang, including `clang-scan-deps`, compiles the modules. On
macOS, C++ and Objective-C++ use libc++ to match the installed Qt libraries.
Qt 6.7 or newer provides QML, Qt Quick, Qt Quick Controls, Qt Quick Shapes,
Qt Network and Qt Concurrent.
The runtime and the rest of Telar still build with Zig.

On macOS, install the dependencies with
`brew install cmake ninja llvm pkgconf luajit qtdeclarative`.
The build discovers LLVM through Homebrew and uses the macOS SDK selected by
`xcrun`. Set `CMAKE_OSX_SYSROOT` or `SDKROOT` to select a different SDK.
On Linux, install CMake, Ninja,
Clang with `clang-scan-deps`, libstdc++ development headers, pkg-config,
LuaJIT 2.1 development headers and libraries, and the Qt QML, Qt Quick and
Qt Quick Controls, Qt Quick Shapes, Qt Network and Qt Concurrent development packages.

CMake finds LuaJIT 2.1 or newer through pkg-config and links it privately to
`desktop-core` and `desktop-ui`. Set `PKG_CONFIG_PATH` if LuaJIT is installed
under a custom prefix. The compilation database includes its header paths
for core and UI sources.

Set `CXX` before the first configure to select another LLVM installation, or
pass `-DCMAKE_CXX_COMPILER=/path/to/clang++`.
Reconfigure with `cmake --fresh --preset debug` after changing the compiler
or standard library so cached flags and compiled modules are regenerated.
Apple Clang is not supported.

CMake finds Qt through its package configuration. Set `CMAKE_PREFIX_PATH`
when Qt is installed under a custom prefix.

`desktop-ui` discovers `.cpp` files under `ui/` and links Qt QML, Quick and
Quick Controls and Shapes. This C++ library is shared across platform backends; Qt
headers and libraries do not become dependencies of `desktop-core`.

On macOS, `desktop-native` discovers all `.mm` files under
`native-backends/macos/` and compiles them as Objective-C++23 with ARC,
using the same LLVM compiler and libc++ as the C++ client. The executable
links that library, `desktop-ui` and AppKit.
The editor target also builds the UI and native libraries, and CMake includes their
source in the compilation database. Native application lifecycle and windows
belong in this platform layer.

## From the repository root

```sh
just desktop-check
just desktop-debug event_queue_dbg
just desktop /path/to/runtime.sock
```

`desktop-check` builds the shared modules, native backend and development
programs without running them. It works independently of `main.cpp`, which
may be under development.

`desktop-debug` builds and runs the named program from `debug/`. Additional
arguments are forwarded to that program. Each `.cpp` in `debug/`, outside
`debug/support/`, is a separate executable with its own `main`.
Nested paths become hyphenated target names:
`debug/input/queue.cpp` becomes `input-queue`. Program names must be unique
and must not collide with build targets such as `telar-desktop` or
`desktop-editor`.

The default socket for `just desktop` is `.zig-out/dev/runtime.sock`. Start
the runtime separately.

### Workspaces and native Spaces integration check

On macOS, build the runtime with `zig build`, then run:

```sh
just desktop-debug spaces_dbg
```

An explicit runtime executable can also be passed as the program's argument.
The default lookup checks `zig-out/bin/telar` and `.zig-out/dev/bin/telar`
relative to the repository, independently of the working directory.

`debug/spaces_dbg.cpp` starts its own runtime, Unix socket and history database
inside a temporary directory. It uses the production `App`, event queue,
`RuntimeReceiverWorker`, `RuntimeSession` and `DesktopSession`. This executable
links `debug/support/spaces_bridge.mm` in place of the production native backend.
It experiments with SkyLight's `SLSBridged` operations for creating, destroying
and switching Spaces. `telar-desktop` continues to use its existing backend.
A second wire client emits `CreateWorkspace`, `CreatePane`, `CreateTab` and
`ClosePane`, acknowledges terminal frames and waits for authoritative exits.
`CreateWorkspace` is the same request the GUI submits after the prefix + N
workspace prompt; the program does not synthesize keyboard shortcuts.

The checks cover a new dedicated Space per workspace, two simultaneous
workspaces, multiple panes/tabs without extra Spaces, closing a non-final pane,
closing a non-final tab, removing the Space after the final pane of the final
tab exits, natural process exit, and closing before native Space creation is
confirmed. The last check holds the bridge's completion until the runtime has
removed the workspace, then verifies that reconciliation removes the orphan.
Probe windows verify that switching changes actual window visibility and that
destroying the active Space migrates its window to a surviving Space. The check
also observes Mission Control entry notifications and fails if one is received.

This is a real system integration check: the focused Space changes during the
run, and Mission Control must remain closed. The experimental bridge does not
require Accessibility, but the reused production `DesktopSession` still gates
workspace reconciliation on that permission, so the runner currently needs it.
The bridge was investigated on macOS 26.6.2 and checks private API availability;
it does not fall back to Mission Control on unsupported versions.
Pre-existing Spaces must remain untouched. Each stage has a timeout; normal
completion and failures both attempt to remove all Spaces created by this run,
restore each display's original Space and the original focus, stop the isolated
runtime and remove its temporary files. Each confirmed stage prints `[PASS]`; failure exits nonzero. It never
connects to an existing runtime or launches another Telar GUI.

## Formatting

Run `just desktop-fmt` to format desktop C++, C++ modules, Objective-C,
Objective-C++ and Lua sources. `just desktop-fmt-check` verifies the same
rules without changing files. Generated build directories are excluded.

Install `clang-format` and StyLua. On macOS, LLVM supplies `clang-format`
and `brew install stylua` installs StyLua. The formatting command discovers
Homebrew LLVM when `clang-format` is not on `PATH`.

`.clang-format` sets a 100-column limit, expands function and lambda bodies,
separates definitions and prevents packing long argument lists onto a line.
`.stylua.toml` applies a matching width and two-space indentation to LuaJIT
scripts. `.editorconfig` keeps indentation consistent while typing.
Use these project files without command-line style overrides. Keep blank
lines between logical sections and between adjacent callback connections;
formatters preserve that grouping but cannot decide it for the author.

## Lua desktop UI

`ui/topbar.lua` creates the bar through `telar.ui`. The default script shows
the focused macOS Space's associated workspace and tabs, with click selection and animated
drag reordering. `ui/components/tabs.lua` implements layout and interaction
entirely in Lua. The native backend owns the panel; Qt Quick draws its contents.

`just desktop` loads `topbar.lua` from the source `ui/` directory. Set
`TELAR_DESKTOP_UI_DIR` to use another directory containing `topbar.lua`.
Without a directory override, the executable loads its bundled `topbar.lua`.
Telar always loads its official API from the bundled `api.lua` resource;
an external `api.lua` cannot replace it. Changes to the official API require
rebuilding the executable.

Saving the external `topbar.lua` or a Lua module loaded with `require` reloads
the UI after a 200 ms debounce.
The watcher follows file replacements made by editors. Each reload builds
a hidden candidate with its own Lua globals in the existing LuaJIT VM.
Success replaces the previous objects, callbacks and animations. A script
or property error discards the candidate and leaves the current UI visible.
Reloading replaces local UI state; it does not reconcile individual objects.
Errors include a Lua stack trace. An invalid initial script still prevents
startup, since no previous UI exists to retain.

The helper API provides:

| API | Behavior |
| --- | --- |
| `ui.item(options)`, `ui.text(options)`, `ui.image(options)` | Create Qt Quick items. `parent` defaults to the generation root. |
| `ui.path(options)` | Create a Shape from an SVG `path` string. Paint options are `fill`, `stroke` and `stroke_width`. |
| `node.property`, `ui.get(node, name)`, `ui.set(node, name, value)` | Read/write Qt properties. Grouped properties use names such as `font.pixelSize`. |
| `ui.on(target, event, callback)` | Subscribe to element or surface events. Returns an unsubscribe function. See [surface events](ui/events.md). |
| `ui.focus(node)` | Request keyboard focus explicitly. |
| `ui.input_method(node, options)` | Supply caret and surrounding text information for a custom text input. |
| `ui.animate(node, property, options)` | Animate a numeric or color property. Requires `to` and integer `duration_ms`; optional `easing` defaults to `out_cubic`. |

On macOS, the native panel forwards hover while Telar is inactive, so
interacting with the bar does not require activating the application.
Shape hover maps the pointer back through the path's scaling and alignment
before checking its filled geometry.

Easings are `linear`, `in_cubic`, `out_cubic` and `in_out_cubic`.
Animations on the same target property replace the previous animation and
start from its current value. Qt performs interpolation without a Lua call
per frame. Animation targets must be direct Qt properties; grouped value
properties such as `font.pixelSize` are readable/writable but not animated
by this API.

`ui.path` exposes `fill`, `stroke`, `stroke_width` and `path` as aliases to
its internal Qt objects, so these properties remain editable after creation.
Paths default to `fillMode = "Stretch"`, scaling their geometry to the
specified `width` and `height`. Use `"PreserveAspectFit"` to retain the aspect
ratio or `"NoResize"` to keep the original path coordinates. This requires
Qt 6.7 or newer. Shape sizing does not resize its text or other child items.
Colors read back as Qt ARGB strings. Image sources accept Qt URL strings.
`ui.surface.width` and `ui.surface.height` read the current logical size;
`ui.surface.root` exposes the generation's root item. `screen`, `scale`,
`safe_area`, `visible` and `active` expose the current surface state.
Reading a value does not establish a reactive binding; subscribe to the
corresponding surface event to react to changes.

Item dimensions do not resize the native panel, which is currently 36
logical points high on macOS. Content extending beyond the surface is
clipped by the window; allow for the item's `y` offset when choosing its height.

For compositions without a helper, use
`ui.create(module, type, properties, parent)` and
`ui.append(object, list_property, child)`. For example, Shapes use objects
from `QtQuick.Shapes` and path elements from `QtQuick`. All referenced
objects must belong to the same generation. Native top-level windows
remain the platform backend's responsibility. Property names and values
are checked; unsupported values and stale object handles raise Lua errors.

UI environments open the base, table, string and math libraries. They
share the VM but keep separate globals and module caches. Reactive
state/bindings and native window geometry controls are not implemented yet.
On macOS, safe-area state includes notch exclusion rectangles where they
intersect the surface; the current bar normally sits below the menu bar.

## Native Spaces and runtime tabs

The desktop connects directly as a control client to the socket passed to
`just desktop /path/to/runtime.sock`. No other Telar client needs to be running.
The runtime owns workspaces, tab identities and tab order. The desktop owns
its selected workspace and tab, remembering tab focus per workspace for its
lifetime. Selecting a tab currently changes this desktop state; it does not
attach or render a terminal, send PTY input, or control another GUI.

On macOS, Telar enumerates displays and existing Spaces itself. The focused
Space determines the desktop's runtime workspace. Native notifications enter
`App` through its event queue; `DesktopSession` associates Spaces with runtime
workspaces, and `RuntimeSession` retrieves their snapshots on its worker.
Lua only receives detached snapshots on the application thread. A workspace
transition clears the previous tab projection until the new snapshot arrives.

Each runtime workspace receives its own newly created ordinary Space on the
focused display, even when pre-existing unassociated Spaces are available.
Adding tabs or panes does not create more Spaces. The runtime removes a
workspace when the final pane in its final tab is collected; that catalog
change causes Telar to remove the workspace's Space. Other workspaces and
pre-existing system Spaces remain untouched.

A Space's `managed` flag identifies Spaces created by this desktop session.
Associations use the native Space UUID where available, so reordering Spaces
does not change them. macOS may omit a UUID; those Spaces use a display UUID
and session-local Space ID instead. Bindings, ownership and selected tabs are
in memory, surviving Lua reloads but not a desktop restart.

A live workspace retains its dedicated Space. Lua cannot remove or unbind it
before the workspace closes, or assign another Space to the same workspace.
If its Space is removed externally through Mission Control, Telar creates a
replacement while the workspace remains alive. Unassociated Spaces show an
empty strip; fullscreen and pre-existing Spaces are never automatically adopted.

`require("telar.desktop")` exposes:

| API | Behavior |
| --- | --- |
| `desktop.state()` | Snapshot with `available`, `accessibility`, `displays`, `spaces`, optional `focused_space`, `pending_space`, and `error`. |
| `desktop.on_change(callback)` | Subscribe to changed desktop snapshots; returns an unsubscribe function and delivers the current state on mount. |
| `desktop.activate_space(id)` | Request activation of an existing Space. Completion is confirmed from macOS; failures appear in `error`. |
| `desktop.bind_space(space_id, workspace_id)` | Associate an unbound managed Space with a workspace that has no Space or pending creation. A live association cannot be changed or cleared. |
| `desktop.create_space(options)` | Create an ordinary Space. Optional `display` selects a display ID; optional `workspace` associates a runtime workspace ID. Defaults to the focused display and no association. Returns a request ID. |
| `desktop.remove_space(space_id)` | Remove an unassociated ordinary Space. A live workspace's Space must close through its final pane. Returns a request ID. |

Display entries contain `id`, `uuid` and global screen bounds (`x`, `y`,
`width`, `height`). Space entries contain `id`, `uuid`, `display`, `index`,
`visible`, `focused`, `fullscreen`, `managed` and optional `workspace`. Several
displays can have a visible Space simultaneously; `focused` identifies the active one.
The current implementation hosts one bar on the initial main screen, following
the globally focused Space, including when focus moves to another display.

`require("telar.runtime")` exposes:

| API | Behavior |
| --- | --- |
| `runtime.state()` | Detached snapshot with `connected`, workspace catalog `workspaces`, optional `workspace`, `active_tab`, and ordered `tabs`. |
| `runtime.on_change(callback)` | Subscribe on the application thread; returns an unsubscribe function and delivers the current snapshot on mount. |
| `runtime.select_tab(id)` | Select a tab in the desktop's current workspace. Returns a request ID. |
| `runtime.move_tab(id, {before = anchor})` | Insert a tab before another tab in its workspace; `{after = anchor}` inserts after it. Returns a request ID. |

IDs are decimal **strings**, preserving complete unsigned 64-bit values in
LuaJIT. Workspaces expose `id`, `kind` and `name`; tabs expose `id`, `label`
and foreground process names in `foregrounds`. `context` identifies the
current native Space. Missing optional fields are `nil`. Runtime requests
report their latest completion through `completed_request`,
`request_succeeded` and optional `error`.

Commands require a mounted generation; startup commands can be issued from a
subscription's initial callback or a `mount` callback. Invalid input raises
Lua errors. Native validation failures appear in the desktop snapshot.
Subscriptions and Lua callback references are released with their generation,
including failed reloads. Filesystem reloads preserve the selected workspace,
selected tab and Space associations.

Space creation/removal are serialized transactions. `pending_operation` contains
`id`, `kind`, `display` and the target `space` when applicable.
`completed_operation` contains those fields plus `succeeded` and optional
`error`; a successful creation includes the new `space` ID. Completion follows
an observed catalog change, not just an accepted Accessibility action. Observe
these snapshots before issuing the next mutation. A failed automatic mutation
pauses further automatic mutations until the workspace catalog gains/loses a
workspace, or a manual mutation succeeds.

The default Lua bar has a `+` button to create an unassociated Space. Its `×`
buttons and middle-click remove unassociated ordinary Spaces when another
ordinary Space remains on their display. Workspace Spaces have no independent
close control: their lifetime follows the runtime workspace.

Runtime transport, decoding and command writes run on a worker, with a bounded
64-command queue. Workspace subscriptions deliver tab changes without polling
clients or tab lists. Dragging changes a Lua preview; dropping sends one
runtime mutation and reconciles against its acknowledgement. Other tabs animate
towards their insertion positions. Cancellation or a Space/workspace/tab-set
change discards the preview. The strip reuses at most 64 tab views and scrolls
when needed. A lost runtime connection displays an error; restart the desktop
to reconnect in this version.

### macOS implementation and limits

Enumeration dynamically resolves private SkyLight functions. Existing Spaces
are activated with synthetic Dock gestures, then checked against the actual
native state, with a bounded timeout and one observed hop at a time. Focusing
another display may activate and raise one of its visible application windows
through Accessibility. Telar neither invokes nor connects to yabai and does not
inject code into Dock or require SIP changes. The gesture reference's MIT
attribution is retained in `licenses/yabai.txt`.

Activation requires Accessibility permission for the executable or its host.
If it is missing, the desktop snapshot reports the System Settings location.
Ordinary changes are driven by Space/application/screen/wake notifications;
a two-second catalog fallback also detects Mission Control reordering and
permission changes. During activation, confirmation runs every 80 ms.

Creating and removing Spaces uses Telar's own asynchronous Accessibility
implementation against Mission Control's Dock controls. Mission Control briefly
appears while these operations run; there is no coordinate-based clicking or
external automation dependency. The Accessibility structure was studied from
Hammerspoon's `hs.spaces`; its MIT attribution is in `licenses/hammerspoon.txt`.
Telar switches away from a visible Space before removing it. Fullscreen Spaces
and the last ordinary Space on a display cannot be removed. If cleanup reaches
that last Space, it remains as an unassociated desktop. Opening Mission Control
manually during an operation may cause it to fail; requests made while Mission
Control is already open are rejected.

The native APIs, Accessibility structure and gesture fields are undocumented
and may change between macOS versions. Missing symbols, vanished Spaces and
rejected transitions are reported as errors. This version does not reorder native Spaces, restore
bindings/ownership from disk, or move application windows between Spaces.
Ownership is session-local: Spaces left by an earlier desktop process are not
silently reclaimed or removed. On restart, live runtime workspaces receive new
managed Spaces; persistent restoration of previous associations is not implemented.

## Filesystem and HTTP

`telar.fs` and `telar.net` are also available through `require("telar.fs")`
and `require("telar.net")`. Every operation accepts a callback with
`(error, result)` and returns a function that cancels the operation.
Success passes `nil` as the error. Operational failures pass an error
string; invalid arguments raise a Lua error immediately.

| API | Result |
| --- | --- |
| `fs.read_file(path, callback)` | File contents as a binary Lua string. |
| `fs.write_file(path, contents, callback)` | `true` after the atomic write commits. The parent directory must exist. |
| `fs.list_dir(path, callback)` | An unsorted array of `{name, path, type}` entries, including hidden entries. Types are `file`, `directory`, `symlink`, `other`. |
| `fs.watch(path, callback)` | Calls back with the absolute path when it changes. The target must exist initially; file replacement and recreation are followed. Directory watches are not recursive. |
| `net.request(options, callback)` | An HTTP response containing `status`, `body`, `headers`, `raw_headers` and final `url`. |

Filesystem access is local to the machine running the desktop client.
Paths resolve relative to the directory containing `topbar.lua`.
Absolute paths and `~/` are supported. `fs.config_dir` exposes that base
directory and `fs.home_dir` exposes the user's home directory. Bundled
resources have a `:/telar/ui` base and are read-only; use a filesystem path
when writing data. Read/write payloads are limited to 16 MiB. Directory
listings are limited to 10000 entries.

File reads, writes and directory listings run on Qt's thread pool. HTTP
uses Qt Network asynchronously. Callbacks run on the UI thread, where they
can safely update UI properties. No asynchronous I/O starts until a candidate
UI has loaded successfully. Reloading cancels its old operations and watches
and suppresses their callbacks. Worker cancellation is cooperative; a write
that has already committed is not rolled back.

```lua
local fs = require("telar.fs")

local cancel = fs.read_file("settings.json", function(err, contents)
    if err then
        print(err)
        return
    end

    print(contents)
end)
```

HTTP options are `url`, `method`, `headers`, `body`, `timeout_ms` and
`max_bytes`. The URL must be absolute HTTP or HTTPS. Defaults are `GET`,
30000 ms total timeout and a 16 MiB response limit. Request bodies are
binary strings limited to 16 MiB. Headers are a table of string names and
values. Bodies default to `application/octet-stream` when no content type
is supplied. HTTPS uses Qt's certificate verification.

Response header names in `headers` are lowercase, with the last value for
repeated names. `raw_headers` preserves every `{name, value}` pair. Response
bodies are binary strings. HTTP errors such as 404 pass both an error string
and the response; transport errors can have `status = 0`. Timeout and response
limit errors pass no response. Cancellation suppresses the callback.

```lua
local net = require("telar.net")

net.request({ url = "https://example.com", timeout_ms = 5000 }, function(err, response)
    if err then
        print(err)
        return
    end

    print(response.status, response.body)
end)
```

## Lua modules

`require("widgets.clock")` searches `widgets/clock.lua`, then
`widgets/clock/init.lua`, relative to the UI directory. Modules return
their public value, commonly a table. `package.path`, `package.preload`
and `package.loaded` are available. `telar`, `telar.ui`, `telar.fs`,
`telar.net` and `telar.runtime` are preloaded.

Module loading is synchronous and cached within the current generation.
Each successful UI reload gets a fresh cache. Imported files are watched,
including files encountered by a failed reload, so fixing a module error
or creating a missing module can recover the UI automatically. Failed
reloads keep the current UI and its operations running.

This loader supports Lua source modules and Qt resources. C modules,
`package.loadlib`, LuaRocks searchers and the standard `io`/`os` libraries
are not enabled; general file and HTTP access use the asynchronous APIs above.

## Adding source files

Create shared `.cppm` modules and `.cpp` implementations anywhere under this
directory, outside `ui/`, `debug/`, `tests/` and generated output directories. CMake
discovers them automatically and Clang scans their module dependencies.
`main.cpp` belongs to the application; files in `debug/` belong to their own
executables. Each debug program links the shared modules.

Put shared Qt UI headers and `.cpp` implementations under `ui/`. CMake
discovers these implementations as part of `desktop-ui`, separately from
the core modules and the platform-specific backends.

Lua scripts under `ui/` are discovered automatically and embedded in the
`telar-desktop` executable as Qt resources. For example, `ui/topbar.lua`
is available through `QFile` at `:/telar/ui/topbar.lua`, independently of
the current working directory. Rebuild `telar-desktop` after editing a
bundled script to update the embedded resource.

Put modules and implementation files shared only by development programs in
`debug/support/`, for example `debug/support/random_data.cppm`. CMake discovers
these `.cppm` and `.cpp` files as the `desktop-debug-support` library and links
it only to the programs in `debug/`. Support modules can import application
modules from `desktop-core`; the application does not link debug support.
The support directory may be empty until the first utility is added.

The next configure or build discovers additions and removals. No build-file
edit is needed for a new module or development program. Keep generated build
trees under `out/`, which is excluded from source discovery and Git.

## Editor

`.clangd` reads `out/debug/compile_commands.json`, generated by CMake. Use the
same LLVM installation's `clangd` with `--experimental-modules-support` so
imported module symbols appear in completion results. `.clangd-args` records
this server argument for Neovim configurations that read that file, one
argument per line. Other editors must enable it in their clangd launch settings.
After adding or changing a source file, module or header, run:

```sh
just desktop-editor
```

This updates the shared modules, builds development programs and refreshes
their module response files for clangd without compiling `main.cpp`. A new
program must compile successfully before its build can complete.

`.clangd-build.json` declares argument arrays for configuring and building
the editor target. Neovim configurations that support this file run those
commands asynchronously on save, serialize builds and retain pending saves.
`build_directory` identifies the project's build tree. The Neovim integration
fingerprints its compiled module timestamps, module maps and compilation
configuration after builds, including failed builds that updated modules
before another target failed. When these change, it stops the
project's clangd, removes only its `.cache/clangd/modules` cache, and restarts
it with all loaded buffers, including unsaved edits. A consumer-only edit
that leaves those inputs unchanged preserves the cache and running server.

On an unexpected clangd exit, the integration retains the failed module cache
in `.cache/clangd/modules-crash`, records the exit details and LSP log path,
and retries once with a fresh cache. A second crash for the same fingerprint
stops automatic recovery. That limit persists across editor restarts and is
reset when the compiled modules or configuration change. The background index
and CMake build outputs are preserved.

Projects without `.clangd-build.json` do not opt into automatic builds or
recovery. Other editors can invoke `just desktop-editor` on save and restart
their clangd after success.

Run `just desktop` once to generate the application's own module response
file before using clangd on `main.cpp` in a fresh build tree.

## Direct CMake commands

From this directory:

```sh
cmake --preset debug
cmake --build --preset debug
./out/debug/event_queue_dbg
```

For an optimized build, use `cmake --preset release` and
`cmake --build --preset release`. Its output is under `out/release/`.
Use `--target <name>` to build only one program. The editor always uses the
Debug compilation database.
