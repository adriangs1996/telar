# Read a machine's clipboard

The C++ CLI can read text or an encoded image through the runtime on that machine.
The CLI on both machines and the source runtime must include this feature.
No Telar window needs to be open.

```sh
set -o pipefail
telar --machine omarchy clipboard get | chafa -f kitty
```

The runtime captures its own machine's clipboard once. SSH forwards the bytes to
this machine, where `chafa` renders them. This requires an image in the source
clipboard and a terminal that supports Kitty graphics. The command does not take
a screenshot itself or modify either clipboard.

```sh
telar clipboard get > clipboard-content
telar --machine omarchy clipboard get > clipboard-content
```

Stdout contains only the original bytes, with no added newline. Images take
priority over alternate text, in PNG, JPEG, TIFF order. The filename does not
select an encoding. The CLI refuses direct terminal output, including text that
could contain escape sequences. Diagnostics go to stderr. Check the producer's
exit status: a failed stream may leave a partial output file.

## Give the runtime session access

Start the runtime as the desktop user from that user's graphical session. On
Linux it needs `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR` for Wayland, or `DISPLAY`
and any required `XAUTHORITY` for X11. Wayland requires the compositor's
`wlr-data-control` protocol. No fallback to an unrelated XWayland clipboard occurs.

An SSH login alone does not provide the graphical environment. A runtime already
started over SSH does not acquire it when a window opens. Start it from the
session, or configure its user service with that session's environment. Do not
restart an existing runtime with live panes just to change its environment.
Telar does not guess display sockets or inspect other processes for credentials.
On macOS the runtime must have access to the logged-in user's pasteboard session.

`clipboard get` requires an existing runtime and never starts one. Use
`--socket /absolute/path` to address an isolated runtime explicitly.

## Bounds and trust

Capture runs on a worker, not the terminal event loop. Only one capture or
transfer is admitted per runtime, with a 32 MiB content limit. Transfers pull
64 KiB chunks and expire 30 seconds after admission. Disconnects discard retained
content; there is no clipboard history, continuous monitoring or checkpoint data.
Linux native reads have a five-second deadline.

Access follows the runtime's same-account socket permissions and SSH
authentication. A process running under that account, including an agent, can
request the clipboard. There is no separate human-approval prompt in this version.

## Build and focused tests

Normal C++ runtime builds enable `TELAR_CLIPBOARD_NATIVE`. Linux adds development
packages for Wayland client, XCB and `wayland-scanner`. On Arch:

```sh
sudo pacman -S --needed wayland libxcb
```

Use `-DTELAR_CLIPBOARD_NATIVE=OFF` for a runtime without desktop dependencies;
clipboard requests then fail explicitly. Static headless Linux distribution
builds default to this setting, preserving their dependency-free linkage.

```sh
cmake --build src/runtime-cpp/out --target telar telar-runtime runtime-clipboard-tests
ctest --test-dir src/runtime-cpp/out \
  -R '^(runtime-clipboard-tests|clipboard-cli-tests|cli-help-tests)$' --output-on-failure
```

On Linux, `-DTELAR_CLIPBOARD_INTEGRATION_TESTS=ON` adds
`runtime-clipboard-native-tests`. It requires Sway, wl-clipboard and Python Pillow,
and uses a private headless session rather than the desktop clipboard. It checks
native text/PNG/JPEG/TIFF output, multi-megabyte transfers, size rejection and
runtime responsiveness while a clipboard owner stalls. The library's separate
Wayland/X11 integration tests live in `lib/clipboard`.
