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
                 pane_inputs adapter
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

`InputHandler` owns routing between the attachment modal, name prompt, copy
mode, Telar actions and pane input. It does not resolve pane storage, encode a
child key, restore scrollback, write pane-input telemetry or enqueue pane
bytes.

`ClientModel.planPaneInput` is a read-only query. It resolves either the focused
pane or an explicit pane in the active tab, requires that pane to be attached
and returns its stable identity plus a value copy of `input_modes`. Missing,
inactive and detached targets are dropped. An active name prompt or copy mode
also rejects the plan because each owns host input exclusively. Planning never
advances `ClientModel.Version`.

`PaneInputHandler` accepts either already-routed bytes or a semantic key. It
encodes keys against the planned child modes before committing anything, then
rejects empty or oversized payloads. Keyboard and paste sources compose
`SetPaneViewportHandler` with a `.bottom` intent before delivery. Mouse reports
preserve the current viewport. The final effect carries only `pane_id` and a
slice borrowed for the synchronous call.

## Paste ownership

A streamed terminal paste captures the focused pane at its opening marker.
Content and the closing marker target that identity instead of following later
focus changes. `PaneInputHandler` consults the planned `bracketed_paste` mode
to add markers only when the child requested them. Lua paste decisions use the
same mode to frame their bounded value in one delivery.

If the captured pane stops being attached or leaves the active tab, later
chunks are dropped. A prompt or copy mode that starts during the stream keeps
exclusive ownership and no paste bytes escape to the child.

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
that viewport commit. Reconnection and canonical runtime frames repair
operational projections; rolling semantic state back would create a second,
unobservable transition.

Debug telemetry measures successful keyboard and paste transactions, including
planning, encoding, optional viewport synchronization and enqueueing. Mouse has
its existing event counter and is not double-counted as user-input enqueue
latency.

Terminal focus reports are deliberately outside this use case. They are
protocol effects of focus synchronization, not user input, and focus-out must
be able to target the pane that just lost focus. They call `Client.enqueueInput`
directly and are excluded from user-input telemetry.

## Presentation and runtime

Successful input at the live bottom changes no client state and requests no
draw. Restoring scrollback advances only `ClientModel.Version.viewport`; the
presenter detects that revision and schedules the paced recomposition. Later
`pane_frame` messages reconcile whatever the child emitted.

Across the socket, `schema.pane_input` enters the runtime attachment boundary.
The runtime validates the attachment, appends bytes to the pane's bounded input
queue and serializes PTY writes per pane. A blocked PTY cannot stop input to a
different pane or the runtime event loop.

## Proof

- `src/frontend/client/model.zig` proves active-target resolution,
  attachment checks, exclusive modes and read-only planning.
- `src/frontend/client/application/pane_input.zig` proves child-mode encoding,
  bounds, source-specific viewport policy, effect order and failure behavior.
- `src/frontend/client/client_test.zig` proves streamed paste framing, viewport
  and protocol order, mouse scrollback preservation, telemetry separation and
  outbox backpressure.
- `src/frontend/input/host.zig` proves terminal-mode-specific key and paste
  encoding.
- `src/backend/runtime/pane_input_test.zig` and
  `src/transport_integration_test.zig` prove runtime queueing, PTY delivery and
  per-pane isolation.
