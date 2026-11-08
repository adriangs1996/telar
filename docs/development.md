# Developing Telar

For an introduction and first launch, see the [README](../README.md).
Run the commands below from the repository root.

The [pinned module build and onboarding guide](build/cpp-modules.md) is the
reference for the toolchain, configure/build/test commands, diagnostics
variants, clangd, CI, standalone libraries and release packaging.

## Build requirements

`tools/cpp bootstrap` installs the pinned LLVM, CMake, Ninja and Just into
`.toolchain/`. The first configure prepares the verified Zig compiler that
only builds the pinned `libghostty-vt`, and the managed Qt, OpenSSL and
native libraries. Building the GUI also needs Cargo and Rust 1.93.1 or newer
for the [diagram renderer](../tools/diagram-renderer/README.md); the
installed application does not need Rust.

### macOS

Install Xcode or the Command Line Tools with a macOS 26 SDK, Python 3.9+,
Git and Rust.

### Linux

On Ubuntu 24.04, install the desktop SDK used by CI, then Rust:

```sh
sudo packaging/release/install-linux-deps.sh
```

The headless profile needs no graphical SDK; the
[build guide](build/cpp-modules.md#comandos-completos) lists its packages.

### Build and launch

```sh
tools/cpp bootstrap
export PATH="$PWD/.toolchain/bin:$PATH"
just app
```

`just app` builds the runtime, the CLI and the GUI in Debug and opens a
window on a development runtime with its own socket and history under
`.dev/`. `just app-release` does the same with optimized builds. `just --list`
shows every recipe. [Packaging](packaging.md) covers release archives,
application bundles and desktop entries.

## Making changes

Test what you change before you commit:

```sh
just runtime-test     # runtime and CLI CTest groups
just gui-test         # GUI tests, the integration ones against the runtime
just runtime-lint
just gui-lint
```

Extra arguments go to CTest, for example `just runtime-test -R server-cli`.
CI runs the C++ workflows in [`.github/workflows`](../.github/workflows).

## Development diagnostics

Debug builds, and optimized builds configured with `-DTELAR_DIAGNOSTICS=ON`,
write per-process telemetry files beside the local runtime socket:

```text
<socket>.runtime-<pid>.log
<socket>.client-<pid>.log
```

`telar diagnostics logs` prints their tails together with the runtime's own
log, without contacting the runtime and without terminal content.
