# Tab removal

A tab disappears for either of two reasons. A client can request its closure,
or the runtime can reap its final pane. Both triggers commit the same
`TabRemoved` domain fact. Only an explicit request has a request ID.

## Explicit request

```text
InputHandler.closeTab
        |
RequestCloseTabHandler -> CloseRequestEffects.detach / send
        |
schema.close_tab -> runtime socket
        |
Server.handleClientMessageEvent -> Server.dispatchClientMessage
        |
close_tab.Controller -> CloseTabHandler
        |
workspace.removeTab -> PaneStore.closeAt -> TabRemoved publication
        |
schema.tab_closed -> runtime socket
        |
handleTabClosed -> client CloseTabHandler -> ClientModel.closeTab
        |
ClosureEffects -> continuations / graphics / focus / successor snapshot
```

`InputHandler.closeTab` only translates the action into a client application
request. `RequestCloseTabHandler` rejects overlapping tab operations, captures
the active identity, detaches its pane views, and then sends `schema.CloseTab`.
If either local effect fails, it requests restoration through the attachment
adapter. If the runtime rejects the request while that tab is still active,
`RecoverCloseTabHandler` requests its canonical snapshot.

The runtime event loop classifies the message and creates a request-scoped
`close_tab.Controller`. The controller removes protocol metadata and calls the
runtime `CloseTabHandler` with only the tab location.

`CloseTabHandler` commits through `workspace.removeTab`. The operation removes
an empty workspace as part of the same command and includes its stable
predecessor in `TabRemoved`. After commit, the handler starts closing every pane
in that tab and publishes the event. The controller then queues
`schema.TabClosed` with the original request ID.

A missing tab produces `tab_not_found` and no pane or event effects. A full
response queue cannot roll back a committed removal. The request fails at its
connection boundary and snapshot reconciliation recovers the disposable
client.

On the return path, `handleTabClosed` validates request correlation and passes
the canonical fact to the client `CloseTabHandler`. `ClientModel.closeTab`
validates the workspace-closure flag before mutation, captures the removed pane
identities, removes the tab, and advances the tab revision plus the active-tab
revision when its identity changed. Only after that commit do client effects
discard stale continuations, graphics, copy/paste/focus state, and request a
snapshot for the successor. Rendering is not an effect of this use case: the
presenter schedules it when it observes the new model version.

## Final-pane exit

```text
pane child exit
      |
Server.collectFinished
      |
destroy final pane -> workspace.removeTab
      |
TabRemoved -> schema.tab_closed(request_id = none)
      |
handleTabClosed
```

`Server.collectFinished` destroys a pane only after no actor or client
attachment still borrows it. If no pane remains at that location, it invokes
the same workspace operation used by the explicit handler. Active clients that
still observe the workspace receive `schema.TabClosed` with `RequestId.none`.
If a client queue is full, `ResponseQueue.pushOrDrop` records the workspace and
predecessor needed for resynchronization.

The client applies this lifecycle event through the same canonical close use
case. A repeated lifecycle event is idempotent; an explicit response for an
unknown tab remains a protocol error.

## Proof

- Unit tests in `workspace/events.zig` and `workspace/commands.zig` cover event
  invariants, repository mutation, missing targets and workspace predecessor
  selection.
- Unit tests in `runtime/commands/close_tab.zig` cover commit ordering, pane
  effects, event publication, final-workspace removal and repeated commands.
- Unit tests in `runtime/controllers/close_tab.zig` cover protocol translation,
  expected failure mapping and unexpected errors.
- `runtime/close_tab_test.zig` proves that response backpressure does not undo
  a committed removal or suppress its event.
- `runtime owns the complete tab lifecycle`, `runtime destroys a pane after its
  shell exits` and `the last pane closes only its tab when the workspace has
  another tab` in `transport_integration_test.zig` cover both triggers across
  the runtime socket.
- `application/close_tab.zig` proves request ordering, recovery boundaries,
  commit-before-effects, rejection, idempotence, and committed-effect failure.
- `client/model.zig` proves closure validation and revision semantics for
  active, inactive, and last-tab removals.
- `client/client_test.zig` proves request delivery and rejection recovery,
  active and inactive lifecycle cleanup, presenter observation, and last-tab
  closure through the real client adapters.
