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

### Desktop workbench

`ui/workbench/` implements the desktop workbench in C++. It uses the existing
C++ wire codecs and Qt Quick scene graph. It does not link the Zig GUI or a Zig
terminal renderer. Cocoa window placement and Accessibility operations live in
`native-backends/macos/workbench.mm`.

Each runtime tab has an independent split tree and focus. Its elements can be
terminal panes, Lua views or other applications' windows. Each terminal
and Lua view has its own window. A visible workspace uses one asynchronous runtime
connection shared by its terminal panes. Switching tabs detaches hidden terminals;
a tab switch attaches the incoming terminals before detaching the outgoing ones,
so the session never leaves its workspace; switching away from a workspace
detaches all of its terminals and keeps its
presentation session open for one minute, so returning skips the handshake. A
detached terminal keeps its last frame, as the GUI does, until the next attachment
delivers a full one.

Every tab of every workspace is prewarmed. A visible workspace's connection
fetches the panes of all its tabs, and a hidden workspace's connection loads
them once and closes. A view exists for each pane right away; its surface and
window are made in idle time, one phase of one pane per turn of the event loop
(`ui/workbench/idle_work.cpp`): the surface, then the native window on its Space,
then showing it transparent so it draws. Each phase fits in a frame, and visible
workspaces go first. The first visit to a tab, or to a workspace, then costs the
same as returning to one. Like the GUI, only the visible tab's terminals are
attached, so a prewarmed terminal fills in with its first attached frame. A pane
that has not been prewarmed yet when its tab is shown is made on the spot. A pane window that has been shown is never hidden again:
hiding a window takes several frames of window server round trips and render
thread waits. Retiring a pane makes its window transparent, which also lets the
mouse through, and reports its surface as not `visible`, so Lua treats it as
gone and its `ui.animate` animations pause until it is visible again. Showing it
again restores its opacity and its last frame at once. A window shown for the
first time is transparent until it draws, so on a tab switch the outgoing windows
stay up until every new one has presented its first frame, or for at most
250 ms. Pane windows never become the key window,
because every change of key window makes macOS switch the input method context
with blocking round trips. The keyboard router (`ui/workbench/keyboard_router.cpp`)
keeps an invisible input window on every Space as the key window, while Qt treats
the focused pane as its focus window: Qt Quick focus, the input method and Lua's
`active` state behave as if the pane were key. The input window forwards key
events to the pane. Moving the keyboard between panes skips the input method
commit Qt Quick makes on focus changes, because it would switch the native input
context; a composition in progress is committed in its pane first. Pressing a
pane, or Lua focusing one of its items, focuses it. Other applications' windows are still activated, as they belong to their applications.
A hidden workspace keeps its windows on its own
Space, which macOS already keeps out of sight; returning shows their last frame. A
terminal shows "Connecting to runtime…" only after 750 ms in view without a live
attachment. These operations leave the processes running in the runtime.

The default prefix remains `ctrl+b`. The default `shortcuts` module binds:

| After the prefix | Action |
| --- | --- |
| `%` / `"` | Split horizontally / vertically |
| Arrow keys / `o` | Directional focus / next element |
| `alt+arrow` | Move the nearest split boundary |
| `z` / `f` | Toggle maximization / floating |
| `x` | Close the terminal, remove the Lua view, or close an external window |

Floating panes can be moved by dragging their header and resized from the bottom
right corner. Closing an external element presses its window's close button, as
clicking it would; the application decides what that means. Existing tab and workspace shortcuts remain available.

Configure pane decoration and geometry independently of the GUI configuration:

```lua
desktop.configure_surface("workbench", {
  module = "workbench",
  options = {
    margin = 8,
    gap = 8,
    padding = 8,
    header_height = 28,
    font_size = 14,
    colors = { background = "#1b1723", foreground = "#cdd6f4", accent = "#c4a7e7" },
  },
})
```

