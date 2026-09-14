# Widget drawing contract

Baseline: `7c1e346b` (`Refine GUI navigation and status bars`).

All GUI components and their drawing support now live under `src/gui/widgets`.
Modal and notification components live in `widgets/overlays`. `gui/chrome` and
`gui/overlays` have been removed, with their consumers importing the new paths.

Every drawable component implements `draw(self, canvas)`. Its geometry and
semantic inputs belong to the widget value. Containers call their children's
`draw` methods. `Context` contains semantic inputs and hit maps; it has no Canvas
and does no drawing. `SidebarState` retains scroll bounds and snapshot order
between transient `Sidebar` values.

`Chrome` and `Overlays` compose values into the frame list and retain interaction
state. Their former `paint` entrypoints, `SidebarView`, `chrome_widget`, the thread
compatibility entrypoint and the unused modal editor have been removed. Test
fixtures use composition, drawing and sealing directly. `Scene.prepare` remains
the production entrypoint for the complete frame.

The migration preserves presentation completion, captured pane damage, hit-map
publication and animation deadlines. Native Metal/Vulkan sources and their
frame ABI are unchanged.

## Checks

The Linux source snapshot contains 3,747 files with aggregate SHA-256
`5845a563422159651c8060f89d5a43715a394db961f900484966d2e58142f7d7`.
The subsequent `TopBar.zig` edit only changes whitespace and optional trailing
initializer commas; comparison with the validated version confirmed this.

- macOS: `zig build install test-gui codestyle check-client-boundaries --summary all`
  passed all 54 steps and all 338 GUI tests. Module/capability boundaries passed.
- macOS: `MTL_DEBUG_LAYER=1 zig build test-gui-window --summary all` passed all
  three steps. Metal API validation was enabled. Window/input checks reported
  zero failures, including IME, clipboard, accessibility and precise scroll.
- Linux: `zig build -j4 install test-gui --summary all` passed all 63 steps:
  337 tests passed and one macOS-specific test was skipped.
- Linux: `zig build -j4 test-gui-window --summary all` passed all 18 steps with
  Vulkan core/synchronization validation enabled and zero window failures.
- Linux: `python3 tools/vm/gui-multiplexer-test.py /tmp/telar-widget-unification-linux-e2e --skip-build --mode default`
  passed all seven stages. It exercised prompts, sidebar keyboard/pointer
  controls, splits, focus, resize, fullscreen, tabs, workspaces and reconnection.
  Five shell PIDs and their generations, workspaces, tabs and split sizes
  survived reattachment. Vulkan logs contained zero validation errors. The VM
  was returned to its initial stopped state.

New regression coverage exercises sidebar scroll/order across successive widget
values and palette rows with empty or narrow bounds. A palette hint is clipped
to the space remaining after its icon, preventing coordinate underflow.

An independent static review compared the moved implementations with the
baseline: drawing order, pixel geometry, clipping, retained animation state and
synchronous borrows were checked. Existing tests retain coverage for failed
drawing, delayed delivery, stale input generations and allocation-free warm
frames.

Logs are available in `/tmp/telar-widget-unification-macos.log`,
`/tmp/telar-widget-unification-macos-window.log`,
`/tmp/telar-widget-unification-linux-gui.log` and
`/tmp/telar-widget-unification-linux-window.log`. End-to-end results and seven
screenshots are in `/tmp/telar-widget-unification-linux-e2e/default/`.
