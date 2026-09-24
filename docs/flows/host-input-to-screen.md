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
host_inputs.handleOwnedRead
      |
      v
host_inputs.feed -> Router.next -> term.parse -> Router.routeEvent
      |
      +---------------- configured sequence ----------------+
      |                                                      |
      v                                                      v
host_inputs.key / mouse                         applyDecision(.action)
      |                                                      |
routeKeyInput / pointer_routing.apply           actions.executeAction
      |                                                      |
physical lease / owner selection             binding authority / copy-mode preflight
      |                                                      |
pane_input.sendPaneInput                  native / Lua / plugin action
      |                                                      |
ClientModel.planPaneInput                                consumed by Telar
      |
encoding_support.encodeKey
      |
pane_viewport.applyPaneViewport(.bottom)
      |
runtime_io.sendRuntimeInput -> model.to_runtime
      |
Outbox.beginSend -> schema.pane_input -> runtime_send worker -> socket
      |
      v
Runtime.run -> Runtime.update(.client_message) -> client_connection.receive
      |
client_request.receive -> pane_input.send
      |
Pane input queue -> pane_input.startInputWrite -> writeInput -> child PTY
      |
      | child emits output
      v
Runtime.update(.pane_output) -> pane_output.receive -> Pane.ingest
      |
inline result or .pane_ingested -> pane_output.finishIngest
      |
Runtime.update flush -> client_delivery.flush -> Delivery.prepare
      |
Attachment.prepareNextCells -> CellSync.prepare -> schema.pane_frame -> socket
      |
      v
runtime_io.receiveRuntime -> handleServerMessage -> receivePaneFrame
      |
pane_frame.receive -> model.to_runtime (.frame_ack)
      |
presentation_lifecycle.observe -> Presenter.presentDue -> presentation.Screen.flush
      |
      v
