# Copy mode

Copy mode is bounded, disposable client state for navigating one pane's
retained history and selecting text. `ClientModel.copy_state` is its only
authority. It owns the target pane, absolute cursor and anchor, selection mode,
entry viewport and current viewport. `ClientModel.Version.copy` identifies
committed changes independently from workspace, pane, chrome and prompt state.

The state and its motions allocate nothing. The runtime still owns scrollback
and performs the actual copy; the client sends a bounded `copy_selection`
request containing only coordinates.

## Input and commit

```text
host key, mouse wheel or native action
        |
InputHandler
        |
copy_modes adapter
        |
CopyModeHandler
        |
ClientModel.planCopyMode
        |
optional copy_selection effect before exit
        |
ClientModel.commitCopyMode
        |
optional set_pane_viewport effect after commit
        |
ClientModel.Version.copy
```

Entry resolves the attached focused pane and captures its current viewport.
An active name prompt, missing pane or repeated entry is a no-op. While copy
mode is active, raw keyboard and paste input never reaches the child. The mouse
is also captured; only wheel events over the target pane move the copy cursor.
Configured prefix bindings remain available. Any native action other than
copy-mode entry first leaves copy mode and restores its entry viewport.

`ClientModel.planCopyMode` applies the pure motion component to a local state
copy. Unhandled keys and boundary motions return no plan and advance no
revision. `commitCopyMode` accepts only the revision and exact prior state that
were planned, so an obsolete plan cannot overwrite a newer command.

Copy delivery is intentionally ordered before the exit commit. If the outbox
is full, the selection and copy-mode revision remain intact and the user can
retry. Viewport synchronization follows the commit. If that effect fails, the
client retains the committed disposable state; reconnection or a later runtime
frame repairs the operational projection.

## Runtime frames and pane retirement

```text
schema.pane_frame
        |
multiplexer.Model.applyFrame
        |
ClientModel.reconcileCopyModeFrame
        |
copy_mode.onFrame
        |
ClientModel.Version.copy when state changed
```

A frame can prune retained rows or confirm a requested viewport. Reconciliation
pulls absolute selection coordinates across pruned history, clamps them to the
new row count and adopts the runtime viewport. Unrelated or identical frames
do not advance the copy revision.

Pane and tab cleanup call `ClientModel.releaseCopyMode` through
`pane_resources`. Only retirement of the target pane closes the mode. Paste,
focus and graphics cleanup remain separate disposable effects. A model
transition that makes another tab active also releases copy authority, so
routing cannot remain attached to an inactive pane after an asynchronous
runtime response.

## Presentation

Neither the input adapter nor the application handler requests a draw or
writes a pane's `copy_view`. After the client event, the loop publishes the
model version. `Presenter` compares the `copy` revision with its last presented
version, projects the latest immutable `CopyModeProjection` into the
multiplexer damage cache and folds it into the paced frame.

The presenter retains only the projection it last painted. It clears the old
pane when the target changes or copy mode exits. Entering and leaving invalidate
the status bar; cursor and selection movement use exact pane damage instead of
invalidating all chrome. `multiplexer.Pane.copy_view` is therefore a rendering
cache, never semantic authority.

## Proof

- `src/frontend/input/copy_mode.zig` proves fixed-state motions, selection and
  frame reconciliation.
- `src/frontend/client/model.zig` proves entry authority, independent
  revisions, no-ops, stale-plan rejection, frame reconciliation and exact pane
  release.
- `src/frontend/client/application/copy_mode.zig` proves copy-before-exit and
  viewport-after-commit ordering, including both failure policies.
- `src/frontend/client/copy_modes.zig` owns the outbox, graphics and viewport
  adapters.
- `src/frontend/client/client_test.zig` proves routing, backpressure and
  presenter-only projection through the real client boundary.
- `src/frontend/client/presenter.zig` is the only client component that writes
  `multiplexer.Pane.copy_view`.
