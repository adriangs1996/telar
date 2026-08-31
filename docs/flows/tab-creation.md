# Tab creation

The runtime creates tabs and root panes. The client plans the request from its
current projection, then commits only the canonical `tab_created` response.

## Request

```text
new-tab action
        |
RequestTabCreationHandler
        |
ClientModel.planTabCreation
        |
owned outbox create_tab
        |
runtime socket
```

The request handler rejects another pending tab operation and requires an
attached focused pane in the active tab. The model returns only the current
workspace identity and cwd source. Planning does not mutate the tab collection
or advance a model version.

The adapter adds the workbench size and launch configuration. An empty label
asks the runtime workspace aggregate to generate the canonical tab label. The
outbox copies a supplied label and launch cwd into bounded storage before the
input event returns. A local delivery failure leaves the model unchanged.

The continuation retains the requested workspace and terminal size. Those are
the facts needed to validate and apply the eventual response; it retains no
borrowed UI or model pointers.

## Runtime transaction

```text
CreateTabController
        |
find workspace -> validate launch authority -> reserve tab identity
        |
create provisional tab -> launch root pane
        |
record and publish tab -> attach root pane -> tab_created
```

`CreateTabHandler` removes the provisional tab if authority or pane launch
fails. It records and publishes the tab only after the root pane is running.
An attachment failure occurs after that commit and cannot remove authoritative
runtime state.

The controller maps expected command failures to `request_failed`. A successful
response carries the runtime-generated location, position, label and root pane
identity.

## Confirmation

```text
tab_created(create_tab continuation)
        |
tab_creations.apply
        |
ConfirmTabCreationHandler
        |
ClientModel.createTab
        |
detach previous tab -> synchronize root-pane focus
        |
presentation_lifecycle.observe -> paced presentation
```

`tab_creations.apply` consumes the typed continuation once and requires the
response workspace to match it. The controller translates `schema.TabCreated`
into the confirmation command and uses the terminal size sent with the request,
not the current workbench. A host resize while the request is in flight cannot
give the client root pane different initial dimensions from the runtime.

The command has no request ID. Its label is borrowed only during the
synchronous commit; the workspace model copies it into bounded tab storage
before the handler returns.

`ClientModel.createTab` constructs and inserts the confirmed tab before
publishing it as active. Rejection preserves the existing tab and every model
revision. A successful commit advances only the tab and active-tab versions.

Attachment effects run after the commit. `RetireTabAttachmentsHandler`
detaches the tab that was active immediately before confirmation, closing its
captured paste and reported focus before its panes detach and committing their
operational flags last. The adapter then synchronizes attachment geometry and
focus reporting with the new root pane. An effect failure preserves the
confirmed tab because the runtime already owns it.

The use cases do not invalidate the view or request a draw. `client_events`
publishes `ClientModel.Version` to `Presenter`, which schedules one paced frame
for the changed model dimensions.

## Failure behavior and proof

A correlated `request_failed` consumes the continuation, preserves the current
projection and shows the runtime message as a notification. It no longer ends
the client. An unknown request ID, incompatible continuation or response for
another workspace is a protocol error. Every known continuation is consumed
before rejection. A duplicate tab fails in the model without detaching the
active tab.

- `src/frontend/client/application/create_tab.zig` proves request gating,
  label validation, exact planning, no provisional mutation,
  commit-before-effects and post-commit failure behavior.
- `src/frontend/client/tab_creations.zig` owns response correlation and
  wire-to-command translation.
- `src/frontend/client/model.zig` proves attached-source planning,
  transactional insertion, identity checks and exact version changes.
- `src/frontend/client/outbox.zig` proves queued creation owns its label and
  cwd until encoding.
- `src/frontend/client/client_test.zig` proves request correlation, preserved
  geometry, failure notification, attachment order and presenter observation.
- `src/backend/runtime/commands/create_tab.zig` and
  `src/backend/runtime/controllers/create_tab.zig` prove runtime rollback,
  commit ordering and expected wire failures.
