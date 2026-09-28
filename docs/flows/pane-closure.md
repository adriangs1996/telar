# Pane closure

The client removes a pane only after the runtime reports `pane_exited`.
Requesting closure does not predict when shutdown and output draining finish.

```text
actions.executeAction
  -> pane_closure.requestPaneClose
     -> pending pane-operation gate
     -> pane_closure.plan
     -> runtime_io.sendRuntimeRequest(close_pane)
  -> runtime requests idempotent child shutdown

runtime pane_exited
  -> runtime_messages.handleServerMessage
  -> pane_closure.applyPaneExit
     -> pane_closure.retire
     -> tracker.ignoreAttachment + tracker.completePaneClose
     -> pane_closure.releasePaneResources
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
value do not affect disposable cleanup. `pane_closure.retire` finds the pane
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

Source: `src/client/panes/pane_closure.zig`, particularly `requestPaneClose`,
`applyPaneExit` and `releasePaneResources`.
Tests: `src/client_tests/pane_lifecycle.zig`,
`src/client_tests/pane_updates.zig`, `src/client_tests/tab_lifecycle.zig`,
`src/model/state/tests/panes.zig`, and transport lifecycle integration tests.
