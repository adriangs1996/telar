# Tab rename

The runtime owns the canonical tab label. The client edits a bounded candidate,
sends it with a stable tab identity, then changes its replica only after the
runtime confirms the label.

This is an interactive flow. Labels must contain between one and
`schema.max_tab_label_bytes` bytes, valid UTF-8 and no control bytes. The prompt,
outbox and runtime response queue use fixed storage. The continuation retains
only `TabLocation`; the outbox copies the candidate before the prompt closes.
No borrowed label crosses the asynchronous boundary.

## Request

```text
name prompt
        |
InputHandler.submitTabRename
        |
RequestRenameTabHandler
        |
TabRenameIntent
        |
owned rename_tab request and typed continuation
        |
runtime socket
```

`RequestRenameTabHandler` rejects another pending tab operation, validates the
candidate and resolves the prompt's tab ID to its complete location. The target
may be inactive. A valid request passes a borrowed label only to the synchronous
adapter callback.

The adapter allocates the request identity, records the expected location and
copies the label into the bounded outbox. Local enqueue does not mutate the
model or advance a version. `InputHandler` closes the prompt only after the
adapter accepts the request into the outbox.

## Runtime command

```text
Server.dispatchClientMessage
        |
tab.Controller.renameTab
        |
RenameTabHandler
        |
Workspace.renameTab
        |
owned TabRenamed event and tab_renamed response
```

The runtime handler resolves the workspace aggregate, commits the new label and
then publishes an owned `TabRenamed` event. The controller copies that canonical
label into its response queue. A missing tab or invalid label becomes
`request_failed`.

The requesting client receives `tab_renamed`. The runtime marks other clients
that observe the workspace for resynchronization. Those clients obtain the new
label from a workspace snapshot and never consume another client's request
identity.

## Confirmation and presentation

```text
tab_renamed(rename_tab continuation)
        |
validate exact TabLocation
        |
ConfirmTabRenameHandler
        |
ClientModel.renameTab
        |
Presenter.observeModel
```

The dispatcher consumes the continuation and requires an exact location match.
The adapter removes the request identity before it invokes
`ConfirmTabRenameHandler`. The handler applies the runtime label, which may
differ from the candidate sent by the prompt.

A changed label advances only `tabs_revision`. An identical canonical label is
a semantic no-op and changes no version. Neither case changes active-tab
identity. The use cases do not invalidate the view or request a draw. The
client loop publishes a changed model version to `Presenter`, which schedules
the frame.

## Failure and recovery

An invalid local label fails before the adapter sees it. A pending operation or
missing prompt target emits nothing. In both suppressed cases the prompt stays
open. A local enqueue failure also leaves the prompt open and removes any
provisional continuation.

A correlated `request_failed` preserves the current label and model version,
then reports the runtime message through the notification flow. A response for
another tab is a protocol error and cannot mutate the replica. Reconnection
rebuilds labels from the canonical workspace snapshot, so the client never
replays a rename.

## Proof

- `src/frontend/client/application/rename_tab.zig` proves local validation,
  gating, exact target resolution, delivery failure and canonical confirmation.
- `src/frontend/client/outbox.zig` proves bounded storage and ownership of
  queued label bytes.
- `src/frontend/workspace/tabs.zig` proves canonical label validation and
  no-op detection.
- `src/frontend/client/model.zig` proves collection and active-identity version
  semantics.
- `src/frontend/client/client_test.zig` proves prompt lifetime, wire
  correlation, runtime authority, failure notification and presenter pacing.
- `src/backend/runtime/commands/tab.zig` and
  `src/backend/runtime/controllers/tab.zig` prove commit ordering, owned events
  and expected runtime errors.
- `runtime owns the complete tab lifecycle` in
  `src/transport_integration_test.zig` proves persistence across the process
  boundary and a later workspace snapshot.