Geometry uses logical desktop coordinates, including negative monitor origins.
The available area excludes the OS menu bar/Dock and the actual topbar/sidebar
rectangles. Setting `options.overlay = true` on either chrome surface removes its
reservation. Each display can present a different workspace. When a split's
minimum sizes no longer fit, only the focused element is shown; the split tree
remains intact and returns when space is available. Terminal rows and columns
come from the content rectangle and font metrics. Pixel cell sizes include the
display scale. Resize messages are coalesced and sent only when effective dimensions
change. The runtime's geometry lease still decides which client may resize a PTY.

`require("telar.workbench")` is available in every surface and in `desktop.lua`.
Commands execute from callbacks after the UI has activated. IDs are strings.

| API | Meaning |
| --- | --- |
| `state()` | Visible workspaces, tabs, focused element, requested/actual geometry and errors |
| `on_change(callback)` | Subscribe to workbench changes; returns an unsubscribe function |
| `command("split", { axis = "horizontal" })` | Create a runtime terminal next to the focused element |
| `command("new_tab")` | Open a tab in the focused workspace whose shell starts in the focused pane's directory, and select it once the runtime lists it |
| `command("focus", { id = "pane:123" })` | Focus an element |
| `command("navigate", { direction = "left" })` | Find the nearest element in a direction |
| `command("cycle", { step = -1 })` | Cycle focus |
| `command("swap", { id = "pane:123", with = "pane:456" })` | Exchange split positions |
| `command("resize", { direction = "right", amount = 0.05 })` | Move a split boundary by a ratio |
| `command("maximize")` | Toggle workbench maximization |
| `command("float", { id = "pane:123", enabled = true })` | Toggle or set floating mode |
| `command("frame", { frame = { x = 0.1, y = 0.1, width = 0.6, height = 0.6 } })` | Set a floating frame relative to the work area |
| `command("constraints", { minimum = { width = 160, height = 90 }, aspect = 0 })` | Set minimum/maximum dimensions and optional aspect ratio |
| `command("view", { module = "my_view", options = {} })` | Create a Lua surface in the current tab; returns its element ID |
| `command("windows")` | List the other applications' windows the desktop watches, with `id`, `application`, `title` and `floating` |
| `command("adopt", { window = "1234" })` | Manage a window whose application a rule ignores; it joins the tab shown on its Space |
| `command("move", { id = "view:...", tab = "2" })` | Move a Lua view or external element to another tab |
| `command("close", { id = "pane:123" })` | Close/release one element |

Commands without `id` use the focused element. Inside a workbench surface they
default to that surface's element instead. A pane's Lua module can read
`ui.surface.element`, `pane`, `workspace`, `tab`, `focused`, `floating`, `area`,
`geometry` and `content`, and follow them with the surface's `state_changed`
event rather than `workbench.on_change`, which runs for every change of every
workbench. The native terminal item lives outside the replaceable
Lua tree, so changing the module does not recreate the terminal connection.

The terminal renderer owns decoded cells and updates changed rows through Qt's
GPU text nodes. Input includes UTF-8 text, IME composition, bracketed paste, VT
keys, keyboard protocol modes, mouse reporting, scrollback and visible-cell
selection/copy. Transport buffers and pending requests are bounded. A missing
delta base requests a snapshot; a disconnected connection disables input and
reconnects without replaying process-creation or closure commands.

Layouts, focus and Lua view modules are saved atomically per runtime socket in
the desktop state directory. The backend exposes refused geometry changes through
`requested`, `actual` and `error` instead of assuming the requested rectangle was
applied.

Moving a terminal to another tab requires a runtime protocol extension and is
deliberately not emulated by client-only state. A tab that shows other
applications' windows outlives its final terminal: see below.

### Other applications' windows

The desktop manages every application with a Dock icon. A window that appears on a
workspace's Space joins the tab shown there, tiled, or floating when it is a dialog
or cannot be resized; minimizing it, hiding its application or closing it takes it
out of its tab, and one that moves to another workspace's Space joins the tab shown
there. The workbench's `windows` option sets a rule per application, by bundle
identifier, or by name for an application without one: `tile`, `float` or `ignore`.

```lua
desktop.configure_surface("workbench", {
  module = "workbench",
  options = {
    windows = {
      ["com.apple.systempreferences"] = "float",
      ["com.1password.1password"] = "ignore",
    },
  },
})
```

