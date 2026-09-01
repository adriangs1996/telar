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
keybind.Router.feed -> term.parse -> binding lease -> Router.routeKey
      |
      +---------------- configured sequence ----------------+
      |                                                      |
      v                                                      v
InputHandler.key / forward / mouse                 InputHandler.action
      |                                                      |
key_routing / pointer_routing                   action_routing adapter
      |                                                      |
application lease / owner handler             ActionRoutingHandler
      |                                                      |
pane_inputs when child-owned                  native / Lua / plugin action
      |                                                      |
PaneInputHandler                                      consumed by Telar
      |
ClientModel.planPaneInput -> input.host.encodeKey
      |
SetPaneViewportHandler(.bottom)
      |
runtime_transport.enqueueInput
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
runtime_transport.handleRead -> server_messages -> pane_frames
      |
presentation_lifecycle.observe -> Presenter.presentDue -> presentation.Screen.flush
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
5. advance the visible input-routing revision when prefix state changed;
6. synchronize input and binding deadlines;
7. schedule the next TTY read.

After the entrypoint returns, `client_events` publishes `ClientModel.Version`
and `PresentationIngress`. The latter contains the disposable view-interaction
and visible input-routing revisions. The presenter schedules a paced draw when
any observed value changed.

The router is in `src/frontend/input/keybind.zig`. `Router.feed` buffers split
terminal sequences, `term.parse` produces semantic events, and `routeKey`
classifies a key press against the compiled keymap. A fixed physical-key lease
keeps repeat and release with the press's binding or application owner. The
configured prefix enters a
persistent router state and therefore schedules no binding deadline. Escape
cancels that state; an unmatched suffix clears it without forwarding either
key. Partial global sequences retain the configured binding timeout.

`host_inputs.handleInputTimeout` and `handleBindingTimeout` release their
worker token before asking the router to expire partial state. Both paths reuse
the same input-routing revision and timer synchronization as a TTY read.

Each deadline uses `deadline_timer.Scheduler`. It stores one atomic absolute
deadline, one wake event and one pending worker. Replacing or removing a
deadline wakes that worker instead of queueing another. A configuration reload
compiles a complete replacement router, swaps it through
`State.replaceRouter`, inherits active physical leases and clears both old
deadlines. A new partial sequence
can then wake the retained workers with the replacement timeout; it never
waits for the old configuration's deadline.

## 2A. Telar action branch

A complete configured sequence returns `.action` from `Router.routeKey`.
`Router.drain` calls `InputHandler.action` in
`src/frontend/client/input_handler.zig`; it does not forward the matched bytes.

`InputHandler.action` delegates the matched value to `action_routing`. The
adapter snapshots prompt and copy-mode authority, then
`ActionRoutingHandler` classifies three action sources:

- built-in actions go to the shared `client_actions.apply` adapter and its
  `NativeActionHandler` preflight;
- explicit Lua callbacks go through `lua_actions` and `LuaActionHandler`, then
  return semantic effects or semantic input;
- plugin actions enter `plugin_actions.start`, then apply a current authorized
  semantic batch through the same dispatcher after `.plugin_result`. See
  [Plugin action](plugin-action.md) for its lifecycle and authority checks.

An active name prompt suppresses every source before its first effect. Native
actions from host bindings, validated Lua batches and authorized plugin batches
share `NativeActionHandler`: active copy mode exits before every action except
copy-mode entry, then the adapter translates the action to its concrete use
case. A Lua expression may return semantic keys or bounded paste. Keys re-enter
`KeyRoutingHandler`; paste enters `PaneInputHandler` only when copy mode is not
active. The adapter retains no returned slice after the synchronous call.
Re-entered owners publish their own semantic or disposable revision.

The Lua branch does not expose the VM, registry or diagnostic storage to input
routing. See [Lua action](lua-action.md) for callback context, complete batch
validation, expression routing and failure presentation.

The detach action delegates to `client_detachments.apply`, which closes
tab-owned paste and focus state before detaching every runtime pane. See
[Client detach](client-detach.md) for ordering and failure semantics.

