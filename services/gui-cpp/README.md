# C++ Qt Quick GUI

The C++23 client uses Qt Quick for the window, models and rendering. The runtime
owns processes, PTYs and durable state; closing this client leaves them running.
Current delivery scope and remaining work are in [DAILY_DRIVER.md](DAILY_DRIVER.md),
[PARITY.md](PARITY.md) and [ZIG_RETIREMENT.md](ZIG_RETIREMENT.md).
Before profiling or optimizing the client, read [OPTIMIZATION.md](OPTIMIZATION.md)
for the frozen benchmark, rejected experiments and reproduction procedure.

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

Native font discovery is owned by `platform/font.h`, `platform/macos/font.m` and
`platform/linux/font.c`. macOS optical terminal text uses the CoreText glyph
rasterizer under `platform/macos`, borrowed font bytes and caller-owned scratch
storage. Qt caches the resulting masks and retains glyph meshes between damaged
frames. Font shaping and cell placement remain in `fonts` and `qt`; these font
adapters no longer include or compile files from the Zig GUI.

`gui.font.thicken` applies to terminal text, cursor text and preedit on both
platforms. macOS uses CoreText optical smoothing. Linux uses a centered FreeType
outline dilation, from zero at `thicken_strength=0` to half a physical pixel at
255, independently of bold/italic styling. It leaves shaping advances and the
terminal grid unchanged. The two rasterizers do not promise pixel-identical ink.
Procedural box, block and braille glyphs are not thickened.

When `gui.window.background_opacity` is below one, sidebar, navigation/status bars
and pane bands reveal the window's single background, even with an explicit
`panel_bg` color. Text and controls retain their own opacity. Image attachment
shelves and preview modals keep covering panel backgrounds, matching Zig.

## Build

Dependencies are CMake 3.24+, Ninja, Python 3, `patch`, a C++23 compiler and the
platform SDK/development libraries below. Installing Qt is not required. The
static-analysis profile requires LLVM 23 or newer.

Native configuration bootstraps Qt 6.12.0 from official source archives through
a separate CMake `ExternalProject` build. Versions, SHA256 hashes and the upstream
CVE-2026-105924 fix are pinned in `cmake/qt/manifest.cmake`. The build includes
qtbase, qtshadertools, qtdeclarative and qtsvg, plus qtwayland on Linux. Qt is shared
and built in Release; Telar's Debug, Release and sanitizer builds reuse it.

The first `cmake` configuration builds and installs Qt before resolving its
packages. Later configurations reuse the cached build. Compiler identity,
explicit architecture/SDK/toolchain options and the dependency recipe select the
cache entry. `TELAR_GUI_QT_BUILD_DIR` changes the cache root, which defaults to
`.qt-cache/` at the repository root, outside the GUI's QML source tree;
`TELAR_GUI_QT_JOBS` limits Qt compiler jobs, defaulting to 2.
Concurrent configurations serialize access to this cache. Native builds are
supported; cross-compiling Qt is not implemented.

Qt libraries, private headers, QML modules and build/deployment tools come from
that same private installation. Existing system Qt package cache entries are
removed during configuration; there is no automatic system-Qt fallback. Private
API compatibility still requires updating and rebuilding the complete pinned set.

