# C++ Qt Quick GUI

The C++23 client uses Qt Quick for the window, models and rendering. The runtime
owns processes, PTYs and durable state; closing this client leaves them running.
Current delivery scope and remaining work are in [DAILY_DRIVER.md](DAILY_DRIVER.md),
[PARITY.md](PARITY.md) and [ZIG_RETIREMENT.md](ZIG_RETIREMENT.md).

## Source layout

| Directory | Responsibility |
| --- | --- |
| `application` | Sessions, workspace/tab state, layout and runtime requests |
| `attachments`, `graphics`, `terminal` | Capture lifecycle, image budgets, cells, damage and placement |
| `input`, `history`, `links` | Keymaps, input ownership, search, selection and navigation |
| `machines`, `transport` | Profiles, SSH discovery, connection state and bounded framing |
| `components`, `config` | Lua configuration, plugins and configured surfaces |
| `fonts`, `presentation`, `core` | Shaping, physical geometry and reusable value types |
| `qt` | QML models, events, scene nodes and asynchronous adapters |
| `platform` | Native window effects, clocks, clipboard, process and socket facilities |
| `tests`, `tools` | Regression fixtures, probes, generators and packaging |

Application policies use explicit allocators and compile-time dependency selection.
Domain components can be used without constructing a window. Native APIs stay in
platform adapters; reusable font and layout code does not depend on QML.

## Build

Dependencies are CMake 3.24+, Ninja, Python 3, a C++23 compiler and Qt 6.7+ with
Gui, Qml, Quick, QuickControls2, Network, Concurrent, ShaderTools and Svg. Qt Test
is needed with `BUILD_TESTING=ON`. Private Qt headers must match the installed Qt
version. The static-analysis profile requires LLVM 23 or newer.

Linux also needs Fontconfig, Wayland-client, libxcb and Qt WaylandClient development
packages, including private headers. Native test fixtures use Wayland-server, Sway,
wtype and a private D-Bus session. Optional X11 clipboard tests use Xvfb, xauth and
libX11. macOS native adapters use AppKit, CoreText and CoreGraphics.

CMake fetches and verifies the pinned font dependencies. Use an existing
libghostty-vt installation from the runtime build or build the pinned dependency:

```sh
python3 services/runtime-cpp/tools/build_ghostty.py \
  --build-dir services/gui-cpp/out-dependencies/ghostty-build \
  --prefix services/gui-cpp/out-dependencies/ghostty
```

Configure and build from the repository root:

```sh
cmake -S services/gui-cpp -B services/gui-cpp/out -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=clang \
  -DCMAKE_CXX_COMPILER=clang++ \
  -DGHOSTTY_VT_ROOT="$PWD/services/gui-cpp/out-dependencies/ghostty" \
  -DCMAKE_PREFIX_PATH=/path/to/qt
cmake --build services/gui-cpp/out --parallel 2
```

On Homebrew, use LLVM's compiler paths and, when Qt modules have separate prefixes,
set `Qt6_DIR` to Homebrew's `lib/cmake/Qt6` and
`QT_ADDITIONAL_PACKAGES_PREFIX_PATH` to the qtdeclarative prefix.

The GUI still generates some data from Telar Zig sources. Building Ghostty also
uses Zig; removing those dependencies is a separate migration.

## Run and configuration

```sh
services/gui-cpp/out/telar-gui
services/gui-cpp/out/telar-gui --socket /path/to/runtime.sock
```

Endpoint selection uses `--socket`, `TELAR_SOCKET`, then `telar server endpoint`
through the shared discovery helper. The client accepts the audited runtime wire
schemas; unknown schemas are rejected.

Configuration comes from `--config`, `TELAR_DEVELOPMENT_CONFIG` or
`$XDG_CONFIG_HOME/telar/config.lua`, defaulting to `~/.config/telar/config.lua`.
Reloading an invalid file retains the previous valid configuration. Local Lua
modules, profiles, custom bindings, callbacks, plugins, bars, panels and picks use
the existing Telar APIs. `--no-config`, `--profile NAME` and `--theme NAME` are
available.

`--cwd PATH` sets the launch directory. Positional arguments select a command for
a newly opened pane; subsequent options are passed to that command. `--fresh`
skips saved-layout restoration. Without a command, the login-shell resolver
supplies the interactive shell. Saved and temporary SSH machines can be selected
with the machine picker or the corresponding launch options.

History supports filtering, inspection and paste/run modes. Configured Enter
behavior can be inverted with Shift+Enter. Session and input controllers retain
pane, machine and generation identities across asynchronous operations.

## Neovim and clangd

Configure and build `gui-editor` before opening headers, so generated headers and
Qt metadata exist:

```sh
cmake -S services/gui-cpp -B services/gui-cpp/out
cmake --build services/gui-cpp/out --target gui-editor --parallel 2
```

`.clangd` uses `out/compile_commands.json` and generated compilation contexts under
`out/clangd` for configuration, domain, Qt and test headers. Use clangd from the
same LLVM installation as the compiler. `.clangd-build.json` provides the existing
build-on-save integration.

## Tests and static analysis

Build the relevant test targets before running their CTest entries:

```sh
cmake --build services/gui-cpp/out --target gui-core-test gui-config-test
ctest --test-dir services/gui-cpp/out --output-on-failure -R '^gui-(core|config)$'
```

Native integration tests use owned temporary runtimes and private clipboard/display
fixtures. Run native window cases serially to avoid focus interference. Core
components can be tested without Qt by configuring `-DTELAR_GUI_NATIVE=OFF`.
Sanitizer builds use `-DTELAR_GUI_SANITIZERS=ON` in a separate build directory.

```sh
cmake --build services/gui-cpp/out --target gui-lint --parallel 2
```

Keep the existing clang-tidy profile, thresholds and diagnostics enabled. Generated
build files, captures, logs and benchmark output belong in ignored `out*/`
directories or temporary directories outside the source tree.

## macOS packaging

`tools/package_macos.py` creates a separately named app, deploys Qt/QML and includes
runtime helpers. Use a fresh Release build for a distributable candidate and keep
the current installed app available while testing it:

```sh
python3 services/gui-cpp/tools/package_macos.py --help
```

Packaging does not establish independence from the bundled runtime/CLI or the
Zig-derived build inputs described in [ZIG_RETIREMENT.md](ZIG_RETIREMENT.md).
