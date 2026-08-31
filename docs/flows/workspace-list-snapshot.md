# Workspace list snapshot

The runtime owns the set and order of open workspaces. Each disposable client
keeps one bounded replica so the top bar can present that set and input can
resolve positional navigation to a stable `WorkspaceId`.

## End-to-end path

```text
workspace.Repository revision
        |
runtime delivery cursor
        |
schema.workspace_list
        |
server_messages dispatcher
        |
workspace_lists adapter
        |
ReconcileWorkspaceListHandler
        |
ClientModel.reconcileWorkspaceList
        |
ClientModel.Version.workspace_list
        |
presentation_lifecycle.observe
        |
Presenter -> View.render(workspaces)
```

The runtime delivery cursor compares its last delivered revision with the
repository revision and encodes the latest list. It does not queue historical
lists. The wire decoder rejects revision zero, more than 64 entries, duplicate
workspace identities, oversized names or paths and invalid tab counts before
the client adapter runs.

`workspace_lists.apply` translates borrowed wire entries into domain inputs on
the stack. `ReconcileWorkspaceListHandler` delegates the transaction to
`ClientModel`; neither layer references `View`, `Presenter` or input routing.

## Client ownership

`ClientModel` is the only owner of the client-side replica. The reusable
`workspace.workspace_list.Snapshot` stores at most 64 entries, truncates display
names to 48 bytes without ending inside a UTF-8 continuation sequence and
retains complete paths in a shared 16 KiB pool. Replacement allocates nothing
and builds a local candidate before assignment, so every validation or capacity
failure preserves the last usable snapshot.

Only a newer runtime revision commits. A commit advances
`ClientModel.Version.workspace_list` once. Equal and older revisions are
canonical no-ops. This presentation revision is local to the client and is
separate from the runtime revision retained in the snapshot.

The model exposes bounded queries for stable identity and zero-based position.
The shared client action dispatcher uses those queries when a top-bar click,
native binding, Lua binding or plugin action selects a workspace. `View` is
not navigation authority and owns no second copy of the list.

## Presentation

The server-message path never requests a draw. After the event completes,
`client_events` publishes the current model version. `Presenter` compares the
workspace-list revision with the last version it painted, invalidates client
chrome and passes the current immutable snapshot to `View.render` when the
paced frame is due.

The presenter retains only version values. For this slice, the view retains
only hit regions from the rendered frame. Several runtime updates that arrive
inside one frame interval therefore fold into one rendering of the latest model
snapshot.

## Failure and recovery

A wire-valid list can still exceed the client's 16 KiB aggregate path budget.
The adapter classifies that model error as a rejected snapshot and leaves the
previous replica and model version intact. Runtime delivery continues with
later repository revisions, each of which gets a fresh reconciliation attempt.
A reconnect constructs a new disposable client model and receives the current
runtime revision through a fresh delivery cursor.

## Proof

- `src/frontend/workspace/workspace_list.zig` proves fixed-capacity copying,
  stale-revision rejection, UTF-8 truncation and atomic capacity failure.
- `src/frontend/client/model.zig` proves sole ownership, bounded navigation
  queries and isolated version publication.
- `src/frontend/client/application/workspace_list_snapshot.zig` proves the use
  case changes only committed client state.
- `src/frontend/client/client_test.zig` proves protocol reconciliation happens
  before presentation, emits no direct draw and reaches the top bar only after
  presenter observation.
- `src/backend/runtime/delivery.zig` and
  `src/backend/workspace/repository.zig` prove the runtime authority and
  per-client revision cursor.
