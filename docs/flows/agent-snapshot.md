# Agent snapshot

The runtime owns agent identity, evidence and status. Each disposable client
stores one bounded copy for navigation, attachment eligibility, sound
validation and sidebar presentation. The view owns no second semantic copy.

## End-to-end path

```text
runtime tracker → runtime delivery → agent_snapshot
  → AttachedClient.handleServerMessage
  → AttachedClient.applyAgentSnapshot
      model.reconcileAgentSnapshot
      AttachedClient.synchronizePaneAttachments
      bounded notifications
      AttachedClient.synchronizeSidebarAnimation
  → event-loop presentation observation
```

Runtime delivery enriches each current agent with canonical workspace, tab,
pane position and bounded display labels immediately before encoding. Its
per-client revision cursor sends the latest snapshot instead of replaying
intermediate revisions.

`AttachedClient.applyAgentSnapshot` copies borrowed wire values into bounded inputs, commits
the model and delivers the dependent resources in one synchronous operation.

## Model transaction

`ClientModel` is the only owner of the client replica. It rejects equal and
older runtime revisions, and `agents.Snapshot` constructs a complete candidate
before assignment. Duplicate identities, invalid labels or capacity errors
leave the previous snapshot and `Version.agents` unchanged.

Each accepted newer snapshot advances the local agent version exactly once.
During the transaction, the model compares exact pane generations with the
previous snapshot and returns status changes only for identities that already
existed. The commit carries the local revision and status changes for immediate delivery. New
agents do not look like transitions.

The model also exposes bounded semantic queries. Input asks for an
`AgentNavigationPlan`, attachment capture asks for the focused eligible agent,
the sidebar animation use case asks whether animation is active, and sound
validation asks whether an exact identity exists. None of those callers reads
snapshot storage. [Agent navigation](agent-navigation.md) owns the ordered local
focus or remote handoff selected from that plan.

## Effects and presentation

After the model accepts a newer snapshot, the operation calls
`AttachedClient.synchronizePaneAttachments`. A shelf geometry change calls
`AttachedClient.resizeAttachedPanes`. This attachment-only synchronization does not
emit child focus reports. The operation then translates transitions to
`blocked`, `done` and `failed` into owned notifications, bounded by the center's
capacity. It finally calls `AttachedClient.synchronizeSidebarAnimation` to arm working-agent
animation without advancing a frame during snapshot application.

Failure stops later delivery stages and preserves the canonical agent revision.
There is no public callback boundary between the commit and its delivery.
[Sidebar animation](sidebar-animation.md) describes the separate timer lifetime.

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

## Validation

Agent snapshot/model tests cover ownership, duplicate identities, bounded text,
revision rejection and transition detection. The real client tests in
`src/frontend/client/tests/notifications_and_agents.zig` cover wire admission,
alert limits, exact sound identity, attachment synchronization and retained
canonical state after host-publication failure. Renderer tests cover derived
pane labels without mutating the replica. Runtime delivery tests cover per-client
revision cursors and enrichment.
