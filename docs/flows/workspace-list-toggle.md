# Workspace list toggle

The top-bar workspace list is disposable client chrome. Collapsing it changes
which workspace labels are shown, but it does not change the active workspace,
tab state, pane geometry or runtime state.

The transition runs on the interactive path. It changes one bounded value,
allocates nothing, emits no protocol message and has no external effect to
wait for.

## Client transition

```text
native, Lua, plugin or top-bar action
        |
actions.executeAction
        |
ClientModel.toggleWorkspaceList
        |
presentation_lifecycle.observe
        |
view_chrome.refresh -> view.setWorkspaceListCollapsed
        |
Presenter
```

`ClientModel` is the source of truth for the collapse preference. A toggle
advances only `model.chrome_revision`, reported as `Version.chrome`, and
returns the committed value and revision. Explicit assignment of the current value is a no-op.

The TUI view's `State.handleMouse` reports a `ViewInteractionCommand` with
intent `.toggle_workspace_list` without changing its projection. The input adapter and configured action sources route
that intent through the shared dispatcher and the same concrete operation.

## Presentation

The action calls `ClientModel.toggleWorkspaceList` directly. No IPC, resource
cleanup or immediate geometry synchronization is needed, and the operation has
no reference to the view or `Presenter`.

After the input event, the TUI's `events.zig` calls
`presentation_lifecycle.observe`. `view_chrome.refresh` sees the changed chrome
revision and copies the committed value into the view. `Presenter` compares the
observed and presented chrome revisions and schedules the paced frame.
Repeated observations of the same version change and schedule nothing.

## Failure and recovery

The model transition cannot fail. A later terminal presentation failure leaves
the committed disposable client state intact until shutdown. Reconnect starts
with the default expanded list; no runtime process or PTY is affected.

## Proof

- `src/model/state/tests/configuration_and_host.zig` proves collapse
  ownership, no-op assignment and chrome-revision isolation, and that the
  toggle changes only committed client state.
- `src/frontend/client/presentation/view.zig` proves top-bar clicks return intent without
  mutating the projection.
- `workspace list toggle is projected only by the presenter` in
  `src/frontend/client/tests/pane_lifecycle.zig` proves the projection remains
  stale until presentation observation, the dispatcher does not request a draw and no
  runtime message is emitted.
