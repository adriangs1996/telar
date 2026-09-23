# Client detach

Detach ends this client only. Runtime panes, PTYs and terminal state remain
available for another attachment.

```text
actions.executeAction(.detach)
  -> client_layout.synchronizeClientLayout
  -> tab_removal.detachAllTabs
     -> capture bounded stable TabLocation list
     -> tab_removal.detachTab for each location
        -> ClientModel.planTabDetachment
        -> finish tab-owned paste
        -> tab-owned focus-out
        -> detach, retire pending correlation, hide graphics per pane
        -> ClientModel.commitTabDetachment
  -> return KeybindControl.stop to the event loop
```

`tab_removal.detachAllTabs` captures tab locations before the first effect and
walks them in stable client order. `tab_removal.detachTab` plans one exact tab,
then applies its effects in paste/focus/pane order. Pending opens also receive a
detach and their continuations become ignored, so late confirmations cannot
revive ownership. The model commits attachment flags and retires pending frames
only after that tab's effects complete.

Detachment advances no semantic presentation version and requests no frame.
The stop directive is returned only after every requested detach enters the
bounded `model.to_runtime` outbox. Disconnect itself also retires the connection's runtime
attachments; no PTY shutdown is requested.

A delivery error propagates instead of returning stop. Earlier effects remain
applied; a partially processed tab does not claim all its flags detached. The
normal error path terminates the client and destroys disposable resources while
the runtime continues.

Source: `src/client/workspace/tab_removal.zig` and
`src/model/state/ClientModel.zig`.
Tests: `src/frontend/client/tests/pane_lifecycle.zig` covers stable multi-tab
wire order, local attachment cleanup, exact paste/focus ownership, version
silence and the final stop directive. Tab close/handoff tests exercise capacity
checks and partial failures in the same attachment retirement operation.