host TTY bytes
```

## 1. Host terminal entry

`run` in `src/frontend/client/run.zig` opens `platform.Tty` and gives its read
handle to `HostInput` (`terminal.host_input`). That state owns the handle,
native router, one read-pending flag and the two replaceable deadline
schedulers. Workspace activation and socket send completion set
`model.to_host.resume_input`; `host_effects.deliver` then calls
`host_inputs.scheduleRead`. The scheduler pauses when `model.to_runtime` has
no capacity and never publishes a second read while one is pending.

The read completes as `.input`. `events.update` delegates it to
`host_inputs.handleOwnedRead`, which owns this ordering:

1. release the outstanding-read flag;
2. stop on EOF;
3. record input activity for media pacing;
4. pull one decoded event with `Router.next`, resolve its typed decision and
   execute it in `host_inputs` before pulling the next event;
5. advance the visible input-routing revision when prefix state changed;
6. synchronize input and binding deadlines;
7. schedule the next TTY read.

After the inbox turn, `events.update` calls `presentation_lifecycle.observe`,
which publishes `ClientModel.Version` and `PresentationIngress`. The latter contains the disposable view-interaction
and visible input-routing revisions. The presenter schedules a paced draw when
any observed value changed.

The routing implementation is in `src/client/input/GenericRouter.zig`. The TUI
factory in `src/frontend/input/GenericRouter.zig` supplies `term.parse`; its
specialized router's `next` method buffers
split terminal sequences. Decoder-free adapters call `routeEvent` with semantic
keys. Both paths use the same compiled keymap. A fixed physical-key lease
keeps repeat and release with the press's binding or application owner. The
configured prefix enters a
persistent router state and therefore schedules no binding deadline. Escape
cancels that state; an unmatched suffix clears it without forwarding either
key. Partial global sequences retain the configured binding timeout.

`host_inputs.handleInputTimeout` and `handleBindingTimeout` release their
worker token before asking the router to expire partial state. Both paths reuse
the same input-routing revision and timer synchronization as a TTY read.

Each deadline uses `core.DeadlineScheduler`. It stores one atomic absolute
deadline, one wake event and one pending worker. Replacing or removing a
deadline wakes that worker instead of queueing another. A configuration reload
sets `model.to_host.rebind_input`; `host_effects.deliver` compiles a complete
replacement router and swaps it through `HostInput.replaceRouter`, which inherits active physical leases and clears both old
deadlines. A new partial sequence
can then wake the retained workers with the replacement timeout; it never
waits for the old configuration's deadline.

## 2A. Telar action branch

A complete configured sequence returns `.action` from `Router.routeEvent`.
`host_inputs.applyDecision` executes it through `actions.executeAction` and
stops reading the batch on `.stop` or an error. Only successful actions arm
repeat state, using the resulting application's repeat policy.

`actions.executeAction(action, .binding)` checks prompt authority and
selects the operation directly:

- built-in actions perform the copy-mode preflight before dispatching;
- explicit Lua callbacks go through `lua_actions` and `lua_action.evaluateLuaAction`, then
  return semantic effects or semantic input;
- plugin actions enter `plugin_actions.startPluginAction`, then apply a current authorized
  semantic batch through the same dispatcher after `.plugin_result`. See
  [Plugin action](plugin-action.md) for its lifecycle and authority checks.

An active name prompt suppresses configured bindings before their first effect.
Validated Lua batches, authorized plugin batches and palette selections enter
`actions.executeAction(action, .effect)`, retaining the authority of their
caller. Both origins share the native action switch: active copy mode exits
before every native action except copy-mode entry. A Lua expression may return
semantic keys or bounded paste. Keys re-enter
`key_routing.routeKeyInput`; paste enters `pane_input.sendPaneInput` only when copy mode is not
active. The adapter retains no returned slice after the synchronous call.
Re-entered owners publish their own semantic or disposable revision.

The Lua branch does not expose the VM, registry or diagnostic storage to input
routing. See [Lua action](lua-action.md) for callback context, complete batch
validation, expression routing and failure presentation.

The detach action delegates to `tab_removal.detachAllTabs`, which closes
tab-owned paste and focus state before detaching every runtime pane. See
[Client detach](client-detach.md) for ordering and failure semantics.

The notification action delegates wire translation, request correlation and
owned outbox delivery to `notifications.requestNotificationDelivery`. See
[Notifications](notifications.md) for request and report handling.

`scroll-pane-up`, `scroll-pane-down` and the Lua `telar.action.scroll_pane`
constructor enter the focused-pane wheel policy through
`pane_mouse_input.inputPaneMouse`.
The policy selects a three-row viewport change, alternate-screen cursor keys,
or an SGR mouse report according to the child's modes. It never forwards the
binding bytes. Worker plugin effects reject scrolling. See
[Pane mouse input](pane-mouse-input.md) for selection and delivery rules.
The native scroll integration test in `frontend/client/tests/host_interaction.zig`
covers viewport bounds and message order; `frontend/client/tests/input.zig` covers
focus, child modes, default bindings and copy-mode retirement.

Actions may mutate disposable client state or enqueue a typed runtime request.
They never call runtime internals. The unit test `a configured sequence runs
once and does not reach the pane` in `src/frontend/input/keybind.zig` proves
that the matched branch is consumed.

## 2B. Key and pane input branch

An unmatched or replayed semantic key reaches `host_inputs.key`, which
delegates it to `key_routing.routeKeyInput`. That method selects one attachment
modal, name prompt, copy-mode or pane owner. A second fixed lease retains that
application owner for the physical lifecycle; pane ownership stores the exact
`PaneId`, not current focus. Only a pane-owned value enters
`pane_input.sendPaneInput`. See [Key routing](key-routing.md) for capture, priority,
failure and `Ctrl+V` follow-up policy.

`pane_input.sendPaneInput` resolves an attached target through
`ClientModel.planPaneInput` and calls `encoding_support.encodeKey` from
`src/client/input/encoding_support.zig` for semantic keys. Encoding uses the pane's most
recently applied cursor/application, modify-key and bracketed-paste modes, even
while an older presentation is still in flight. Replayed
byte slices have already passed parser and binding classification before they
enter the bounded pane-input bytes path.

The pane-input boundary also owns raw routed chunks, Lua paste,
alternate-scroll cursor sequences and SGR mouse reports. Streamed paste first
passes through `paste_routing`, which assigns every phase to one prompt
or pane owner. A pane-owned start then enters `pane_input.startPanePaste`, which captures
one pane and reuses pane input for every chunk and marker. See
[Pane input](pane-input.md) for ownership, target, session, viewport, failure
and telemetry policy.

## 2C. Pointer interaction branch

`host_inputs.mouse` lets `tab_drag.retained` keep an active tab drag, then
delegates to `pointer_routing.apply`. That procedure records host telemetry,
rejects prompt-owned input or an absent active tab, and converts supported
host pixels to cells. It then gives copy mode, the view, textual links and
pane input exclusive refusal in that order. It reaches the adapter's view only
through `client.chrome.pointer` and `client.chrome.linkPointer`.

`copy_mode_pointer` resolves a fixed copy and geometry snapshot;
`copy_mode_pointer.apply` consumes every pointer event while copy mode is active
and selects only bounded vertical movement or exit. Only an unowned event
reaches `HostChrome.pointer`, which the TUI answers with `State.handleMouse`
in `src/frontend/client/presentation/State.zig`. See [Copy mode](copy-mode.md).

`State.handleMouse` returns one `ViewInteractionCommand`. The command contains
one exclusive semantic intent plus layout and pointer-capture facts. Hover,
sidebar scroll and attachment-modal changes advance `State.interactionVersion`.
The view does not select tabs, focus panes, start prompts or navigate
notifications.

During the resulting draw, the view maps semantic hover to one bounded mouse
pointer shape. Clickable chrome uses `pointer`, the sidebar separator and its
active drag use `ew-resize`, and passive chrome and pane borders restore the
terminal default. Over attached pane content, it uses that pane's canonical
OSC 22 shape, regardless of keyboard focus. Copy mode and active prompts restore
the default because they own pointer input before the view. Attachment-modal
hits retain their own shape and never inherit an underlying pane's shape. The default is emitted explicitly rather than as
an empty reset so terminals implementing only CSS shape names restore it too.
`presentation.Screen` emits OSC 22 in the synchronized frame only when that
shape differs from the last successful flush.
A failed flush marks it unknown so recovery re-emits it, while the platform
leave sequence restores the default before leaving the alternate screen.
Unsupported terminals ignore the OSC sequence. Physical pointer state is per
client, fixed-size and allocation-free. The runtime publishes the child's shape
in `pane_frame.pointer_shape`, including pointer-only updates and recovery
snapshots. See [Pane pointer shape](pane-pointer-shape.md) for protocol bounds,
stationary-pointer updates, UI priority and proofs.

`view_interactions.apply` in `src/client/input/view_interactions.zig` applies
the semantic intent by calling the concrete sidebar, workspace-list,
agent-navigation, tab-selection, pane-focus, name-prompt, handoff or
notification operation. If the interaction changed layout, that same function
sets `model.to_host.invalidate_placements` and calls
`pane_resize.resizeAttachedPanes` with the original active model and current area.
It then returns whether the triggering event was consumed.

Tab selection and agent navigation consume the triggering pointer event.
Explicitly consumed view chrome does the same. Pane focus remains routable so
the newly focused child receives the press after focus resources commit. If an
effect fails, dispatch stops before later effects and the input entrypoint does not
forward the event. Otherwise pointer routing forwards only events that remain
inside the workbench. It delegates them to `pane_mouse_input.inputPaneMouse`
without reading pane geometry or child mouse modes. `tab_layout.planPaneMouse`
resolves the pane snapshot, `pane_mouse_input.inputPaneMouse` chooses one
viewport, alternate-scroll or report effect (`pane_mouse_inputs.encodeReport`
encodes reports) and applies it through the existing viewport and pane-input
use cases. See [Pane mouse input](pane-mouse-input.md).

The command and operation use fixed value types. The pure capture policy stays
in `src/client/input/view_interaction.zig`. View tests cover
hit-to-intent translation; `src/frontend/client/tests/mouse_selection.zig` and
`synchronization.zig` exercise actual sidebar-agent handoff, notification
activation and focus-before-press forwarding through client input.

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

For CSI-u character reports, a child requesting Kitty flag 16 also receives
associated text. The encoder uses the same UTF-8 or shifted-alternate character
as legacy text output, never the physical/base key. It emits one report, not a
report plus raw text. Ctrl/Alt shortcuts, control characters, Kitty functional
key codepoints and releases carry no associated text. Children not requesting
that flag retain their existing encoding; bracketed paste is unchanged.

This is a client-owned, allocation-free interactive operation. It reads the
acknowledged pane modes, adds at most one Unicode scalar and ten bytes to the
existing bounded encoding buffer, and retains no state across events. Buffer
exhaustion returns an encoding error before viewport or delivery effects. It
changes neither host negotiation nor IPC. Host flags 7 do not carry a separate
associated-text field; supporting host reports with multi-codepoint text would
require a separate parser and semantic-event change.

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

For keyboard presses, repeats and paste sources, `pane_input.sendPaneInput` plans and
encodes input before applying the optional `.bottom` viewport intent. A changed
viewport commits, updates graphics visibility and queues `set_pane_viewport`.
The concrete input operation then calls `runtime_io.sendRuntimeInput` directly.

`model.to_runtime` copies the bytes through `Outbox.pushInput`.
`Client.startRuntimeSend` calls `Outbox.beginSend`, which encodes the
head into the transport's send buffer through `core.encodePaneInput`, then
starts the `runtime_send` job with `client.workers.start`. Its `.sent`
completion reaches `Client.update`, and `completeRuntimeSend` releases
that claim through `Outbox.finishSend` before pumping the next entry; the
operation never borrows model data into that worker.

The outbox is bounded, owns copied input bytes and coalesces adjacent input for
the same pane. Only one socket send is in flight. When the viewport changes,
wire order is `set_pane_viewport` followed by `pane_input`.

A release never changes the viewport. It is encoded only when the exact pane's
acknowledged Kitty flags request event types; otherwise it is a zero-byte no-op
and never enters the outbox.

## 3. Runtime input entry

The client read actor completes as `.client_message`. `Runtime.update` calls
`client_connection.receive` in `src/backend/runtime/client_connection.zig`,
which validates the client generation, decodes the message, establishes the
connection role, calls `client_request.receive` and rearms the socket read.
After the event, `Runtime.update` runs `client_delivery.flush` once for every
client.

`client_request.receive` in `src/backend/runtime/client_request.zig` routes
`.pane_input` to `pane_input.send`, which validates the attachment and live
pane, then records bounded agent/history observation before queueing PTY
input and starting its writer.

`pane_input.startInputWrite` permits one in-flight write per pane.
`writeInput` serializes PTY writes with terminal-query responses and writes
the bytes to the child PTY. Its `.pane_input_written` completion
(`pane_input.finishInputWrite`) consumes the queue prefix and starts the next
chunk. A blocked pane write does not block
the event loop or another pane.

## 4. Child output and VT ingestion

The child may echo the input, repaint, emit unrelated output, or emit nothing.
There is no assumption that one key produces one frame.

`pane_launch.readPane` completes as `.pane_output`. `Runtime.update` calls
`pane_output.receive` in `src/backend/runtime/pane_output.zig`. That
procedure:

1. marks EOF or failure as completed output;
2. feeds copies to the observation and media queues;
3. acquires the VT borrow and runs `ingestPane` inline only when
   `Pane.canInlineOutput` admits the entire fragment; otherwise it schedules
   the interactive ingest actor.

Inline admission allows at most 32 printable ASCII bytes. Ghostty must be at
parser and UTF-8 ground, with no pending wrap, insertion, alternate charset,
active hyperlink, style migration or complex target cells. The run must fit
strictly before the right margin on the cursor's resident row. This bounds
both validation and mutation without permitting escape completion, scrolling,
decompression of retained pages, or grapheme cleanup. Tests reject partial
sequences at every byte and exercise admitted writes with allocation disabled.

`ingestPane` calls `Pane.ingest` in `src/backend/pane/Pane.zig`. The pane feeds
the bytes to its `vt.Terminal`, snapshots child input modes and marks its cell
projection dirty. VT is the only component that interprets child escape
sequences.

The inline result enters `pane_output.finishIngest` after the output procedure
has queued its work, without queueing an event or exposing the VT mid-ingest.
The actor still reports `.pane_ingested`, which `Runtime.update` sends to that
same procedure. It applies deferred resize state, schedules terminal responses
and the next PTY read; the update's flush then publishes.

## 5. Runtime frame publication

`client_delivery.flush` pumps each client once per update and publishes a pane
only after ingestion is complete and only when that client's prior frame has
been acknowledged. `Delivery.prepare` selects
the attachment cell lane and calls `Attachment.prepareNextCells`. The internal
`CellSync.prepare` in `src/backend/runtime/attachment/CellSync.zig` renders the
pending VT state, computes a bounded cell diff against that attachment's
acknowledged buffer and calls `schema.encodePaneFrame`. `client_connection.startSend`
writes the `.pane_frame` message to that client. Intermediate visual states may
be folded; they are not queued as a replay.

Admission happens before VT projection and diff. Each attachment owns a
`core.Pacer`: idle credits permit an immediate burst, then sustained output
uses the shared 60 Hz policy. A completed no-op projection consumes a credit
too. Admitted PTY input opens a bounded grace window for that pane's
attachments; snapshots and final output bypass the cadence. Outstanding ACKs
and active ingestion retain their existing ownership rules.

One runtime-owned `core.DeadlineScheduler` wakes the runtime when a deferred
publication is due; the update's flush arms it once from every client's
earliest deadline. Its `updateEarlier` policy preserves an armed
deadline through temporary ingest/ACK waits; only an earlier deadline replaces
it. A completion rechecks current owners and may find no work left. It retains
no pane or attachment pointer and does not poll idle panes. Ingest completion,
socket completion and ACKs resume
work blocked on those operations. Runtime shutdown joins the timer before
destroying the model. An exit message waits for the final projection
and its acknowledgement.

The timer reuses the existing cancellable `std.Io` task scheduler. Its one
logical worker and up to two child waits are a bounded scheduling exception
to the allocation-free interactive policy: `std.Io.Threaded` allocates task
records outside Telar's instrumented heap. Per-update admission and deadline
state remain inline; no queue of obsolete frames is introduced.

## 6. Client frame and host presentation

The client socket read completes at `runtime_io.receiveRuntime`. That
entrypoint releases its read token, uses the message decoded by the receive
producer, delegates to
`runtime_messages.handleServerMessage`, accounts flow-control credits and
schedules the next read only for a non-terminal outcome. See
[Client runtime transport](runtime-transport.md) for buffer ownership, queue
capacity and socket failure policy.

The `.pane_frame` case calls `pane_frames.receivePaneFrame`, which commits
through `pane_frame.receive` in `src/model/panes/pane_frame.zig`. That
procedure validates the base, applies spans, reconciles scroll, input modes and
copy state, advances the frame revision and queues `.frame_ack` in
`model.to_runtime`. In the same synchronous call,
`pane_frames.receivePaneFrame` starts the runtime send before updating
graphics visibility and active resources. A broken base queues
`request_snapshot` without changing state or acknowledging that frame.

After the inbox turn, `events.update` calls `presentation_lifecycle.observe`.
`Presenter` detects the new frame revision and schedules the paced draw; the
frame use case does not decide whether to paint. See
[Client presentation lifecycle](presentation-lifecycle.md) for observation,
coalescence, task tokens and media pacing.

The `.draw` event calls `presentation_lifecycle.handleDraw`, then
captures an immutable `presentation_projection` and calls
`Presenter.presentDue`:

1. the presenter-owned `Compositor` from `src/frontend/workspace/Compositor.zig`
   composes the immutable active-tab model into the screen back buffer;
2. the TUI view's `State.render` composes Telar chrome;
3. `flushScreen` calls `Screen.flush` in
   `src/frontend/presentation/Screen.zig`;
4. the screen emits the minimal terminal diff and flushes the host writer;
5. successful host-write completion commits the exact presented pane damage
   and releases graphics credits independently of cell ACKs.

New patches can be applied and acknowledged while this write is pending.
They update the same model; the next preparation captures its latest state.

## Native input and drawing cadence

The GUI admits native events through `GuiAdapter.input`, then the window
thread drains `InputQueue` into the shared router. After `pane_input.sendPaneInput`
successfully admits nonempty child input, `pane_input.recordPaneInput` sets
`model.to_host.pane_input`; `GuiAdapter.deliverHostEffects` hands it to
`GuiAdapter.notePaneInput`, and the TUI's `host_effects.deliver` discards it. Local shortcuts, suppressed
releases and rejected outbox writes grant no terminal drawing grace.

`NativeLoop` owns one `FramePacer` per GUI connection. It records the target's
pane ID, attachment generation and applied frame at input admission. A visible
terminal pane can bypass ordinary cadence only for a newer frame of that same
attachment, within the shared Pacer's 30 ms and 16-frame grace. Concurrent child
output can also qualify; this is a bounded latency hint, not proof that the
frame contains an echo. The fixed table holds at most `max_panes_per_tab`
entries. Replacing its oldest entry loses only an optimization. Detachment or
reattachment cannot transfer the old attachment's grace.

On macOS, `TelarView.drawDelay` queries `GuiAdapter.frameDelayNs` before
acquiring a drawable. Querying does not consume budget. A nonzero preparation
token charges the ordinary cadence and only the newer pane frames captured in
its presentation commit. An early frame reanchors the next interval at its
preparation time, so repeated input cannot accumulate future cadence debt.
Ordinary output retains one frame per 60 Hz cadence slot. Linux retains its
existing Wayland frame clock and does not query this optional native callback.

The native renderer and presentation lifecycle still allow one frame in
flight. GPU completion retires only its captured commit. It does not clear a
newer input hint, delay cell ACKs or add an output replay queue. Dirty work
waits for the display callback when cadence blocks it; idle clients add no
polling timer. All pacing state is disposable and is destroyed with the GUI
connection. Native hosts without the callback retain their local cadence.

## Validation

- `src/gui/tests/frame_pacer.zig` covers cadence, idle reanchoring, pure
  queries, per-pane grace, captured revisions, expiry, bounded credits,
  reattachment and fixed-capacity replacement.
- `src/gui/tests/input_pacing.zig` exercises native key routing, nonempty
  outbox admission, suppressed releases, local shortcuts, outbox rejection
  and older GPU completion without retiring newer damage or duplicating ACKs.

- `lib/pacing/deadline_timer.zig` proves replacement, removal,
  parking, wakeup and token release for successful and failed workers.
- `src/frontend/client/input/host_inputs.zig` proves owned timeout configuration,
  router replacement without duplicate workers and prefix-status projection.
- `host input reads pause at outbox capacity and resume with one token` in
  `src/frontend/client/tests/transport.zig` proves bounded backpressure, one real
  socket completion and one resumed TTY read token.
- `a configured sequence runs once and does not reach the pane` in
  `src/frontend/input/keybind.zig` proves the Telar-action split.
- `src/client/panes/pane_input.zig` proves prompt
  suppression, source selection, Lua router control, input reinjection and
  selected-effect failure ordering.
- `src/client/input/pointer_routing.zig` owns copy, view, link and pane owner
  ordering; the copy-mode pointer tests in
  `src/frontend/client/tests/host_interaction.zig` and the name-prompt pointer
  test in `src/frontend/client/tests/input.zig` prove it before any pointer
  effect reaches a child.
- `mouse pointer distinguishes clickable chrome panes and sidebar resizing` in
  `src/frontend/client/presentation/view.zig` proves the semantic hover mapping.
- `mouse pointer changes fold until a shape or recovery changes` in
  `src/frontend/presentation/screen_support.zig` proves OSC 22 coalescence and recovery;
  the platform sequence test proves exit restores the default before leaving
  the alternate screen.
- `host pointer shape follows semantic hover through paced presentation` in
  `src/frontend/client/tests/presentation.zig` proves the complete mouse-router
  to host-flush path with substituted terminal resources.
- The configured-action, Lua key and Lua paste tests in
  `src/frontend/client/tests/configuration.zig` prove the adapter against prompt,
  copy-mode and acknowledged pane-mode authority.
- The persistent-prefix, invalid-suffix, Escape-cancellation, and global-timeout
  tests in `src/frontend/input/keybind.zig` prove that prefix mode has no timing window without
  changing global multi-key sequence recovery.
- `unbound input is byte-for-byte transparent` and the terminal-sequence split
  tests in the same file prove parser and routing boundaries.
- The physical lifecycle tests in `src/frontend/input/keybind.zig` prove
  binding/application ownership, prefix release, configuration replacement and
  fail-closed saturation.
- `cursor keys follow the focused child's mode` in
  `src/client/input/encoding_tests.zig` proves semantic child encoding.
