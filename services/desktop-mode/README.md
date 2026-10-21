# C++ desktop client

CMake 3.28 or newer and Ninja 1.11 or newer build the C++23 desktop client.
Upstream LLVM Clang, including `clang-scan-deps`, compiles the modules. On
macOS, C++ and Objective-C++ use libc++ to match the installed Qt libraries.
Qt 6.7 or newer provides QML, Qt Quick, Qt Quick Controls, Qt Quick Shapes,
Qt Network and Qt Concurrent.
The desktop keybinding engine is a standalone C++ library in `keybindings-engine/`.
Building the desktop does not require Zig. The runtime and the rest of Telar
still build with Zig.

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
Quick headers and libraries do not become dependencies of `desktop-core`.
The core uses Qt Core privately for the persistent Space registry.

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

The default socket for `just desktop` is `.zig-out/dev/runtime.sock` until a
desktop clone has been prepared, then `.zig-out/desktop-dev/runtime.sock`. An
explicit socket always takes precedence. Start the runtime separately.

### Switching between the regular runtime and a development clone

Create a separate development environment from the regular runtime's checkpoint:

```sh
just desktop-runtime /absolute/path/to/regular/runtime.sock /absolute/path/to/session.ckpt
```

This runs the cloned runtime in the foreground, under `.zig-out/desktop-dev`.
In another terminal, run `just desktop` or `just desktop-dev`. After stopping the
clone, `just desktop-runtime` restores it without needing the source arguments again.
To return to the regular runtime,
run `just desktop /absolute/path/to/regular/runtime.sock`. A new Desktop asks
the previous Desktop to exit and waits for exclusive ownership before touching
Spaces or registering global shortcuts. Both runtimes and their processes remain
running. A pending Space operation delays the handoff; retry once it finishes.

The clone copies the checkpoint's workspace and tab IDs, names, directories,
pane sizes and saved client layouts. Each pane starts a fresh `$SHELL`, falling
back to `/bin/sh`. Agent resumes, original launch commands and worktree ownership
are excluded. Files in those directories are shared; this is not a filesystem
sandbox. The checkpoint is an atomic, coherent snapshot, which may lag the live
runtime until its next checkpoint write. Reading it does not stop the source.

Later starts reuse the clone's own checkpoint. Seeding refuses to overwrite an
existing environment without matching origin metadata. The ordinary development
runtime in `.zig-out/dev` is unaffected. `--fresh` explicitly resets a runtime and
also sets its desktop clone origin aside.

Desktop manages the session's ordinary Spaces. It restores saved associations,
adopts existing Spaces before creating any, and removes surplus ordinary Spaces.
The clone's original workspaces reuse the source's associations; workspaces created
later in development have their own identities. Switching after creating or closing
workspaces reconciles the difference with the selected runtime. The selected Space
is retained when it survives reconciliation. There is no automatic merge back into
the source runtime.

The registry lives in Qt's user data directory under `telar/desktop/spaces.json`,
with owner-only permissions and atomic writes. `TELAR_DESKTOP_STATE_DIR` overrides
the registry and controller endpoint together, for isolated diagnostics. Corrupt
state stops automatic reconciliation. No Spaces are removed before a complete,
connected runtime workspace catalog is received.

macOS requires at least one ordinary Space per display. If there are fewer
workspaces than displays, the last Space of an unassigned display remains.
Fullscreen Spaces are owned by the applications' fullscreen lifecycle and are
excluded from ordinary-Space reconciliation.

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
`RuntimeReceiverWorker`, `RuntimeSession`, `DesktopSession` and native backend.
Both this executable and `telar-desktop` link the same SkyLight implementation.
`debug/support/spaces_probe.mm` only supplies probe windows and observations.
A second wire client emits `CreateWorkspace`, `CreatePane`, `CreateTab` and
`ClosePane`, acknowledges terminal frames and waits for authoritative exits.
`CreateWorkspace` is the same request the GUI submits after the prefix + N
workspace prompt; the program does not synthesize keyboard shortcuts.

