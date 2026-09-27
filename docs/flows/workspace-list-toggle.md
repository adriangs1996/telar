# Workspace list toggle

The workspace-list collapse preference is disposable client-layout state. It
was drawn by the terminal client's top bar; that view left with the terminal
client. The window's top bar does not read the preference, so toggling it
changes nothing on screen today. The shared model still commits, persists and
reports it.

The transition runs on the interactive path. It changes one bounded value,
allocates nothing, emits no protocol message and has no external effect to
wait for.

## Client transition

```text
native binding (prefix w), Lua or plugin action
        |
actions.executeAction(.toggle_workspace_list)
        |
workspace_list.toggle -> model.workspace_list_collapsed, Version.chrome
        |
client_layout: retained in the client layout snapshot
cli_control / config queries: reported as workspace_list_collapsed
```

`ClientModel` is the source of truth for the collapse preference. A toggle
advances only `model.chrome_revision`, reported as `Version.chrome`, and
returns the committed value and revision. Explicit assignment of the current
value is a no-op. A `.toggle_workspace_list` view-interaction command reaches
the same operation through `view_interactions.apply`.

No IPC, resource cleanup or geometry synchronization is needed, and the
operation has no reference to any view. The changed chrome revision reaches
the window's observation like any other; repeated observations of the same
version schedule nothing.

## Failure and recovery

The model transition cannot fail. Reconnect restores the value retained in the
client layout snapshot; no runtime process or PTY is affected.

## Proof

- `src/model/state/tests/configuration_and_host.zig` proves collapse
  ownership, no-op assignment and chrome-revision isolation, and that the
  toggle changes only committed client state.
- `workspace list toggle is projected only by the presenter` in
  `src/client_tests/pane_lifecycle.zig` proves the projection remains
  stale until presentation observation, the dispatcher does not request a draw
  and no runtime message is emitted.