- The modified-Enter parser and router tests cover both host encodings,
  malformed reports and every byte boundary. The encoder tests cover modifier
  combinations, physical lifecycles, alternate key codes, legacy release
  suppression, protocol precedence, plain Enter, LF and bounded output.
- `host keys use the keyboard modes received in a pane frame` in
  `src/frontend/client/tests/input.zig` proves frame decoding, normal key
  routing and the outgoing `pane_input` bytes, including associated text,
  repeat/release and Ctrl+C under Kitty flags 27, flags 7 and legacy modes.
- The associated-text encoder tests cover ASCII, shifted symbols, Unicode,
  every flag combination for plain characters, shortcut modifiers, controls,
  functional keys, repeats, releases, paste and every insufficient output size.
- `tools/verify_terminal_browser.py` types through macOS System Events into
  the fixture's focused input. It requires Accessibility permission. A DOM key
  event alone or pasted text cannot pass: the input must report `insertText`
  and retain exactly `a` on completion. `tools/test_verify_terminal_browser.py`
  checks rejection of those false positives, duplicate text and incomplete runs.
- `releasing the physical prefix preserves its logical sequence through client routing`
  in `src/frontend/client/tests/input.zig` proves the complete host-parser-to-action lease path.
- `modified Enter follows the compatibility profile and child keyboard negotiation through the PTY` in
  `src/transport_integration_test.zig` proves that a real child can enable
  Kitty flags 7, switch to modifyOtherKeys and return to legacy mode while
  receiving the corresponding bytes.
- The `inline output` tests in `src/backend/pane/pane_namespace.zig` prove admission bounds,
  allocation-free simple runs and fallback for parser continuations, wrapping,
  styles, charsets, hyperlinks, graphemes and wide cells.
- `PTY input remains live while the bounded ingest actor is occupied` in
  `src/transport_integration_test.zig` proves that input does not wait for VT
  ingestion.
- `input to one pane flows while another pane's PTY is wedged` in the same file
  proves per-pane input isolation.
- The pane frame, reconnect and independent-acknowledgement integration tests
  in `src/transport_integration_test.zig` prove publication and client-specific
  recovery.
- `src/backend/runtime/tests/cell_publication_test.zig` covers deferred final
  frames, urgent snapshots, EOF ordering, independent clients, bounded input
  grace, ingest/ACK waits, reconnect and no-op publication budgets.
