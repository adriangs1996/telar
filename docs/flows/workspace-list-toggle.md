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
InputHandler.toggleWorkspaceList
        |
ToggleWorkspaceListHandler
        |
ClientModel.toggleWorkspaceList
        |
Client.observeModel
        |
Presenter
        |
View.setWorkspaceListCollapsed
```

`ClientModel` is the source of truth for the collapse preference. A toggle
advances only `ClientModel.Version.chrome` and returns the committed value and
revision. Explicit assignment of the current value is a no-op.

`View.handleMouse` reports `Interaction.toggle_workspace_list` without
changing its projection. `InputHandler` routes that intent and configured
actions through the same use case.

## Presentation

This slice has no application effects port because the state change needs no
IPC, resource cleanup or immediate geometry synchronization. The use case has
no reference to `View` or `Presenter`.

After the input event, the client loop calls `Client.observeModel`.
`Presenter` compares the observed and presented chrome revisions and schedules
the paced frame. When that frame is due, it projects the committed value into
`View` before composing. Repeated observations of the same version schedule
nothing.

## Failure and recovery

The model transition cannot fail. A later terminal presentation failure leaves
the committed disposable client state intact until shutdown. Reconnect starts
with the default expanded list; no runtime process or PTY is affected.

## Proof

- `src/frontend/client/model.zig` proves collapse ownership, no-op assignment
  and chrome-revision isolation.
- `src/frontend/client/application/toggle_workspace_list.zig` proves the use
  case changes only committed client state.
- `src/frontend/client/view.zig` proves top-bar clicks return intent without
  mutating the projection.
- `src/frontend/client/client_test.zig` proves the projection remains stale
  until presenter observation, the toggle never sets `InputHandler.redraw` and
  no runtime message is emitted.