A tab that is not shown parks its windows past a bottom corner of their display,
leaving a one point sliver: macOS pulls a window that is wholly off every display
back into view, and no window may sit above the top edge. Of the two bottom
corners, the one with less of another display beyond it is used, so a parked
window does not show on a neighbouring display. Activating a parked window, with
Cmd+Tab or the Dock, shows its tab. A tab holding other applications' windows is
held in the runtime (`hold_tab`), so it survives its last terminal while the
desktop runs; the runtime lets go when the desktop disconnects.

`native-backends/macos/window_observer.mm` watches the windows on a thread of its
own. Reads come from the window server, which answers even for an application
that hangs: the window list, `SLSCopySpacesForWindows` for each window's Space.
Accessibility notifications only say when to read again, and Accessibility tells
what the window server does not: titles, subroles and whether a window can be
resized. Writes go through Accessibility on a serial queue per application, each
call bounded by 50 ms, so an application that hangs delays only its own windows,
and a window's queued write is replaced by a newer one. The debug programs
`external_window_dbg`, `window_observer_dbg` and `space_switch_dbg` hold the
measurements behind these choices. Other applications' windows are managed on
macOS only; a Linux window-manager integration is still required.

For manual review, run `just desktop`. Split a
terminal, send output to both panes, change focus, resize, switch tabs and return.
Then change the workbench Lua module and check that the shell processes and layout
remain. Managing other applications' windows additionally requires Accessibility
permission.

### Build and run

