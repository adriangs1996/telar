# Host input to screen

This flow starts when bytes arrive from the real terminal. It has two outcomes:
a configured sequence becomes a Telar action, or semantic input is encoded for
the focused child. Only the second branch crosses into the runtime. If the child
then emits output, that output returns through VT state and the client renderer.

## Overview

```text
host TTY bytes
      |
      v
Client.handleHostInput
      |
      v
keybind.Router.feed -> term.parse -> Router.routeKey
      |
      +---------------- configured sequence ----------------+
      |                                                      |
      v                                                      v
InputHandler.key / forward                         InputHandler.action
      |                                                      |
input.host.encodeKey                              native / Lua / plugin action
      |                                                      |
Client.enqueueInput                              consumed by Telar
      |
Outbox.encodeNext -> schema.pane_input -> socket
      |
      v
Runtime.run -> application.handle(.client_message) -> ClientEvents.handleMessage
      |
Application.dispatchClientMessage
      |
Pane input queue -> writePaneInput -> child PTY
      |
      | child emits output
      v
application.handle(.pane_output) -> PaneEvents.Pipeline -> Pane.ingest
      |
application.handle(.pane_ingested) -> pane ingest Coordinator -> Application.pump
      |
Attachment.prepareNextCells -> cell.Sync.prepare -> schema.pane_frame -> socket
      |
      v
Client.handleServerEvent -> handleServerMessage -> handlePaneFrame
      |
Client.presentDue -> Client.present -> presentation.Screen.flush
      |
      v
host TTY bytes
```

## 1. Host terminal entry

`client.run` in `src/frontend/client/root.zig` opens `platform.Tty`, schedules
`readInput`, and classifies its completion as `.input`. The event loop delegates
that completion to `Client.handleHostInput`.

`Client.handleHostInput` owns this entrypoint's ordering:

1. release the outstanding-read flag;
2. stop on EOF;
3. record input activity for media pacing;
4. call `keybind.Router.feed` with an `InputHandler`;
5. request a draw if routing changed client state;
6. schedule input and binding deadlines;
7. schedule the next TTY read.

The router is in `src/frontend/input/keybind.zig`. `Router.feed` buffers split
terminal sequences, `term.parse` produces semantic events, and `routeKey`
classifies a key against the compiled keymap. The configured prefix enters a
persistent router state and therefore schedules no binding deadline. Escape
cancels that state; an unmatched suffix clears it without forwarding either
key. Partial global sequences retain the configured binding timeout.

## 2A. Telar action branch

A complete configured sequence returns `.action` from `Router.routeKey`.
`Router.drain` calls `InputHandler.action` in
`src/frontend/client/root.zig`; it does not forward the matched bytes.

`InputHandler.action` separates three action sources:

- built-in actions go to `InputHandler.applyNativeAction`;
- explicit Lua callbacks run in the bounded client-owned config VM and return
  semantic effects;
- plugin actions schedule an isolated worker and apply its validated semantic
  effects later through `.plugin_result`.

Actions may mutate disposable client state or enqueue a typed runtime request.
They never call runtime internals. The unit test `a configured sequence runs
once and does not reach the pane` in `src/frontend/input/keybind.zig` proves
that the matched branch is consumed.

## 2B. Pane input branch

An unmatched semantic key reaches `InputHandler.key`. It selects the focused,
attached pane and calls `input.host.encodeKey` from
`src/frontend/input/host.zig`. Encoding uses the pane's last acknowledged
cursor/application, modify-key and bracketed-paste modes; host bytes are not
copied blindly into the child.

### Modified Enter

The host session requests Kitty keyboard disambiguation. The parser recognizes
modified Enter in both CSI-u and xterm modifyOtherKeys reports. A bare LF stays
Ctrl+J, so a host mapping that sends LF for multiline input is not rewritten to
Enter.

The runtime reads keyboard flags from the pane's VT and publishes them in
`pane_frame.input_modes`. The client uses them when encoding Enter:

- Kitty flags preserve modifiers as CSI-u. Plain Enter remains CR unless the
  child requests all keys as escape codes.
- xterm modifyOtherKeys mode 2 preserves modifiers in its numeric encoding.
- A child with neither mode active receives the legacy Enter encoding.

The application decides whether Shift+Enter inserts a newline. Telar does not
infer this from agent detection or inject a paste. A host that sends the same CR
for Enter and Shift+Enter provides no modifier to preserve.

Keyboard mode stacks belong to the runtime VT, including separate main and
alternate screens. Snapshots and mode-only frame updates rebuild the client's
copy after changes or reattachment. The two extra frame bytes and fixed input
buffers add no allocation or queue to the interactive path.

The encodings follow the
[Kitty keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/) and
[xterm key modifier controls](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html).

### Enqueueing input

`InputHandler.sendPaneBytes` then calls, in order:

1. `Client.enqueueInput`;
2. `client.Outbox.pushInput` in `src/frontend/client/outbox.zig`;
3. `Client.pumpOutbox`;
4. `Outbox.encodeNext`;
5. `schema.encodePaneInput` in `src/core/schema/root.zig`;
6. `core.transport.SocketChannel.send` in
   `src/core/transport/root.zig`.

