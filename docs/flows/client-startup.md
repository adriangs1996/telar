# Client startup

This flow starts after `run` has opened the host terminal and constructed one
heap-stable `Client`. It ends when the runtime handshake is complete and every
initial asynchronous event source is armed.

## Boundary

`run` owns the TTY, resize watcher, output writer, process heap and client
lifetime. `client_startup.start` owns startup order. It receives the watcher and
borrowed launch values but retains no launch slice.

```text
run -> Client.init
        |
client_startup.start
        |
validate workbench geometry
        |
register initial_open continuation
        |
configure_graphics
        |
request_runtime_state
        |
open_pane
        |
arm resize, runtime read, capability, telemetry, bar and config sources
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

The fixed `initial_open` continuation is registered before bytes leave the
client. `runtime_transport.State.bootstrap` then sends three synchronous frames
through its bounded send buffer:

1. `configure_graphics` with this client's shared-memory support;
2. `request_runtime_state` for reconnectable replicas;
3. `open_pane` with the validated size and borrowed launch request.

The runtime receive task starts only after all three sends complete. A reply
cannot therefore race an unregistered continuation or an incomplete handshake.

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
- `client startup registers its handshake before arming event sources` crosses
  a real socketpair and proves the continuation, three ordered messages,
  geometry, launch arguments and receive token.
- `runtime bootstrap emits its three frames in causal order` proves the bounded
  transport encoding independently of startup orchestration.
- Resize, capability, telemetry and reload lifecycle tests prove their own
  scheduling-token cleanup and failure rules.
