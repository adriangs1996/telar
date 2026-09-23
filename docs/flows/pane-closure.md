# Pane closure

The client removes a pane only after the runtime reports `pane_exited`.
Requesting closure does not predict when shutdown and output draining finish.

```text
AttachedClient.executeAction
  -> AttachedClient.requestPaneClose
     -> pending pane-operation gate
     -> ClientModel.planPaneClosure
     -> AttachedClient.sendRuntimeRequest(close_pane)
  -> runtime requests idempotent child shutdown

runtime pane_exited
  -> AttachedClient.handleServerMessage
  -> AttachedClient.applyPaneExit
     -> ClientModel.retirePane
     -> tracker.ignoreAttachment + tracker.completePaneClose
     -> AttachedClient.releasePaneResources
     -> active: model.to_host.invalidate_placements, synchronizeActivePane
     -> resizeAttachedPanes when the active tab remains nonempty
  -> adapter observes presentation revisions
```

Planning resolves the attached focused pane and exact tab without mutation.
Correlation retains both identities; the wire needs only the pane because the
runtime authorizes closure through this connection's attachment. Success has
no immediate reply. Missing authority returns a correlated failure.

The runtime reports exit after terminal ingestion and outstanding frame work
finish. The client operation uses stable pane identity; process exit kind and
value do not affect disposable cleanup. `ClientModel.retirePane` finds the pane
in `model.panes`, requires its `location` to match its tab and removes it with
`tab_layout.removePane`. Active retirement advances `panes_revision`; inactive
retirement changes stored membership without a visible revision. Repeated exits
are stale.

The same synchronous operation completes a matching close continuation,
retires pending attachment work and clears exact copy/paste/focus/graphics
resources. Canonical focus retirement emits no focus-out. An active nonempty
tab synchronizes its new focus and offers attached pane sizes. Inactive and
stale exits do not resize the active tab. A pending split remains correlated:
its eventual reply owns a distinct runtime pane that still needs adoption or
detachment.

The final pane can leave an empty client tab temporarily. Once runtime actors
and attachments release the exited pane, runtime collection removes it and
publishes the separate canonical `tab_closed` fact if no pane remains.
[Tab removal](tab-removal.md) handles that fact and workspace closure.

Delivery failure never restores a canonically retired pane. Completed effects
remain applied, and the normal client error/reconnect path repairs disposable
resources. This flow adds no queue; scans and cleanup are bounded by tab/pane
capacity. Presentation follows model revisions, not an explicit draw request.

Source: `src/client/AttachedClient.zig`, particularly `requestPaneClose`,
`applyPaneExit` and `releasePaneResources`.
Tests: `src/frontend/client/tests/pane_lifecycle.zig`,
`src/frontend/client/tests/tab_lifecycle.zig`,
`src/model/state/tests/panes.zig`, and transport lifecycle integration tests.
