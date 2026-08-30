# Workspace snapshot reconciliation

The runtime owns workspace names, tab membership, tab labels and tab order.
The client keeps a disposable replica and owns the layout, focus, attachments
and host graphics associated with that replica.

## Workspace rename

```text
name prompt -> InputHandler.submitWorkspaceRename
        |
RequestRenameWorkspaceHandler -> RenameRequestEffects.send
        |
schema.rename_workspace -> runtime socket
        |
rename_workspace.Controller -> RenameWorkspaceHandler
        |
Workspace.rename -> WorkspaceRenamed
        |
PendingWorkspaceSnapshot -> runtime Encoder
        |
schema.workspace_snapshot -> client socket
        |
handleWorkspaceSnapshot -> ApplyWorkspaceSnapshotHandler
        |
ClientModel.reconcileWorkspace -> tabs.Model.reconcileWorkspace
        |
ReconciliationEffects -> client resource synchronization
        |
Client.observeModel -> Presenter
```

`RequestRenameWorkspaceHandler` accepts only the workspace currently projected
by `ClientModel` and refuses overlapping workspace operations. Its adapter
copies the borrowed name into the outbox before the prompt closes. Sending the
request does not change the client replica.

The runtime aggregate commits the name and publishes an owned
`WorkspaceRenamed` event. The controller queues a workspace reference rather
than a borrowed snapshot. The runtime encoder reads the latest workspace and
pane state when it sends `schema.workspace_snapshot`, so queued work cannot
preserve an obsolete list.

## Client commit

`handleWorkspaceSnapshot` consumes the matching `rename_workspace` or
`workspace_snapshot` continuation and delegates. It does not mutate tabs,
release resources or request a frame.

`ClientModel.reconcileWorkspace` validates the complete bounded descriptor
list before mutation. It records tabs and panes that disappear, preserves
retained tab layouts, then classifies the committed result:

- A changed workspace name increments `workspace_revision`.
- Changed membership, order or tab labels increment `tabs_revision` once.
- Losing the active tab increments `active_tab_revision` once.
- An identical snapshot changes no revision.

A pane-count mismatch marks the corresponding tab snapshot stale. That is a
synchronization requirement, not a visible model change, so it does not advance
a presentation revision.

The result holds at most 64 removed tabs and 4096 removed pane IDs. The
reconciliation allocates no unbounded storage. After the commit, the client
adapter ignores requests for removed tabs, releases their copy, paste, focus
and graphics state, and restores the new active tab. It requests a tab snapshot
when needed. An otherwise current active tab re-offers its size to recover a
lost geometry lease.

The resource effects still run for an identical workspace snapshot because a
resync may be about attachments or geometry. The presenter receives only model
versions, so that operational recovery does not force a frame.

## Resync and failure

`schema.resync_required` follows the same commit path after
`handleResyncRequired` requests one coalesced workspace snapshot. A workspace
that closes before encoding returns `schema.request_failed` instead of stale
state.

A pending workspace operation or a prompt targeting another workspace emits no
rename request and leaves the prompt open. A local delivery failure does the
same. Runtime rejection consumes the continuation and uses the existing failure
notification. A model validation failure runs no client effects. If resource
synchronization fails after a valid commit, the committed replica remains and
a later resync or reconnect rebuilds the disposable resources.

## Proof

- `frontend/client/application/rename_workspace.zig` proves request gating,
  stale-target rejection, delivery failure and absence of provisional state.
- `frontend/client/application/workspace_snapshot.zig` proves commit-before-
  effects ordering and post-commit failure semantics.
- `frontend/client/model.zig` proves independent workspace, tab and active-tab
  revisions, canonical no-ops and bounded retirement data.
- `frontend/workspace/tabs.zig` proves retained layouts and replacement at the
  64-tab capacity.
- `frontend/client/client_test.zig` proves the prompt, wire correlation,
  resource cleanup, active-tab recovery and presenter boundary through the real
  client adapters.
- `backend/runtime/commands/rename_workspace.zig`,
  `backend/runtime/controllers/rename_workspace.zig` and
  `backend/runtime/encoder.zig` prove the authoritative half.
