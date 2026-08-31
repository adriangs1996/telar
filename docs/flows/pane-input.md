# Pane input

Pane input begins after the host parser and key router have decided that an
event belongs to a child. The client validates one disposable target, applies
source-specific viewport policy and sends bounded bytes to the runtime. The
runtime remains responsible for attachment authorization, queueing and the PTY
write.

The interactive path allocates nothing. One command is at most 8 KiB, matching
the client outbox's owned input slot. The protocol permits larger messages, but
the client keeps this tighter bound so one event cannot monopolize its fixed
queue.

## Client boundary

```text
semantic key, routed bytes, paste or mouse report
                         |
                  InputHandler
                         |
         +---------------+---------------+
         |                               |
  pane_pastes adapter             pane_inputs adapter
         |                               |
  PanePasteHandler                        |
         |                               |
 ClientModel.pane_paste                   |
         |                               |
         +---------------+---------------+
                         |
                 PaneInputHandler
                         |
             ClientModel.planPaneInput
                         |
              encode key when required
                         |
       host / paste ---------------- mouse
             |                         |
 SetPaneViewportHandler(.bottom)       |
             |                         |
             +-----------+-------------+
                         |
                  send effect
                         |
 Client.enqueueInput -> Outbox -> pane_input
```

`InputHandler` classifies attachment-modal, name-prompt, copy-mode, Telar-action
and pane-input events. For a streamed pane paste it delegates start, content
and finish without reading the captured pane identity or framing mode. It does
not resolve pane storage, encode a child key, restore scrollback, write
pane-input telemetry or enqueue pane bytes.

`ClientModel.planPaneInput` is a read-only query. Normal input resolves the
focused or explicit pane in the active tab. A captured paste may resolve its
exact pane in the tab being detached after a selection commit. Every target
must remain attached; missing and detached targets are dropped. An active name
prompt or copy mode rejects normal input because each owns it exclusively.
Planning returns a value copy of `input_modes` and never advances
`ClientModel.Version`.

`PaneInputHandler` accepts either already-routed bytes or a semantic key. It
encodes keys against the planned child modes before committing anything, then
rejects empty or oversized payloads. Keyboard and paste sources compose
`SetPaneViewportHandler` with a `.bottom` intent before delivery. Mouse reports
preserve the current viewport. The final effect carries only `pane_id` and a
slice borrowed for the synchronous call.

## Paste ownership

The input router identifies bracketed-paste boundaries and owns only its parser
flag. `PanePasteHandler.start` asks `ClientModel` to capture the focused pane
and its current `bracketed_paste` mode as one `PanePasteSession`. The state has
no presentation revision because the UI does not render it.

The handler commits the session before sending an opening marker. A failed or
unavailable opening delivery rolls that exact session back. Content uses the
captured session as its pane-input authority, so a later focus change or modal
does not retarget the paste. Copy mode and name prompts cannot start while the
pane session is active. A paste that started in an existing name prompt stays
with that prompt through its own `Prompt.pasting` state.

The session also freezes whether framing is required. If the child changes its
terminal mode during the stream, Telar still emits a closing marker exactly
when it emitted an opening marker. `PanePasteHandler.finish` keeps the session
valid during that final delivery and clears it afterward even when delivery
fails.

An intentional tab detach finishes a paste owned by that tab before focus-out
and `detach_pane`. The captured target remains valid across the preceding tab
selection commit, so the closing marker can still reach the old attached pane.
If the pane has already detached or disappeared, the plan drops the delivery
and cleanup releases the session through `ClientModel`. Lua paste decisions do
not create a streamed session; they read the focused child's current mode and
frame one bounded value in one delivery.

An unmodified `Ctrl+V` follows the normal pane-input transaction first. Only
after delivery does the client schedule its best-effort local image preview.
See [Clipboard image preview](clipboard-image.md) for its media worker,
identity, bounds and presentation path.

## Effects and failure policy

`pane_inputs` wires the application ports to the shared `pane_viewports` effect
and `Client.enqueueInput`. The outbox copies the borrowed bytes, coalesces
adjacent input for the same pane and preserves protocol order.

Validation and key-encoding failures happen before viewport or delivery
effects. A viewport synchronization failure leaves the committed client
viewport intact and prevents input delivery. A later outbox failure also keeps
that viewport commit. Paste start is the exception for its new session: it
rolls back when the opening marker cannot be delivered, because no later
boundary may target an unopened session. Paste finish always clears the
session. Reconnection and canonical runtime frames repair operational
projections; rolling viewport state back would create a second, unobservable
transition.

Debug telemetry measures successful keyboard and paste transactions, including
planning, encoding, optional viewport synchronization and enqueueing. Mouse has
its existing event counter and is not double-counted as user-input enqueue
latency.

Terminal focus reports are deliberately outside this use case. They are
protocol effects of focus synchronization, not user input, and focus-out must
be able to target the pane that just lost focus. They call `Client.enqueueInput`
directly and are excluded from user-input telemetry.

## Presentation and runtime

Successful input at the live bottom changes no rendered client state and
requests no draw. Starting or finishing a pane paste changes model state but no
presentation revision. Restoring scrollback advances only
`ClientModel.Version.viewport`; the presenter detects that revision and
schedules the paced recomposition. Later `pane_frame` messages reconcile
whatever the child emitted.

Across the socket, `schema.pane_input` enters the runtime attachment boundary.
The runtime validates the attachment, appends bytes to the pane's bounded input
queue and serializes PTY writes per pane. A blocked PTY cannot stop input to a
different pane or the runtime event loop.

## Proof

- `src/frontend/client/model.zig` proves active-target resolution, paste
  identity and framing capture, exact release, attachment checks and exclusive
  modes.
- `src/frontend/client/application/pane_paste.zig` proves start rollback,
  ordered delivery, unframed behavior, content retention and unconditional
  finish cleanup.
- `src/frontend/client/application/pane_input.zig` proves child-mode encoding,
  explicit marker delivery, bounds, source-specific viewport policy, effect
  order and failure behavior.
- `src/frontend/client/client_test.zig` proves captured target and framing,
  viewport and protocol order, owner exclusion, close-before-detach,
  pane-retirement cleanup, mouse scrollback preservation, telemetry separation
  and outbox backpressure.
- `src/frontend/input/host.zig` proves terminal-mode-specific key and paste
  encoding.
- `src/backend/runtime/pane_input_test.zig` and
  `src/transport_integration_test.zig` prove runtime queueing, PTY delivery and
  per-pane isolation.
