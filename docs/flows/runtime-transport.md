# Client runtime transport

This flow starts when a connected client bootstraps its runtime session, or
when either side completes one framed message. The client owns bounded buffers
and queue state. The runtime remains the authority for panes, workspaces and
terminal state.

## Boundary

`connection/RuntimeTransportState`, held in `Client.runtime_transport`,
owns the client side of runtime I/O:

- one borrowed `SocketChannel` for the client's lifetime;
- one receive buffer and one send buffer, each exactly
  `core.max_frame_size` bytes;
- one `core.read_buffer_size` read-ahead buffer bound to the
  channel, so a burst of small runtime messages costs one `read` instead of
  two per message and the length prefix never costs its own syscall. The
  runtime binds the same kind of buffer to each client session;
- one receive token (`receive_pending`) and the decoded message it lends.

The outbound queue is not transport state. It is the model's allocation-free
`Outbox`, `model.to_runtime`, with fixed message and copied-byte storage, and it
owns the single send token.

The state does not own request correlation. `model.request_lifecycle` decides
which typed continuation may consume a reply. Transport only preserves framed
delivery, bounded storage and I/O ordering. See
[Client request lifecycle](request-lifecycle.md).

`runtime_io.receiveRuntime` and `completeRuntimeSend` coordinate I/O
completion with graphics credits, host input and server-message dispatch.
`TelemetryState.recordMessage` owns the received-message counters and decode
latency. Consumers read outbound counters directly from `Outbox.snapshot`.

`connection/RuntimeTransportState.zig` owns connection buffers, framing and
transfer reservations. It knows neither `Client` nor the client
`Message` protocol. `Outbox` owns copied messages, capacity and folding rules.

`runtime_io.sendRuntime` and its typed variants copy messages into
`model.to_runtime` and call the private `startRuntimeSend`. Callers supply only the message.
Pane input uses the existing `core.PaneInput` value, including bounded batches
when it exceeds one slot. `startRuntimeRead` and `startRuntimeSend` reserve
transport storage and start a worker with `client.workers.start`
(`.runtime_read` or `.runtime_send`), releasing the reservation if the adapter
refuses the job. `job_runner.run` performs the read or write on the worker and
returns `Message.server` or `Message.sent`.

## Bootstrap

When a session starts, `model.to_runtime.pushBootstrap` admits these frames
atomically to the ordinary outbox, in order:

1. `configure_graphics`, so the runtime knows whether it may offer shared
   memory resources;
2. `configure_terminal_colors`, so terminal queries use the client's default
   colors (the window's theme);
3. `request_runtime_state`, so reconnectable replicas can be rebuilt.

Bootstrap only queues messages. `runtime_link` then calls
`runtime_io.startRuntimeIo` to activate the receive loop before starting the
queued send. The send actor writes independently of reception. The initial
runtime layout determines the subsequent `open_pane` transaction.

## Outbound path

```text
concrete client operation
       |
runtime_io.sendRuntimeRequest -> runtime_io.sendRuntime
       or runtime_io.sendRuntimeInput
       |
Outbox copies and folds bounded data
       |
Client.startRuntimeSend()
       |
Outbox.beginSend -> schema encoder -> workers.start(.runtime_send) -> SocketChannel.send
       |
Message.sent -> Client.update
       |
runtime_io.completeRuntimeSend
       |
Outbox.finishSend -> queueGraphicsCredits -> startRuntimeSend -> model.to_host.resume_input
```

`Outbox.beginSend` lends the shared send buffer to one write actor. No producer
can mutate the head or reuse that buffer until `.sent` releases the claim.
Queue insertion may fold pane input, resize and frame acknowledgements only
where their ordering rules permit it.

A full outbox stops the adapter from taking more input. A successful send
removes one message, pumps its successor and sets `model.to_host.resume_input`;
the adapter drains it after the event. `GuiAdapter.resumeInput` drains the
window's queued input again only if capacity still exists; the headless client
reads its next stdin line under the same capacity check. Request correlation rolls back when an enqueue fails; transport does
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
RuntimeTransportState.read -> RuntimeMessage.decode on the receiving worker
       |
reserved inbox slot -> Message.server -> Client.update
       |
runtime_io.receiveRuntime
       |
runtime_messages.handleServerMessage
       |
concrete client operation -> ClientModel or disposable resources
       |
graphics credit flush -> next runtime read
```

`runtime_io.receiveRuntime` releases the receive token before inspecting
the result. It records bounded decode telemetry, dispatches the message and rearms
the read after every non-terminal result. `runtime_stopping`, a client exit
outcome or an error leaves no new read behind.

Transport does not inspect a decoded message after dispatch. Message-specific
recovery, user notification and last-resort error reporting belong to the
selected operation; in particular, `request_failure.failRuntimeRequest` owns
reporting the runtime's bounded rejection text.

Decoded slices borrow the receive buffer only for this entrypoint. Operations
must copy any bytes that outlive dispatch. A new read starts only
after dispatch and credit handling finish, so it cannot overwrite borrowed
wire data early.

## Destruction and failures

The host closes its inbox and joins producers before `RuntimeTransportState.deinit` frees either frame
buffer. A socket the adapter handed in (tests do) stays the caller's to close;
a socket a connection job produced is the client's, and `Client.deinit`
closes it.

If inbox admission or task creation refuses a read or write actor, transport releases the token it
reserved. A completed socket error also releases its token. A client that
connects by itself (the window or the headless client, `options.machine`
set) then loses the link
instead of failing: see [runtime link](runtime-link.md). A client handed its
socket propagates the error as before. Telar never retries an uncertain
partial socket write inside the same session; a reconnect starts a new
session. Dispatch errors propagate without transport classifying their
original message.

## Validation

- Tests in `Client.zig` exercise rejected read/write scheduling, copied
  input batches surviving rejected sends, queue saturation, retry without
  duplicate reservations, and preservation of queued frame order.
- `src/client/connection/runtime_transport.zig` checks partial-allocation cleanup
  and that a non-reading peer over a real socketpair cannot block receive
  admission or local input.
- `runtime bootstrap queues colors before subscribing to the initial layout` in
  `src/model/connection/Outbox.zig` checks the exact three-frame bootstrap order.
- `src/model/connection/outbox_support.zig` proves one send claim, completion on success
  and failure, copied payload ownership, folding rules and saturation bounds.
- `runtime reads own one token and do not rearm after shutdown` in
  `src/client_tests/transport.zig` crosses the real framed socket and
  proves rearming, terminal shutdown and error cleanup.
- `host input reads pause at outbox capacity and resume with one token` proves
  that a real send completion sets `resume_input` and restores one slot.
- `graphics credits remain owned until the outbox accepts them` proves credit
  retention across saturation and transfer after one slot opens.
