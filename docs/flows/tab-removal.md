# Tab removal

The runtime workspace aggregate owns whether a tab exists. A client may ask to
close its active tab, but it does not remove the tab from its model until the
runtime returns the canonical result. The runtime can produce the same removal
when a tab loses its final pane.

This flow runs on the interactive path. Its protocol values have fixed size.
Each client stores outbound messages in an outbox bounded to
`schema.max_panes_per_tab + 16` entries and continuations in a tracker bounded
to `schema.max_panes_per_tab + 8` entries. Only one tab operation may be
pending per client.

## Close request

```text
close-tab action
        |
RequestCloseTabHandler
        |
capacity check -> provisional detach -> TabCloseIntent
        |
close_tab request and typed continuation
        |
runtime socket
```

`RequestCloseTabHandler` resolves the active tab identity without changing the
semantic model. Its adapter checks request identity, continuation and outbox
capacity before the first provisional effect. The check accounts for a
required paste-closing marker, focus output, every pane detach and the close
request itself.

After that check, the handler closes any captured paste, detaches the active tab
and asks the adapter to send one `close_tab` message. The adapter allocates the
request ID, records the exact `TabLocation` in the continuation tracker and
queues the message. The request does not advance a model version.

A detach or send failure asks for a canonical tab snapshot. A capacity failure
happens before focus or attachment state changes. A runtime `request_failed`
passes through `HandleRequestFailureHandler`, which delegates to
`RecoverTabClosureHandler` before publishing the failure notice. Recovery asks
for a snapshot when the same tab remains active. If navigation has already
selected another tab, selecting the rejected tab later requests its snapshot
through the normal attachment flow.

## Runtime transaction

```text
Server.dispatchClientMessage
        |
close_tab.Controller
        |
CloseTabHandler
        |
workspace.removeTab
        |
close tab panes -> publish TabRemoved
        |
tab_closed response
```

The request-scoped controller removes the request ID and translates
`schema.CloseTab` into the application command. `CloseTabHandler` commits
through the workspace repository. The repository returns an owned
`TabRemoved` fact containing the removed location, whether the workspace also
disappeared and its canonical predecessor when another workspace survives.

After the commit, the handler starts closing the tab's panes and publishes
`TabRemoved`. Both ports are infallible. The controller then queues
`schema.TabClosed` for the requesting client. A missing target returns
`tab_not_found` without pane or publication effects. Response backpressure
cannot undo the committed removal.

The runtime marks other clients that observe the workspace for snapshot
reconciliation. They do not receive the requesting client's correlation ID.

## Final-pane lifecycle

```text
pane child exit
        |
Server.collectFinished
        |
workspace.removeTab
        |
TabRemoved
        |
tab_closed(request_id = none)
```

The runtime destroys an exited pane only after no actor or client attachment
still borrows it. When that pane was the tab's last pane, lifecycle cleanup
uses the same repository operation and publishes the same `TabRemoved` fact.
Every client still observing the workspace receives `tab_closed` with
`RequestId.none`. A saturated response queue records a resynchronization
requirement instead of blocking PTY work.

## Client application

```text
tab_closed
        |
tab_closures.apply
        |
correlate explicit response or classify lifecycle event
        |
ApplyTabRemovalHandler
        |
ClientModel.removeTab
        |
retire requests -> release pane resources
        |
stay, hand off to predecessor, or exit
        |
Presenter.observeModel
```

The dispatcher only delegates the decoded message. `tab_closures.apply`
classifies a zero request ID as a lifecycle fact. Otherwise it consumes the
continuation, requires its `close_tab` type and verifies the exact tab identity.
A terminal response for a request already retired by canonical reconciliation
is consumed and returns `ignored`. The slice removes protocol-only fields and
calls `ApplyTabRemovalHandler`.

The application handler owns the client policy. It validates the workspace
transition and commits the canonical fact through `ClientModel.removeTab`.
Requested removals must still exist. Repeated or stale lifecycle facts are
idempotent and only retire obsolete continuations.

After a commit, the handler retires requests for the removed tab and releases
its copy, paste, focus and graphics state. Removing an inactive tab leaves the
active identity untouched. Removing the active tab exposes its successor,
synchronizes focus and requests that tab's canonical snapshot.

If the last tab removed the workspace, the handler forgets its navigation
bookmark. It starts a workspace handoff when the runtime supplied a canonical
predecessor. The projection is already empty, so continuations retired by the
removal cannot block this runtime-directed handoff. With no surviving
predecessor the handler returns an exit directive. The slice translates the
application directive into `applied` or `exit`; the dispatcher only maps
`exit` to process status `0`.

The handler never requests a draw. `ClientModel.removeTab` advances the tab
version and advances the active-tab version only when the active identity
changed. The client loop passes that version to `Presenter`, which coalesces
presentation onto its paced frame deadline. A repeated lifecycle fact leaves
the version unchanged and schedules no frame.

Client death needs no rollback. Runtime tabs and panes remain canonical, and a
new client rebuilds its disposable model through workspace and tab snapshots.

## Proof

- `src/frontend/client/tab_closures.zig` proves explicit correlation,
  lifecycle classification, retired-response handling and wire translation.
- `src/frontend/client/application/close_tab.zig` proves request ordering,
  failure recovery, commit-before-effects, lifecycle idempotence, workspace
  transition policy and post-commit failures.
- `src/frontend/client/model.zig` proves exact location and workspace-removal
  validation, captured pane identities and model version changes.
- `src/frontend/client/client_test.zig` proves bounded request delivery,
  correlation, late responses, resource cleanup, predecessor handoff, exit and
  presenter observation through the real client adapters.
- `src/backend/workspace/commands.zig` and
  `src/backend/workspace/events.zig` prove aggregate removal and owned event
  invariants.
- `src/backend/runtime/commands/close_tab.zig` proves commit ordering, pane
  closure, publication and missing-target behavior.
- `src/backend/runtime/controllers/close_tab.zig` proves protocol translation
  and expected failure mapping.
- `src/backend/runtime/close_tab_test.zig` proves response backpressure does
  not undo the runtime commit or suppress publication.
- `src/transport_integration_test.zig` proves requested and final-pane removal
  across the runtime socket.
