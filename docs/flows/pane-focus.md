# Pane focus

Pane focus is disposable client state. The runtime owns pane processes and
PTYs. Each client decides which pane receives input, which pane occupies a
fullscreen layout and which focus state it has reported to the child.

The transition runs on the interactive path. Direction lookup is bounded by
`schema.max_panes_per_tab`, and protocol effects use the fixed client outbox.
It allocates no queue and never waits for a runtime response.

## Client transition

```text
native direction / workbench click / notification / sidebar agent
        |
client_actions.focusPane
        |
FocusPaneHandler -> ClientModel.focusPane
        |
pane_focus.syncResources
        |
        +-- attachment_targets.sync -> shelf geometry
        |
        +-- PaneFocusReportingHandler
                    |
          ClientModel.syncReportedPaneFocus
                    |
          focus-out -> focus-in
        |
fullscreen resize
        |
Client.observeModel -> Presenter
```

The source adapter translates its intent into either a stable pane identity or
a direction before calling `client_actions.focusPane`. `View.handleMouse`
returns a pane identity and does not mutate the workspace model. Sidebar
navigation may select the pane's tab first, then sends the same identity
through this transition.

`ClientModel.focusPane` resolves the target only inside the active tab. A
missing identity, the already focused identity, a direction without a
candidate, or an absent active tab is a no-op. A commit advances only
`ClientModel.Version.panes` and returns the exact tab, previous pane, focused
pane and whether fullscreen geometry changed.

## Reported focus

Semantic focus and reported focus are different states. Semantic focus affects
layout and rendering. `ClientModel.reported_pane_focus` is operational state
with no presentation revision. It stores one pane identity and whether that
pane had focus-event reporting enabled during the last synchronization.

`PaneFocusReportingHandler` asks the model to commit either the active focused
pane or an intentional clear. The returned transition contains at most one
focus-out and one focus-in. The handler emits focus-out first. A pane that opts
in while already focused receives focus-in once. Opting out updates the state
without sending focus-out because the child disabled that protocol.

An intentional tab detach clears reported focus only when that tab contains
the reported pane. It emits focus-out before `detach_pane`. Detaching another
tab leaves the active owner's state untouched. Authoritative pane retirement
uses `releaseReportedPaneFocus` and sends no byte because the child is already
gone. Workspace reconciliation may also forget stale reporting state before it
synchronizes the newly active pane.

`pane_focus_reports` is the only adapter that translates semantic focus-in and
focus-out into `pane_input`. These bytes do not count as user-input telemetry.
Close-tab and workspace-handoff preflights reserve the focus-out slot before
they mutate attachment state.

## Geometry and presentation

Focus reporting does not own attachment geometry. `attachment_targets.sync`
reconciles the focused agent shelf and re-offers pane sizes if that shelf
changes the workbench. `pane_focus.syncResources` fixes the order between that
operation and focus reporting. A fullscreen focus change then invalidates
graphics placements and resizes the newly visible pane.

A workbench click completes these resource effects before it sends the
triggering mouse event to the new pane. No focus-reporting transition requests
a draw. The client loop publishes the semantic pane revision, and `Presenter`
folds it into the paced frame loop.

## Failure and recovery

The semantic focus and reported target commit before their resource effects.
If a resize or focus message cannot enter the outbox, the error reaches the
client loop with committed client state. The client exits. Reconnect rebuilds
the disposable layout and reporting state from canonical snapshots while the
runtime panes and PTYs continue running.

## Proof

- `src/frontend/client/model.zig` proves focus resolution, report transitions,
  exact retirement and the absence of presentation revisions for report state.
- `src/frontend/client/application/focus_pane.zig` proves semantic
  commit-before-effects ordering.
- `src/frontend/client/application/pane_focus_reporting.zig` proves reporting
  commit order, focus-out before focus-in, no-op behavior and effect failure.
- `src/frontend/client/attachment_targets.zig` keeps shelf geometry outside
  focus-reporting policy.
- `src/frontend/client/client_test.zig` proves protocol order, mode opt-in,
  exact tab ownership, capacity reservation, mouse ordering and presentation
  through a substituted runtime socket.
