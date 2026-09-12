# Native frontend spike

On macOS, run `zig build exper-native`. The terminal version remains available
through `zig build exper`. Both support `+`, `-`, and `q`; closing the native
window also requests quit. The scripted requests are `3, -2, 0`, ending at 1.

`exper.zig` owns the shared model, inboxes, backend replies, script, frame ticker,
and task supervision. `Renderer.zig` receives an immutable counter value.
`TerminalRenderer.zig` composes the existing terminal widgets. `native.m` draws
rectangles and text in an AppKit view, with geometry measured in points.

AppKit runs on the main thread. A worker runs the same experiment and publishes
one atomic value; the host retains no model pointer and queues no frames. A
16 ms host timer samples that value and requests drawing only when it changes.
This polling is a simulation-only exception, like the existing frame ticker;
it is not a production idle/pacing design. Window resize also redraws the view.
Native keys enter a bounded nonblocking pipe and reuse the experiment's input
reader. A full pipe closes input and reports a host error. All actors finish or
are canceled and joined before the pipe, renderer, or window are destroyed.

This demonstrates interchangeable drawing for the counter experiment. It does
not implement a native Telar client, terminal glyph rendering, GPU delivery, or
the production presentation completion contract. A successful render call here
means snapshot publication, not confirmation that a frame reached the display.

Validation: `zig build test-exper build-exper-native`. The shared flow test checks
that backend replies update the model and that a render opportunity delivers
its resulting value through the renderer contract. The widget test also covers
small and empty drawing areas. Native interaction and window drawing require a
macOS graphical session.
