# Workspace handoff

A workspace handoff replaces one disposable client projection with another.
The runtime remains authoritative for pane and workspace existence; the client
owns navigation history, the explicit empty transition between projections,
and when each committed model version reaches the terminal.

## Request and departure

```text
workspace position or identity -> SelectWorkspaceHandler --+
                                                           |
sidebar agent, resync or workspace closure ----------------+
                                                           |
                                      RequestWorkspaceHandoffHandler
                                                           |
                                      PrepareWorkspaceHandoffHandler
                                                           |
detach active runtime attachments -> schema.open_pane
                                                           |
ClientModel.departWorkspace
                                                           |
ReleaseWorkspaceResourcesHandler
                                                           |
presentation_lifecycle.observe -> present empty client model
```

`SelectWorkspaceHandler` resolves positions and stable identities through the
committed workspace-list replica. It suppresses unknown, already active and
request-blocked selections without changing client state. This policy is
shared by configured actions, workspace-list clicks and notification targets.

`workspace_handoffs` resolves an accepted workspace bookmark to its last
focused pane. Without a bookmark it targets the workspace identity. A sidebar
agent can target its pane directly and retains a workspace fallback only when
the pane belongs to an ordinary workspace. [Agent navigation](agent-navigation.md)
owns that local-or-remote decision.

`HandleResyncRequiredHandler` also requests a handoff when the runtime reports
that the projected workspace disappeared. It forgets the closed workspace's
bookmark first and uses the runtime's canonical predecessor as the target. A
failed handoff cannot restore identity that no longer exists.

`PrepareWorkspaceHandoffHandler` checks that the fixed outbox has room for a
required paste-closing marker, focus-out, every detach and the final open before
it changes attachment state. It reserves focus-out only when the reported pane
still exists, remains attached and has focus events enabled. Every attached
pane and every unattached pane with an attachment request in flight reserves a
detach slot. This prevents a pending attachment from consuming capacity that
the old adapter preflight did not account for. The per-tab count is owned by
the same retirement rule used by tab closure, so both flows reserve identical
paste, focus and attachment deliveries.

After the capacity gate, the preparation handler delegates each tab to
`RetireTabAttachmentsHandler`, which closes the paste and delivers detaches in
tab and pane order before `open_pane`; socket order prevents the new attachment
from preceding retirement of the old ones. `workspace_handoffs` now supplies
only outbox capacity and the physical paste, focus, attachment and graphics
ports. A local detach or open failure does not commit departure and requests a
canonical tab snapshot to repair any provisional attachment effects.

`RestoreWorkspaceHandoffHandler` owns that local recovery. It captures the
still-active tab, restores graphics for its panes in stable order and then
delegates canonical repair to `RequestTabSnapshotRecoveryHandler`, which
coalesces an existing tab snapshot or requests the exact location once. A
restoration failure preserves completed physical effects but never replaces
the original detach or open error returned by the handoff request.

Only after `open_pane` is accepted locally does `ClientModel.departWorkspace`
commit the empty model. It captures the source workspace, focused tab, focused
pane, client-owned layout and every pane identity in fixed-capacity values,
then advances the affected workspace, tab, active-tab and pane revisions once.
`ReleaseWorkspaceResourcesHandler` copies the bookmark into navigation history
and gives every retired pane identity to `ReleasePaneResourcesHandler`.
`RetireReportedPaneFocusHandler` then removes any remaining stale reporting
context without emitting child input.

The use case neither invalidates the view nor requests a draw. `client_events`
publishes `ClientModel.Version` to `Presenter`, which presents the empty model
as a normal blank cell grid and records that version. Re-observing it schedules
nothing, so an outstanding runtime reply cannot produce a 60 Hz redraw loop.

## Confirmation and arrival

