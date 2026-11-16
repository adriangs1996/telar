# Clipboard

C++23 clipboard reader for macOS and Linux, a folder of the repository's tree. Run
these commands from the repository root.
`telar::clipboard::read()` returns owned bytes and a MIME type. It reads text
and encoded PNG, JPEG, or TIFF images, in that order, preferring images over alternate text.
Storage grows to the content size instead of using a fixed 2048-byte buffer.
Allocation failures and clipboard changes during capture are reported as errors.
Images retain their original encoding; reading does not decode or convert pixels.
`read(maximum_bytes)` bounds captured bytes, defaulting to 32 MiB. Each native
backend checks before appending to the owned buffer; oversized content returns
`content_too_large`. Native OS APIs may still materialize their own representation.

The shared `telar-clipboard` CMake target is also linked by the C++ runtime.
See [remote clipboard reads](../../docs/clipboard.md). The `clipboard` executable and
its tests build with the tree's other tests (`BUILD_TESTING`).
`-DTELAR_CLIPBOARD_NATIVE=OFF` builds an explicit unavailable backend without desktop
dependencies, for headless installations.

## Build and test

C++ importers reach the API through the `telar.clipboard` module, which owns
`includes/clipboard.hpp`; the header stays for Objective-C++. The Linux backends
are C++ modules too (`telar.clipboard.wayland` and `telar.clipboard.x11`, each the
only owner of its library's headers, on top of `telar.clipboard.transfer`), and the
reader imports `std` and `telar.sys`. Every build therefore needs the toolchain
that `cmake/TelarBuild.cmake` requires: Ninja and the pinned Clang, which the
root presets select through `tools/cpp`.
On Linux, also install pkg-config, the Wayland client and XCB development packages,
and `wayland-scanner`. On Arch/Omarchy:

```sh
sudo pacman -S --needed base-devel clang cmake ninja pkgconf wayland libxcb
```

LLVM's `clangd`,
`clang-format`, and `clang-tidy` should be on `PATH` for editor and tooling support.
No machine-specific compiler or SDK paths are stored in the project.

```sh
tools/cpp configure
tools/cpp build -- --target lib/clipboard/all
tools/cpp test -- -L '^lib\.clipboard$'
out/dev/lib/clipboard/clipboard
```

The sanitize preset's tree (`tools/cpp configure sanitize`) enables
AddressSanitizer and UndefinedBehaviorSanitizer.

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
tools/cpp configure -- -DCLIPBOARD_LINUX_INTEGRATION_TESTS=ON
tools/cpp build -- --target lib/clipboard/all
tools/cpp test -- -L '^lib\.clipboard$'
```

The suites passed in the Omarchy ARM64 VM with Clang 23.1.4 in Debug and with
AddressSanitizer/UndefinedBehaviorSanitizer enabled. A read-only probe also
succeeded on the VM's existing Hyprland session, discarding captured bytes.
macOS's private-pasteboard tests still pass.

## Read the clipboard

```sh
# Print text, with no added newline.
out/dev/lib/clipboard/clipboard

# Save text or an image to a local file.
out/dev/lib/clipboard/clipboard --output /tmp/clipboard-content

# Pipe encoded image bytes to another program or file.
out/dev/lib/clipboard/clipboard > /tmp/clipboard-content
```

Images are not printed to an interactive terminal. Use `--output` or redirect
stdout instead. With `--output`, stderr reports the MIME type and byte count;
stdout remains untouched. The filename does not select or convert the encoding:
a clipboard TIFF stays TIFF even if the output filename ends in `.png`.
Empty or unsupported clipboards and read/write failures exit with status `1`.

To treat compiler warnings as errors in this project's own sources (the library,
the reader and its tests, not the `std` module CMake builds from the toolchain):

```sh
tools/cpp configure -- -DCLIPBOARD_WARNINGS_AS_ERRORS=ON
```

## Editor and debugger

The repository's `.clangd` reads `out/dev/compile_commands.json`, generated by the dev preset.
It supplies C++23, the `includes/` directory, and the macOS SDK when applicable.
Do not commit the database or create a symlink. The repository root's `.clang-format`
formats the sources, `.editorconfig` follows the sibling DLL projects, and `.clang-tidy`
follows `tbc`, including naming checks.

For LazyVim, enable `lang.clangd` and `dap.core` in `:LazyExtras` and install
`codelldb` through `:Mason`. Open Neovim from `lib/clipboard`, build the dev tree, and use
`<leader>dc` to select `clipboard: main`. The launch profile stops at `main`.
Rebuild before debugging changed code; launching does not build automatically.

## Format and analysis

```sh
just format
just format-check
just lint
just lifetime
just blank-lines
```

The targets come from the repository's `cmake/TelarChecks.cmake`. `format` and
`format-check` cover every C++ file Git tracks in the repository; `lint`,
`lifetime` and `blank-lines` analyze the sources of the targets that register for
them, the library, the `clipboard` executable and its test among them. Tooling runs
explicitly, not during normal builds.
Add new implementation files to the `clipboard` target in `CMakeLists.txt`.

`lifetime` uses the tbc-lint that the repository's `.tbc.json` names, which
`just lifetime-checker` builds at `lib/tbc/out/release/tbc-lint`.

The checker requires the LLVM/Clang development packages documented in `../tbc/README.md`.
Use `-DTBC_LINTER=/path/to/tbc-lint` during configuration to override the checker
for the CMake target. Local preset overrides belong in the repository's ignored
`CMakeUserPresets.json`.
