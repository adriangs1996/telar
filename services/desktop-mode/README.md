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

`ui/topbar.lua` creates the bar through `telar.ui`. The default script draws
an SVG path, adds text and animates its opacity on hover. The native backend
owns the panel; Qt Quick draws its transparent contents.

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
and `package.loaded` are available. `telar`, `telar.ui`, `telar.fs` and
`telar.net` are preloaded.

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
