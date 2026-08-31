# Workspace snapshot reconciliation

The runtime owns workspace names, tab membership, tab labels and tab order.
The client keeps a disposable replica and owns the layout, focus, attachments
and host graphics associated with that replica.

## Workspace rename

```text
name prompt -> InputHandler -> name_prompts.handleInput
        |
NamePromptHandler -> name_prompts submit effect
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
workspace_snapshots.apply -> ApplyWorkspaceSnapshotHandler
        |
ClientModel.reconcileWorkspace -> tabs.Model.reconcileWorkspace
        |
WorkspaceReconciliation commit
        |
DeliverWorkspaceSnapshotHandler
        |
retirement -> active resources -> snapshot or geometry recovery
        |
presentation_lifecycle.observe -> Presenter
```

`RequestRenameWorkspaceHandler` accepts only the workspace currently projected
by `ClientModel` and refuses overlapping workspace operations. Its adapter
copies the borrowed name into the outbox before `NamePromptHandler` closes the
model-owned prompt. Sending the request does not change the canonical workspace
replica.

The runtime aggregate commits the name and publishes an owned
`WorkspaceRenamed` event. The controller queues a workspace reference rather
than a borrowed snapshot. The runtime encoder reads the latest workspace and
pane state when it sends `schema.workspace_snapshot`, so queued work cannot
preserve an obsolete list.

## Client commit

`workspace_snapshots.apply` consumes the matching `rename_workspace` or
`workspace_snapshot` continuation once and verifies the exact workspace. It
translates the wire descriptors into a fixed array of domain tab inputs. Slice
order carries canonical position, so request IDs, encoded bytes and protocol
positions stop at the controller. Names and labels are borrowed only during
the synchronous call; the workspace model copies them before it returns.

The controller does not mutate tabs, release resources or request a frame.

`ClientModel.reconcileWorkspace` validates the complete bounded descriptor
list before mutation. It records tabs and panes that disappear, preserves
retained tab layouts, then classifies the committed result:

- A changed workspace name increments `workspace_revision`.
- Changed membership, order or tab labels increment `tabs_revision` once.
- Losing the active tab increments `active_tab_revision` once.
- An identical snapshot changes no revision.

The reconciliation captures those three revisions, the current pane revision
and the active tab's exact `snapshot_loaded` state. Delivery rejects the commit
if topology or recovery state changed before any disposable resource is
touched.

A pane-count mismatch marks the corresponding tab snapshot stale. That is a
synchronization requirement, not a visible model change, so it does not advance
a presentation revision.

The result holds at most 64 removed tabs and 4096 removed pane IDs. The
reconciliation allocates no unbounded storage. After the commit, the client
delivery handler ignores requests for removed tabs and gives each pane identity
to `ReleasePaneResourcesHandler`. When the active tab changes,
`RetireReportedPaneFocusHandler` silently forgets the previous reporting
context before the handler synchronizes the new active tab. It then preserves
an existing tab-snapshot request, requests one when needed, or delegates exact
attached-pane sizing to `OfferPaneGeometryHandler`. The adapter implements only
request tracking, graphics, active-resource and runtime-resize ports.

The resource effects still run for an identical workspace snapshot because a
resync may be about attachments or geometry. The presenter receives only model
versions, so that operational recovery does not force a frame.

## Resync and failure

`schema.resync_required` enters `resync_requirements.apply`.
`HandleResyncRequiredHandler` validates the projected workspace and requests
one coalesced workspace snapshot. The later correlated snapshot follows the
same commit path described above. A workspace that closes before snapshot
encoding returns `schema.request_failed` instead of stale state.

A pending workspace operation or a prompt targeting another workspace emits no
rename request and leaves the prompt open. A local delivery failure does the
same. An unknown request ID, incompatible continuation or mismatched workspace
is a protocol error. Every known continuation is consumed before rejection.
Runtime rejection consumes the continuation and uses the existing failure
notification. A model validation failure runs no client effects. If resource
synchronization fails after a valid commit, the committed replica remains and
a later resync or reconnect rebuilds the disposable resources.

## Proof

- `frontend/client/application/rename_workspace.zig` proves request gating,
  stale-target rejection, delivery failure and absence of provisional state.
- `frontend/client/name_prompt.zig`,
  `frontend/client/application/name_prompt.zig` and
  `frontend/client/name_prompts.zig` prove editor ownership and submit ordering.
- `frontend/client/application/workspace_snapshot.zig` proves commit-before-
  effects ordering and post-commit failure semantics.
- `frontend/client/application/workspace_snapshot_delivery.zig` proves exact
  validation, retirement and activation ordering, request coalescence,
  geometry recovery and partial failure semantics.
- `frontend/client/workspace_snapshots.zig` owns correlation and wire-to-domain
  translation plus concrete client ports.
- `frontend/client/application/resync_required.zig` proves resync validation,
  coalescence and absence of direct model or presentation work.
- `frontend/client/model.zig` proves independent workspace, tab and active-tab
  revisions, canonical no-ops and bounded retirement data.
- `frontend/workspace/tabs.zig` proves retained layouts and replacement at the
  64-tab capacity, plus atomic rejection of malformed domain snapshots.
- `frontend/client/client_test.zig` proves the prompt, wire correlation,
  resource cleanup, active-tab recovery and presenter boundary through the real
  client adapters.
- `backend/runtime/commands/rename_workspace.zig`,
  `backend/runtime/controllers/rename_workspace.zig` and
  `backend/runtime/encoder.zig` prove the authoritative half.
