# Client presentation lifecycle

A client event commits semantic or physical display state. Presentation observes
that state, prepares bounded work and reports delivery. Only then can the
application retire exact frame damage. Cell ACKs follow validated model
application independently of presentation.

## Boundary

The common `telar-client.presentation` capability owns the borrowed projection,
observations, pane-coordinate geometry and single-flight completion identity.
Each client has one lifecycle, `Client.presentation` (`LifecycleState`). The
window reads it through its `app`. `GuiAdapter` owns the renderer, the frame
pacer, the cursor clock and widget presentation state. Common procedures do not
request draws.

```text
committed client event (GuiAdapter.update turn)
        |
model version + ingress and geometry revisions (GuiAdapter.observation)
        |
app.presentation.observe -> needsPreparation -> needs_draw
        |
native render callback -> GuiAdapter.draw -> prepare
        |
projection + Scene.prepare -> app.presentation.begin -> owned token
        |
GPU submission -> native complete callback -> .presented message
        |
GuiAdapter.complete -> widgets present -> app.presentation.complete(token)
        |
presentation_delivery.apply -> ClientModel.commitPresentation
        |
filter attachment generations + exact damage commit
```

The headless client uses the same projection, lifecycle and delivery
procedure on `Client`. `HeadlessClient.present` captures the active tab's
commit, begins and completes it as delivered at once, then applies the
delivery; there is no host to write to. The test `HeadlessAdapter` copies cells
into bounded storage, and its caller controls when preparation and delivery
fail or finish.

## Observation and preparation

`Observation` contains `ClientModel.Version`, visible input-routing and view
interaction revisions and the workbench-grid revision. The lifecycle keeps
observed, prepared and delivered values separately. Observing unchanged
prepared work adds no frame, including while its GPU work is pending. A newer
observation replaces the desired version; there is no frame queue.

The native loop asks `GuiAdapter.frameDelayNs` before drawing. `FramePacer`
keeps the window's frame cadence and gives admitted pane input a bounded grace,
so a frame carrying that pane's echo need not wait for the next interval. The
cursor clock and widget animations report their own wakeups through
`wakeupAfter`.

`GuiAdapter.prepare` captures the projection through the shared
`projection_support.capture` builder. The projection carries `layout`, the
cached snapshot of the active tab. Rendering borrows model data synchronously.
No worker borrows the model or the projection. The scene returns its bounded
`PresentationCommit`, including fullscreen-hidden panes. Preparation advances
prepared revisions, not delivered revisions or pane acknowledgement state.

## Completion

The common lifecycle consumes the matching token once. A duplicate or replaced
token cannot complete a newer flight. A valid completion for an older model
version still identifies only that version's captured pane frames.

`ClientModel.commitPresentation` rejects retired attachment generations, even
when a reconstructed pane reuses the same wire frame number. Exact pending-frame
matching prevents an old delivery from clearing newer damage.
`presentation_delivery.apply` validates the bounded commit and commits model
damage; the next flush returns the resource credit those frames held. This
procedure sends no cell ACK. `pane_frame.receive` queues the ACK for owned
cells before resource delivery, so new patches can update the model while a
frame is still on the GPU. The next preparation captures the latest state.

`Geometry` owns region, tab, layout, host size and pane-shape identities. A new
pointer gesture cannot use changed pane geometry during an in-flight
presentation. Captured gestures retain their existing owner. Widget hit maps
remain adapter-owned; the contract does not prescribe native widget layout.

## Host services

Window-title formatting and change suppression use the shared
`WindowTitleState`; the window passes a `Sink` that copies the title into
native storage. Clipboard writes, terminal notifications, clipboard capture and
machine requests go through `model.to_host`, which the window drains after
every event in `GuiAdapter.deliverHostEffects`. Links, sound and system
notifications run as client jobs the adapter starts from
`Client.to_workers` and `Client.to_background`. Common
procedures do not receive a GPU device.

## Failure and teardown

Failed preparation cannot create a delivery. Failed or cancelled completion
keeps model damage pending and permits a fresh preparation. Cancellation means
that consumers have stopped borrowing, not that their storage may be reused
while they are still running.

A new connection rebuilds runtime snapshots. Runtime PTYs and history remain
valid after client death. After successful delivery, a credit error does not
undo earlier effects. The event loop closes that client and snapshot
reconciliation recovers it. Completion reports GPU delivery, not monitor
presentation timing.

## Proof

- `src/client/presentation/lifecycle.zig` tests busy admission, failure,
  cancellation, exact-token completion and captured-frame delivery.
- `src/client/presentation/headless_tests.zig` exercises shared entrypoints,
  concrete procedures, coalescing, resource lifetime and outbox without a
  window.
- `src/client/connection/presentation_delivery.zig` contains the direct
  completion procedure and `src/model/panes/presentation_delivery.zig` the
  exact retirement; headless and adapter tests exercise its damage/credit
  ordering through actual client state.
- `src/client_tests/presentation.zig` tests observation folding and pointer
  shape delivery through presentation.
- `src/gui/tests/navigation.zig` rejects queued pointer presses after the
  geometry changes, including before a GPU flight starts.
