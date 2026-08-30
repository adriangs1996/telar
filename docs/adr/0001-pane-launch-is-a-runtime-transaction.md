---
status: accepted
---

# Treat pane launch as a runtime transaction

A pane outlives any client connection, so client attachment and response
delivery cannot decide whether it exists. The runtime commits a pane launch
only after it owns the pane and both long-lived pane actors are active. A
failure before that point aborts only the launch and never stops the runtime.

## Decision

The runtime owns the launch transaction through a concrete `PaneLauncher`
module and returns either a `running` pane or an error. `PaneLauncher` owns only
the cohesive launch dependencies and never receives `Server` or client state.
`PaneStore` owns every spawned pane allocation while the launch moves from
`starting` to `running` or `aborting`. Discovery and attachment expose only
`running` panes.

The runtime schedules `waitPane` before `readPane`. If a later launch step
fails, it marks the pane `aborting`, revokes its proxy credential, shuts down
the PTY, and retains the allocation until the child is reaped and no actor can
access it. A consumed `PaneKey` is never reused.

A workspace or tab created for the first pane remains provisional until
`PaneLauncher` commits the pane. The application flow, rather than
`PaneLauncher` or a request controller, owns rollback of provisional
containers and geometry leases; migrated mutations place that policy in their
command handler. The `createTab` handler consumes its proposed tab identity and
publishes the owned domain event only after pane commit. After commit,
attachment or response delivery failure removes neither the pane nor its
container. Reconnection discovers the committed pane from runtime state and
never replays the launch automatically.

Pre-commit failures keep the existing protocol categories: `resource_limit`,
`invalid_request`, and `spawn_failed`. Internal phase and cause stay in
diagnostics and history.

A launch carries either an explicit working directory or an attached source
pane. For inherited launches, the runtime verifies that the source belongs to
the requesting client and the affected tab or workspace, then snapshots the
runtime-owned pane working directory. The client never turns its disposable
cwd replica back into launch authority.

The launch working directory and workspace path are separate values. The first
initializes the child and the pane's mutable cwd state. The second remains the
stable workspace identity and history scope. Before forking, the PTY layer
opens the launch directory and treats failure as a pre-commit launch failure.

History stores a process-spawned, aborted launch in a dedicated
`launch_attempt` record. It creates a normal `session` record only after launch
commit. This keeps `session` synonymous with a pane that became usable.

## Considered options

- Extending the transaction through client response delivery would make
  disposable client state control a runtime-owned PTY. Delivery can also fail
  after the runtime has sent the response, so it cannot define commit.
- Committing with one missing actor would publish a pane whose output or child
  exit is no longer managed.
- Stopping the runtime after partial actor startup would let one client request
  terminate every pane.
- A separate pending-launch store would duplicate ownership and event lookup
  already provided by `PaneStore`.
- Recording an aborted launch as a session would make failed startup look like
  normal terminal activity.
- Sending the client's last cwd observation as an explicit launch path would
  avoid a protocol field, but queueing and reconnects can make that borrowed
  observation stale. Runtime resolution keeps one cwd authority.

## Consequences

Pane IDs may contain gaps. Client confirmation can be lost even though the pane
exists, and snapshot reconciliation is the recovery path. SQLite gains a
`launch_attempt` table, while `session` starts at runtime commit.

Inherited cwd changes the wire schema and requires an exact client/runtime
schema match. A missing, detached, exited, or wrong-container source pane fails
the request before the runtime mutates workspace or tab state.

Tests must inject failure at every launch phase and allocation point. They must
prove that the runtime survives, only `running` panes are discoverable, every
child is reaped, credentials and geometry leases are released, provisional
containers roll back, one launch attempt is recorded, and reconnect does not
create a duplicate pane.
