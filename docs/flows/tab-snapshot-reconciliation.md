# Tab snapshot reconciliation

The runtime owns pane membership. The client owns the layout, cell buffers,
focus, attachments and host graphics associated with those pane identities.
A tab snapshot joins those two sets of responsibilities without replacing
retained client state.

## Flow

```text
bootstrap / tab selection / resync
        |
request_lifecycle.requestTabSnapshot
        |
schema.request_tab_snapshot -> runtime socket
        |
tab_snapshot.Controller -> tab_snapshot.Handler
        |
PendingTabSnapshot -> runtime Encoder
        |
PaneStore.descriptorsAt
        |
schema.tab_snapshot -> client socket
        |
tab_snapshots.apply -> ApplyTabSnapshotHandler
        |
ClientModel.reconcileTab -> tabs.Model.reconcileTab
        |
TabReconciliation commit
        |
DeliverTabSnapshotHandler
        |
retirement -> active resources -> geometry -> missing attachments
        |
presentation_lifecycle.observe -> Presenter
```

The runtime query checks that the tab exists and has a running pane. Its
response queue stores only the stable tab location. The encoder reads the
current pane store when it writes `schema.tab_snapshot`, so queued responses
do not retain borrowed pane data.

`tab_snapshots.apply` consumes the continuation once and verifies the exact tab
location before it delegates. It translates the wire view into a bounded list
of pane identities, so request IDs, encoded descriptors and pane lifecycle
fields do not enter the application or model layers. The controller does not
mutate pane state, touch attachments or request a frame.

## Client commit

`ClientModel.reconcileTab` rejects an unknown tab and any pane identity already
owned by another tab. It captures removed pane IDs before delegating to the
workspace model. The workspace model keeps the buffers, attachment state and
layout nodes of retained panes. It creates newly discovered panes as detached
and removes identities absent from the canonical list.

The model exposes `panes_revision` as part of its presentation version. An
active tab advances that revision when reconciliation changes its layout or
pane membership. Reconciliation of an inactive tab does not advance a visible
revision. Selecting that tab later advances `active_tab_revision` and presents
its current state. An identical snapshot changes no revision.

The commit also captures the exact workspace, tabs, active-tab and pane
revisions, the tab-local layout revision, `snapshot_loaded` and the workbench
area used for reconciliation. The tab-local revision is required because an
inactive tab can change membership without advancing the visible pane version.
Delivery rejects a stale commit in O(1) before touching disposable resources.

Initial reconciliation restores runtime display order or a saved client split
tree. Display order places panes left to right with equal widths; past ten
panes the leading shares clamp at the minimum split ratio. If the previously
focused pane vanished, the layout selects a surviving pane before restoration.
This avoids committing the removal and then failing on a stale focus identity.

Membership never depends on geometry. A discovered pane the workbench cannot
fit still joins the layout, detached and with a placeholder buffer, because
the runtime owns which panes exist. Its content stays empty until the layout
or the workbench gives it room.

The reconciliation result contains at most 64 removed pane IDs. After the
model commit, `DeliverTabSnapshotHandler` marks their pending operations as
ignored and gives each exact identity to `ReleasePaneResourcesHandler`.
Authoritative retirement sends no focus-out. For an active tab, the handler
synchronizes attachment geometry and focus reporting, delegates exact attached
pane sizes to `OfferPaneGeometryHandler`, then delegates attachment selection
to `RequestPaneAttachmentsHandler`: one request for each detached pane with
visible content. A pane with an attachment request already pending does not
receive a duplicate request, and a pane without content is skipped rather than
failed, since it cannot carry a terminal size. The adapter owns request
identities, registration and protocol encoding, not attachment selection
policy.

Resource effects still run for an identical snapshot. This lets a resync
repair sizes or attachments without inventing a model change. The presenter
requests a frame only after `presentation_lifecycle.observe` publishes a
changed version.

## Failure and recovery

An unknown request ID, an incompatible continuation or a response for another
tab is a protocol error. Every known continuation is consumed before rejection.
If tab lifecycle or workspace reconciliation already retired the request, the
controller consumes its `ignored` continuation and discards the late snapshot.

Model validation runs before client resource effects. If a resource effect
fails after commit, the canonical pane membership remains in `ClientModel`; a
later tab snapshot can retry disposable attachments and geometry.

Local tab closure, pane-attachment rejection and pre-commit workspace handoff
each decide whether their own failed operation still needs repair. Once it
does, they delegate snapshot coalescence to
`RequestTabSnapshotRecoveryHandler`. That coordinator checks the singleton
snapshot group and either reuses the pending repair or requests the exact
`TabLocation` once. Adapters expose only the pending query and physical
request; they do not repeat recovery policy.

The runtime bounds each snapshot to `schema.max_panes_per_tab`. Client cleanup
uses the same fixed bound and allocates no unbounded retirement list.

## Proof

- `frontend/client/application/tab_snapshot.zig` checks commit ordering,
  canonical no-ops, model rejection and post-commit effect failure.
- `frontend/client/application/tab_snapshot_delivery.zig` checks exact active
  and inactive validation, retirement, geometry and attachment ordering,
  coalescence and partial failure semantics.
- `frontend/client/application/tab_snapshot_recovery.zig` checks singleton
  coalescence, exact location delivery and request failure propagation.
- `frontend/client/model.zig` checks active and inactive revision semantics,
  removed pane capture, membership bounds and cross-tab pane identity
  rejection.
- `frontend/workspace/tabs.zig` checks display-order restoration, saved layout
  restoration, malformed membership rejection and replacement of a vanished
  focused pane.
- `frontend/client/requests.zig` checks attachment lookup and retirement of
  pane-scoped continuations.
- `frontend/client/request_lifecycle.zig` checks request identity and bounded
  registration before transport delivery.
- `frontend/client/client_test.zig` checks real protocol correlation,
  attachment requests, resource cleanup and the presenter boundary.
- `backend/runtime/queries/tab_snapshot.zig`,
  `backend/runtime/controllers/tab_snapshot.zig` and
  `backend/runtime/encoder.zig` check the canonical runtime half.