```text
open_pane.Controller -> OpenPaneHandler
        |
schema.pane_opened -> client socket
        |
pane_openings.apply
        |
DeliverPaneOpenHandler
        |
ConfirmWorkspaceHandoffHandler
        |
ClientModel.arriveWorkspace
        |
WorkspaceActivation
        |
ActivateWorkspaceHandler
        |
focus sync -> input read -> workspace snapshot -> tab snapshot
        |
presentation_lifecycle.observe -> present arrived workspace
```

The `initial_open` continuation correlates the runtime response.
`pane_openings.apply` consumes it once, removes its request identity and
translates it to the narrow application continuation. `DeliverPaneOpenHandler`
selects the handoff-arrival port. Before the commit, that concrete port copies a
saved layout only when its exact tab identity matches the confirmed location.

`ClientModel.arriveWorkspace` accepts only an empty model. The tab store builds
the root tab and confirmed pane transactionally before publishing them, then
the model stages the saved layout and advances all four semantic dimensions
once. It returns a `WorkspaceActivation` carrying every pre/post semantic
revision and the exact copy revision transition. Construction failure therefore
preserves the prior empty model and every revision.

`ActivateWorkspaceHandler` runs after the commit. It validates the active pane
and root, the current revisions, every one-step semantic delta and the exact
copy release. It then synchronizes attachment geometry and
`ClientModel.reported_pane_focus`, schedules host input, and requests canonical
workspace and tab snapshots in order. The tab snapshot restores the saved
split tree only if the runtime still reports exactly the bookmarked pane set;
otherwise normal deterministic display order wins. Delivery failure does not
roll the confirmed model back.

The dispatcher does not draw the arrival. The presenter observes its new
version independently. Its compositor detects the new immutable source and
dimensions and folds one complete composition into the paced frame loop.

## Stale bookmark recovery

A handoff that targets a remembered pane retains its containing workspace in
the continuation. If the runtime reports `pane_not_found`,
`HandleRequestFailureHandler` delegates to `RecoverWorkspaceHandoffHandler`,
which forgets that bookmark and retries once with a workspace target. The
client remains in its already presented empty version; the retry is not
another model transition.

A missing fallback or any other failure code is unrecoverable and propagates
as `RuntimeRequestFailed`. The workspace retry carries no fallback, so another
failure cannot form a retry loop.

## Bounds and proof

The handoff adds no queue, and departure allocates nothing. It scans the
bounded tab and pane stores, returns pane identities in
`RemovedWorkspacePanes`, and reuses the existing fixed request tracker and
outbox. Arrival reuses the empty fixed tab store; only the confirmed pane's
normal cell buffer and damage-row bootstrap allocations occur before commit.

- `src/frontend/client/application/workspace_handoff.zig` checks selection,
  gating, request ordering, local recovery, commit-before-effects and exact
  retry conditions.
- `src/frontend/client/application/pane_open_delivery.zig` checks
  successful-open routing, retired work and delivery failure propagation.
- `src/frontend/client/application/workspace_handoff_preparation.zig` checks
  complete capacity accounting, pending attachments, preflight-before-effects,
  multi-tab retirement order and partial detach failures.
- `src/frontend/client/application/workspace_handoff_restoration.zig` checks
  active-pane graphics order, snapshot coalescence and partial recovery
  failures.
- `src/frontend/client/application/workspace_transition_delivery.zig` checks
  resource retirement, exact activation validation, ordered snapshot requests
  and partial failures.
- `src/frontend/client/model.zig` checks idempotent departure, bounded capture,
  atomic arrival, rejected arrival and saved-layout staging.
- `src/frontend/client/client_test.zig` checks protocol order, navigation and
  resource cleanup, outbox preflight, the presented empty version, confirmed
  arrival and stale-pane fallback.
- `src/frontend/client/presenter.zig` owns both empty and populated model
  presentation; neither handoff use case contains a draw decision.
- `src/backend/runtime/controllers/open_pane.zig` checks authoritative target
  resolution, attachment and exact failure mapping.
