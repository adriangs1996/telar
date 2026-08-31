# Pane split

A split is a runtime pane launch with a client-owned layout intention. The
runtime decides whether the pane exists; the client decides where that pane is
shown. The provisional resize sent before launch is an effect, not a model
commit.

## Flow

```text
client_actions.apply
        |
RequestPaneSplitHandler
        |
ClientModel.planPaneSplit
        |
pane_resize target -> create_pane -> runtime socket
        |
create_pane.Controller -> CreatePaneHandler
        |
launch pane -> attach client -> PendingPaneOpened
        |
schema.pane_opened -> client socket
        |
pane_openings.apply
        |
ConfirmPaneSplitHandler
        |
ClientModel.commitPaneSplit
        |
pane_splits applies attachment, size and focus effects
```

`ClientModel.planPaneSplit` reads the active, focused and attached pane plus
the current workbench geometry. It returns the exact tab identity, target pane,
axis, request-time workbench, provisional target size, restoration size and
new-pane size. Planning does not alter `ClientModel.Version`, so the request
does not schedule a frame. Retaining that workbench with the continuation means
a host resize while launch is in flight cannot invalidate accepted geometry.

`RequestPaneSplitHandler` owns the provisional protocol conversation. It sends
the target resize before `create_pane`; any local delivery failure restores the
pre-request size. The request tracker stores the exact target, tab, axis and
request-time workbench. `pane_openings.apply` consumes that continuation once
and translates the successful protocol response into the confirmation command.

## Runtime confirmation

The backend commits pane launch before replying and identifies a successful
`create_pane` with `created = true`. `ConfirmPaneSplitHandler` rejects a reply
with a different tab, the original target identity or `created = false` before
the model changes.

An active-tab confirmation adds and focuses the created pane, marks it attached
and advances the pane revision once. The adapter then resizes attached panes
and synchronizes focus. It does not invalidate the view or request a draw;
`Presenter.observeModel` notices the revision after the server event and folds
the change into the paced frame loop.

An inactive-tab confirmation records membership but leaves the created pane
detached and advances no visible revision. The adapter sends `detach_pane` for
the attachment created by the runtime and hides any pane graphics. Returning
to that tab uses its canonical snapshot and normal attachment flow.

## Races and recovery

Pane exit and snapshot reconciliation retain a pending split continuation. A
late success carries a new runtime pane identity that the client must either
adopt or explicitly detach; replacing the continuation with `ignored` would
lose that cleanup identity.

If the target pane disappears while launch is in flight but its tab remains,
the confirmation adds the created pane deterministically to that exact tab.
If the tab itself disappears, the model returns a stale commit without adding
the pane. The adapter detaches the runtime attachment and requests one
coalesced workspace snapshot when the client still observes the same
workspace.

A failed request passes through `HandleRequestFailureHandler`, which delegates
size restoration to `RecoverPaneSplitHandler`. Recovery changes size only when
the exact requested target is still attached in the active tab. An inactive
target needs no restoration because tab selection detached it. A retired
target or tab is stale: it receives neither rollback nor an obsolete failure
notification.

## Bounds and proof

The split adds no queue. It occupies the existing singleton `pane_operation`
request slot, and every plan and commit is fixed-size. Provisional resizes use
the coalescing outbox, so a local restore replaces obsolete unsent resize work
when possible.

- `frontend/client/application/split_pane.zig` checks request ordering,
  restoration, exact confirmation, commit-before-effects and recovery gating.
- `frontend/client/model.zig` checks target-exit, inactive-tab and retired-tab
  transitions plus version ownership.
- `frontend/client/requests.zig` checks that lifecycle retirement preserves
  split correlation.
- `frontend/client/client_test.zig` checks protocol delivery, presenter
  observation, inactive detachment, stale-tab refresh and exact failure
  recovery.
- `backend/runtime/commands/create_pane.zig` and
  `backend/runtime/controllers/create_pane.zig` check the runtime launch and
  attachment transaction.
