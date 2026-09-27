# Copy mode

Copy mode is bounded, disposable client state for navigating one pane's
retained history and selecting text. `ClientModel.copy_state` is its only
authority. It owns the target pane, absolute cursor and anchor, selection mode,
entry viewport and current viewport. `ClientModel.copy_revision` (reported as
`Version.copy`) identifies committed changes independently from workspace,
pane, chrome and prompt state. Viewport commits advance
`ClientModel.viewport_revision` separately.

Mouse selection reuses the range and projection without taking keyboard input
or changing the child cursor. Its physical gesture has a separate bounded pane
ID lease. See [Mouse selection](mouse-selection.md) for entry, copying and
cancellation. The keyboard-mode rules below apply only to keyboard copy mode.

The state and its motions allocate nothing. The runtime still owns scrollback
and performs the actual copy; the client sends a bounded `copy_selection`
request containing only coordinates.

## Input and commit

```text
window key, mouse wheel or native action
        |
key_routing / copy_mode_pointer / actions.executeAction
        |
copy_mode.applyCopyMode
        |
copy_mode.planCommand
        |
optional copy_selection effect before exit
        |
copy_mode.commitPlan
        |
optional set_pane_viewport effect after commit
        |
ClientModel.copy_revision and optional viewport_revision
```

Entry resolves the attached focused pane and captures its current viewport.
An active name prompt, missing pane or repeated entry is a no-op. While copy
mode is active, `key_routing.routeKeyInput` sends semantic keys to copy mode and
consumes replayed bytes. Neither reaches the child. Copy mode does not make
`key_routing.captures` true, so configured prefix bindings remain available. See
[Key routing](key-routing.md).

`copy_mode_pointer.apply` resolves a fixed authority snapshot from copy state
and the active tab's layout (`tab_layout.view`). Active copy mode owns every pointer event.
Non-wheel events and wheels outside the captured pane are consumed; a wheel
inside moves the cursor by three rows. If the captured pane no longer exists,
the event leaves copy mode. Temporarily unavailable geometry consumes the
event without surrendering ownership. Only an inactive copy mode returns the
event to view and pane routing.

`copy_mode_pointer.apply` reads that snapshot from `client.model`, then
applies the selected movement or exit through `copy_mode.applyCopyMode`
or `copy_mode.leaveCopyMode`. It allocates nothing, retains no pane
pointer and adds no queue. A selected effect failure propagates and cannot fall through
to view or pane mouse handling.

`actions.executeAction` owns the exit rule for actions from host bindings, Lua
batches and plugin batches. It receives a synchronous copy-mode authority
snapshot, leaves copy mode before any action other than entry, then delegates
the concrete action. A leave failure prevents that action; a later action
failure retains the completed exit and restored entry viewport.

`copy_mode.planCommand` applies the pure motion component to a local state
copy. Unhandled keys and boundary motions return no plan and advance no
revision. `copy_mode.commitPlan` accepts only the revision and exact prior state that
were planned, so an obsolete plan cannot overwrite a newer command.

`o` resolves the textual URI under the cursor through the bounded cell adapter.
The application dispatches that target without committing copy state, moving
the viewport or leaving the mode. See [Link opening](link-opening.md).

Copy delivery is intentionally ordered before the exit commit:
`copy_mode.applyCopyMode` pushes `copy_selection` into `model.to_runtime`
before `copy_mode.commitPlan`. If that queue is full, the selection and copy-mode revision remain intact and the user can
retry. Viewport synchronization follows the commit. If that effect fails, the
client retains the committed disposable state; reconnection or a later runtime
frame repairs the operational projection. Copy mode uses the same
`PaneViewportChange` as normal scrolling, so graphics and
`set_pane_viewport` policy stay in `pane_viewport.deliverPaneViewport`.

## Search

