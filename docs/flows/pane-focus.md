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
pane_focus handler adapter
        |
FocusPaneHandler -> ClientModel.focusPane
        |
DeliverActivePaneResourcesHandler.deliverFocus
        |
        +-- attachment target effect
        |             |
        |       changed pane reservation -> pane geometry
        |
        +-- PaneFocusReportingHandler
                    |
          ClientModel.syncReportedPaneFocus
                    |
          focus-out -> focus-in
        +-- fullscreen placement invalidation -> pane geometry
        |
presentation_lifecycle.observe -> Presenter

canonical tab / workspace transition
        |
RetireReportedPaneFocusHandler
        |
ClientModel.forgetReportedPaneFocus -> no protocol effect
```

The source adapter translates its intent into either a stable pane identity or
a direction before constructing `FocusPaneHandler`. `View.handleMouse`
returns a pane identity and does not mutate the workspace model. Sidebar
navigation uses [Agent navigation](agent-navigation.md) to select the pane's tab
first, then sends the same identity through this transition.

`ClientModel.focusPane` resolves the target only inside the active tab. A
missing identity, the already focused identity, a direction without a
candidate, or an absent active tab is a no-op. A commit advances only
`ClientModel.Version.panes` and returns the exact tab, previous pane, focused
pane and whether fullscreen geometry changed.

The commit also carries the exact `Version.panes` revision, so resource
delivery rejects a superseded focus even if later navigation returned to the
same pane.

Attachment-driven geometry uses `OfferActivePaneGeometryHandler`; the active
resource adapter reports whether the pane reservation changed but does not
resolve the workspace projection itself.

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
uses `ReleasePaneResourcesHandler` and sends no byte because the child is
already gone. A canonical tab or workspace transition that invalidates the
whole reporting context enters `RetireReportedPaneFocusHandler`. That handler
has no effect port: it can only call `forgetReportedPaneFocus`, so it cannot
mistake canonical retirement for an intentional focus-out. Repeated retirement
is a no-op.

`pane_focus_reports` is the only adapter that translates semantic focus-in and
focus-out into `pane_input`. Its retirement entrypoint constructs the
effect-free handler and never touches runtime transport. Report bytes do not
count as user-input telemetry. Close-tab and workspace-handoff preflights
reserve the focus-out slot before they mutate attachment state.

## Geometry and presentation

Focus reporting does not own attachment geometry.
`DeliverActivePaneResourcesHandler` first gives the model-derived attachment
target to a physical view effect. If the shelf appears, disappears or moves,
the handler re-offers pane sizes before focus reporting. The geometry
projection shortens only the pane that owns the shelf and places the shelf in
the released rows below it. A fullscreen focus change then invalidates
graphics placements and re-offers the committed focus rectangle.

The same handler exposes `synchronize` for tab, workspace, frame and snapshot
flows whose committed state may change the active pane without entering
`FocusPaneHandler`. Agent snapshots use `synchronizeAttachments`, because a
new agent identity may change the shelf but cannot change child focus. These
entrypoints prevent unrelated adapters from depending on the pane-focus
adapter while preserving one resource order.

A workbench click completes these resource effects before it sends the
triggering mouse event to the new pane. No focus-reporting transition requests
a draw. `client_events` publishes the semantic pane revision, and `Presenter`
folds it into the paced frame loop.

## Failure and recovery

The semantic focus and reported target commit before their resource effects.
If a resize or focus message cannot enter the outbox, the error reaches the
client loop with committed client state. The client exits. Reconnect rebuilds
the reporting state from canonical snapshots and restores retained focus when
the saved pane set is still authoritative. Runtime panes and PTYs continue
running.

## Proof

- `src/frontend/client/model.zig` proves focus resolution, report transitions,
  exact retirement and the absence of presentation revisions for report state.
- `src/frontend/client/application/focus_pane.zig` proves semantic
  commit-before-delivery ordering.
- `src/frontend/client/application/active_pane_resource_delivery.zig` proves
  attachment, reporting and geometry order, stale-focus rejection and partial
  failures.
- `src/frontend/client/application/pane_focus_reporting.zig` proves reporting
  commit order, focus-out before focus-in, effect failure and silent,
  idempotent canonical retirement.
- `src/frontend/client/active_pane_resources.zig` implements view, transport,
  graphics and geometry ports without selecting their order.
- `src/frontend/client/client_test.zig` proves protocol order, mode opt-in,
  exact tab ownership, silent retirement, capacity reservation, mouse ordering
  and presentation through a substituted runtime socket.
