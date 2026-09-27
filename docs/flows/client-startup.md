# Client startup

This flow starts after the window has constructed one heap-stable
`GuiAdapter` embedding `Client` and the native surface reports usable
geometry. The window's colors come from its own renderer theme, so no host
probe gates the bootstrap. The headless client follows the same order from
fixed host facts (see [Headless client](headless-client.md)).

## Boundary

`GuiAdapter.run` owns the native window, the renderer and the client lifetime.
`GuiAdapter.windowReady` starts the client once: repeated notifications do not
repeat the bootstrap. Launch values remain owned by the heap-stable client
until the runtime answers with its retained layout.

```text
GuiAdapter.run -> native window
        |
GuiAdapter.windowReady(viewport)
        |
GuiAdapter.resizeViewport: measure the grid, commit host size
        |
GuiAdapter.start
        |
host_resize.applyHostUpdate (theme colors, capabilities)
        |
startup.phase = .opening, Client.bootstrap
        |
runtime_link.start -> connect worker -> runtime_link.finishConnect
        |
Outbox.pushBootstrap: configure_graphics -> configure_terminal_colors
                      -> request_runtime_state(client_identity)
        |
client_layout_snapshot
        |
client_layout.restoreClientLayout: chrome, navigation and split layouts
        |
client_layout.openInitialPane -> register initial_open
        |
open_pane(restored pane or default launch)
        |
pane activation -> client_startup.finish -> drain retained input
```

`GuiAdapter.start` sets the startup phase and stores `Client.bootstrap`. On a
new connection `runtime_link.start` queues the connect job; its completion
pushes the bootstrap and starts runtime I/O. A window that already holds a
connection pushes the bootstrap directly. The common
`client_layout.restoreClientLayout` restores runtime layout and requests the
initial pane. The window-thread consumer `GuiAdapter.update` dispatches each
inbox message; each resource owner keeps its own token and rearming policy.

## Validation and handshake

Startup derives the initial pane size from the current workbench.
`GuiAdapter.windowReady` returns without starting when the viewport measures
to an invalid grid. `client_layout.openInitialPane` returns
`TerminalTooSmall` for an empty workbench before request correlation or
transport state changes.

`model.to_runtime.pushBootstrap` checks space for three FIFO messages before
changing the bounded outbox:

1. `configure_graphics` with this client's shared-memory support;
2. `configure_terminal_colors` with the renderer theme's foreground and
   background;
3. `request_runtime_state` with the client's stable identity.

The ordinary runtime send worker delivers them in order. Early user input is
retained until the first pane is active: `StartupState.holdsInput` is true
while the phase is `probing` or `opening`, so `GuiAdapter.drainInput` leaves
the queue untouched and the headless client reads no stdin line. The runtime
delivers `client_layout_snapshot` before its other level-triggered
projections. The client restores sidebar visibility and width,
workspace-list collapse, active tab, pane focus, fullscreen state and
validated split trees. It then derives geometry from the restored sidebar,
registers `initial_open`, and requests the retained pane. With no safe pane
layout, it uses the normal default launch while still restoring retained
chrome preferences. A reply therefore cannot race an unregistered
continuation, and the first pane size matches the restored view.

A machine the window does not show defers its first pane: the layout is kept
in `Client.deferred_layout` and the open waits until the window shows it. See
[Machine presentation](machine-presentation.md).

## Event sources and lifetime

Before waiting for replies, startup arms one runtime connection, configured
bar deadlines and configuration reload. Adapters with disabled configuration
schedule no worker. Each active adapter owns its bounded pending token.

Any startup error aborts the disposable client. The adapter closes and joins
inbox producers before freeing client buffers. Telar does not retry an
uncertain partial handshake inside the same client; the runtime remains the
authority and a later client reconnects from snapshots.

## Validation

- `native startup sends the ordered bootstrap without graphics credits or a
  server reply` in `src/gui/tests/terminal.zig` proves the window's bootstrap
  order.
- `client startup waits for runtime layout before its initial open` in
  `src/client_tests/transport.zig` crosses a real socketpair and proves
  identity delivery, deferred correlation, geometry, launch arguments and the
  receive token.
- `restored client layout controls the initial attach geometry` in the same
  file proves that retained chrome and navigation precede the attach request.
- `runtime bootstrap queues colors before subscribing to the initial layout`
  in `src/model/connection/Outbox.zig` proves ordered bounded delivery
  independently of startup orchestration.
- `each GUI drains only its own queue and respects its own startup gate` in
  `src/gui/tests/host_input.zig` proves that input waits for startup.
