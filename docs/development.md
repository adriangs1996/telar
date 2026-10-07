# Developing Telar

For an introduction and first launch, see the [README](../README.md).
Run the commands below from the repository root.

## Build requirements

Use Zig 0.16.0, the version declared in [build.zig.zon](../build.zig.zon).
The native GUI also needs Cargo and Rust 1.93.1 or newer to build the
[diagram renderer](../tools/diagram-renderer/README.md). Rust is a build
requirement; the installed application does not need it.

### macOS

The GUI requires macOS 26 and a Metal 4 GPU. Install Xcode or the Command
Line Tools with a macOS 26 SDK, along with Zig and Rust.

Brotli and nghttp2 are built from pinned sources. Telar uses macOS's SQLite;
there is no separate Homebrew library installation required by the default
build. Linux builds SQLite from pinned sources too. Distribution builds can
choose system libraries with `-Dbrotli=PREFIX`, `-Dnghttp2=PREFIX` and
`-Dsqlite=PREFIX`; see [native libraries](../build/native_libraries.zig).

### Linux

The GUI needs a Wayland session and a Vulkan 1.3 device with the
required extensions. Building it also requires
Wayland protocol definitions and `wayland-scanner`, `glslc`, and development
headers for xkbcommon, Fontconfig, Vulkan, ATK and GLib.

On Ubuntu 24.04, use the dependency script used by CI, then install Zig and
Rust separately:

```sh
sudo packaging/release/install-linux-deps.sh
```

On Arch Linux or Arch Linux ARM, install the platform dependencies, then
install the Zig and Rust versions above:

```sh
sudo pacman -Syu --needed base-devel pkgconf \
  wayland wayland-protocols libxkbcommon vulkan-headers vulkan-icd-loader shaderc \
  fontconfig ttf-dejavu at-spi2-core glib2
```

### Build and launch

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/telar
```

The default build installs `telar` and `telar-diagram-renderer` together in
`zig-out/bin`. Keep both executables together when moving an installation.
[Packaging](packaging.md) covers application bundles, desktop entries and
installation into another prefix.

For a server without a desktop, build the runtime and CLI without the GUI
or Rust helper:

```sh
zig build -Dgui=false -Doptimize=ReleaseFast
```

This build runs `telar server` and CLI commands; it cannot open a window.
It is different from the headless client (`zig build headless`).

## Making changes

Read the [Zig source layout](zig-source-layout.md).
[Build navigation](../build/README.md) maps build targets to their definitions.

Check the tree before you commit:

```sh
zig build check
zig build codestyle
```

CI runs `zig build` and `zig build check` on macOS and Linux. Optional `just`
recipes wrap build, check and benchmark commands; see [justfile](../justfile)
and the [CI workflow](../.github/workflows/ci.yml).

[Benchmarks](benchmarks.md) documents measurement commands and historical
results.

## Development diagnostics

Debug builds emit one JSON Lines sample per second without writing terminal or
PTY contents. Logs live beside the local runtime socket:

```text
<socket>.runtime-<pid>.log
<socket>.client-<pid>.log
```

Runtime samples cover PTY throughput, folded updates, frame size, damaged rows,
diff scans, no-op frames, VT ingestion, frame encoding, and acknowledgement
latency. Client samples separate cell `flush_*` from `media_flush_*`, attribute
KGP wire bytes to panes, toasts, and the sidebar, and report retained bytes for
the Kitty store, toast textures, sidebar atlas, screen buffers, Lua VM, and
instrumented heap. File writes run outside the interactive loop. Optimized
builds collect this telemetry only with `-Ddiagnostics=true`.

Runtime heap samples keep the aggregate `interactive_alloc*` counters and split
them into `interactive_vt_alloc*` for terminal-emulator state growth and
`interactive_telar_alloc*` for allocations owned by Telar's event path. Proxy
rejections likewise distinguish missing or malformed authorization from an
otherwise valid credential that is no longer registered, without logging
either value.