```sh
just desktop-check
just desktop-debug event_queue_dbg
just desktop
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

Without a socket, `just desktop` starts a new environment on every run: it
builds `telar`, stops the runtime a previous run left behind, removes
`.zig-out/desktop`, starts a runtime there with its own history, and stops it
when the desktop exits. The workbench layout saved for that socket is removed
too. Space associations, session logs and the desktop's exclusive control stay
in the regular desktop state directory, so a run hands off with another desktop
as usual and reuses the Spaces of the previous run. With a socket, it connects to
that runtime, which must already be running, and changes nothing else.

### The user's runtime

`telar-desktop SOCKET` connects to a runtime someone else started and never
starts one, so a development runtime with its own history is never replaced by
one without it. Without a socket, the desktop uses the user's own runtime, the
one `telar` in a terminal uses, and starts it when none runs: it runs
`telar server endpoint` and connects to the socket that prints
(`runtime_endpoint.cpp`). The runtime detaches from the desktop, so quitting the
desktop leaves it, its panes and its agents running.

- **Environment.** A launch from Finder or at login carries launchd's
  environment, and the runtime passes its own environment to every pane.
  `telar` therefore runs through the user's login shell (`$SHELL -l -c`, with
  the same per-shell script as `lib/pty/login_shell.zig`), so a runtime started
  here sees the PATH, EDITOR and SHELL a terminal would. A runtime that was
  already running keeps the environment it has.
- **Which `telar`.** The one beside `telar-desktop`, then
  `../Resources/bin/telar` for an application bundle, then whatever the login
  shell finds on PATH.
- **Failures.** The answer must be exactly the socket path and the schema, one
  per line; anything else, such as output from a shell startup file, is refused.
  A schema other than the desktop's names both versions. telar has 30 seconds
  to answer, which covers starting the runtime, and is killed after that.

### Switching between the regular runtime and a development clone

Create a separate development environment from the regular runtime's checkpoint:

```sh
just desktop-runtime /absolute/path/to/regular/runtime.sock /absolute/path/to/session.ckpt
```

This runs the cloned runtime in the foreground, under `.zig-out/desktop-dev`.
In another terminal, run `just desktop-dev`. After stopping the
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

```sh
just desktop-debug input_router_dbg --mode router --panes 9
just desktop-debug input_router_dbg --mode activate --panes 9 --bench 100 --quit
```

`debug/input_router_dbg.cpp` compares two ways of moving the keyboard focus
between pane windows. `activate` makes the focused pane the key window. `router`
uses the workbench's keyboard router, so no pane ever becomes key. Physical
ctrl+h/j/k/l and clicks move the focus, and every key window change is printed;
one that reaches a pane in `router` mode is marked unexpected. `--bench N`
measures N moves once the application is active.

```sh
just desktop-debug window_hide_dbg --strategy alpha --windows 13 --switches 40
```

`debug/window_hide_dbg.cpp` measures switching between two tabs of pane windows
that share the same rectangles, with the windows adopted by the keyboard router,
the application active and an animation in every window. `--strategy hide` hides
the outgoing windows; `--strategy alpha` leaves them ordered in, transparent,
without mouse events and with invisible content. It reports both halves of each
switch, the frames the outgoing windows draw in one second, where a mouse down at
each pane's centre lands and the memory footprint. `--hold` keeps the windows up,
to inspect them in Mission Control.

```sh
just desktop-debug external_window_dbg --switches 20 --hang 3 --timeout 0.05
just desktop-debug external_window_dbg --strategy offscreen --app Safari
```

`debug/external_window_dbg.cpp` measures hiding another application's windows on
a tab switch. A helper process, the same program with `--serve`, owns two tabs of
windows sharing the same rectangles; `--app` uses a running application's
windows instead. `minimize` minimizes them through Accessibility, `offscreen`
moves them to their display's bottom right corner leaving `--sliver` points on
screen, and `space` moves them to a parking Space through SkyLight, created for the
run when the display has no spare one and removed afterwards. It reports how long
the calls block the calling thread, when the window server shows the incoming
windows and drops the outgoing ones, refused calls and what stays visible of a
hidden window. `--hang` freezes the helper's main thread and times one hide and
one show per strategy; `--timeout` sets the Accessibility messaging timeout.
It needs Accessibility permission for the terminal that runs it.

```sh
just desktop-debug space_switch_dbg --switches 20
```

`debug/space_switch_dbg.cpp` measures how long a Space switch through the
desktop's SkyLight bridge takes to show. It creates a temporary Space on the
focused display, puts one of its own windows on that Space and another on the
current one, and switches between them, reporting when the destination's window
appears, when the origin's disappears and how long both are on screen together.
On macOS 26.6 both land in one or two frames, with no overlap: the bridge switch
has no slide animation. The temporary Space is removed afterwards.

```sh
just desktop-debug window_observer_dbg --rounds 10 --hang 2
```

`debug/window_observer_dbg.cpp` measures watching other applications' windows
from a thread with its own run loop, as the desktop's window observer does. It
times attaching Accessibility observers to every running application, then
drives a helper application, the same program with `--serve`, that creates,
moves, focuses and closes windows, and reports how long each notification takes
to arrive, timed with the system's uptime clock in both processes. With the
helper frozen it times attaching to it again and compares reading a frame from
the window server (`SLSGetWindowBounds`) with reading it through Accessibility.

## Session logs

Debug builds, including `just desktop`, write one log per desktop session to
`logs/` in the desktop state directory: `~/Library/Application Support/telar/desktop/logs`
on macOS, or `$TELAR_DESKTOP_STATE_DIR/logs` when that variable is set. Startup prints
the file's path, and `logs/latest.log` always points to the newest one. The 20 most
recent sessions are kept; a file stops growing at 64 MiB.

Every line has the wall clock, seconds since startup, level, category and thread,
and the source location:

```
2026-10-21T16:35:38.106 +12.403 D telar.desktop.connection [1f137a180] ws 3 attach pane 12 (runtime_connection.cpp:569)
```

| Category | Traces |
| --- | --- |
| `telar.desktop.session` | Process start, runtime handshake and exit |
| `telar.desktop.catalog` | Workspace list, tab selection and moves, the runtime message that invalidated each snapshot, catalog failures |
| `telar.desktop.spaces` | Focused Space changes, Space commands and their results |
| `telar.desktop.shortcuts` | Compiled keymaps and the bound sequence each shortcut matched |
| `telar.desktop.workbench` | Workspace visibility, surfaces created, windows shown and hidden and their first frames, resident memory and window counts every 10 s, commands |
| `telar.desktop.connection` | Each workspace's runtime session: handshake, snapshots, attach and detach, resyncs, failures |
| `telar.desktop.terminal` | Terminals showing "Connecting to runtime…" |
| `telar.desktop.frames` | Every terminal frame; off by default |

Other Qt messages, including Lua errors, land in the same file. Warnings and
errors still reach the console. Filter a log with `grep`, or change what is
recorded with `QT_LOGGING_RULES`, which overrides the defaults; for example
`QT_LOGGING_RULES="telar.desktop.frames.debug=true"` adds every frame.

Logs never contain terminal input, screen contents or keys that pass through to
other applications; shortcuts are recorded only as the bound sequence that
matched. Files are created owner-only, without following symbolic links. Release
builds define `QT_NO_DEBUG_OUTPUT` and `QT_NO_INFO_OUTPUT`: they write no session
log, and debug and info traces compile to nothing.

### Timing traces

Logs say what happened; timing goes to a trace written next to each log,
`desktop-….trace.json`, with `logs/latest.trace.json` pointing to the newest. Open
it in [Perfetto](https://ui.perfetto.dev): every thread gets a track, and nested
calls show where a slow one spent its time.

A function is timed by its first statement, `TELAR_TRACE("component.function");`
from `trace.hpp`, which records from there to the end of the scope. A block such
as one native call can be timed the same way inside braces. Names are string
literals, checked at compile time, so a trace holds no content. Each scope costs
about 0.1 µs; a writer thread formats and writes the records, at least once a
second, so a crash loses at most the last second. A trace stops at 256 MiB. Release
builds expand `TELAR_TRACE` to nothing and never evaluate its argument.

Timing comes from traces only: logs carry no durations.

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

`ui/wallpaper/init.lua` creates a background shared by all monitors and Spaces.
The native backend maintains one wallpaper panel per connected monitor, covering
its full frame, and removes the panel when that monitor is disconnected.
Wallpaper panels ignore mouse input and cannot take keyboard focus. They use a
window level above the system wallpaper and below desktop icons, with
`CanJoinAllSpaces`, `Stationary` and `IgnoresCycle` collection behaviors.
Closing Telar reveals the system wallpaper; system wallpaper preferences are
unchanged. Login and lock-screen backgrounds are outside this surface.

All panels use `TelarSurfacePanel` for native window behavior and `LuaSurface`
for their Qt/Lua contents. `DesktopUi` owns configuration and coordinates reloads.
Configuration and surfaces share the runtime connection, desktop service, shortcut
engine, LuaJIT VM and one QML engine owned by `DesktopUi`, with separate globals,
module caches and subscriptions. The shared QML engine compiles each Qt Quick type
once, instead of giving every surface its own type cache and JavaScript heap.
Only surface environments have a visual root.

The desktop has its own Lua entry point, separate from the GUI's `config.lua`:

1. `TELAR_DESKTOP_CONFIG`, when set, selects a specific file. A missing file is an error.
2. Otherwise, load `$XDG_CONFIG_HOME/telar/desktop.lua`, or `~/.config/telar/desktop.lua`
   when `XDG_CONFIG_HOME` is unset or empty.
3. If that default file does not exist, run the bundled `ui/desktop.lua`, which
   configures all surfaces and registers the default shortcuts.

The desktop does not load `config.lua` or use `TELAR_DEVELOPMENT_CONFIG`.
Its configuration is an executable Lua script using the desktop API, rather than
the GUI's configuration table. For example, `desktop.lua` can contain:

```lua
local shortcuts = require("telar.shortcuts")
local desktop = require("telar.desktop")
shortcuts.set_prefix("ctrl+s")
require("shortcuts")()

