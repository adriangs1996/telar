# Client runtime transport

This flow starts when a connected client bootstraps its runtime session, or
when either side completes one framed message. The client owns bounded buffers
and queue state. The runtime remains the authority for panes, workspaces and
terminal state.

## Boundary

`runtime_transport.State` owns the client side of runtime I/O:

- one borrowed `SocketChannel` for the client's lifetime;
- one receive buffer and one send buffer, each exactly
  `core.transport.max_frame_size` bytes; the send buffer carries a batch of
  framed messages, so one write may hold every message that fits;
- one `core.transport.read_buffer_size` read-ahead buffer bound to the
  channel, so a burst of small runtime messages costs one `read` instead of
  two per message and the length prefix never costs its own syscall. The
  runtime binds the same kind of buffer to each client session;
- one allocation-free `Outbox` with fixed message and copied-byte storage;
- one receive token, while `Outbox` owns the single send token.

The state does not own request correlation. `request_lifecycle.State` decides
which typed continuation may consume a reply. Transport only preserves framed
delivery, bounded storage and I/O ordering. See
[Client request lifecycle](request-lifecycle.md).

I/O completion orchestration lives in `client/entrypoints/runtime_io.zig`.
It connects transport state to graphics credit, host input and runtime-message
controllers. `connection/runtime_transport.zig` never imports `Client` or a
controller. Existing local aliases named `runtime_transport` in controllers
refer to this event adapter for enqueue and scheduling operations.

## Bootstrap

Before the event loop starts its first read, `client_startup` registers the
initial continuation and asks `State.bootstrap` to send these frames
synchronously through the same send buffer:

1. `configure_graphics`, so the runtime knows whether it may offer shared
   memory resources;
2. `request_runtime_state`, so reconnectable replicas can be rebuilt;
3. `open_pane`, which starts or attaches the initial pane transaction.

After all three writes finish, `client_startup` asks
`runtime_transport.scheduleRead` to reserve the only receive token.

## Outbound path

```text
client slice effect
       |
request_lifecycle.deliver / runtime_transport.enqueueInput
       |
Outbox copies and folds bounded data
       |
runtime_transport.pump
       |
Outbox.beginSend -> schema encoder -> SocketChannel.send
       |
ClientEvent.sent
       |
runtime_transport.handleSent
       |
Outbox.finishSend -> next send -> host input capacity check
```

`Outbox.beginSend` claims every queued message that fits the shared send
buffer, oldest first, encodes each as its own wire frame and lends the batch to
one write actor. No producer can mutate a claimed message or reuse that buffer
until `.sent` releases the claim; messages queued behind the claim still fold.
Queue insertion may fold pane input, resize, viewport and frame
acknowledgements only where their ordering rules permit it.

A full outbox stops new host TTY reads. A successful send removes the claimed
batch, pumps its successor and asks `host_inputs` to resume only if capacity
still exists. The runtime assembles its deliveries the same way: `pump`
prepares and commits payloads behind one another in the session's send buffer
while a maximum frame still fits, stops at a transaction whose completion
must run after the write, and sends the batch with one framed write. Request correlation rolls back when an enqueue fails; transport does
not invent or consume continuations.

Graphics memory credit follows the same queue. The graphics store retains a
credit until `flushGraphicsCredits` inserts its complete message. Saturation
therefore delays credit without losing it.

## Inbound path

```text
SocketChannel.receive
       |
ClientEvent.server
       |
client_events.handle
       |
runtime_transport.handleRead
       |
schema.decodeServer -> server_messages.handleServerMessage
       |
client slice adapter -> ClientModel or disposable resources
       |
graphics credit flush -> next runtime read
```

`handleRead` releases the receive token before inspecting the result. It
records bounded decode telemetry, dispatches the decoded message and rearms
the read after every non-terminal result. `runtime_stopping`, a client exit
outcome or an error leaves no new read behind.

Transport does not inspect a decoded message after dispatch. Message-specific
recovery, user notification and last-resort error reporting belong to the
selected slice adapter; in particular, `request_failures` owns reporting the
runtime's bounded rejection text.

Decoded slices borrow the receive buffer only for this entrypoint. Slice
adapters must copy any bytes that outlive dispatch. A new read starts only
after dispatch and credit handling finish, so it cannot overwrite borrowed
wire data early.

## Destruction and failures

`Client.deinit` cancels its select before `State.deinit` frees either frame
buffer. The caller still owns and closes the `SocketChannel` after `client.run`
returns.

If the select refuses a read or write actor, transport releases the token it
reserved. A completed socket error also releases its token, retains bounded
queue ownership for cleanup and propagates the error. Telar does not retry an
uncertain partial socket write inside the same client session. Dispatch errors
propagate without transport classifying their original message.

## Proof

- `src/frontend/client/runtime_transport.zig` checks partial-allocation cleanup
  and the exact three-frame bootstrap order over a real socketpair.
- `src/frontend/client/outbox.zig` proves the batched send claim, completion
  on success and failure, copied payload ownership, folding rules and
  saturation bounds.
- `runtime reads own one token and do not rearm after shutdown` in
  `src/frontend/client/client_test.zig` crosses the real framed socket and
  proves rearming, terminal shutdown and error cleanup.
- `host input reads pause at outbox capacity and resume with one token` proves
  that a real send completion recovers TTY capacity without duplicate reads.
- `graphics credits remain owned until the outbox accepts them` proves credit
  retention across saturation and transfer after one slot opens.
