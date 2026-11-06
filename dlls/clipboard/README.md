# Clipboard

Standalone C++23 clipboard reader for macOS and Linux. Run these commands from `dlls/clipboard`.
`telar::clipboard::read()` returns owned bytes and a MIME type. It reads text
and encoded PNG, JPEG, or TIFF images, in that order, preferring images over alternate text.
Storage grows to the content size instead of using a fixed 2048-byte buffer.
Allocation failures and clipboard changes during capture are reported as errors.
Images retain their original encoding; reading does not decode or convert pixels.
`read(maximum_bytes)` bounds captured bytes, defaulting to 32 MiB. Each native
backend checks before appending to the owned buffer; oversized content returns
`content_too_large`. Native OS APIs may still materialize their own representation.

The shared `telar-clipboard` CMake target is also linked by the C++ runtime.
See [remote clipboard reads](../../docs/clipboard.md). `cmake/library.cmake` embeds
only the library, not this project's executable, tests or tooling targets.
`-DTELAR_CLIPBOARD_NATIVE=OFF` builds an explicit unavailable backend without desktop
dependencies, for headless installations.

## Build and test

Requires CMake 3.25+, Ninja, and a C++23 compiler. On Linux, also install
pkg-config, the Wayland client and XCB development packages, and `wayland-scanner`.
On Arch/Omarchy:

```sh
sudo pacman -S --needed base-devel clang cmake ninja pkgconf wayland libxcb
```

LLVM's `clangd`,
`clang-format`, and `clang-tidy` should be on `PATH` for editor and tooling support.
No machine-specific compiler or SDK paths are stored in the project.

```sh
cmake --preset debug
cmake --build --preset debug
ctest --preset debug
./out/debug/clipboard
```

`release` and `sanitize` have matching configure, build, and test presets.
`sanitize` enables AddressSanitizer and UndefinedBehaviorSanitizer with GCC or Clang.
To select a different compiler, pass `-DCMAKE_CXX_COMPILER=/path/to/clang++`
when configuring that preset. If Apple's sanitizer runtime hangs before `main`,
try Homebrew LLVM on macOS:

```sh
cmake --preset sanitize -DCMAKE_CXX_COMPILER="$(brew --prefix llvm)/bin/clang++"
cmake --build --preset sanitize
ctest --preset sanitize
```

Tests cover large UTF-8 text, empty text, PNG/TIFF/JPEG images larger than 2048
bytes, MIME types, image priority, exact file output, and unsupported content.
On macOS, they reuse the GUI tests' private pasteboard helper, so they neither
read nor modify the system clipboard. The smoke test only prints CLI help.

## Linux backends and integration tests

The Linux API uses libwayland-client and XCB directly. It does not spawn clipboard
utilities, create a visible window, or depend on Qt. Wayland requires a compositor
that exposes `zwlr_data_control_manager_v1`. Compositors without that protocol
return `unsupported_protocol`; there is no silent fallback to XWayland.
The vendored wlr-data-control XML retains its upstream copyright and license.

With `WAYLAND_DISPLAY` set, the reader uses Wayland and the first advertised seat.
Otherwise it uses the X11 `CLIPBOARD` selection through `DISPLAY`, including INCR
transfers. The graphical session's environment and access permissions must be
available to the process; an SSH login alone does not provide them. Reads have a
five-second transfer deadline. Buffers grow with received data, and X11 size hints
are never used to allocate memory. UTF-8 MIME types and `UTF8_STRING` are preferred
over generic `text/plain`; bytes are preserved rather than transcoded.

The optional integration suites start private headless Sway and authenticated
Xvfb sessions. They test multi-megabyte PNG/JPEG/TIFF images, empty and large text,
UTF-8 aliases, embedded NUL bytes, terminal protection, stalled owners, and X11
INCR, malformed transfers, owner changes, and untrusted size hints. They reuse the
GUI tests' X11 provider and fixture helpers. No desktop clipboard is modified.

```sh
sudo pacman -S --needed sway wl-clipboard xorg-server-xvfb xorg-xauth xclip python-pillow
cmake --preset debug -DCMAKE_CXX_COMPILER=clang++ -DCLIPBOARD_LINUX_INTEGRATION_TESTS=ON
cmake --build --preset debug
ctest --preset debug
```

The suites passed in the Omarchy ARM64 VM with Clang 23.1.4 in Debug and with
AddressSanitizer/UndefinedBehaviorSanitizer enabled. A read-only probe also
succeeded on the VM's existing Hyprland session, discarding captured bytes.
macOS's private-pasteboard tests still pass.

## Read the clipboard

```sh
# Print text, with no added newline.
./out/debug/clipboard

# Save text or an image to a local file.
./out/debug/clipboard --output /tmp/clipboard-content

# Pipe encoded image bytes to another program or file.
./out/debug/clipboard > /tmp/clipboard-content
```

Images are not printed to an interactive terminal. Use `--output` or redirect
stdout instead. With `--output`, stderr reports the MIME type and byte count;
stdout remains untouched. The filename does not select or convert the encoding:
a clipboard TIFF stays TIFF even if the output filename ends in `.png`.
Empty or unsupported clipboards and read/write failures exit with status `1`.

To treat compiler warnings as errors:

```sh
cmake --preset debug -DCLIPBOARD_WARNINGS_AS_ERRORS=ON
```

The previous `build/` directory is not used by the presets. Direct configuration
with `cmake -S . -B build` still works, but configure `debug` for the editor.

## Editor and debugger

`.clangd` reads `out/debug/compile_commands.json`, generated by the Debug preset.
It supplies C++23, the `includes/` directory, and the macOS SDK when applicable.
Do not commit the database or create a symlink. `.clang-format` and `.editorconfig`
follow the sibling DLL projects. `.clang-tidy` follows `tbc`, including naming checks.

For LazyVim, enable `lang.clangd` and `dap.core` in `:LazyExtras` and install
`codelldb` through `:Mason`. Open Neovim from this directory, build Debug, and use
`<leader>dc` to select `clipboard: main`. The launch profile stops at `main`.
Rebuild before debugging changed code; launching does not build automatically.

## Format and analysis

```sh
cmake --build --preset debug --target format
cmake --build --preset debug --target format-check
cmake --build --preset debug --target lint
cmake --build --preset debug --target lifetime-check
```

Formatting and clang-tidy reuse `../ebnf/cmake/tooling.cmake` rather than copying it.
Formatting discovers project C++ files; lint analyzes translation units in the
selected compilation database. Build directories and generated or vendored code
are excluded. Tooling runs explicitly, not during normal builds.
Add new implementation files to the `clipboard` target in `CMakeLists.txt`.

`lifetime-check` reuses TBC's CMake helper and `.tbc.json` editor configuration.
Build the sibling checker first if `../tbc/out/debug/tbc-lint` does not exist:

```sh
cmake -S ../tbc -B ../tbc/out/debug -G Ninja -DCMAKE_BUILD_TYPE=Debug
cmake --build ../tbc/out/debug --target tbc-lint
```

The checker requires the LLVM/Clang development packages documented in `../tbc/README.md`.
Use `-DTBC_LINTER=/path/to/tbc-lint` during configuration to override the checker
for the CMake target. Local preset overrides belong in the ignored `CMakeUserPresets.json`.
