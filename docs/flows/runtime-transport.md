# Client runtime transport

This flow starts when a connected client bootstraps its runtime session, or
when either side completes one framed message. The client owns bounded buffers
and queue state. The runtime remains the authority for panes, workspaces and
terminal state.

## Boundary

`connection/RuntimeTransportState` owns the client side of runtime I/O:

- one borrowed `SocketChannel` for the client's lifetime;
- one receive buffer and one send buffer, each exactly
  `core.transport.max_frame_size` bytes;
- one `core.transport.read_buffer_size` read-ahead buffer bound to the
  channel, so a burst of small runtime messages costs one `read` instead of
  two per message and the length prefix never costs its own syscall. The
  runtime binds the same kind of buffer to each client session;
- one allocation-free `Outbox` with fixed message and copied-byte storage;
- one receive token, while `Outbox` owns the single send token.

The state does not own request correlation. `connection/LifecycleState` decides
which typed continuation may consume a reply. Transport only preserves framed
delivery, bounded storage and I/O ordering. See
[Client request lifecycle](request-lifecycle.md).

`AttachedClient.receiveRuntime` and `completeRuntimeSend` coordinate I/O
completion with graphics credits, host input and server-message dispatch.
`TelemetryState.recordMessage` owns the received-message counters and decode
latency. Consumers read outbound counters directly from `Outbox.snapshot`.

`connection/RuntimeTransportState.zig` owns connection buffers, framing and
transfer reservations. It knows neither `AttachedClient` nor `TransportDriver`.
`Outbox` owns copied messages, capacity and folding rules.

`AttachedClient.sendRuntime` and its typed variants copy messages into the
outbox and call the private `startRuntimeSend`. Callers supply only the message.
Pane input uses the existing `core.PaneInput` value, including bounded batches
when it exceeds one slot. `startRuntimeRead` and `startRuntimeSend` reserve
transport storage and activate the client's driver, releasing the reservation
if scheduling fails. Native transport ports bind directly to `NativeLoop`.

## Bootstrap

After host negotiation, `RuntimeTransportState.bootstrap` admits these frames
atomically to the ordinary outbox, in order:

1. `configure_graphics`, so the runtime knows whether it may offer shared
   memory resources;
2. `configure_terminal_colors`, so terminal queries use the host defaults;
3. `request_runtime_state`, so reconnectable replicas can be rebuilt.

Bootstrap only queues messages. The GUI calls `AttachedClient.startRuntimeIo`
to activate the receive loop before starting the queued send. The TUI finishes its color probes before queuing the
same bootstrap. The send actor writes independently of reception. The initial
runtime layout determines the subsequent `open_pane` transaction.

## Outbound path

```text
concrete client operation
       |
AttachedClient.sendRuntimeRequest -> AttachedClient.sendRuntime
       or AttachedClient.sendRuntimeInput
       |
Outbox copies and folds bounded data
       |
AttachedClient.startRuntimeSend()
       |
Outbox.beginSend -> schema encoder -> inbox producer reservation -> SocketChannel.send
       |
ClientEvent.sent
       |
AttachedClient.completeRuntimeSend
       |
Outbox.finishSend -> queueGraphicsCredits -> startRuntimeSend -> resume host input
```

`Outbox.beginSend` lends the shared send buffer to one write actor. No producer
can mutate the head or reuse that buffer until `.sent` releases the claim.
Queue insertion may fold pane input, resize and frame acknowledgements only
where their ordering rules permit it.

A full outbox stops new host TTY reads. A successful send removes one message,
pumps its successor and asks `host_inputs` to resume only if capacity still
exists. Request correlation rolls back when an enqueue fails; transport does
not invent or consume continuations.

Graphics memory credit follows the same queue. The graphics store retains a
credit until the private `queueGraphicsCredits` inserts its complete message.
That method never starts I/O. Receive and send completions call it before
explicitly starting the next send; presentation and other credit-release paths
use `flushGraphicsCredits`, which queues credits and then starts delivery.
Saturation delays credit without losing it.

## Inbound path

```text
SocketChannel.receive
       |
RuntimeMessage.decode on the receiving worker
       |
reserved inbox slot -> ClientEvent.server -> consumer dispatch
       |
AttachedClient.receiveRuntime
       |
AttachedClient.handleServerMessage
       |
concrete client operation -> ClientModel or disposable resources
       |
graphics credit flush -> next runtime read
```

`AttachedClient.receiveRuntime` releases the receive token before inspecting
the result. It records bounded decode telemetry, dispatches the message and rearms
the read after every non-terminal result. `runtime_stopping`, a client exit
outcome or an error leaves no new read behind.

Transport does not inspect a decoded message after dispatch. Message-specific
recovery, user notification and last-resort error reporting belong to the
selected operation; in particular, `request_failures` owns reporting the
runtime's bounded rejection text.

Decoded slices borrow the receive buffer only for this entrypoint. Operations
must copy any bytes that outlive dispatch. A new read starts only
after dispatch and credit handling finish, so it cannot overwrite borrowed
wire data early.

## Destruction and failures

The host closes its inbox and joins producers before `RuntimeTransportState.deinit` frees either frame
buffer. The caller still owns and closes the `SocketChannel` after the owning host loop
returns.

If inbox admission or task creation refuses a read or write actor, transport releases the token it
reserved. A completed socket error also releases its token, retains bounded
queue ownership for cleanup and propagates the error. Telar does not retry an
uncertain partial socket write inside the same client session. Dispatch errors
propagate without transport classifying their original message.

## Validation

- Tests in `AttachedClient.zig` exercise rejected read/write scheduling, copied
  input batches surviving rejected sends, queue saturation, retry without
  duplicate reservations, and preservation of queued frame order.
- `src/client/connection/runtime_transport.zig` checks partial-allocation cleanup
  and the exact three-frame bootstrap order over a real socketpair.
- `src/model/connection/outbox_support.zig` proves one send claim, completion on success
  and failure, copied payload ownership, folding rules and saturation bounds.
- `runtime reads own one token and do not rearm after shutdown` in
  `src/frontend/client/tests/` crosses the real framed socket and
  proves rearming, terminal shutdown and error cleanup.
- `host input reads pause at outbox capacity and resume with one token` proves
  that a real send completion recovers TTY capacity without duplicate reads.
- `graphics credits remain owned until the outbox accepts them` proves credit
  retention across saturation and transfer after one slot opens.