The checks cover a new dedicated Space per workspace, two simultaneous
workspaces, multiple panes/tabs without extra Spaces, closing a non-final pane,
closing a non-final tab, removing the Space after the final pane of the final
tab exits, natural process exit, and closing before native Space creation is
confirmed. The last check delays delivery of the production backend's completion
until the runtime has removed the workspace, then verifies orphan cleanup.
Probe windows verify that switching changes actual window visibility and that
destroying the active Space migrates its window to a surviving Space. The check
also observes Mission Control entry notifications and fails if one is received.
When another managed display is attached, it also checks creation and removal
on that display without changing its visible Space.

This is a real system integration check: the focused Space changes during the
run, and Mission Control must remain closed. Neither the bridge nor workspace
reconciliation requires Accessibility. The runner prints its current permission
status; the lifecycle also passes when launched as an app without that permission.
The bridge was investigated on macOS 26.6.2 and checks private API availability;
it does not fall back to Mission Control on unsupported versions.
Pre-existing Spaces must remain untouched. Each stage has a timeout; normal
completion and failures both attempt to remove all Spaces created by this run,
restore each display's original Space and the original focus, stop the isolated
runtime and remove its temporary files. Each confirmed stage prints `[PASS]`;
failure exits nonzero. It never connects to an existing runtime or launches
another Telar GUI.

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

`ui/topbar/init.lua` creates the bar through `telar.ui`. The default script shows
the focused macOS Space's associated workspace and tabs, with click selection and animated
drag reordering. `ui/topbar/tabs.lua` implements layout and interaction
entirely in Lua. The native backend owns the panel; Qt Quick draws its contents.

`ui/sidebar/init.lua` creates the left sidebar. It lists runtime workspaces and their
tab counts, highlights the focused workspace, and activates a workspace's macOS
Space on click. The list scrolls when it exceeds the panel height. Selection is
disabled while disconnected or while a Space operation is pending.

Both panels use `TelarSurfacePanel` for native window behavior and `LuaSurface`
for their Qt/Lua contents. `DesktopUi` owns configuration and coordinates reloads.
Configuration and surfaces share the runtime connection, desktop service, shortcut
engine and LuaJIT VM, with separate globals, module caches and subscriptions.
Only surface environments have a visual root.

The desktop has its own Lua entry point, separate from the GUI's `config.lua`:

1. `TELAR_DESKTOP_CONFIG`, when set, selects a specific file. A missing file is an error.
2. Otherwise, load `$XDG_CONFIG_HOME/telar/desktop.lua`, or `~/.config/telar/desktop.lua`
   when `XDG_CONFIG_HOME` is unset or empty.
3. If that default file does not exist, run the bundled `ui/desktop.lua`, which
   configures both surfaces and registers the default shortcuts.

The desktop does not load `config.lua` or use `TELAR_DEVELOPMENT_CONFIG`.
Its configuration is an executable Lua script using the desktop API, rather than
the GUI's configuration table. For example, `desktop.lua` can contain:

```lua
local shortcuts = require("telar.shortcuts")
local desktop = require("telar.desktop")
shortcuts.set_prefix("ctrl+s")
require("shortcuts")()

local colors = { background = "#1b1723", accent = "#c4a7e7" }

desktop.configure_surface("topbar", {
  module = "topbar",
  options = { colors = colors },
})

desktop.configure_surface("sidebar", {
  module = "sidebar",
  options = { colors = colors, title = "My fleet" },
})
```

`desktop.lua` executes once at startup and once per configuration reload, in an
environment independent of both panels. It registers global shortcuts and chooses
each surface's module and options. UI creation belongs inside a surface module;
calling UI operations from the global environment raises an error. Existing
configurations should replace `require("topbar")` with `require("shortcuts")()`
and `desktop.configure_surface(...)` calls.

`configure_surface(name, settings)` accepts `topbar` or `sidebar`, with optional
`module` and `options` fields. The default module matches the surface name, with
empty options. Options are copied data tables, including nested tables and dense
arrays of up to 4096 entries, with at most 16 levels of table nesting;
functions and UI objects cannot cross environments. Each surface reads its own
copy through `ui.surface.options`. `ui.surface.name` and `ui.surface.module`
identify the surface and its configured module. Local edits to an options table
do not change the global configuration or another surface.