local colors = { background = "#1b1723", accent = "#c4a7e7" }

desktop.configure_surface("wallpaper", {
  module = "wallpaper",
  options = {
    color = "#16131d",
    image = "~/Pictures/wallpaper.jpg",
    fit = "cover",
  },
})

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
environment independent of the panels. It registers global shortcuts and chooses
each surface's module and options. UI creation belongs inside a surface module;
calling UI operations from the global environment raises an error. Existing
configurations should replace `require("topbar")` with `require("shortcuts")()`
and `desktop.configure_surface(...)` calls.

`configure_surface(name, settings)` accepts `topbar`, `sidebar` or `wallpaper`, with optional
`module` and `options` fields. The default module matches the surface name, with
empty options. Options are copied data tables, including nested tables and dense
arrays of up to 4096 entries, with at most 16 levels of table nesting;
functions and UI objects cannot cross environments. Each surface reads its own
copy through `ui.surface.options`. `ui.surface.name` and `ui.surface.module`
identify the surface and its configured module. Local edits to an options table
do not change the global configuration or another surface.

The topbar and sidebar accept a `colors` table; the sidebar also accepts `title`.
Custom modules can interpret their options freely. These options configure UI
content, not native panel geometry.

The wallpaper accepts `color`, optional `image` and `fit`. The image can be a Qt
URL, an absolute path, a path starting with `~/`, or a path relative to
`desktop.lua`. `cover` fills the monitor with cropping, `contain` shows the whole
image with the background color around it, `center` keeps the image centered at
its natural size, and `stretch` fills the monitor without preserving aspect ratio.
The default is a solid color with `fit = "cover"`. Images load asynchronously;
an image load error leaves the background color visible and is reported by Qt.

