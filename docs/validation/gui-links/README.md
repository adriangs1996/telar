# Native links and pointer feedback

Validated on 2026-09-13, on the `feat/gui-integration` branch. Native checks ran
on macOS (AppKit/Metal 4) and the existing Fedora Wayland VM (Sway/Vulkan).

## Results

| Check | macOS | Linux |
| --- | --- | --- |
| Core, shared client, runtime and TUI | 3,342 passed / 3,344; 2 skipped | 3,344 / 3,344 passed |
| GUI, including final preview-ownership regressions | 144 / 144 passed | 143 passed / 144; 1 skipped |
| Code style and client boundaries | Passed | Passed |
| Native window | 7 painted, 6 delivered, 0 failures | 15 painted, 13 delivered, 2 intentional retries, 0 failures |
| Native link probe | Passed | Passed |

The Linux GUI skip is the macOS-specific optical font weight check. Native
Wayland keyboard and cursor C tests also passed, including cursor-shape enum
mapping, enter serials, fallback themes, scaling and retained idle behavior.
The Vulkan window test ran with `VK_LAYER_KHRONOS_validation` and synchronization
validation enabled; its rejected-scene cleanup case passed as well.

The counts above combine disjoint root `test` and `test-gui` suites. Compressed
logs preserve the commands’ individual summaries: [macOS core](macos-core.log.gz),
[macOS GUI](macos-gui.log.gz), [Linux complete suite](linux-suite.log.gz), and
[Linux final GUI](linux-gui.log.gz). The complete Linux run preceded four final
GUI regressions, which the final GUI run includes. Native window logs are
[macOS](macos-window.log.gz) and [Linux](linux-window.log.gz).

## End-to-end behavior

The macOS probe verifies 12 native cursor states, including Command press/release
without pointer movement, OSC 22 crosshair/text, sidebar resize and pointer leave.
It opens two local files through an isolated recording editor. One is a visible
`file://` URL; the other is an OSC 8 label with a different destination. Both paths
contain spaces and arrive as exactly one decoded argument. A URI crossing a soft
wrap produces two exact underline rectangles. The original child and both editor
children survive GUI closure. [Native results](macos-native.json).

The Linux probe uses QEMU pointer/button/modifier input and a raw child PTY.
A recording `xdg-open` receives exactly three full destinations: visible HTTP,
OSC 8 and a URL crossing a soft wrap. Nothing opens on press; each release opens
once. The child receives only its two explicit `x`/`t` commands for OSC 22, with
no residual input from link gestures. Both the original shell and raw reader
survive GUI detachment. [Native results](linux-native.json).

Both probes isolate socket, history, configuration and opener. HTTP is never
sent to an actual browser. Each desktop has one native probe at a time. macOS
input is synthetic AppKit input; the driver asserts window/application focus and
cursor state together so a focus cancellation cannot masquerade as opener failure.

| Platform | OSC 8 label and actual destination | Soft-wrapped URI |
| --- | --- | --- |
| macOS | [Capture](macos-osc8.png) | [Capture](macos-wrap.png) |
| Linux | [Capture](linux-osc8.png) | [Capture](linux-wrap.png) |

## Regression coverage and resource bounds

The new regressions cover UTF-8 and wide-cell intervals, explicit identities,
soft wraps versus hard newlines, rejected/truncated targets, exact frame bases,
independent clients and history viewports. Metadata-only changes travel without
cell spans; unchanged patches retain their table. Corrupt offsets, counts, flags,
dimensions and dictionary references are rejected, including the maximum row
count that originally exposed narrow-integer overflow.

GUI regressions verify release-only opening, drag/focus/leave cancellation,
intervening target or tab changes, in-flight frames, keyboard-prefix preservation,
mouse reporting and presented preview bounds. A preview owns its entire click
through release, even when the next frame removes it. Text behind the preview
cannot receive that gesture. Single-row panes retain links without a preview
that would cover them.

Allocation checks exercise 120 frame replacements and 120 metadata captures
with a failing allocator after setup. Saturating 256 OSC 8 identities drops the
whole table, preserves row flags and later recovers. A URI cannot exceed 4,096
bytes; each viewport permits 2,048 runs and 64 KiB of URI bytes. At 40 rows,
five reserved metadata stores total 438,015 bytes for a pane with one client
(runtime, client and the attachment’s independent history projection). Unchanged
patches carry a four-byte marker. Hover reuses retained cell meshes and glyphs;
changing only the native cursor creates no GPU frame or polling timer.

## Reproduction

```sh
zig build test test-gui codestyle check-client-boundaries
zig build test-gui-window
zig build install --prefix /tmp/telar-link-build
python3 tools/gui_links.py /tmp/telar-link-build/bin/telar /tmp/telar-link-probe

python3 tools/vm/vm.py build install test test-gui test-gui-keyboard test-gui-pointer
python3 tools/vm/gui-links-test.py /tmp/telar-wayland-link-probe
```

Probe directories must be new. Native probes must run alone on each desktop.
The wire schema is now `466f97d7`; GUI/TUI and runtime require matching builds.
The user’s running runtime and children were not restarted. See
[link opening](../../flows/link-opening.md) and [pane frames](../../flows/pane-frame.md#terminal-text-metadata)
for ownership, supported schemes and compatibility details.
