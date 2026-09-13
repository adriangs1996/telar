# Native titlebar and blur validation

Validated on 2026-09-13 on macOS/Metal 4 and the Fedora/Sway Wayland VM.
Configuration, macOS and Linux implementations were developed in separate
worktrees, followed by independent code review and integrated native probes.

Evidence: [macOS suite](macos-suite.log.gz), [integrated build](macos-build.log.gz),
[Metal window](macos-window.log.gz), [reload result](macos-reload.json),
[hidden startup result](macos-hidden-start.json), [hidden titlebar capture](macos-hidden.png),
[Linux suite](linux-suite.log.gz), [Vulkan window](linux-window.log.gz),
[Linux reload](linux-reload.log.gz), and [Wayland trace](linux-wayland.log.gz).

```lua
gui = {
  window = {
    titlebar = false,
    background_opacity = 0.95,
    background_blur = 20,
  },
}
```

`titlebar` defaults to `true`. Blur is an integer in `0..255`; zero disables
it. Legacy `true` maps to `20`, and `false` maps to zero. Both settings reload
through the existing watcher. Runtime protocol and TUI rendering are unchanged.

| Check | Result |
| --- | --- |
| macOS client and GUI tests | 1,019/1,019 passed: 874 client and 145 GUI |
| Linux client and GUI tests | 1,018/1,019 passed: 874 client and 144 GUI; one macOS-only test skipped |
| Style and client boundaries | Passed on both platforms |
| Linux keyboard, pointer and window options | Passed |
| Native Metal window | 16 prepared, 12 delivered, 3 discarded for changed geometry, final submission closed in flight; zero failures |
| Native Vulkan window | 15 prepared, 13 delivered, 2 retries; zero failures; rejected-scene cleanup passed |
| Vulkan validation | No validation errors or VUID diagnostics in native window or reload runs |

The configuration tests cover defaults, profile inheritance, legacy booleans,
integral floating-point input, invalid numbers/types and invalid unselected
profiles. GUI tests exercise watched reload, rejection of radius 256, and
preservation of the active atlas and configuration after rejection.

## macOS

The native test checks actual WindowServer acceptance of radii 40, 80 and 0,
window/layer opacity, title visibility and buttons, focus and first responder,
top-edge hit testing, outer frame preservation, and real fullscreen entry/exit
with a preference changed while fullscreen. A prepared frame invalidated by
the new content size completes with `delivered = 0` and is retried with the
new viewport. It cannot publish stale hit geometry.

The full Lua reload probe completed stage 24 with 11 appearance transitions.
The shell PID remained 43657 through font, theme, padding, titlebar and blur
changes, and was still alive after the GUI closed. `stty size` reported:

| Window state | Rows × columns |
| --- | --- |
| Titlebar visible, font size 17 | 94 × 148 |
| Titlebar hidden, blur 40 | 95 × 148 |
| Titlebar hidden, blur 80 | 95 × 148 |
| Titlebar restored, blur 80 | 94 × 148 |

The outer window rectangle and atlas page identity stayed constant across the
window-only changes. The final radius-zero reload disabled the native blur
while preserving transparency. A separate lifecycle probe passed starting
directly with `titlebar = false` and radius 40: input succeeded, resize changed
the PTY from 105 × 169 to 16 × 29, and shell PID 44171 survived detach.

The probe observes successful native completions, excluding deferred or
discarded preparations. Atlas identity proves retention; its upload version
may still increase when changing chrome text adds glyphs to the same page.
Earlier probe assertions compared that version or observed discarded frames;
those assertions were corrected before the final run.

The optional private API follows
[Ghostty's implementation](https://github.com/ghostty-org/ghostty/blob/f2d5758f6305867dc36b36293c6165d8152b853e/src/apprt/embedded.zig#L2356).
The public `NSVisualEffectView` fallback is reviewed in code; these runs did
not simulate missing CGS symbols or a rejected native radius.

## Linux

Each Lua generation used a distinct native keybinding to prove adoption even
without compositor blur support. Radii 20, 80 and 0 all retained the same
31 × 60 PTY grid. Wayland tracing recorded decoration requests `[2, 1, 2]`:
visible, hidden, visible. Only changed preferences produced a new request.

This Sway instance configured mode `[2]`, imposing server-side decorations,
and offered no usable blur capability. Consequently the real VM run verifies
request negotiation, reload, transparency and lifecycle, not visible titlebar
removal or compositor blur. Mock protocol tests cover accepted client-side
decorations and supported blur, including object lifetime and repeated frames.

[xdg-decoration](https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/main/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml)
permits compositor overrides.
[ext-background-effect-v1](https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/main/staging/ext-background-effect/ext-background-effect-v1.xml)
exposes a blur region but no radius, so all positive values request the same
effect. Telar does not alter compositor configuration to bypass either limit.

Input, paste, invalid-font rejection, font recovery, padding and resize also
passed. Closing and reconnecting retained shell PID 286856. All probe runtimes,
history files and sockets were isolated from the development session.

## Reproduction

```sh
zig build test-client test-gui codestyle check-client-boundaries --summary all
zig build test-gui-window --summary all
zig build install --prefix /tmp/telar-window-options-build
python3 tools/gui_lifecycle.py /tmp/telar-window-options-build/bin/telar /tmp/telar-window-reload-new --reload --capture

python3 tools/vm/vm.py build test-client test-gui test-gui-keyboard test-gui-pointer test-gui-window-options codestyle check-client-boundaries --summary all
python3 tools/vm/gui-terminal-test.py /tmp/telar-window-linux-new --reload
```

macOS lifecycle output directories must be new. Run desktop probes serially
on each host so focus and native input belong to the intended window.
The macOS probe writes `result.json` and optional captures. The Linux probe
retains full Wayland traces in `gui.log` and `reattach.log`.