Linux also needs Fontconfig, Wayland-client/server, wayland-scanner, XCB/X11,
xkbcommon and OpenGL/EGL development packages. Qt's
[Linux build requirements](https://doc.qt.io/qt-6/linux-requirements.html) list the
XCB development packages. The managed build supplies Qt WaylandClient and
WaylandCompositor, including private headers. Native test fixtures additionally
use Sway, wtype and a private D-Bus session.
Optional X11 clipboard tests use Xvfb, xauth and
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
  -DTELAR_GUI_QT_JOBS=2
cmake --build services/gui-cpp/out --parallel 2
```

On macOS, use the Xcode SDK and a C++23 compiler. `just app`, `just gui-test` and
`just install-gui` use the same managed Qt bootstrap through the GUI CMake project;
they do not need Homebrew's Qt packages. They still use Homebrew's LLVM and the
runtime's separately documented dependencies.

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
components can be tested without downloading or building Qt by configuring
`-DTELAR_GUI_NATIVE=OFF`.
Sanitizer builds use `-DTELAR_GUI_SANITIZERS=ON` in a separate build directory.

```sh
cmake --build services/gui-cpp/out --target gui-lint --parallel 2
```

Keep the existing clang-tidy profile, thresholds and diagnostics enabled. Generated
build files, captures, logs and benchmark output belong in ignored `out*/`
directories or temporary directories outside the source tree.

Native animation cadence can be checked with `gui-animation-probe` and
`tools/check_animation_cadence.py`. See [ANIMATION_CADENCE.md](ANIMATION_CADENCE.md)
for the measurement endpoint, paired results, reproduction and limitations.

`gui-screen-probe` measures application of preencoded terminal frames without Qt.
It covers empty, one-cell, one-row and full-grid deltas, plus changing and retained
snapshots. Each run verifies the final cells and rejects allocation churn after
warmup. Compare two frozen Release builds with seven alternating pairs:

```sh
python3 services/gui-cpp/tools/compare_screen.py out-A/gui-screen-probe out-B/gui-screen-probe out-screen-pairs
```

The default grid is 82×21; `--columns` and `--rows` select another grid. The driver
records binary hashes, raw results, win counts and Screen-owned allocation bytes.
Those counters exclude fixture storage and framework allocations. Timing includes
frame descriptor selection and application, excludes encoding, and does not measure
native presentation latency or runtime performance.

The standalone Qt binding-storage oracle compares experimental inline storage
with the actual private `QRhiBatchedBindings` container. It checks 4,123 binding
sequences, copying, clearing, repeated finish and dynamic fallback. Supply the
managed Release Qt prefix and its matching source header; the output directory
must be new:

```sh
python3 services/gui-cpp/tools/check_qt_binding_storage.py \
  --qt-prefix /path/to/managed-qt/install \
  --qt-header /path/to/matching-qtbase/src/gui/rhi/qrhi_p.h \
  --output out-qt-binding-oracle --compiler /path/to/clang++ --sanitize
```

Omit `--sanitize` for a Release run. The tool generates the experimental header
in the output directory, preserving Qt's copyright and license identifiers, and
records source/library hashes and build logs. It does not modify Qt or establish
native rendering equivalence or a performance gain. The Metal inline-storage
experiment is not retained: its native timing series was discarded for elevated
shared-host load, so no qualified native CPU gain is established. Details are in
[the performance report](../../docs/cpp-performance-progress.md).

`gui-font-coverage-probe` records coverage for every codepoint value through
U+10FFFF, including surrogates, and three out-of-range values. It repeats the
coverage checks after metrics, shaping and rasterization at three sizes. Compare
frozen reference and candidate probes with:

```sh
cmake --build services/gui-cpp/out --target gui-font-coverage-probe
python3 services/gui-cpp/tools/check_font_coverage.py \
  /path/to/reference/gui-font-coverage-probe \
  /path/to/candidate/gui-font-coverage-probe out-font-coverage
```

The default corpus contains four bundled fonts and the variable-font fixture at
default/wide coordinates. Repeat `--font PATH regular` or `--font PATH wide` to
supply another corpus. The new output directory receives hashes, exact bitmaps
and failures. This checks coverage and its stability across font operations;
it does not compare rendered pixels or establish performance.

## macOS packaging

`tools/package_macos.py` creates a separately named app, deploys Qt/QML and includes
runtime helpers. It selects `qtpaths` and `macdeployqt` from the managed Qt prefix
recorded in the GUI build cache, not from PATH, and includes Qt license texts and
the pinned source manifest in the bundle. Use a fresh Release build for a distributable candidate and keep
the current installed app available while testing it:

```sh
python3 services/gui-cpp/tools/package_macos.py --help
```

Packaging does not establish independence from the bundled runtime/CLI or the
Zig-derived build inputs described in [ZIG_RETIREMENT.md](ZIG_RETIREMENT.md).
