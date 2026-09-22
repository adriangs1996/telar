# Workspace creation

Creation is a runtime transaction followed by one atomic client replacement.
The client owns its prompt, navigation history and disposable projection.

```text
operations/input/name_prompts.handleInput
  -> operations/workspaces/workspace_creations.request
     -> idle gate, validate name, choose CWD source, retain request size
     -> AttachedClient.sendCreateWorkspaceRequest
  -> runtime commits workspace/root and replaces this client's attachments
  -> pane_opened(create_workspace continuation)
  -> entrypoints/AttachedClient.handleServerMessage
  -> operations/panes/AttachedClient.completePaneOpen
     -> workspace_creations.confirmation
     -> workspace_creations.confirm
        -> Model.replaceWorkspace
        -> workspace_transitions.release(departure)
        -> workspace_transitions.activate(root)
  -> adapter observes presentation revisions
```

Without an explicit directory, planning requires an attached focused pane and
uses it as `cwd_source`. A typed directory travels expanded in `launch.cwd`,
with no CWD source; `create_cwd` carries the user's confirmation to create it.
The bounded outbox owns name/CWD/arguments before the prompt can close. Invalid
names, a busy lifecycle, missing source or local send failure leave canonical
state unchanged.

The runtime resolves launch authority, prepares workspace/geometry and starts
the root before publishing canonical state. Pre-commit failure rolls back the
proposal. A committed workspace survives later attachment failure. Successful
creation replaces the requesting client's old attachments before replying, so
the client must not send stale detach or focus-out messages afterward.

The continuation retains the size originally sent, independent of later host
resize. Confirmation consumes it once, checks `created=true`, and stages a
saved layout only for the exact confirmed workspace/tab. `Model.replaceWorkspace`
captures the old departure and constructs the new root before retiring the old
store. Validation/allocation failure keeps the previous projection and all
revisions. Success advances workspace, tabs, active-tab and panes once; there
is no intermediate empty model.

In the same synchronous operation, `workspace_transitions.release` remembers
the old focused pane/layout and clears exact copy, paste, focus and graphics
owners. It silently forgets any remaining obsolete report context.
`workspace_transitions.activate` validates the committed root and revision
deltas, synchronizes active resources, resumes host input, then requests the
workspace snapshot followed by the tab snapshot.

A later activation failure preserves replacement and completed cleanup. A
correlated runtime failure before confirmation preserves the old projection
and becomes an owned notice. Unknown, incompatible, malformed or replayed
confirmation cannot replace the model. Empty-source confirmation remains valid
for recovery. Presentation is driven by the committed revision.

Source: `src/client/operations/workspaces/workspace_creations.zig`,
`workspace_transitions.zig`, and `src/client/model/Model.zig`.
Tests: `src/frontend/client/tests/workspace_lifecycle.zig`,
`src/client/model/tests/workspaces.zig`, bounded outbox tests and runtime
creation tests cover owned requests, atomic replacement, no stale detach/focus,
snapshot ordering, full-outbox failure and retained canonical state after
activation delivery failure.
