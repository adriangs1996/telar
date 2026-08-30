# Workspace handoff

A workspace handoff replaces one disposable client projection with another.
The runtime remains authoritative for pane and workspace existence; the client
owns navigation history, the explicit empty transition between projections,
and when each committed model version reaches the terminal.

## Request and departure

```text
workspace selection, sidebar agent, resync or workspace closure
        |
RequestWorkspaceHandoffHandler
        |
detach active runtime attachments -> schema.open_pane
        |
ClientModel.departWorkspace
        |
release pane resources and remember navigation bookmark
        |
Presenter.observeModel -> present empty client model
```

`workspace_handoffs` resolves a workspace bookmark to its last focused pane.
Without a bookmark it targets the workspace identity. A sidebar agent can
target its pane directly and retains a workspace fallback only when the pane
belongs to an ordinary workspace.

The adapter checks that the fixed outbox has room for focus-out, every detach
and the final open before it changes attachment state. The request handler then
delivers detaches before `open_pane`; socket order prevents the new attachment
from preceding retirement of the old ones. A local detach or open failure does
not commit departure and requests a canonical tab snapshot to repair any
provisional attachment effects.

Only after `open_pane` is accepted locally does `ClientModel.departWorkspace`
commit the empty model. It captures the source workspace, focused tab, focused
pane, client-owned layout and every pane identity in fixed-capacity values,
then advances the affected workspace, tab, active-tab and pane revisions once.
Post-commit effects copy the bookmark into navigation history and release copy,
paste, reported-focus and graphics resources for every retired pane.

The use case neither invalidates the view nor requests a draw. The runtime loop
publishes `ClientModel.Version` to `Presenter`, which presents the empty model
as a normal blank cell grid and records that version. Re-observing it schedules
nothing, so an outstanding runtime reply cannot produce a 60 Hz redraw loop.

## Confirmation and arrival

```text
open_pane.Controller -> OpenPaneHandler
        |
schema.pane_opened -> client socket
        |
ConfirmWorkspaceHandoffHandler
        |
ClientModel.arriveWorkspace
        |
focus sync -> input read -> workspace snapshot -> tab snapshot
        |
Presenter.observeModel -> present arrived workspace
```

The `initial_open` continuation correlates the runtime response. Before the
commit, the adapter copies a saved layout only when its exact tab identity
matches the confirmed location.

`ClientModel.arriveWorkspace` accepts only an empty model. The tab store builds
the root tab and confirmed pane transactionally before publishing them, then
the model stages the saved layout and advances all four semantic dimensions
once. Construction failure therefore preserves the prior empty model and every
revision.

Operational effects run after the commit. They validate the active pane,
synchronize reported focus, schedule host input, and request canonical
workspace and tab snapshots. The tab snapshot restores the saved split tree
only if the runtime still reports exactly the bookmarked pane set; otherwise
normal deterministic display order wins. Effect failure does not roll the
confirmed model back.

The dispatcher does not draw the arrival. The presenter observes its new
version independently, invalidates the affected composition dimensions and
folds the result into the paced frame loop.

## Stale bookmark recovery

A handoff that targets a remembered pane retains its containing workspace in
the continuation. If the runtime reports `pane_not_found`,
`RecoverWorkspaceHandoffHandler` forgets that bookmark and retries once with a
workspace target. The client remains in its already presented empty version;
the retry is not another model transition.

A missing fallback or any other failure code is unrecoverable and propagates
as `RuntimeRequestFailed`. The workspace retry carries no fallback, so another
failure cannot form a retry loop.

## Bounds and proof

The handoff adds no queue, and departure allocates nothing. It scans the
bounded tab and pane stores, returns pane identities in
`RemovedWorkspacePanes`, and reuses the existing fixed request tracker and
outbox. Arrival reuses the empty fixed tab store; only the confirmed pane's
normal cell buffer and damage-row bootstrap allocations occur before commit.

- `src/frontend/client/application/workspace_handoff.zig` checks gating,
  request ordering, local recovery, commit-before-effects and exact retry
  conditions.
- `src/frontend/client/model.zig` checks idempotent departure, bounded capture,
  atomic arrival, rejected arrival and saved-layout staging.
- `src/frontend/client/client_test.zig` checks protocol order, navigation and
  resource cleanup, outbox preflight, the presented empty version, confirmed
  arrival and stale-pane fallback.
- `src/frontend/client/presenter.zig` owns both empty and populated model
  presentation; neither handoff use case contains a draw decision.
- `src/backend/runtime/controllers/open_pane.zig` checks authoritative target
  resolution, attachment and exact failure mapping.