All monitors receive the same wallpaper options. Each instance has its own size
and Lua state, and receives screen and resize events through the shared surface
API. Global shortcuts belong in `desktop.lua`, so adding monitors does not register
the same shortcut repeatedly. The default wallpaper subscribes only to resize
events and does not run a timer or animation loop. The wallpaper module can be
replaced like any other surface; it has the same runtime, filesystem and network
APIs. Its native window remains noninteractive even with a custom module.

To replace the sidebar, select another module or put `sidebar/init.lua` in the
directory containing `desktop.lua`; during development, edit
`ui/sidebar/init.lua` or add an override at `dev/sidebar/init.lua`. The same
rules apply to the topbar and wallpaper. Shared Lua components can be imported by all
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

An edit imported only by a surface reloads all instances of that surface type
together. It does not execute `desktop.lua` or recreate unrelated panels.
Reloading a surface without bindings
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
by the same margin. Every display gets its own wallpaper, topbar and sidebar,
created and closed as displays come and go (`native-backends/macos/screen_panels.mm`),
and each follows its display's geometry. They are visible across Spaces. The sidebar overlays application windows;
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

A custom map can reuse the default module's actions without installing its keys:
`require("shortcuts").actions` provides `select_tab(index)`,
`step_tab(offset, move)`, `step_space(offset)`, `select_workspace(index)`,
`create_tab()` and `create_workspace()`. `select_workspace` activates the focused
display's workspace at that position, in the order of its Spaces. `create_workspace`
opens a workspace on `$HOME` on the focused display and activates its Space once
the desktop has given it one.
The default map binds them to prefix + `c` and prefix + `N`, as the GUI does.

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
`just desktop /path/to/runtime.sock`, or to the user's runtime when no socket is
passed (see [The user's runtime](#the-users-runtime)). No other Telar client
needs to be running.
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
Runtime notifications that invalidate the snapshot, such as foreground process
changes, refresh it at most every 100 ms; selecting a workspace refreshes it at once.

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
| `desktop.on_change(callback)` | Subscribe to changed desktop snapshots; returns an unsubscribe function and delivers the current state on mount. The callback gets the whole state and a second table telling what changed since the last delivery: `focus` (focused or visible Spaces), `spaces` (Spaces added, removed, moved or rebound), `displays`, `operation` (a pending activation or Space operation) and `status` (availability, Accessibility, error). The first delivery marks everything changed, and a state equal to the last is not delivered. |
| `desktop.activate_space(id)` | Request activation of an existing Space. Completion is confirmed from macOS; failures appear in `error`. |
| `desktop.bind_space(space_id, workspace_id)` | Associate an unbound managed Space with a workspace that has no Space or pending creation. A live association cannot be changed or cleared. |
| `desktop.create_space(options)` | Create an ordinary Space for the required `workspace` ID, if it has no Space yet. Optional `display` selects a display ID; the default is the focused display. Returns a request ID. Normal workspace reconciliation handles creation automatically. |
| `desktop.remove_space(space_id)` | Remove an unassociated ordinary Space. A live workspace's Space must close through its final pane. Returns a request ID. |

Display entries contain `id`, `uuid` and global screen bounds (`x`, `y`,
`width`, `height`). Space entries contain `id`, `uuid`, `display`, `index`,
`visible`, `focused`, `fullscreen`, `managed` and optional `workspace`. Several
displays can have a visible Space simultaneously; `focused` identifies the active one.

Each display is a desktop of its own. A workspace belongs to the display its Space is on, and
the surfaces on a display show only that display: the sidebar lists its workspaces in the order
of their Spaces, and the topbar shows the workspace on its visible Space with that workspace's
tabs and the display's Spaces. Actions act on the focused display: `select_workspace(index)`
counts the focused display's workspaces, and a new workspace goes to the focused display.
`require("displays")` finds what belongs to a display: `of(ui.surface)`, `focused(state)`,
`spaces(state, display)`, `workspaces(state, display)` and
`view(runtime_state, desktop_state, display)`.

`require("telar.runtime")` exposes:

| API | Behavior |
| --- | --- |
| `runtime.state()` | Detached snapshot with `connected`, workspace catalog `workspaces`, and `views`, one per workspace on screen (one per display), each with `workspace`, optional `active_tab` and ordered `tabs`. The focused workspace's `workspace`, `active_tab` and `tabs` also sit at the top level. |
| `runtime.on_change(callback)` | Subscribe on the application thread; returns an unsubscribe function and delivers the current snapshot on mount. |
| `runtime.select_tab(id)` | Select a tab in whichever workspace on screen holds it. Returns a request ID. |
| `runtime.move_tab(id, {before = anchor})` | Insert a tab before another tab in its workspace; `{after = anchor}` inserts after it. Returns a request ID. |
| `runtime.create_workspace()` | Open a workspace on `$HOME` on the focused display, whose first pane runs the login shell. Returns a request ID; `created = {request, workspace}` reports the latest creation, without `workspace` when it failed. |

IDs are decimal **strings**, preserving complete unsigned 64-bit values in
LuaJIT. Workspaces expose `id`, `kind` and `name`; tabs expose `id`, `label`
and foreground process names in `foregrounds`. `context` identifies the
current native Space. Missing optional fields are `nil`. Runtime requests
report their latest completion through `completed_request`,
`request_succeeded` and optional `error`.

No display stays without a workspace. When a display has none, at startup, after
its last workspace closes or when it is connected, the desktop opens one on
`$HOME` for it, one creation at a time; after a failure the next attempt waits
for the catalog to change. A created workspace goes to the display it was
created for: a free Space there, or a new one. A workspace never moves to
another display by itself; macOS moves the Spaces of a disconnected display,
and their workspaces with them. A workspace is created on a short connection of its own, as
`telar workspace create` does: the runtime attaches the first pane to the
connection that asked and leases it the workspace's geometry, and both end with
it, leaving the workspace free for the workbench. A tab is created on the
workbench's own connection to its workspace, which already holds that lease.

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
frame, with a five-second timeout. A full event queue causes publication to be
retried. Snapshots are read on a thread of their own
(`native-backends/macos/spaces_observer.mm`): during a Space switch the window
server answers only after its animation, and the UI thread must not wait for it.
Commands to SkyLight, and confirming or timing out what is pending, stay on the
UI thread, which checks commands against the latest snapshot instead of taking
one. A snapshot makes two window server calls whatever the number of Spaces: the
catalog already carries each Space's name and type and each display's current
Space. It lists displays through CoreGraphics, since AppKit is main-thread only. Creation on another display waits for the new Space's placement before
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
reloads keep the current UI and its operations running. A generation's imports
are watched in one batch when it finishes loading: on macOS every watch change
flushes the file event stream synchronously. Every Lua environment, one per
surface, shares a single watch (`ui/module_watch.cpp`), which changes only when
the union of their modules does.

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