Both built-in surfaces accept a `colors` table; the sidebar also accepts `title`.
Custom modules can interpret their options freely. These options configure UI
content, not native panel geometry.

To replace the sidebar, select another module or put `sidebar/init.lua` in the
directory containing `desktop.lua`; during development, edit
`ui/sidebar/init.lua` or add an override at `dev/sidebar/init.lua`. The same
rules apply to the topbar. Shared Lua components can be imported by both
surfaces, with separate local state.
Local modules resolve relative to `desktop.lua`. Modules not found there are
looked up in `TELAR_DESKTOP_UI_DIR`, if set, then in the bundled UI resources.
`just desktop` and `just desktop-dev` explicitly select the repository's
`dev/desktop.lua` through `TELAR_DESKTOP_CONFIG`, independently of the installed
desktop configuration. They also set `TELAR_DESKTOP_UI_DIR` to the source `ui/`
directory unless it is already set. Edit `dev/desktop.lua` for development;
its changes and imported modules reload automatically. The GUI continues to use
its own `dev/config.lua`. Running the desktop executable directly follows the
configuration lookup above.
Telar always loads its official API from the bundled `api.lua` resource;
an external `api.lua` cannot replace it. Changes to the official API require
rebuilding the executable.

Saving `desktop.lua` or a module it imports prepares a new configuration and all
attached surfaces after a 200 ms debounce. Scripts, properties and the combined
shortcut map must validate before any live environment is replaced. A rejected
reload keeps the previous configuration, interfaces and bindings; fixing an
imported file retries the complete pending configuration.

An edit imported only by a surface reloads that surface. It does not execute
`desktop.lua` or recreate the other panel. Reloading a surface without bindings
also preserves a pending global shortcut sequence. Creating the default config
while the desktop is running reloads the desktop; removing it restores the
bundled entry point.

The watcher follows file replacements made by editors. Candidates have their
own Lua globals in the existing LuaJIT VM and remain hidden while being built.
Success replaces the previous objects, callbacks and animations. A script or
property error leaves the current UI visible.
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

Item dimensions do not resize the native panels. On macOS the topbar is 36
logical points high; the sidebar is 280 points wide, inset 8 points from the
left and bottom of the screen's available area and separated from the topbar
by the same margin. Both attach to the main screen at startup and follow its
geometry changes, falling back to the current main screen if it is removed.
They are visible across Spaces. The sidebar overlays application windows;
it does not yet reserve their layout area or collapse. Content extending beyond
a surface is clipped by its window.

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

## Desktop shortcuts

`require("telar.shortcuts")` registers desktop-wide shortcuts from Lua. macOS
captures matching keys even when another application is focused, including the
Telar GUI. Desktop shortcuts take priority without focusing the bar. Other keys
pass through unchanged; after its prefix, the desktop owns the whole sequence.
Capture requires Accessibility permission for the desktop process, or the terminal
launching it during development. The backend retries when permission is granted;
it does not change system permissions. `shortcuts.state()` exposes `available`,
`error`, `prefix` and `pending`.

The default `desktop.lua` loads `shortcuts` and uses `Ctrl+B`, followed by:

| Suffix | Action |
| --- | --- |
| `1`–`9` | Select that tab in the active Space's workspace. |
| `n`, `p` | Select the next or previous tab, wrapping at the ends. |
| `,`, `.` | Move the selected tab before or after its neighbor. |

`Ctrl+Left` and `Ctrl+Right` are global bindings without the prefix. They select
the previous or next ordinary Space on the focused display, wrapping at the ends.

These actions use the existing runtime and desktop APIs. Pane operations, creating
workspaces/tabs, palettes and terminal rendering are not connected to this keymap.
Tab selection currently changes the desktop's selected tab, as with a click on
the topbar; it does not change a separate GUI client's focus.

The desktop keymap does not import the GUI's `client.prefix` or `client.keybindings`.
Global bindings belong in `desktop.lua`, independently of any surface. To use
`Ctrl+S`, call `require("telar.shortcuts").set_prefix("ctrl+s")` there before
registering bindings. Each surface inherits that prefix and can register its own
bindings for UI actions. Omit `require("shortcuts")()` to define a complete custom
global map. For example:

```lua
local shortcuts = require("telar.shortcuts")
shortcuts.set_prefix("ctrl+s")

local unbind = shortcuts.bind({ "g", "t" }, function()
  -- Dispatch work through telar.runtime or telar.desktop.
end)

shortcuts.bind_global("cmd+shift+p", function()
  -- Run a global action without the prefix.
end)
```

`bind` accepts one to four suffix chords; `bind_global` accepts a single modified
chord. Both return an idempotent unbind function. The C++ chord parser preserves
the GUI's spelling, case and modifier rules. Prefixes require Ctrl, Alt or
Command/Super. Arbitrary unprefixed multi-key sequences are intentionally rejected:
replaying buffered input into a different application is not implemented.

The prefix waits without a timeout. Escape, an invalid suffix, a mouse press,
switching applications or Spaces, or replacing bindings cancels it. A held
key invokes its callback once. The router retains intercepted key releases
across reloads and focus changes. Duplicate or ambiguous bindings are rejected;
the whole desktop holds at most 256 bindings, with one shared prefix across surfaces.

Each environment owns its callbacks. A configuration reload validates and replaces
all affected groups together, including when the shared prefix changes. A rejected
replacement leaves the previous map active. Queued actions
from an obsolete generation or focus context are discarded. Native capture only
queues action IDs in `App`'s event queue. Lua runs when `App` drains that queue,
outside the macOS event tap callback.

The `keybindings-engine` CMake target has no Qt, Lua or native dependencies:

- `chord.hpp/.cpp` parses and normalizes key names, modifiers and UTF-8 characters.
- `keymap.hpp/.cpp` validates and sorts bindings, rejecting duplicate and ambiguous sequences.
- `router.hpp/.cpp` resolves events into consumed/pass-through decisions and action IDs.

Routing uses binary searches within the remaining candidates and a bounded table
of 64 held physical keys, without allocating. If that table is full, a new press
passes through and cancels the sequence so its eventual release also reaches the
focused application. Configuration replacement is transactional and preserves
already intercepted keys until release. `Shortcuts` manages callback ownership
and queued action generations; the platform backend owns global keyboard capture.

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

Each runtime workspace receives an ordinary Space. Desktop first restores its
saved association, then adopts available Spaces, and creates one only when none
is available. Visible Spaces and displays without an associated workspace are
preferred during adoption. Adding tabs or panes does not create more Spaces.
Closing the final pane in the final tab removes the runtime workspace and its
Space, subject to macOS's minimum of one ordinary Space per display. Surplus
ordinary Spaces are removed after all live workspaces have an association.

The `managed` flag covers all ordinary Spaces while Desktop controls the session.
Associations persist by runtime identity, workspace ID and native Space UUID, so
desktop restarts and Space reordering preserve them. macOS may omit a UUID; those
Spaces use a display UUID and session-local Space ID instead. Selected tabs still
live in memory. Development clones share only their original workspaces' identities.

A live workspace retains its dedicated Space. Lua cannot remove or unbind it
before the workspace closes, or assign another Space to the same workspace.
If its Space is removed externally through Mission Control, Telar creates a
replacement while the workspace remains alive, adopting an available Space first.
Fullscreen Spaces are excluded from this reconciliation.

`require("telar.desktop")` exposes:

| API | Behavior |
| --- | --- |
| `desktop.configure_surface(name, settings)` | Configure `topbar` or `sidebar` with `module` and `options`. Available only while loading the global configuration. |
| `desktop.state()` | Snapshot with `available`, `accessibility`, `displays`, `spaces`, optional `focused_space`, `pending_space`, and `error`. |
| `desktop.on_change(callback)` | Subscribe to changed desktop snapshots; returns an unsubscribe function and delivers the current state on mount. |
| `desktop.activate_space(id)` | Request activation of an existing Space. Completion is confirmed from macOS; failures appear in `error`. |
| `desktop.bind_space(space_id, workspace_id)` | Associate an unbound managed Space with a workspace that has no Space or pending creation. A live association cannot be changed or cleared. |
| `desktop.create_space(options)` | Create an ordinary Space for the required `workspace` ID, if it has no Space yet. Optional `display` selects a display ID; the default is the focused display. Returns a request ID. Normal workspace reconciliation handles creation automatically. |
| `desktop.remove_space(space_id)` | Remove an unassociated ordinary Space. A live workspace's Space must close through its final pane. Returns a request ID. |

