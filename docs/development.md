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
Line Tools with a macOS 26 SDK, along with Zig and Rust. See the
[renderer requirements](flows/metal4-renderer.md).

Brotli and nghttp2 are built from pinned sources. Telar uses macOS's SQLite;
there is no separate Homebrew library installation required by the default
build. Linux builds SQLite from pinned sources too. Distribution builds can
choose system libraries with `-Dbrotli=PREFIX`, `-Dnghttp2=PREFIX` and
`-Dsqlite=PREFIX`; see [native libraries](../build/native_libraries.zig).

### Linux

The GUI needs a Wayland session and a Vulkan 1.3 device with the
[required extensions](flows/vulkan-renderer.md). Building it also requires
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
It is different from the [headless test client](flows/headless-client.md).

## Making changes

Read the [architecture](architecture.md), [naming conventions](naming.md),
[Zig source layout](zig-source-layout.md) and relevant [invariants](invariants.md).
The [flow index](flows/README.md) maps behavior to its implementation and tests;
[build navigation](../build/README.md) maps build targets to their definitions.

Run the tests for the area you change, for example:

```sh
zig build test-cli
zig build codestyle
```

CI runs `zig build`, `zig build check` and `zig build test` on macOS and Linux.
Some integration tests require Node.js 22.13 or newer and Python 3. Optional
`just` recipes wrap build, test, coverage, fuzzing and benchmark commands; see
[justfile](../justfile) and the [CI workflow](../.github/workflows/ci.yml).

[Benchmarks](benchmarks.md) documents measurement commands and historical
results. [Performance gates](performance-gates.md) defines how to compare runs.

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

## Test coverage

Telar uses [zcov](https://github.com/ericsssan/zcov) to run the native test
suites with SanitizerCoverage and write an LCOV tracefile:

```sh
just coverage
```

`zig-cov` and its adjacent `zig-cov-rt.o` must be installed together. Set
`ZIG_COV_BIN` when the executable is not on `PATH`, or
`TELAR_COVERAGE_FILE` to change the default `coverage.lcov` destination:

```sh
ZIG_COV_BIN=/path/to/zig-cov just coverage
```

The coverage build forces LLVM and libc only for native test executables. It
instruments Telar's Zig-only shared modules and suite roots, while leaving
C-family dependencies and cross-target compile checks alone. Generated
packages, caches, and vendored sources are excluded from the report.

Feed the result into `zig-crap` to join line coverage with per-function
complexity:

```sh
zig-crap src --lcov coverage.lcov --lcov-base .
```

## Fuzzing

Telar uses Zig's built-in fuzzer (`std.testing.fuzz`) with 12 target steps:
handshake, client and server IPC, frame bodies, cell runs, text metadata,
PNG, ICO, HTTP/1 heads and bodies, and HTTP/2 frame reading and observation.
The targets use synthetic inputs and do not start a runtime or contact real
services. Their contracts and limits are described in
[`docs/testing/`](testing/).

Run every fuzz root's deterministic tests and replay its seed corpus:

```sh
just fuzz-check
```

Fuzz every target in sequence, with GUI disabled and one build job. The
argument takes Zig's `K`, `M` and `G` suffixes and is passed to each target,
not shared across the whole campaign:

```sh
just fuzz         # --fuzz=10K for each target
just fuzz 1M      # --fuzz=1M for each target
```

Each target prints its report before the next starts. Coverage counts the
whole executable, including the runner and oracles, not only production
code. Wuffs C and nghttp2 provide no fuzz coverage feedback. Run these
commands without `-Dcoverage`.

With Zig 0.16.0, `zig build --fuzz` can exit 0 after a failure. `just fuzz`
checks each target's output for saved inputs, panics and termination signals
and stops with a nonzero status if it finds one or the build fails.

A failing input is reported as `input saved to '.zig-cache/f/crash'`. It is
in Smith input form, not necessarily raw protocol bytes. Zig has sometimes
written an empty or truncated crash file; the target documents explain how
to recover the complete input from `.zig-cache/f/in<N>` and replay it.

The fuzz roots stay out of ordinary suites and coverage discovery. Their
executables use LLVM and disable error return traces only on the root;
Debug runtime safety stays enabled.
