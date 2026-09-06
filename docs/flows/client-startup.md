# Client startup

This flow starts after `run` has opened the host terminal and constructed one
heap-stable `Client`. It negotiates host colors before subscribing to the runtime
state that triggers the first pane opening. See [terminal colors](terminal-colors.md)
for probe ownership and early-input bounds.

## Boundary

`run` owns the TTY, resize watcher, output writer, process heap and client
lifetime. `client_startup.start` owns startup order. It receives the watcher;
launch values remain owned by the heap-stable client until the runtime answers
with its retained layout.

```text
run -> Client.init
        |
client_startup.start
        |
validate workbench geometry
        |
start host probes and TTY input, arm asynchronous event sources
        |
run -> select.await -> client_events
        |
OSC 10/11 results or 250 ms deadline
        |
client_startup.advance
        |
configure_graphics -> configure_terminal_colors
        |
request_runtime_state(client_identity)
        |
client_layout_snapshot
        |
restore chrome, navigation and split layouts
        |
register initial_open continuation
        |
open_pane(restored pane or default launch)
        |
pane activation -> replay retained input
```

The startup controller owns the negotiation gate and bootstrap ordering. The
layout controller continues to restore the runtime snapshot and request the
initial pane without knowing about probes. `run` waits for `client_events`
outcomes; individual adapters own their tokens and rearming policy.

## Validation and handshake

Startup derives the initial pane size from the current workbench. An empty
workbench returns `TerminalTooSmall` before request correlation or transport
state changes.

After color negotiation settles, `runtime_transport.State.bootstrap` reserves
space for three FIFO messages before changing its bounded outbox:

1. `configure_graphics` with this client's shared-memory support;
2. `configure_terminal_colors` with the known foreground and background;
3. `request_runtime_state` with the stable identity of the host terminal.

The ordinary send actor delivers them in order. Runtime and TTY reads are
already armed; early user input is retained until the first pane is active.
The runtime delivers `client_layout_snapshot` before its other level-triggered projections. The
client restores sidebar visibility and width, workspace-list collapse, active
tab, pane focus, fullscreen state and validated split trees. It then derives
geometry from the restored sidebar, registers `initial_open`, and requests the
retained pane. With no safe pane layout, it uses the normal default launch while
still restoring retained chrome preferences. A reply therefore cannot race an
unregistered continuation, and the first pane size matches the restored view.

## Event sources and lifetime

Before waiting for replies, startup arms the host resize watcher, one runtime
read, one TTY read, the host-capability deadline, telemetry, configured bar
deadlines and configuration reload. Adapters with disabled configuration
schedule no worker. Each active adapter owns its bounded pending token.

Any startup error aborts the disposable client. `Client.deinit` cancels tasks
before freeing client buffers, and its defer runs before `run` destroys the
watcher. Telar does not retry an uncertain partial handshake inside the same
client; the runtime remains the authority and a later client reconnects from
snapshots.

## Proof

- `client startup validates geometry before request registration` proves that
  an invalid workbench changes neither correlation nor transport state.
- `client startup waits for runtime layout before its initial open` crosses a
  real socketpair and proves identity delivery, deferred correlation, geometry,
  launch arguments and the receive token.
- `restored client layout controls the initial attach geometry` proves that
  retained chrome and navigation precede the attach request.
- `runtime bootstrap queues colors before subscribing to the initial layout`
  proves ordered bounded delivery independently of startup orchestration.
- `startup timeout publishes unknown colors once and consumes late replies`
  proves fallback and expiry.
- `startup replays early typing exactly once after pane activation` proves that
  negotiation does not discard keystrokes.
- Resize, capability, telemetry and reload lifecycle tests prove their own
  scheduling-token cleanup and failure rules.
