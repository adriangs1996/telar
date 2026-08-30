# Workspace creation

Workspace creation is one runtime transaction followed by one client-model
replacement. The runtime owns workspace, tab, pane and attachment existence.
The client owns the creation prompt, its disposable projection, navigation
history and the version the presenter eventually paints.

## Request

```text
workspace-name prompt
        |
RequestWorkspaceCreationHandler
        |
validate name + plan attached focused pane
        |
owned outbox create_workspace
        |
runtime socket
```

`RequestWorkspaceCreationHandler` rejects pending operations, invalid names
and a missing or detached focused pane before any effect. A valid request uses
the focused pane only as `cwd_source`; it does not mutate the client model and
does not advance a semantic version.

The adapter supplies workbench geometry and launch configuration. The outbox
copies the prompt name and launch cwd into bounded storage before the input
event returns, so the view can close the prompt immediately after local
delivery succeeds. A delivery failure leaves both the prompt and model intact.

## Runtime transaction

```text
CreateWorkspaceController
        |
prepare launch authority -> propose workspace -> acquire geometry
        |
launch root pane -> commit aggregate -> publish event
        |
replace client attachments -> pane_opened(created = true)
```

`CreateWorkspaceHandler` keeps the workspace proposal invisible until launch
succeeds. Authority, proposal, geometry and pane-launch failures roll back all
pre-commit state. Once committed, the workspace survives an attachment failure
because rollback would contradict the authoritative runtime state.

The runtime replaces that client's attachments before it queues the successful
`pane_opened` response. This ordering determines the client confirmation rule:
the client must forget its previous local resources, but must not emit stale
`detach_pane` or focus-out messages for attachments the runtime already
replaced.

## Atomic client replacement

```text
pane_opened(create_workspace continuation)
        |
ConfirmWorkspaceCreationHandler
        |
ClientModel.replaceWorkspace
        |
capture departure + construct new root before retiring old projection
        |
one version commit
        |
bookmark/release old resources -> focus/input/snapshot effects
        |
Presenter.observeModel -> paced presentation
```

The continuation retains the nonzero terminal size sent to the runtime, so a
host resize cannot replace valid construction geometry with a zero-sized
workbench while the response is in flight. The `created` flag is checked before
mutation. The adapter also stages a remembered layout only when its exact
workspace and tab identity matches the runtime confirmation.

`ClientModel.replaceWorkspace` captures the previous workspace, focused-pane
bookmark, layout and bounded pane identities. The tab store constructs the new
root tab and pane first. Only successful construction retires the old store and
publishes the new workspace, so allocation or validation failure preserves the
old projection and every revision.

The successful replacement advances workspace, tabs, active-tab and panes
exactly once. There is no intermediate empty model and therefore no empty
frame between the old and new workspace. This differs deliberately from a
normal workspace handoff, whose departure is visible while it waits for an
existing runtime target.

Post-commit effects retain the navigation bookmark, release copy, paste,
reported-focus and graphics resources for every retired pane, activate the
confirmed root and request canonical workspace and tab snapshots. For reported
focus, resource release only forgets the local value; it sends neither
focus-out nor detach for the retired runtime attachments. Effect failure
preserves the committed model.

Neither creation use case invalidates the view nor requests a draw. The client
runtime publishes `ClientModel.Version` to `Presenter`; the presenter compares
it with the last observed and presented versions and folds the changed
dimensions into the paced frame loop.

## Failure behavior and proof

A correlated `request_failed` leaves the old projection and its semantic
version unchanged, closes only the request continuation and surfaces the
runtime failure as a notification. A malformed successful response is rejected
before replacement. A response arriving after an already-empty departure can
still install the confirmed root, which keeps recovery deterministic.

- `src/frontend/client/application/create_workspace.zig` proves request
  gating, validation, no provisional mutation, response validation,
  commit-before-effects and post-commit failure behavior.
- `src/frontend/client/model.zig` and `src/frontend/workspace/tabs.zig` prove
  bounded departure capture, atomic construction, exact versioning, rejection
  without mutation and recovery from an empty source.
- `src/frontend/client/outbox.zig` proves queued creation owns its name and cwd.
- `src/frontend/client/client_test.zig` proves the protocol request, single
  replacement commit, presenter boundary, exact snapshot messages, navigation
  restoration, absence of stale detach/focus output and failure preservation.
- `src/backend/runtime/commands/create_workspace.zig` and
  `src/backend/runtime/controllers/create_workspace.zig` prove transaction
  ordering, rollback categories, post-commit preservation and wire mapping.