The outbox is bounded, owns copied input bytes and coalesces adjacent input for
the same pane. Only one socket send is in flight.

## 3. Runtime input entry

`receiveSession` completes as `.client_message`. `Runtime.run` delegates it
through `application.handle` to `Dispatcher.handleMessage` in
`src/backend/runtime/application/event_dispatcher/client.zig`. That adapter
resolves the client generation, decodes the message, establishes the connection
role, calls `Application.dispatchClientMessage`, pumps pending responses and
schedules the next socket read.

`RequestDispatcher.dispatch` in
`src/backend/runtime/application/request_dispatch.zig` routes `.pane_input`
through its request-scoped controller:

1. resolves the client's attachment and rejects stale or exited panes;
2. copies the bytes into the best-effort history observer;
3. appends them to the pane's bounded input queue;
4. asks `operation_scheduler.zig` to schedule pane input.

`PaneEvents.Io.scheduleInput` permits one in-flight write per pane.
`writePaneInput` serializes PTY writes with terminal-query responses and writes
the bytes to the child PTY. Its `.pane_input_written` completion consumes the
queue prefix and schedules the next chunk. A blocked pane write does not block
the event loop or another pane.

## 4. Child output and VT ingestion

The child may echo the input, repaint, emit unrelated output, or emit nothing.
There is no assumption that one key produces one frame.

`readPane` completes as `.pane_output`, which delegates to
`Pipeline.handle` in
`src/backend/runtime/entrypoints/events/pane/output.zig` through
`application/event_dispatcher/pane/pipeline.zig`. The pipeline:

1. marks EOF or failure as completed output;
2. feeds copies to the observation and media queues;
3. schedules `ingestPane` on the interactive ingest actor.

`ingestPane` calls `Pane.ingest` in `src/backend/pane/root.zig`. The pane feeds
the bytes to its `vt.Terminal`, snapshots child input modes and marks its cell
projection dirty. VT is the only component that interprets child escape
sequences.

The `.pane_ingested` completion delegates to `Coordinator` in
`src/backend/runtime/entrypoints/events/pane/ingest.zig`. It applies deferred
resize state, schedules terminal responses and the next PTY read, then calls
`Application.pumpAll`.

## 5. Runtime frame publication

`Application.pump` publishes a pane only after ingestion is complete and only when
that client's prior frame has been acknowledged. `Delivery.prepare` selects
the attachment cell lane and calls `Attachment.prepareNextCells`. The internal
`cell.Sync.prepare` in `src/backend/runtime/attachment/cell.zig` renders the
pending VT state, computes a bounded cell diff against that attachment's
acknowledged buffer and calls `schema.encodePaneFrame`. `startSessionSend`
writes the `.pane_frame` message to that client. Intermediate visual states may
be folded; they are not queued as a replay.

## 6. Client frame and host presentation

The client socket read completes at `Client.handleServerEvent`. That entrypoint
decodes the message, accounts flow-control credits, delegates to
`Client.handleServerMessage`, and schedules the next read.

The `.pane_frame` case calls `Client.handlePaneFrame`, which validates the base
frame, applies spans to the disposable workspace model, updates scroll and
input-mode state, and requests a paced draw.

The `.draw` event calls `Client.handleDrawEvent`, then `Client.presentDue` and
`Client.present`:

1. `workspace.multiplexer.Model.renderThemed` composes panes into the screen
   back buffer;
2. `client.View.render` composes Telar chrome;
3. `flushScreen` calls `presentation.Screen.flush` in
   `src/frontend/presentation/screen.zig`;
4. the screen emits the minimal terminal diff and flushes the host writer;
5. the client enqueues `.frame_ack` only after presentation.

## Proof

- `a configured sequence runs once and does not reach the pane` in
  `src/frontend/input/keybind.zig` proves the Telar-action split.
- The persistent-prefix, invalid-suffix, Escape-cancellation, and global-timeout
  tests in the same file prove that prefix mode has no timing window without
  changing global multi-key sequence recovery.
- `unbound input is byte-for-byte transparent` and the terminal-sequence split
  tests in the same file prove parser and routing boundaries.
- `cursor keys follow the focused child's mode` in
  `src/frontend/input/host.zig` proves semantic child encoding.
- The modified-Enter parser and router tests cover both host encodings,
  malformed reports and every byte boundary. The encoder tests cover modifier
  combinations, protocol precedence, plain Enter, LF and bounded output.
- `host Enter variants use the keyboard modes received in a pane frame` in
  `src/frontend/client/client_test.zig` proves frame decoding, normal key
  routing and the outgoing `pane_input` bytes.
- `modified Enter follows child keyboard negotiation through the PTY` in
  `src/transport_integration_test.zig` proves that a real child can enable
  Kitty, switch to modifyOtherKeys and return to legacy mode while receiving
  the corresponding bytes.
- `PTY input remains live while the bounded ingest actor is occupied` in
  `src/transport_integration_test.zig` proves that input does not wait for VT
  ingestion.
- `input to one pane flows while another pane's PTY is wedged` in the same file
  proves per-pane input isolation.
- The pane frame, reconnect and independent-acknowledgement integration tests
  in `src/transport_integration_test.zig` prove publication and client-specific
  recovery.
