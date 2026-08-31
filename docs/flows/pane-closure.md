# Pane closure

A pane leaves the client only when the runtime reports `pane_exited`. An
explicit close request asks the runtime to stop a child, but it is not a model
transition and has no success acknowledgement. The same client transition
therefore handles requested closure and a child that exits by itself.

## Explicit request

```text
client_actions.apply
        |
RequestClosePaneHandler
        |
ClientModel.planPaneClosure
        |
schema.close_pane -> runtime socket
        |
close_pane.Controller -> ClosePaneHandler
        |
request idempotent PTY shutdown
```

`ClientModel.planPaneClosure` resolves the active, focused and attached pane
plus its exact tab identity. Planning is read-only. It does not remove the
pane, detach it, advance `ClientModel.Version` or schedule presentation.

`RequestClosePaneHandler` rejects another pending pane operation and sends the
request through the existing fixed-capacity tracker. The continuation retains
the pane and tab identities needed to correlate a failure. The wire message
needs only the request and pane identities because the runtime authorizes the
operation through that client's attachment.

The runtime `ClosePaneHandler` requests `Pane.requestClose` through the
requesting client's attachment. Repeating the command is harmless. A missing
attachment returns `request_failed`; success queues no response because child
shutdown and output draining have not completed yet.

## Authoritative exit

```text
child exit -> drain output and outstanding frame acknowledgement
        |
schema.pane_exited -> client socket
        |
pane_closures.applyExit
        |
HandlePaneExitHandler
        |
ClientModel.retirePane
        |
pane_closures releases continuations, resources, focus and sizes
        |
Presenter.observeModel
```

The runtime sends `pane_exited` only after terminal ingestion has finished and
the attachment has no outstanding frame. Committing that delivery detaches
the runtime attachment, allowing the exited pane to be reaped later.

The dispatcher only delegates the decoded event. `pane_closures.applyExit`
removes the wire-only process outcome and passes the stable pane identity to
`HandlePaneExitHandler`. Exit kind and value do not affect disposable client
cleanup; process lifecycle remains runtime-owned. The slice returns the
resulting `retired` or `stale` transition for direct observation.

`ClientModel.retirePane` locates the pane globally by stable identity and
removes it from its exact tab. Retirement in the active tab advances the pane
revision once. Retirement in an inactive tab changes stored membership but no
visible revision. A missing or repeated identity is stale and changes nothing.

After the model commit, `pane_closures` completes a matching close
continuation, retires a pending attachment, and releases copy, paste,
reported-focus and graphics state keyed by the pane. Report release is silent
because the authoritative exit means no child remains to receive focus-out.
Active-tab retirement then synchronizes the new focused pane and re-offers
attached sizes. Inactive and stale exits do not touch active focus or geometry.

The handler neither invalidates the view nor requests a draw. The presenter
observes the model revision independently and folds an active retirement into
the paced frame loop. A stale event and an inactive retirement schedule no
frame.

## Final pane and races

Removing the final pane temporarily leaves an empty client tab. Once every
client attachment is gone, `Server.collectFinished` destroys the runtime pane.
If its tab has no remaining panes, the runtime publishes the separate canonical
`tab_closed` lifecycle fact. The tab-removal flow then removes that tab and, if
necessary, its workspace.

A natural child exit follows the same pane transition without a close
continuation. A late or repeated exit still runs idempotent resource cleanup so
an attachment continuation cannot revive the pane. A pending split
continuation is deliberately preserved: its later `pane_opened` response owns
a distinct runtime pane that must still be adopted or detached.

## Bounds and proof

The flow adds no queue or allocation to the interactive path. Planning and
retirement scan only the bounded tab and pane stores. Close correlation uses
the existing singleton `pane_operation` slot, and resize effects use the
coalescing outbox.

- `frontend/client/application/close_pane.zig` checks request gating, pure
  planning, commit-before-effects, stale cleanup and committed-effect failure.
- `frontend/client/pane_closures.zig` checks wire translation and owns request,
  resource, focus and geometry effects after the application transition.
- `frontend/client/model.zig` checks active, inactive and repeated retirement
  plus presentation revision ownership.
- `frontend/client/requests.zig` checks exact close completion and attachment
  retirement without suppressing split correlation.
- `frontend/client/client_test.zig` checks the close wire message, natural and
  requested exits, resource cleanup, inactive exits and presenter observation.
- `backend/runtime/commands/close_pane.zig` and
  `backend/runtime/controllers/close_pane.zig` check attachment authorization,
  idempotent shutdown and the absence of an invented success acknowledgement.
- Runtime attachment and transport tests check output-before-exit delivery,
  post-send detachment, pane reaping and final-tab closure.
