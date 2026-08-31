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
attachment sync + actionable alerts
             |
SidebarAnimationHandler.synchronize
             |
Client.observeModel
             |
Presenter -> View.render(agents)
```

Runtime delivery enriches each current agent with canonical workspace, tab,
pane position and bounded display labels immediately before encoding. Its
per-client revision cursor sends the latest snapshot instead of replaying
intermediate revisions.

`agent_snapshots.apply` copies borrowed wire values into fixed stack inputs.
It contains protocol translation and concrete client effects, but no semantic
transition rules. `ApplyAgentSnapshotHandler` orders the model commit before
resource reconciliation and alerts.

## Model transaction

`ClientModel` is the only owner of the client replica. It rejects equal and
older runtime revisions, and `agents.Snapshot` constructs a complete candidate
before assignment. Duplicate identities, invalid labels or capacity errors
leave the previous snapshot and `Version.agents` unchanged.

Each accepted newer snapshot advances the local agent version exactly once.
During the transaction, the model compares exact pane generations with the
previous snapshot and returns status changes only for identities that already
existed. New agents do not look like transitions.

The model also exposes bounded semantic queries. Input asks for an
`AgentNavigationPlan`, attachment capture asks for the focused eligible agent,
the sidebar animation use case asks whether animation is active, and sound
validation asks whether an exact identity exists. None of those callers reads
snapshot storage.

## Effects and presentation

After the commit, the application handler first synchronizes attachment shelf
resources. It then emits at most the notification center capacity of
transitions to `blocked`, `ready` or `failed`. Failure in an effect does not
roll back the committed runtime state.

The adapter then invokes the separate sidebar-animation use case. A working
agent ensures that one future tick is armed; a snapshot does not advance the
visible animation frame. Animation ownership and timer failure are documented
in [Sidebar animation](sidebar-animation.md).

The snapshot itself does not request a draw. At the event boundary,
`Client.observeModel` publishes the current version. `Presenter` compares
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
- `src/frontend/client/application/agent_snapshot.zig` proves commit-before-
  effect ordering, actionable filtering, alert bounds and retained commits on
  effect failure.
- `src/frontend/client/application/sidebar_animation.zig` and
  `src/frontend/client/sidebar_animations.zig` separate active-state policy
  from the single pending timer.
- `src/frontend/widgets/sidebar.zig` proves local pane-index projection does
  not mutate the runtime replica.
- `src/frontend/client/client_test.zig` proves protocol adaptation,
  presenter-owned drawing, alert content and exact sound identity validation.
- `src/backend/runtime/delivery.zig` proves runtime enrichment and per-client
  revision delivery.
