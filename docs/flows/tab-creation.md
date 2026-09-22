# Tab creation

The runtime creates tabs and root panes. The client requests a tab from its
current projection and adopts only a canonical reply.

```text
AttachedClient.executeAction
  -> operations/tabs/tab_creations.request
     -> pending-operation gate, label validation, Model.planTabCreation
     -> AttachedClient.sendCreateTabRequest -> owned create_tab outbox entry
  -> runtime creates tab/root and returns tab_created
  -> entrypoints/AttachedClient.handleServerMessage
  -> tab_creations.apply
     -> consume exact create_tab correlation
     -> Model.createTab
     -> tab_attachments.detach(previous)
     -> AttachedClient.synchronizeActivePane
     -> request agent conversation when applicable
  -> adapter observes presentation revisions
```

Planning requires an attached focused source and supplies its workspace and
CWD identity. `command_tab` carries a bounded argv and optional label, replacing
the default launch command. Workbench size and launch configuration are copied
into the request. The outbox owns name, CWD and argument bytes before the input
event returns. No provisional tab or presentation version is created.

An empty canonical label means automatic naming from the client's focused
foreground process. Explicit labels always win. Creation, snapshots and
checkpoints preserve that distinction; old checkpoints with nonempty labels
retain them because they did not record whether a name was automatic.

Runtime launch/authority failures discard the provisional tab. After successful
launch the runtime commits/publishes it before attachment; a later attachment
failure cannot undo canonical state. The successful reply contains runtime
location, position, label and root identity.

`tab_creations.apply` consumes correlation once and requires the expected
workspace. It constructs the root with the nonzero size retained from the
request, even if host geometry changed meanwhile. Model construction is atomic:
invalid or duplicate state preserves the previous tab and revisions. Valid
construction publishes the new active tab before resource effects.

The same call then retires the previous tab's captured paste, reported focus
and attachments in order, before synchronizing the new root. A resource error
keeps the confirmed tab and completed effects. The runtime already owns that
tab, so client rollback would invent a false projection.

A failed request releases correlation and preserves the old projection.
Runtime rejection becomes an owned failure notice. Unknown, incompatible,
wrong-workspace or replayed replies cannot mutate tabs. Presentation observes
model revisions; this operation does not draw.

Source: `src/client/operations/tabs/tab_creations.zig` and
`src/client/operations/tabs/tab_attachments.zig`.
Tests: `src/frontend/client/tests/tab_lifecycle.zig`,
`src/client/model/tests/tabs.zig`, `src/client/connection/outbox_support.zig`,
and runtime/transport tab-lifecycle tests. The frontend suite includes invalid
labels, full-outbox correlation rollback and a confirmed creation whose later
attachment retirement fails.
