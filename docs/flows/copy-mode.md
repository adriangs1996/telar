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
host key, mouse wheel or native action
        |
key_routing / copy_mode_pointer / AttachedClient.executeAction
        |
AttachedClient.applyCopyMode
        |
ClientModel.planCopyMode
        |
optional copy_selection effect before exit
        |
ClientModel.commitCopyMode
        |
optional set_pane_viewport effect after commit
        |
ClientModel.copy_revision and optional viewport_revision
```

Entry resolves the attached focused pane and captures its current viewport.
An active name prompt, missing pane or repeated entry is a no-op. While copy
mode is active, `AttachedClient.routeKeyInput` sends semantic keys to copy mode and
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
applies the selected movement or exit through `AttachedClient.applyCopyMode`
or `AttachedClient.leaveCopyMode`. It allocates nothing, retains no pane
pointer and adds no queue. A selected effect failure propagates and cannot fall through
to view or pane mouse handling.

`AttachedClient.executeAction` owns the exit rule for actions from host bindings, Lua
batches and plugin batches. It receives a synchronous copy-mode authority
snapshot, leaves copy mode before any action other than entry, then delegates
the concrete action. A leave failure prevents that action; a later action
failure retains the completed exit and restored entry viewport.

`ClientModel.planCopyMode` applies the pure motion component to a local state
copy. Unhandled keys and boundary motions return no plan and advance no
revision. `commitCopyMode` accepts only the revision and exact prior state that
were planned, so an obsolete plan cannot overwrite a newer command.

`o` resolves the textual URI under the cursor through the bounded cell adapter.
The application dispatches that target without committing copy state, moving
the viewport or leaving the mode. See [Link opening](link-opening.md).

Copy delivery is intentionally ordered before the exit commit:
`AttachedClient.applyCopyMode` pushes `copy_selection` into `model.to_runtime`
before `commitCopyMode`. If that queue is full, the selection and copy-mode revision remain intact and the user can
retry. Viewport synchronization follows the commit. If that effect fails, the
client retains the committed disposable state; reconnection or a later runtime
frame repairs the operational projection. Copy mode uses the same
`PaneViewportChange` as normal scrolling, so graphics and
`set_pane_viewport` policy stay in `AttachedClient.deliverPaneViewport`.

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
                    AttachedClient.receiveRuntime
                              |
                    AttachedClient.handleServerMessage(.pane_clipboard)
                              |
                 model.to_host.writeClipboard
                              |
     host_effects.deliver -> term.writeClipboard (OSC 52) -> writer flush
```

`AttachedClient.handleServerMessage(.pane_clipboard)` validates pane identity
and copies the bytes into `model.to_host`; a later write in the same event
replaces an earlier one. The event changes no other `ClientModel` state; the
runtime already selected the requested text. The schema decoder rejects an
invalid pane identity, and the client keeps the same check for direct callers.
After the event the TUI drains the request in `host/host_effects.deliver`,
which encodes OSC 52 and flushes it; the GUI drains it in
`GuiClient.deliverHostEffects`.
A pane may exit after the copy request without cancelling the user's completed
copy.

Clipboard output bypasses the cell diff and does not advance a model version or
schedule presentation. The schema and terminal writer share the 64 KiB bound.

## Runtime frames and pane retirement

```text
schema.pane_frame
        |
AttachedClient.receiveRuntime -> handleServerMessage -> receivePaneFrame
        |
pane_frame.receive
        |
screen commit + ClientModel.reconcileCopyModeFrame -> copy_mode.onFrame
        |
frame_revision always + copy_revision when copy state changed
```

A frame can prune retained rows or confirm a requested viewport. Reconciliation
is internal to the frame transaction. It pulls absolute selection coordinates
across pruned history, clamps them to the new row count and adopts the runtime
viewport. Unrelated or identical copy projections do not advance the copy
revision.

Pane and tab cleanup enter `AttachedClient.releasePaneResources`. Only retirement of
the target pane closes the mode. The same operation releases paste and reported
focus before clearing physical graphics. A model
transition that makes another tab active also releases copy authority, so
routing cannot remain attached to an inactive pane after an asynchronous
runtime response.

## Presentation

Neither the input adapter nor the operation requests a draw or
writes presentation state. After the turn's client events, `events.update`
observes the model version once. `Presenter` compares the `copy` revision with
its last presented version and folds the latest immutable `Projection.copy`
(`CopyProjection`) into the paced frame.

When copy movement also changes the viewport, `Presenter` observes the
independent viewport revision. Its compositor detects the changed scroll
projection; the copy use case does not mutate rendering caches.

The presenter-owned compositor retains only the projection it last painted.
It clears the old pane when the target changes or copy mode exits. Entering and
leaving invalidate the status bar; cursor and selection movement patch exact
visible ranges without mutating multiplexer pane damage. Copy projection is
presentation state, never semantic authority inside the model's `Pane`.

## Validation

- `src/model/input/copy_mode.zig` proves fixed-state motions, selection and
  frame reconciliation.
- `src/model/state/tests/input_and_frames.zig` proves entry authority,
  independent revisions, no-ops, stale-plan rejection, frame reconciliation,
  exact pane release and release on an active tab transition.
- `src/client/AttachedClient.zig` owns copy-before-exit and
  viewport-after-commit ordering (`applyCopyMode`), the selection push into
  `model.to_runtime`, and graphics visibility and runtime viewport
  synchronization for both normal input and copy mode
  (`deliverPaneViewport`).
- `src/frontend/presentation/screen_support.zig` proves exact OSC 52 encoding,
  multi-chunk payloads and the terminal-side size bound.
- `src/frontend/client/tests/` proves key and pointer routing,
  outside-wheel consumption, missing-target exit, source-independent
  copy-mode preflight, backpressure, clipboard delivery and presenter-only
  projection through the real client boundary.
- `src/frontend/workspace/multiplexer.zig` proves that copy deltas belong to
  `Compositor` and patch exact visible ranges without pane-model mutation.
