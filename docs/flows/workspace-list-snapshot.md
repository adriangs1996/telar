# Workspace list snapshot

The runtime owns open workspace membership and order. Each client keeps a
bounded replica for chrome and positional navigation.

```text
runtime Workspaces revision and per-client cursor -> workspace_list
  -> runtime_messages.handleServerMessage
  -> workspace_list_snapshot.apply
     -> decode bounded domain inputs
     -> workspace_list_snapshot.reconcile -> model.workspace_list_snapshot.replace
     -> classify stale, rejected (classifyRejection) or applied
  -> adapter observes workspace_list revision
```

Runtime delivery encodes the latest `Workspaces` revision rather than queuing
historical lists. Wire validation rejects revision zero, excess entries,
duplicate identities, oversized names/paths and invalid tab counts.

The model owns the only client replica, `model.workspace_list_snapshot`. It holds at most 64 entries,
UTF-8-safe display names up to 48 bytes and complete paths in a shared 16 KiB
pool. Reconciliation builds a candidate before replacement; it allocates
nothing. A validation or aggregate-path capacity failure preserves the last
snapshot. The operation classifies bounded validation errors as rejected and
propagates unclassified failures.

Only a newer runtime revision commits. Each such commit advances
`model.workspace_list_revision` once; repeated/older runtime versions are no-ops.
Model queries resolve stable identity and zero-based position for actions and
clicks. The window retains hit regions, not navigation authority or a second list.

No server-message operation requests a draw. The window observes the model
revision and draws the latest immutable snapshot in its next frame.
Several updates can fold into one presentation. A later valid runtime revision
can recover from rejected input; reconnect obtains a fresh canonical snapshot.

Source: `src/model/state/ClientModel.zig`,
`src/model/workspace/WorkspaceListSnapshot.zig`,
`src/model/workspace/workspace_list_snapshot.zig` and
`src/model/workspace/workspace_list.zig`.
Tests: `src/model/state/tests/workspaces.zig`, workspace-list storage tests and
`src/client_tests/notifications_and_agents.zig` cover revision
ownership, bounded rejection, navigation and presentation.