The notification action delegates wire translation, request correlation and
owned outbox delivery to `notifications.requestDelivery`. See
[Notifications](notifications.md) for request and report handling.

Actions may mutate disposable client state or enqueue a typed runtime request.
They never call runtime internals. The unit test `a configured sequence runs
once and does not reach the pane` in `src/frontend/input/keybind.zig` proves
that the matched branch is consumed.

## 2B. Key and pane input branch

An unmatched semantic key or replayed byte slice reaches `InputHandler`, which
delegates it to `key_routing`. `KeyRoutingHandler` selects one attachment
modal, name prompt, copy-mode or pane owner. A second fixed lease retains that
application owner for the physical lifecycle; pane ownership stores the exact
`PaneId`, not current focus. Only a pane-owned value enters
`PaneInputHandler`. See [Key routing](key-routing.md) for capture, priority,
failure and `Ctrl+V` follow-up policy.

`PaneInputHandler` resolves an attached target through
`ClientModel.planPaneInput` and calls `input.host.encodeKey` from
`src/frontend/input/host.zig` for semantic keys. Encoding uses the pane's last
acknowledged cursor/application, modify-key and bracketed-paste modes. Replayed
byte slices have already passed parser and binding classification before they
enter the bounded pane-input bytes path.

The pane-input boundary also owns raw routed chunks, Lua paste,
alternate-scroll cursor sequences and SGR mouse reports. Streamed paste first
passes through `PasteRoutingHandler`, which assigns every phase to one prompt
or pane owner. A pane-owned start then enters `PanePasteHandler`, which captures
one pane and reuses pane input for every chunk and marker. See
[Pane input](pane-input.md) for ownership, target, session, viewport, failure
and telemetry policy.

## 2C. Pointer interaction branch

`InputHandler.mouse` delegates to `pointer_routing`. The adapter records host
telemetry, rejects prompt-owned input or an absent active model, and converts
supported host pixels to cells. `PointerRoutingHandler` gives copy mode, the
view and pane input exclusive refusal in that order. It knows their outcomes,
but it does not read any model or view representation.

`copy_mode_pointer` resolves a fixed copy and geometry snapshot;
`CopyModePointerHandler` consumes every pointer event while copy mode is active
and selects only bounded vertical movement or exit. Only an `unowned` result
reaches `View.handleMouse`. See [Copy mode](copy-mode.md).

`View.handleMouse` returns one `view_interaction.Command`. The command contains
one exclusive semantic intent plus layout and pointer-capture facts. Hover,
sidebar scroll and attachment-modal changes advance `View.interactionVersion`.
The view does not select tabs, focus panes, start prompts or navigate
notifications.

During the resulting draw, the view maps semantic hover to one bounded mouse
pointer shape. Clickable chrome uses `pointer`, the sidebar separator and its
active drag use `ew-resize`, and pane content or passive chrome restore the
terminal default. Copy mode also restores the default because it owns every
pointer event before the view. The default is emitted explicitly rather than as
an empty reset so terminals implementing only CSS shape names restore it too.
`presentation.Screen` emits OSC 22 in the synchronized frame only when that
shape differs from the last successful flush.
A failed flush marks it unknown so recovery re-emits it, while the platform
leave sequence restores the default before leaving the alternate screen.
Unsupported terminals ignore the OSC sequence. This state is per client,
fixed-size and allocation-free.

`view_interactions.apply` wires that command to
`DispatchViewInteractionHandler`. The application handler applies the semantic
intent before layout delivery and returns `Outcome`. The adapter maps the
intent to the existing sidebar, workspace-list, agent-navigation,
tab-selection, pane-focus, name-prompt, workspace-handoff or notification use
case. For a layout change, the application handler invalidates physical
graphics placements before offering the original active model's attached pane
geometry through separate ports. The adapter implements each operation but
does not choose their order.

