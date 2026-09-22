# Workspace snapshot reconciliation

The runtime owns workspace name, tab membership, labels and order. The client
retains layouts, focus, buffers and disposable resources for canonical identities.

```text
operations/input/name_prompts.handleInput
  -> operations/workspaces/workspace_renames.request
  -> owned rename_workspace -> runtime rename

rename reply or requested workspace_snapshot
  -> AttachedClient.handleServerMessage
  -> AttachedClient.applyWorkspaceSnapshot
     -> consume rename/snapshot correlation and verify workspace
     -> bounded descriptor decoding -> Model.reconcileWorkspace
     -> ignore removed-tab requests; release removed-pane resources
     -> synchronize active resources if active tab changed
     -> retain pending tab snapshot, request one, or offer attached sizes
  -> adapter observes presentation revisions
```

Rename accepts only the projected workspace and refuses overlapping operations.
The bounded outbox owns the candidate before the prompt closes; request delivery
changes no canonical state. Runtime queues stable workspace identity and encodes
its latest snapshot at send time, so an older borrowed descriptor list cannot
remain queued.

The client consumes the typed continuation once and requires the exact
workspace. It decodes fixed-capacity domain inputs; borrowed names are copied
synchronously by the model. Complete validation precedes mutation and resource
cleanup. A changed name advances the workspace revision; membership/order/label
changes advance tabs once; losing the active identity advances active-tab once.
An identical snapshot changes no display revision. Pane-count mismatch marks
that tab's snapshot stale without inventing a visible semantic change.

Foreground descriptors include bounded names keyed by pane identity without
requiring PTY attachments. Automatic tab names follow current or retained focus,
falling back to the first canonical pane. The tab stores a fixed name and that
identity while terminal models are absent. Manual labels remain separate.
Global foreground updates match those retained identities; attachment-specific
metadata cursors still bootstrap newly created local panes.

The reconciliation returns bounded removed tab/pane identities. In the same
operation, removed-tab requests become ignored and exact pane authorities and
graphics are released. An active-tab change silently forgets the obsolete
reporting context, shows successor graphics and synchronizes active resources.
An existing tab snapshot is retained. Otherwise an active change or stale
membership requests one; an already loaded active tab receives geometry offers.
Repeated canonical snapshots can repair resources without forcing a frame.

`AttachedClient.applyResyncRequirement` coalesces a workspace snapshot request; the reply
returns here. A workspace that disappears before runtime encoding returns a
correlated failure rather than stale state.

Unknown/type/location-mismatched correlation is rejected after consuming any
known continuation. Model rejection performs no resource effects. Post-commit
failure preserves the canonical replica and completed cleanup. Reconnect or a
later snapshot repairs disposable resources. No operation schedules a draw.

Source: `src/client/AttachedClient.zig`,
`workspace_renames.zig`, and `src/client/model/Model.zig`.
Tests: `src/frontend/client/tests/synchronization.zig`,
`renaming_and_telemetry.zig`, `src/client/model/tests/workspaces.zig`, and
`tabs.zig` cover correlation, atomic validation, retained layouts, foreground
metadata, cleanup, coalescence and canonical no-ops.
