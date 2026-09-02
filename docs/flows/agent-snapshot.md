# Agent snapshot

The runtime owns agent identity, evidence and status. Each disposable client
stores one bounded copy for navigation, attachment eligibility, sound
validation and sidebar presentation. The view owns no second semantic copy.

## End-to-end path

```text
backend agent.Tracker revision
             |
runtime Delivery.prepare
             |
schema.agent_snapshot
             |
server_messages dispatcher
             |
agent_snapshots adapter
             |
ApplyAgentSnapshotHandler
             |
ClientModel.reconcileAgentSnapshot
             |
agents.Snapshot + Version.agents
             |
DeliverAgentSnapshotHandler
             |
attachment sync + actionable alerts
             |
SidebarAnimationHandler.synchronize
             |
presentation_lifecycle.observe
             |
Presenter -> View.render(agents)
```

Runtime delivery enriches each current agent with canonical workspace, tab,
pane position and bounded display labels immediately before encoding. Its
per-client revision cursor sends the latest snapshot instead of replaying
intermediate revisions.

`agent_snapshots.apply` copies borrowed wire values into fixed stack inputs and
supplies only concrete client ports. `ApplyAgentSnapshotHandler` owns the model
commit and delegates its exact result to `DeliverAgentSnapshotHandler`. The
adapter contains no transition, alert or ordering policy.

## Model transaction

`ClientModel` is the only owner of the client replica. It rejects equal and
older runtime revisions, and `agents.Snapshot` constructs a complete candidate
before assignment. Duplicate identities, invalid labels or capacity errors
leave the previous snapshot and `Version.agents` unchanged.

Each accepted newer snapshot advances the local agent version exactly once.
During the transaction, the model compares exact pane generations with the
previous snapshot and returns status changes only for identities that already
existed. The commit carries the local revision before and after replacement so
delivery can prove that it represents exactly one accepted snapshot. New
agents do not look like transitions.

The model also exposes bounded semantic queries. Input asks for an
`AgentNavigationPlan`, attachment capture asks for the focused eligible agent,
the sidebar animation use case asks whether animation is active, and sound
validation asks whether an exact identity exists. None of those callers reads
snapshot storage. [Agent navigation](agent-navigation.md) owns the ordered local
focus or remote handoff selected from that plan.

## Effects and presentation

After validating the runtime revision, entry count, one-step local revision and
every reported current identity, the delivery handler enters
`DeliverActivePaneResourcesHandler.synchronizeAttachments`. It reconciles the
attachment shelf and re-offers pane geometry only if the shelf appeared,
disappeared or moved to another pane, delegating active-tab selection to
`OfferActivePaneGeometryHandler`; it cannot emit child focus reports. Delivery
then translates transitions to `blocked`, `done` or `failed` into notification
inputs and emits at most the notification center capacity. Failure in a
delivery stage does not roll back the committed runtime state.

Finally, the same delivery handler invokes the separate sidebar-animation use
case. A working agent ensures that one future tick is armed; a snapshot does
not advance the visible animation frame. Animation ownership and timer failure
are documented in [Sidebar animation](sidebar-animation.md).

The snapshot itself does not request a draw. At the event boundary,
`presentation_lifecycle.observe` publishes the current version. `Presenter` compares
`Version.agents` with the version it last painted, resets transient sidebar
scroll, invalidates chrome and passes `ClientModel.agentSnapshot()` to the
view on the paced frame.

Sidebar composition derives focused highlighting and any active-layout pane
index during rendering. The stored runtime entry remains unchanged. Several
accepted snapshots inside one frame interval fold into one render of the
latest revision.

## Failure recovery

Agent sounds consult this replica only for exact identity authority. Their
separate worker lifecycle and local policy are documented in
[Agent sound](agent-sound.md).

A reconnect constructs an empty disposable model and receives the current
runtime revision through a fresh delivery cursor. A stale snapshot is a no-op.
Malformed wire data is rejected before the adapter. The domain storage still
validates its public input independently; any rejection preserves the last
usable replica and its local version.

## Proof

- `src/frontend/agents/snapshot.zig` proves bounded ownership, stale rejection,
  exact identity lookup and atomic validation failure.
- `src/frontend/client/model.zig` proves isolated versioning, transition
  detection, navigation, attachment eligibility and immutable queries.
- `src/frontend/client/application/agent_snapshot.zig` proves atomic commit
  before exact delivery, stale suppression and retained commits on delivery
  failure.
- `src/frontend/client/application/agent_snapshot_delivery.zig` proves exact
  commit validation, attachment-alert-animation ordering, alert policy and
  bounds, and failure cutoffs.
- `src/frontend/client/application/active_pane_resource_delivery.zig` proves
  attachment-only synchronization and conditional geometry delivery.
- `src/frontend/client/application/sidebar_animation.zig` and
  `src/frontend/client/sidebar_animations.zig` separate active-state policy
  from the single pending timer.
- `src/frontend/widgets/sidebar.zig` proves local pane-index projection does
  not mutate the runtime replica.
- `src/frontend/client/client_test.zig` proves protocol adaptation,
  presenter-owned drawing, alert content and exact sound identity validation.
- `src/backend/runtime/delivery.zig` proves runtime enrichment and per-client
  revision delivery.
