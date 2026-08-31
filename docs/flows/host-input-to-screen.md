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
host_inputs.handleRead
      |
      v
keybind.Router.feed -> term.parse -> Router.routeKey
      |
      +---------------- configured sequence ----------------+
      |                                                      |
      v                                                      v
InputHandler.key / forward                         InputHandler.action
      |                                                      |
pane_inputs adapter                               native / Lua / plugin action
      |                                                      |
PaneInputHandler                                  consumed by Telar
      |                                                      |
ClientModel.planPaneInput -> input.host.encodeKey
      |
SetPaneViewportHandler(.bottom)
      |
runtime_transport.enqueueInput
      |
Outbox.encodeNext -> schema.pane_input -> socket
      |
      v
Server.handleClientMessageEvent -> dispatchClientMessage
      |
Pane input queue -> writePaneInput -> child PTY
      |
      | child emits output
      v
Server.handlePaneOutputEvent -> ingestPane -> Pane.ingest
      |
Server.handlePaneIngestedEvent -> Server.pump
      |
runtime.encoder.encodeFrame -> schema.pane_frame -> socket
      |
      v
runtime_transport.handleRead -> server_messages -> pane_frames
      |
Client.observeModel -> Presenter.presentDue -> presentation.Screen.flush
      |
      v
host TTY bytes
```

## 1. Host terminal entry

`client.run` opens `platform.Tty` and gives its read handle to
`host_inputs.State`. That state owns the handle, native router, one read token
and the two replaceable deadline schedulers. Workspace activation and socket
send completion call `host_inputs.scheduleRead`. The scheduler pauses when the
bounded outbox has no capacity and never publishes a second read while one is
pending.

The read completes as `.input`. The event loop delegates it to
`host_inputs.handleRead`, which owns this ordering:

1. release the outstanding-read flag;
2. stop on EOF;
3. record input activity for media pacing;
4. call `keybind.Router.feed` with an `InputHandler`;
5. request a draw for immediate `View` changes that have no model revision;
6. synchronize input and binding deadlines;
7. schedule the next TTY read.

After the entrypoint returns, the event loop publishes `ClientModel.Version`.
The presenter schedules a paced draw when a model-owned slice changed.

The router is in `src/frontend/input/keybind.zig`. `Router.feed` buffers split
terminal sequences, `term.parse` produces semantic events, and `routeKey`
classifies a key against the compiled keymap. The configured prefix enters a
persistent router state and therefore schedules no binding deadline. Escape
cancels that state; an unmatched suffix clears it without forwarding either
key. Partial global sequences retain the configured binding timeout.

`host_inputs.handleInputTimeout` and `handleBindingTimeout` release their
worker token before asking the router to expire partial state. Both paths reuse
the same prefix invalidation, draw request and timer synchronization as a TTY
read.

Each deadline uses `deadline_timer.Scheduler`. It stores one atomic absolute
deadline, one wake event and one pending worker. Replacing or removing a
deadline wakes that worker instead of queueing another. A configuration reload
compiles a complete replacement router, swaps it through
`State.replaceRouter`, and clears both old deadlines. A new partial sequence
can then wake the retained workers with the replacement timeout; it never
waits for the old configuration's deadline.

## 2A. Telar action branch

A complete configured sequence returns `.action` from `Router.routeKey`.
`Router.drain` calls `InputHandler.action` in
`src/frontend/client/input_handler.zig`; it does not forward the matched bytes.

`InputHandler.action` classifies three action sources:

- built-in actions go to the shared `client_actions.apply` dispatcher;
- explicit Lua callbacks go through `lua_actions` and `LuaActionHandler`, then
  return semantic effects or semantic input;
- plugin actions enter `plugin_actions.start`, then apply a current authorized
  semantic batch through the same dispatcher after `.plugin_result`. See
  [Plugin action](plugin-action.md) for its lifecycle and authority checks.

The Lua branch does not expose the VM, registry or diagnostic storage to input
routing. See [Lua action](lua-action.md) for callback context, complete batch
validation, expression routing and failure presentation.

Actions may mutate disposable client state or enqueue a typed runtime request.
They never call runtime internals. The unit test `a configured sequence runs
once and does not reach the pane` in `src/frontend/input/keybind.zig` proves
that the matched branch is consumed.

## 2B. Pane input branch

An unmatched semantic key reaches `InputHandler.key`, which delegates one
input command to the `pane_inputs` adapter. `PaneInputHandler` resolves an
attached target through `ClientModel.planPaneInput` and calls
`input.host.encodeKey` from `src/frontend/input/host.zig`. Encoding uses the
pane's last acknowledged cursor/application, modify-key and bracketed-paste
modes; host bytes are not copied blindly into the child.

The pane-input boundary also owns raw routed chunks, Lua paste,
alternate-scroll cursor sequences and SGR mouse reports. Streamed paste first
passes through `PanePasteHandler`, which captures one pane and then reuses pane
input for every chunk and marker. Prompts, copy mode and an active paste keep
their exact input ownership. See [Pane input](pane-input.md) for target,
session, viewport, failure and telemetry policy.

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

For keyboard and paste sources, `PaneInputHandler` first executes
`SetPaneViewportHandler` with a `.bottom` intent. If the pane is scrolled back,
that use case commits the client viewport, updates graphics visibility and
queues `set_pane_viewport`. The handler then invokes the adapter's send effect,
which calls, in order:

1. `runtime_transport.enqueueInput`;
2. `Outbox.pushInput` inside `runtime_transport.State`;
3. `runtime_transport.pump`;
4. `Outbox.encodeNext`;
5. `schema.encodePaneInput` in `src/core/schema/root.zig`;
6. `core.transport.SocketChannel.send` in
   `src/core/transport/root.zig`.

The outbox is bounded, owns copied input bytes and coalesces adjacent input for
the same pane. Only one socket send is in flight. When the viewport changes,
wire order is `set_pane_viewport` followed by `pane_input`.

## 3. Runtime input entry

`receiveSession` completes as `.client_message`. The runtime loop delegates it
to `Server.handleClientMessageEvent` in `src/backend/runtime/root.zig`. That
entrypoint resolves the client generation, decodes the message, establishes
the connection role, calls `Server.dispatchClientMessage`, pumps pending
responses and schedules the next socket read.

The `.pane_input` case in `Server.dispatchClientMessage`:

1. resolves the client's attachment and rejects stale or exited panes;
2. copies the bytes into the best-effort history observer;
3. appends them to the pane's bounded input queue;
4. calls `schedulePaneInput`.

`schedulePaneInput` permits one in-flight write per pane.
`writePaneInput` serializes PTY writes with terminal-query responses and writes
the bytes to the child PTY. Its `.pane_input_written` completion consumes the
queue prefix and schedules the next chunk. A blocked pane write does not block
the event loop or another pane.

## 4. Child output and VT ingestion

The child may echo the input, repaint, emit unrelated output, or emit nothing.
There is no assumption that one key produces one frame.

`readPane` completes as `.pane_output`, which delegates to
`Server.handlePaneOutputEvent`. The entrypoint:

1. marks EOF or failure as completed output;
2. feeds copies to the observation and media queues;
3. schedules `ingestPane` on the interactive ingest actor.

`ingestPane` calls `Pane.ingest` in `src/backend/pane/root.zig`. The pane feeds
the bytes to its `vt.Terminal`, snapshots child input modes and marks its cell
projection dirty. VT is the only component that interprets child escape
sequences.

The `.pane_ingested` completion delegates to
`Server.handlePaneIngestedEvent`. It applies deferred resize state, schedules
terminal responses and the next PTY read, then calls `Server.pumpAll`.

## 5. Runtime frame publication

`Server.pump` publishes a pane only after ingestion is complete and only when
that client's prior frame has been acknowledged. It calls
`runtime.encoder.encodeFrame` in `src/backend/runtime/encoder.zig`.

`encodeFrame` renders pending VT state through the pane projection, computes a
bounded cell diff against that attachment's acknowledged buffer, and calls
`schema.encodePaneFrame`. `startSessionSend` writes the `.pane_frame` message
to that client. Intermediate visual states may be folded; they are not queued
as a replay.

## 6. Client frame and host presentation

The client socket read completes at `runtime_transport.handleRead`. That
entrypoint releases its read token, decodes the message, delegates to
`server_messages.handleServerMessage`, accounts flow-control credits and
schedules the next read only for a non-terminal outcome. See
[Client runtime transport](runtime-transport.md) for buffer ownership, queue
capacity and socket failure policy.

The `.pane_frame` case delegates through the `pane_frames` adapter and
`ApplyPaneFrameHandler` to `ClientModel.applyPaneFrame`. The model validates the
base, applies spans to the disposable workspace, reconciles scroll, input modes
and copy state, then publishes `ClientModel.Version.frame`. A broken base
requests a fresh snapshot without changing state.

After dispatch, the client loop calls `Client.observeModel`. `Presenter`
detects the new frame revision and schedules the paced draw; the frame use case
does not decide whether to paint.

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

- `src/frontend/client/deadline_timer.zig` proves replacement, removal,
  parking, wakeup and token release for successful and failed workers.
- `src/frontend/client/host_inputs.zig` proves owned timeout configuration,
  router replacement without duplicate workers and prefix-status projection.
- `host input reads pause at outbox capacity and resume with one token` in
  `src/frontend/client/client_test.zig` proves bounded backpressure, one real
  socket completion and one resumed TTY read token.
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