Tab selection and agent navigation consume the triggering pointer event.
Explicitly consumed view chrome does the same. Pane focus remains routable so
the newly focused child receives the press after focus resources commit. If an
effect fails, dispatch stops before later effects and `InputHandler` does not
forward the event. Otherwise `InputHandler` forwards only events that remain
inside the workbench. It delegates them to `pane_mouse_inputs` without reading
pane geometry or child mouse modes. `multiplexer.Model.planPaneMouse` resolves
the pane snapshot, `PaneMouseHandler` chooses one viewport, alternate-scroll
or report effect, and the adapter applies it through the existing viewport and
pane-input use cases. See [Pane mouse input](pane-mouse-input.md).

The command and handler use fixed value types and allocate no memory. Unit
tests in `application/view_interaction.zig` prove intent-before-invalidation-
before-geometry order, layout-only delivery, partial failure boundaries and
capture policy. View tests prove hit-to-intent translation. Client tests prove
sidebar-agent handoff, notification activation and focus-before-press
forwarding through the complete input entrypoint.

### Modified Enter

The host session pushes Kitty flags 7: key disambiguation, event types and
alternate key codes. The parser accepts alternate codepoint fields and explicit
press, repeat and release suffixes across arbitrary TTY chunks. Every report
retains its logical key, phase and stable physical identity. The parser also
recognizes xterm
modifyOtherKeys reports. A bare LF stays Ctrl+J, so a host mapping that sends LF
for multiline input is not rewritten to Enter.

Two bounded, allocation-free lease tables route that lifecycle. The native
router assigns the press to a Telar binding or the application. The application
then assigns it to a modal, prompt, copy mode or exact pane. Repeat and release
never repeat either decision. A binding-owned release cannot cancel a pending
prefix, and a pane-owned release cannot move when focus or modal authority
changes. A duplicate press replaces stale ownership after a lost release.
Saturation drops the new lifecycle and increments `key_lease_overflows`.

Pane children receive a stable compatibility profile:

- `TERM=xterm-256color`
- `COLORTERM=truecolor`
- `TERM_PROGRAM=ghostty`
- `TELAR_TERM_PROGRAM=telar`

Some applications gate extended keyboard negotiation on a known
`TERM_PROGRAM`. Telar implements the Ghostty keyboard contract, so it advertises
that compatibility identity while retaining its own identity separately.
Inherited `TERM_PROGRAM_VERSION`, `GHOSTTY_RESOURCES_DIR` and `TELAR_SOCKET`
are removed before pane-specific overrides are applied.

The runtime reads keyboard flags from the pane's VT and publishes them in
`pane_frame.input_modes`. The client uses them when encoding Enter:

- Kitty flags preserve modifiers as CSI-u. Plain Enter remains CR unless the
  child requests all keys as escape codes. Event-aware children use the
  default press encoding and receive explicit repeat and release suffixes;
  legacy children receive repeats as presses and no release bytes.
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

For keyboard presses, repeats and paste sources, `PaneInputHandler` first executes
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

A release never changes the viewport. It is encoded only when the exact pane's
acknowledged Kitty flags request event types; otherwise it is a zero-byte no-op
and never enters the outbox.

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

The client socket read completes at `runtime_transport.handleRead`. That
entrypoint releases its read token, decodes the message, delegates to
`server_messages.handleServerMessage`, accounts flow-control credits and
schedules the next read only for a non-terminal outcome. See
[Client runtime transport](runtime-transport.md) for buffer ownership, queue
capacity and socket failure policy.

The `.pane_frame` case delegates through the `pane_frames` adapter and
`ApplyPaneFrameHandler` to `ClientModel.applyPaneFrame`. The model validates the
base, applies spans to the disposable workspace, reconciles scroll, input modes
and copy state, then publishes `ClientModel.Version.frame`. The exact commit
passes through `DeliverPaneFrameHandler` before the adapter updates graphics
and active-pane resources. A broken base requests a fresh snapshot without
changing state.

After dispatch, `client_events` calls `presentation_lifecycle.observe`.
`Presenter` detects the new frame revision and schedules the paced draw; the
frame use case does not decide whether to paint. See
[Client presentation lifecycle](presentation-lifecycle.md) for observation,
coalescence, task tokens and media pacing.

