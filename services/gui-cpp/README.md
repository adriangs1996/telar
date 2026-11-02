# C++ Qt Quick GUI

The C++ client runs beside the Zig app and connects to the same runtime protocol.
The runtime owns PTYs, processes and durable history; the client owns disposable
presentation state. Closing the GUI leaves runtime processes running.

Current candidate and launch/rollback instructions: [DAILY_DRIVER.md](DAILY_DRIVER.md).
Scoped status: [PARITY.md](PARITY.md). Own-Zig removal remains a separate gate in
[ZIG_RETIREMENT.md](ZIG_RETIREMENT.md).

## Build and run

Requires CMake 3.24+, Ninja, Python 3, C++23 and Qt 6.7+ with Gui/GuiPrivate,
Qml, Quick, QuickControls2, Network, Concurrent, ShaderTools and Svg. Tests also
require Qt Test. Lua and assets are shared repository inputs. CMake downloads
pinned FreeType 2.13.2 with hash verification; offline builds can set
`FETCHCONTENT_SOURCE_DIR_TELAR_FREETYPE` to an extracted copy. An installed
libghostty-vt prefix is required; building that dependency needs its Zig toolchain.
The GUI generators still read own Zig source data and font build metadata.

Linux additionally requires Fontconfig, Wayland-client, libxcb and matching Qt
WaylandClient/WaylandClientPrivate development packages. Native clipboard fixtures
use owned Xvfb/X11 or Sway/wtype sessions, with normal D-Bus session tooling.
macOS requires the matching Qt private headers and Apple SDK. Native font adapters
reuse shared C/Objective-C sources; native APIs stay outside the application layer.

From the repository root, prepare Ghostty once or reuse a compatible prefix:

```sh
python3 services/runtime-cpp/tools/build_ghostty.py \
  --build-dir services/gui-cpp/out-dependencies/ghostty-build \
  --prefix services/gui-cpp/out-dependencies/ghostty
cmake -S services/gui-cpp -B services/gui-cpp/out -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_COMPILER=clang++ \
  -DGHOSTTY_VT_ROOT="$PWD/services/gui-cpp/out-dependencies/ghostty" \
  -DCMAKE_PREFIX_PATH=/path/to/qt
cmake --build services/gui-cpp/out --parallel 2
services/gui-cpp/out/telar-gui --socket /path/to/runtime.sock
```

Homebrew's split Qt installation can use `-DQt6_DIR="$(brew --prefix)/lib/cmake/Qt6"`
and `-DQT_ADDITIONAL_PACKAGES_PREFIX_PATH="$(brew --prefix qtdeclarative)"`.
Use LLVM 23+ for the unchanged clang-tidy profile, with matching clangd/compiler.

Endpoint selection is `--socket`, then `TELAR_SOCKET`, then `telar server endpoint`.
The runtime must speak the client's wire schema. Configuration comes from
`--config`, `TELAR_DEVELOPMENT_CONFIG` or `$XDG_CONFIG_HOME/telar/config.lua`
(default `~/.config/telar/config.lua`). Local-module changes and atomic replacements
reload automatically; invalid reloads retain the last valid preferences.
`--no-config`, `--profile NAME` and `--theme NAME` are available.

## Packaging

Create a fresh Release build for each candidate and preserve earlier bundles.
The existing packager deploys Qt/QML, runtime/CLI, diagram and command helpers,
licenses and a login-shell-aware launcher. It refuses to overwrite an output:

```sh
python3 services/gui-cpp/tools/package_macos.py \
  --build services/gui-cpp/out-release \
  --runtime-prefix /path/to/compatible/runtime-prefix \
  --output "services/gui-cpp/out-adoption/Telar C++ Preview.app"
```

Qualify the exact relocated bundle with signature/linkage checks and disposable
state. Packaging does not authorize replacing the installed app or migrating
sessions, and successful startup does not qualify Zig retirement.

## Tests and analysis

Run the relevant CTest targets for the changed flow. Domain-only builds use
`-DTELAR_GUI_NATIVE=OFF`; `-DTELAR_GUI_SANITIZERS=ON` enables C++ ASan/UBSan.
The macOS Objective-C/Objective-C++ backends are not instrumented by that option.
Do not suppress actual sanitizer failures or weaken comparison thresholds.

```sh
ctest --test-dir services/gui-cpp/out --output-on-failure
cmake --build services/gui-cpp/out --target gui-lint
cmake --build services/gui-cpp/out --target gui-editor --parallel 2
```

The lint target validates `.clang-tidy`, builds generated inputs and treats
warnings as errors. `.clangd` uses `out/compile_commands.json`; `gui-editor`
refreshes generated headers and platform/domain/test header contexts.

## Boundaries and local outputs

`application` owns runtime-session projection and attachment lifecycle;
`terminal`, `graphics`, `attachments`, `history`, `input`, `machines` and `config`
contain bounded domain logic. `qt` translates events and models into QML/scene
nodes. `platform` owns native window/clipboard/font/process APIs. Keep allocator
ownership and dependency injection explicit, with portable domain code on both OSes.

Real runners remain in `tools`, with regression inputs in `tests/fixtures`.
Builds, temporary helpers and benchmark outputs belong in ignored `out*`
directories or outside the repository. Do not commit logs, captures, copied
sources, manifests or benchmark evidence. Keep status documentation brief.
