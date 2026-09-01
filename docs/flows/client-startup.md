# Client startup

This flow starts after `run` has opened the host terminal and constructed one
heap-stable `Client`. It ends when the runtime handshake is complete and every
initial asynchronous event source is armed.

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
configure_graphics
        |
request_runtime_state(client_identity)
        |
arm resize, runtime read, capability, telemetry, bar and config sources
        |
client_layout_snapshot
        |
restore chrome, navigation and split layouts
        |
register initial_open continuation
        |
open_pane(restored pane or default launch)
        |
run -> select.await
```

The startup entrypoint is the only caller that knows this complete sequence.
`run` starts it and then waits for `client_events` outcomes. The individual
adapters still own their tokens, worker functions and rearming policy.

## Validation and handshake

Startup derives the initial pane size from the current workbench. An empty
workbench returns `TerminalTooSmall` before request correlation or transport
state changes.

`runtime_transport.State.bootstrap` sends two synchronous frames through its
bounded send buffer:

1. `configure_graphics` with this client's shared-memory support;
2. `request_runtime_state` with the stable identity of the host terminal.

The runtime receive task starts after both sends complete. The runtime delivers
`client_layout_snapshot` before its other level-triggered projections. The
client restores sidebar visibility and width, workspace-list collapse, active
tab, pane focus, fullscreen state and validated split trees. It then derives
geometry from the restored sidebar, registers `initial_open`, and requests the
retained pane. With no safe pane layout, it uses the normal default launch while
still restoring retained chrome preferences. A reply therefore cannot race an
unregistered continuation, and the first pane size matches the restored view.

## Event sources and lifetime

After the handshake, startup arms the host resize watcher, one runtime read,
the host-capability deadline, telemetry, configured bar deadlines and
configuration reload. Adapters with disabled configuration schedule no worker.
Each active adapter owns its bounded pending token.

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
- `runtime bootstrap emits graphics and identity before asynchronous reads`
  proves the bounded transport encoding independently of startup orchestration.
- Resize, capability, telemetry and reload lifecycle tests prove their own
  scheduling-token cleanup and failure rules.
