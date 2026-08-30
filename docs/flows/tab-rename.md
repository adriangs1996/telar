# Tab rename

A rename crosses the client prompt, the runtime workspace aggregate, and the
client's disposable replica. The runtime label remains canonical throughout.

## Successful request

```text
name prompt -> InputHandler.submitTabRename
        |
RequestRenameTabHandler -> RenameRequestEffects.send
        |
schema.rename_tab -> runtime socket
        |
Server.dispatchClientMessage -> tab.Controller.renameTab
        |
runtime RenameTabHandler -> Workspace.renameTab -> TabRenamed
        |
schema.tab_renamed -> runtime socket
        |
handleTabRenamed -> ClientModel.renameTab
        |
Client.observeModel -> Presenter
```

The prompt supplies a tab ID and a label bounded by
`schema.max_tab_label_bytes`. `RequestRenameTabHandler` refuses overlapping tab
operations, resolves the complete `TabLocation`, and passes a borrowed label to
the synchronous client adapter. The outbox copies the label before the prompt
closes. Sending the request does not mutate `ClientModel`.

The runtime controller translates the wire request into the runtime
`RenameTabHandler`. That handler resolves the workspace aggregate, commits the
label, and publishes the owned `TabRenamed` event before the controller queues
`schema.TabRenamed` for the requesting client. Other clients recover the same
label through workspace snapshots.

`handleTabRenamed` first consumes and validates the request continuation. It
then commits the canonical label through `ClientModel.renameTab`. A changed
label increments `tabs_revision`; an identical label changes no version. A
rename never changes the active-tab identity. Neither the use case nor the
protocol entrypoint requests a frame. The presenter schedules one after it
observes the changed model version.

## Failure

A missing tab or invalid runtime command returns `schema.request_failed`. The
client consumes the continuation and shows the existing failure notification.
A local delivery failure leaves the prompt open because `finishNamePrompt`
runs only after the request adapter succeeds. A pending tab operation or a tab
that vanished before submission emits nothing and also leaves the prompt open.

## Proof

- `frontend/client/application/rename_tab.zig` proves request gating, exact
  target resolution, delivery failure, and absence of provisional mutation.
- `frontend/workspace/tabs.zig` proves label bounds, UTF-8 validation, no-op
  detection, and missing-tab rejection.
- `frontend/client/model.zig` proves collection and active-identity revision
  semantics.
- `frontend/client/client_test.zig` proves prompt submission, wire correlation,
  canonical commit, no-op presentation, and presenter observation through the
  real client adapters.
- `runtime/commands/tab.zig`, `runtime/controllers/tab.zig`, and `runtime owns
  the complete tab lifecycle` in `transport_integration_test.zig` prove the
  runtime half across its process boundary.
