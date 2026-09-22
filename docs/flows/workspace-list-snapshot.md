# Workspace list snapshot

The runtime owns open workspace membership and order. Each client keeps a
bounded replica for chrome and positional navigation.

```text
runtime repository revision and per-client cursor -> workspace_list
  -> AttachedClient.handleServerMessage
  -> Model.applyWorkspaceList
     -> decode bounded domain inputs
     -> Model.reconcileWorkspaceList
     -> classify stale, rejected or applied
  -> adapter observes workspace_list revision
```

Runtime delivery encodes the latest repository revision rather than queuing
historical lists. Wire validation rejects revision zero, excess entries,
duplicate identities, oversized names/paths and invalid tab counts.

The model owns the only client replica. Its snapshot holds at most 64 entries,
UTF-8-safe display names up to 48 bytes and complete paths in a shared 16 KiB
pool. Reconciliation builds a candidate before replacement; it allocates
nothing. A validation or aggregate-path capacity failure preserves the last
snapshot. The operation classifies bounded validation errors as rejected and
propagates unclassified failures.

Only a newer runtime revision commits. Each such commit advances the local
workspace-list revision once; repeated/older runtime versions are no-ops.
Model queries resolve stable identity and zero-based position for actions and
clicks. The view retains hit regions, not navigation authority or a second list.

No server-message operation requests a draw. The adapter observes the model
revision and composes the latest immutable snapshot at the paced deadline.
Several updates can fold into one presentation. A later valid runtime revision
can recover from rejected input; reconnect obtains a fresh canonical snapshot.

Source: `src/client/model/Model.zig`,
`src/client/model/Model.zig`, and `src/client/workspace/workspace_list.zig`.
Tests: `src/client/model/tests/workspaces.zig`, workspace-list storage tests and
`src/frontend/client/tests/notifications_and_agents.zig` cover revision
ownership, bounded rejection, navigation and presentation.
