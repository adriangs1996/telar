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
host adapter drains semantic input
  -> AttachedClient.routeKeyInput / paste_routing / pointer_routing
  -> AttachedClient.sendPaneInput / startPanePaste / inputPaneMouse
       capture the target and its current input modes
       encode key, paste marker, mouse report or supplied bytes
       applyPaneViewport(.bottom) when required by the source
  -> private deliverPaneInput
  -> private sendRuntimeInput -> Outbox -> pane_input
```


The host adapter dispatches semantic keys and replayed bytes to
`AttachedClient.routeKeyInput`. Paste and pointer routing retain their current
entrypoints and call the corresponding owner operations. Child input policy,
leases, viewport restoration, telemetry and transport delivery are visible in
`AttachedClient`. See [Key routing](key-routing.md) for keyboard ownership.

`AttachedClient.inputPaneMouse` selects viewport, alternate-scroll or child-report policy.
Only the latter two enter `AttachedClient.sendPaneInput`. See
[Pane mouse input](pane-mouse-input.md) for target and coordinate rules.

`ClientModel.planPaneInput` is a read-only query. Normal input resolves the
focused or explicit pane in the active tab. A physical key lease and a captured
paste may resolve their exact pane outside the active tab after a focus or
selection commit. Every target
must remain attached; missing and detached targets are dropped. An active name
prompt or copy mode rejects normal input because each owns it exclusively.
Planning returns a value copy of `input_modes` and never advances
`ClientModel.Version`.

`AttachedClient.sendPaneInput` accepts either already-routed bytes or a semantic key. It
encodes keys against the planned child modes before committing anything, then
rejects empty or oversized external payloads. A release that the child's
protocol cannot represent becomes a zero-byte no-op. Press, repeat and paste
compose `AttachedClient.applyPaneViewport` with a `.bottom` intent before delivery.
Release and mouse reports preserve the current viewport. The final effect
carries only `pane_id` and a slice borrowed for the synchronous call.

## Paste ownership

The input router identifies bracketed-paste boundaries and owns only its parser
flag. For every phase, the `paste_routing` adapter snapshots attachment-modal,
prompt, copy-mode and pane-session authority. `paste_routing` assigns the
phase to at most one owner. An attachment modal blocks start. An active prompt
owns start, copy mode blocks it, and every other accepted start reaches the
pane use case. Content and finish stay with an active pane session first, then
with a prompt whose `pasting` flag is set. Without an established owner they
are dropped.

The routing snapshot and borrowed command are fixed values. The operation adds no
allocation, queue or retained pointer. A selected owner failure propagates and
never falls through to the other owner.

`AttachedClient.startPanePaste` asks `ClientModel` to capture the focused pane and its
current `bracketed_paste` mode as one `PanePasteSession`. The state has no
presentation revision because the UI does not render it.

The operation commits the session before sending an opening marker. A failed or
unavailable opening delivery rolls that exact session back. Content uses the
captured session as its pane-input authority, so a later focus change or modal
does not retarget the paste. Copy mode and name prompts cannot start while the
pane session is active. A paste that started in an existing name prompt stays
with that prompt through its own `Prompt.pasting` state.

The session also freezes whether framing is required. If the child changes its
terminal mode during the stream, Telar still emits a closing marker exactly
when it emitted an opening marker. `AttachedClient.finishPanePaste` keeps the session
valid during that final delivery and clears it afterward even when delivery
fails.

An intentional tab detach finishes a paste owned by that tab before focus-out
and `detach_pane`. The captured target remains valid across the preceding tab
selection commit, so the closing marker can still reach the old attached pane.
If the pane has already detached or disappeared, the plan drops the delivery
and cleanup releases the session through `ClientModel`. Lua paste decisions do
not create a streamed session; they read the focused child's current mode and
frame one bounded value in one delivery.

An unmodified `Ctrl+V` follows the normal pane-input transaction first.
`AttachedClient.routeKeyInput` requests its best-effort local image preview only after a
confirmed delivery. See [Key routing](key-routing.md) for that ordering and
[Clipboard image preview](clipboard-image.md) for its media worker, identity,
bounds and presentation path.

## Effects and failure policy

`AttachedClient.sendPaneInput` plans and encodes the input, calls `AttachedClient.applyPaneViewport`
when needed, then calls `AttachedClient.sendRuntimeInput` directly. The outbox copies the borrowed bytes,
coalesces adjacent input for the same pane and preserves protocol order. See
[Client runtime transport](runtime-transport.md) for send-token and
backpressure ownership.

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

Terminal focus reports are deliberately outside this use case. They pass
through `AttachedClient.synchronizeReportedFocus` or `clear`. These operations
use `AttachedClient.sendRuntimeInput`, so
focus bytes remain outside user-input telemetry and can target the pane that
just lost focus.

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

## Validation

- `src/model/state/Model.zig` proves active-target resolution, paste
  identity and framing capture, exact release, attachment checks and exclusive
  modes.
- `src/model/application/input/pane_paste.zig` proves start rollback,
  ordered delivery, unframed behavior, content retention and unconditional
  finish cleanup.
- `src/client/application/input/paste_routing.zig` proves start authority,
  established-owner priority, ignored phases and failure isolation.
- `src/client/application/input/pane_input.zig` proves child-mode encoding,
  exact key-lease targets, legacy and Kitty releases, explicit marker delivery,
  bounds, source-specific viewport policy, effect order and failure behavior.
- `src/model/application/input/pane_mouse.zig` proves exclusive pointer
  policy before any report reaches pane input.
- `src/frontend/client/tests/` proves captured target and framing,
  prompt and copy-mode routing, viewport and protocol order, owner exclusion,
  close-before-detach, pane-retirement cleanup, mouse scrollback preservation,
  telemetry separation and outbox backpressure.
- `src/frontend/input/host_tests.zig` proves terminal-mode-specific key and paste
  encoding.
- `src/backend/runtime/tests/requests_test.zig` and
  `src/transport_integration_test.zig` prove runtime queueing, PTY delivery and
  per-pane isolation.