Display entries contain `id`, `uuid` and global screen bounds (`x`, `y`,
`width`, `height`). Space entries contain `id`, `uuid`, `display`, `index`,
`visible`, `focused`, `fullscreen`, `managed` and optional `workspace`. Several
displays can have a visible Space simultaneously; `focused` identifies the active one.
The current implementation hosts the topbar and sidebar on the initial main screen, following
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
an observed catalog change, not just a submitted bridge operation. Observe
these snapshots before issuing the next mutation. A failed automatic mutation
pauses further automatic mutations until the workspace catalog gains/loses a
workspace, or a manual mutation succeeds.

The default Lua bar creates no standalone Spaces. Its `×` buttons and middle-click
can remove surplus ordinary Spaces while another ordinary Space remains on their
display. Workspace Spaces have no independent close control: their lifetime
follows the runtime workspace.

Runtime transport, decoding and command writes run on a worker, with a bounded
64-command queue. Workspace subscriptions deliver tab changes without polling
clients or tab lists. Dragging changes a Lua preview; dropping sends one
runtime mutation and reconciles against its acknowledgement. Other tabs animate
towards their insertion positions. Cancellation or a Space/workspace/tab-set
change discards the preview. The strip reuses at most 64 tab views and scrolls
when needed. A lost runtime connection displays an error; restart the desktop
to reconnect in this version.

### macOS implementation and limits

Enumeration dynamically resolves private SkyLight functions. Mutation uses
SkyLight's `SLSBridged` operations through `performWithWMBridgeDelegate`.
Creation returns a Space ID synchronously; removal and switching are asynchronous.
Switching shows the destination, hides the source and updates the display's
current Space. These are separate operations, without a custom animation.

Creating, removing and changing the visible Space require neither Accessibility
nor SIP changes. Telar does not inject into Dock, synthesize gestures, open
Mission Control or depend on yabai. The `accessibility` snapshot field remains
informational. Moving keyboard focus to another display is separate: when
permission exists, Telar can raise a visible application window through AX.
If macOS changes visibility but does not grant display focus, activation reports
that distinction instead of claiming success.

Space/application/screen/wake notifications drive observation. A two-second
fallback catches external catalog changes; pending operations are checked every
20 ms, with a five-second timeout. A full event queue causes publication to be
retried. Creation on another display waits for the new Space's placement before
reporting success. Failed placement attempts to remove that newly created Space.

macOS handles window migration when an active Space is destroyed. Fullscreen
Spaces and the last ordinary Space on a display cannot be removed. If automatic
cleanup reaches that last Space, it remains as an unassociated desktop.

The private API was verified on macOS 26.6.2. Required classes, selectors and
operation return types are checked at runtime. Missing APIs, vanished Spaces and
rejected transitions are reported as errors, with no Mission Control fallback.
This version does not expose native Space reordering or move individual
application windows between Spaces. Native UUID persistence across macOS reboots
depends on the operating system; missing identities fall back to ordinary-Space
adoption.

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
Paths resolve relative to the directory containing `desktop.lua`, including when
the bundled entry point is used because the default config has not been created.
Absolute paths and `~/` are supported. `fs.config_dir` exposes that base
directory and `fs.home_dir` exposes the user's home directory. Bundled
resources under `:/telar/ui` are read-only. Read/write payloads are limited to 16 MiB. Directory
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
`widgets/clock/init.lua`, relative to the directory containing `desktop.lua`,
then in `TELAR_DESKTOP_UI_DIR` and the bundled UI resources. Modules return
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
`telar-desktop` executable as Qt resources. Each surface has its own directory:
`ui/topbar/` and `ui/sidebar/`, with `init.lua` as its entry point and its
surface-specific components alongside it. `require("topbar")` and
`require("sidebar")` resolve those entry points through the `?/init.lua` pattern.
Shared UI infrastructure remains directly under `ui/`.

For example, `ui/topbar/init.lua`
is available through `QFile` at `:/telar/ui/topbar/init.lua`, independently of
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
