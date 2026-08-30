# Tab removal

A tab disappears for either of two reasons. A client can request its closure,
or the runtime can reap its final pane. Both triggers commit the same
`TabRemoved` domain fact. Only an explicit request has a request ID.

## Explicit request

```text
InputHandler.closeTab
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
handleTabClosed
```

`InputHandler.closeTab` first detaches the client's pane views, then enqueues
`schema.CloseTab`. The runtime event loop classifies that message and creates a
request-scoped `close_tab.Controller`. The controller removes protocol metadata
and calls `CloseTabHandler` with only the tab location.

`CloseTabHandler` commits through `workspace.removeTab`. The operation removes
an empty workspace as part of the same command and includes its stable
predecessor in `TabRemoved`. After commit, the handler starts closing every pane
in that tab and publishes the event. The controller then queues
`schema.TabClosed` with the original request ID.

A missing tab produces `tab_not_found` and no pane or event effects. A full
response queue cannot roll back a committed removal. The request fails at its
connection boundary and snapshot reconciliation recovers the disposable
client.

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