`/` and `?` open a bounded search input rendered by the same prompt widget
that renames tabs; while it is open, keys belong to the prompt and copy mode
waits. Submit sends `search_pane` with the needle; the runtime scans the most
recent 10,000 rows of retained history and screen (ASCII smart-case, at most
64 matches) and replies with `pane_matches` in absolute coordinates. The
client stores the matches in copy state, selects the first match relative to
the cursor in the chosen direction, highlights it as the selection and
follows it with the viewport. `n` and `N` cycle with wrap. A reply for
another pane or after copy mode ended changes nothing.

## Clipboard delivery

```text
runtime-selected bytes -> schema.pane_clipboard
                              |
                    runtime_io.receiveRuntime
                              |
                    runtime_messages.handleServerMessage(.pane_clipboard)
                              |
                 model.to_host.writeClipboard
                              |
     GuiAdapter.deliverRequests -> requestClipboardWrite -> native clipboard
```

`runtime_messages.handleServerMessage(.pane_clipboard)` validates pane identity
and copies the bytes into `model.to_host`; a later write in the same event
replaces an earlier one. The event changes no other `ClientModel` state; the
runtime already selected the requested text. The schema decoder rejects an
invalid pane identity, and the client keeps the same check for direct callers.
After the event the window drains the request in
`GuiAdapter.deliverHostEffects`; `requestClipboardWrite` hands the bytes to
the native host services, which the window thread completes (see
[Native host services](native-host-services.md)). The headless client records
the request in its trace and performs nothing.
A pane may exit after the copy request without cancelling the user's completed
copy.

Clipboard output does not advance a model version or schedule presentation.
The schema bounds the payload at 64 KiB. The window's host services also reject
text over their own request bound or invalid UTF-8, and log that the update was
not admitted.

## Runtime frames and pane retirement

```text
schema.pane_frame
        |
runtime_io.receiveRuntime -> handleServerMessage -> receivePaneFrame
        |
pane_frame.receive
        |
screen commit + copy_mode.reconcileFrame -> copy_mode.onFrame
        |
frame_revision always + copy_revision when copy state changed
```

A frame can prune retained rows or confirm a requested viewport. Reconciliation
is internal to the frame transaction. It pulls absolute selection coordinates
across pruned history, clamps them to the new row count and adopts the runtime
viewport. Unrelated or identical copy projections do not advance the copy
revision.

Pane and tab cleanup enter `pane_closure.releasePaneResources`. Only retirement of
the target pane closes the mode. The same operation releases paste and reported
focus before clearing physical graphics. A model
transition that makes another tab active also releases copy authority, so
routing cannot remain attached to an inactive pane after an asynchronous
runtime response.

## Presentation

Neither the input adapter nor the operation requests a draw or writes
presentation state. After the inbox turn, `GuiAdapter.update` observes the
model version once through `Client.presentation.observe`. A changed `copy` or
viewport revision asks for a frame. `GuiAdapter.prepare` captures the latest
immutable `Projection.copy` (`CopyProjection`), and the terminal renderer
reads it per pane through `copy_selection.forPane`. The copy use case does not
mutate rendering caches. Copy projection is presentation state, never
semantic authority inside the model's `Pane`.

## Validation

- `src/model/input/copy_mode.zig` proves fixed-state motions, selection and
  frame reconciliation.
- `src/model/state/tests/input_and_frames.zig` proves entry authority,
  independent revisions, no-ops, stale-plan rejection, frame reconciliation,
  exact pane release and release on an active tab transition.
- `src/client/input/copy_mode.zig` owns copy-before-exit and
  viewport-after-commit ordering (`applyCopyMode`), the selection push into
  `model.to_runtime`, and graphics visibility and runtime viewport
  synchronization for both normal input and copy mode
  (`deliverPaneViewport`).
- `src/client_tests/host_interaction.zig`, `input.zig` and
  `graphics_and_clipboard.zig` prove key and pointer routing, outside-wheel
  consumption, missing-target exit, source-independent copy-mode preflight,
  backpressure and clipboard delivery through the real client boundary.
- `src/gui/tests/scene.zig` and `italic.zig` draw a copy projection in the
  window's renderer.
