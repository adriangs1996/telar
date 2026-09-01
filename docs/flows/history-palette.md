# History palette

`prefix+/` searches command history from the UI client. The palette is a
`history` name-prompt target rendered through the goto-picker list modal;
results live in the runtime's SQLite history and reach the client over the
existing UI connection.

## Query

```text
history_palette action
        |
history_palettes.begin -> name prompt (target .history)
        |
model.history_palette.begin + expect(request id)
        |
outbox query_history (global scope, bounded query, limit 16)
        |
runtime routeQueryHistory (observation path)
```

Opening clears previous results and sends the unfiltered newest history.
Every visible query edit sends one more `query_history`; selection moves and
pastes are local and send nothing. The palette records the newest request id
and ignores every other reply, so out-of-order replies cannot show stale
results for a newer query. The runtime classifies a session's role from its
first request only, so a UI connection issuing `query_history` keeps its
attachment.

## Reply

```text
history_results
        |
history_palettes.apply
        |
model.history_palette.apply(request id, entries)
        |
Version.history -> presenter invalidate -> list modal frame
```

Entries are copied into bounded model storage inside the handler because the
decoded view borrows the receive buffer: at most 16 entries, commands
truncated to 512 bytes. A reply arriving after the palette closed still
lands in model storage but is invisible; a reply for an unexpected request
id changes nothing and is not a protocol error.

## Submit

Enter first closes the prompt, then pastes the selected command into the
focused pane through the ordinary pane-paste path
(`pane_inputs.expressionPaste`) without executing it. The order matters:
`planPaneInput(.focused)` refuses input while a prompt owns it, so the
submit effect only accepts the closure and the paste runs from a
pre-dispatch snapshot of the selection once the prompt is gone. The goto
picker defers its navigation the same way. An empty result list just
closes the palette. Escape closes it without side effects.

Deviations from herdr: global scope only (scope toggles pending) and
keyboard-only interaction.

- `src/frontend/client/model/history_palette.zig` proves stale-reply
  rejection and command bounds.
- `src/frontend/client/model/name_prompt.zig` proves selection commands and
  empty-query submission for list targets.
- `src/frontend/client/tests/graphics_and_clipboard.zig` proves stray
  history results are ignored without ending the client.
