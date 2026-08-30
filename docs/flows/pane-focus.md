# Pane focus

Pane focus is disposable client state. The runtime owns pane processes and
PTYs, while each client decides which pane receives its input and occupies a
fullscreen layout.

The transition runs on the interactive path. Direction lookup uses a fixed
layout snapshot bounded by `schema.max_panes_per_tab`, and its effects use the
fixed client outbox. It allocates no queue and never waits for a runtime
response.

## Client transition

```text
native direction / workbench click / notification / sidebar agent
        |
InputHandler.focusPane
        |
FocusPane { target, area }
        |
FocusPaneHandler
        |
ClientModel.focusPane
        |
pane_focus.applyFocus
        |
focus-out -> focus-in -> fullscreen resize
        |
Client.observeModel -> Presenter
```

`InputHandler` translates every source into either a stable pane identity or a
direction. `View.handleMouse` reports a pane identity and does not receive or
mutate the workspace model. Sidebar navigation may select the pane's tab
first, then sends the same identity through this transition.

`ClientModel.focusPane` resolves the target only inside the active tab. A
missing identity, the already focused identity, a direction without a
candidate, or an absent active tab is a no-op. A committed focus advances only
`ClientModel.Version.panes` and returns the exact tab, previous pane, focused
pane and whether fullscreen geometry changed.

## Effects and presentation

After the model commit, the adapter verifies that the exact tab is still
active and that its focused identity matches the result. It then synchronizes
terminal focus reporting. If both panes opted into focus events, this enqueues
`pane_input` with focus-out for the previous pane before focus-in for the new
pane.

Fullscreen follows focus, so a fullscreen change also invalidates graphics
placements and sends one `pane_resize` for the newly visible attached pane.
Tiled focus changes do not resize panes. A workbench click completes these
focus effects before the triggering mouse event is translated and enqueued for
the newly focused pane.

Neither the use case nor the adapter requests a frame. The client loop calls
`Client.observeModel` after the event, and `Presenter` detects the pane revision
and folds composition into the paced frame loop.

## Failure and recovery

The semantic focus commits before resource effects. If focus reporting or a
resize cannot be enqueued, the error reaches the client loop with the new focus
preserved. The client exits rather than pretending the effects completed.
Runtime panes and PTYs remain valid, and reconnect reconstructs the disposable
client model and focus-reporting state from canonical snapshots.

## Proof

- `src/frontend/client/model.zig` proves identity and direction resolution,
  no-op behavior and pane-version ownership.
- `src/frontend/client/application/focus_pane.zig` proves commit-before-effects
  ordering and the post-commit failure contract.
- `src/frontend/client/view.zig` proves workbench clicks return intent without
  mutating layout state.
- `src/frontend/client/client_test.zig` proves focus-report and fullscreen
  resize order, presenter observation and repeated-direction no-ops through a
  real substituted runtime socket.