The `.draw` event calls `presentation_lifecycle.handleDraw`, then
captures an immutable `presentation_projection` and calls
`Presenter.presentDue`:

1. the presenter-owned `workspace.multiplexer.Compositor` composes the
   immutable active-tab model into the screen back buffer;
2. `client.View.render` composes Telar chrome;
3. `flushScreen` calls `presentation.Screen.flush` in
   `src/frontend/presentation/screen.zig`;
4. the screen emits the minimal terminal diff and flushes the host writer;
5. the lifecycle commits the exact presented pane damage;
6. the client enqueues `.frame_ack` only after presentation.

## Proof

- `src/frontend/client/resources/deadline_timer.zig` proves replacement, removal,
  parking, wakeup and token release for successful and failed workers.
- `src/frontend/client/controllers/input/host_inputs.zig` proves owned timeout configuration,
  router replacement without duplicate workers and prefix-status projection.
- `host input reads pause at outbox capacity and resume with one token` in
  `src/frontend/client/tests/transport.zig` proves bounded backpressure, one real
  socket completion and one resumed TTY read token.
- `a configured sequence runs once and does not reach the pane` in
  `src/frontend/input/keybind.zig` proves the Telar-action split.
- `src/frontend/client/application/input/action_routing.zig` proves prompt
  suppression, source selection, Lua router control, input reinjection and
  selected-effect failure ordering.
- `src/frontend/client/application/input/pointer_routing.zig` proves copy, view and
  pane owner ordering before any pointer effect reaches a child.
- `mouse pointer distinguishes clickable chrome panes and sidebar resizing` in
  `src/frontend/client/presentation/view.zig` proves the semantic hover mapping.
- `mouse pointer changes fold until a shape or recovery changes` in
  `src/frontend/presentation/screen.zig` proves OSC 22 coalescence and recovery;
  the platform sequence test proves exit restores the default before leaving
  the alternate screen.
- `host pointer shape follows semantic hover through paced presentation` in
  `src/frontend/client/tests/presentation.zig` proves the complete mouse-router
  to host-flush path with substituted terminal resources.
- The configured-action, Lua key and Lua paste tests in
  `src/frontend/client/tests/configuration.zig` prove the adapter against prompt,
  copy-mode and acknowledged pane-mode authority.
- The persistent-prefix, invalid-suffix, Escape-cancellation, and global-timeout
  tests in the same file prove that prefix mode has no timing window without
  changing global multi-key sequence recovery.
- `unbound input is byte-for-byte transparent` and the terminal-sequence split
  tests in the same file prove parser and routing boundaries.
- The physical lifecycle tests in `src/frontend/input/keybind.zig` prove
  binding/application ownership, prefix release, configuration replacement and
  fail-closed saturation.
- `cursor keys follow the focused child's mode` in
  `src/frontend/input/host.zig` proves semantic child encoding.
- The modified-Enter parser and router tests cover both host encodings,
  malformed reports and every byte boundary. The encoder tests cover modifier
  combinations, physical lifecycles, alternate key codes, legacy release
  suppression, protocol precedence, plain Enter, LF and bounded output.
- `host Enter variants use the keyboard modes received in a pane frame` in
  `src/frontend/client/tests/input.zig` proves frame decoding, normal key
  routing and the outgoing `pane_input` bytes.
- `releasing the physical prefix preserves its logical sequence through client routing`
  in the same file proves the complete host-parser-to-action lease path.
- `modified Enter follows the compatibility profile and child keyboard negotiation through the PTY` in
  `src/transport_integration_test.zig` proves that a real child can enable
  Kitty flags 7, switch to modifyOtherKeys and return to legacy mode while
  receiving the corresponding bytes.
- `PTY input remains live while the bounded ingest actor is occupied` in
  `src/transport_integration_test.zig` proves that input does not wait for VT
  ingestion.
- `input to one pane flows while another pane's PTY is wedged` in the same file
  proves per-pane input isolation.
- The pane frame, reconnect and independent-acknowledgement integration tests
  in `src/transport_integration_test.zig` prove publication and client-specific
  recovery.
