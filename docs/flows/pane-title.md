# Pane title

A child's OSC 0/2 window title is free evidence the emulator already parses.
The runtime keeps a sanitized bounded copy per pane, every client mirrors it,
and the window's title can follow the focused pane.

## End-to-end path

```text
child writes ESC ] 0 ; title BEL
        |
ghostty-vt Terminal.setTitle
        |
Pane.ingest -> TitleState.observe (drop control bytes, cut on UTF-8, revision)
        |
Attachment.prepareTitle (lane after cwd and foreground)
        |
schema.pane_title
        |
runtime_messages.handleServerMessage
        |
pane_metadata.update(.title) -> Pane.setTitle
        |
pane_metadata_revision
        |
native pump -> GuiAdapter.windowTitle -> WindowTitleState.sync
            -> NSWindow title (macOS) / xdg_toplevel_set_title (Linux)
               (only when the rendered `client.window_title` changes)
        +-> Lua bar context `pane_title`
        +-> agent snapshot `session_title` fallback (source `terminal`)
```

## Runtime

`TitleState.observe` runs on the interactive path after each ingest: one
bounded compare, no allocation. It drops C0/DEL bytes and invalid UTF-8
sequences and cuts at `core.max_pane_title_bytes` on a code point boundary,
so the stored value is safe in a wire frame and in a window title.

Attachments start at the empty-title revision. A fresh attachment therefore
receives a `pane_title` only for a title a child actually set; a cleared title
is delivered as an empty string so clients forget it.

Agent snapshot enrichment substitutes the pane title for the placeholder
session title while no generated, manual or agent title exists and marks the source
`terminal`. The history store never persists that source.

## Client

The client `Pane` stores the title as an owned slice allocated on change, like
the working directory, because a fixed buffer per pane would cost megabytes
per client model.

`client.window_title` is a template with `{hostname}`, `{workspace}`, `{tab}`
and `{pane_title}`. An empty template, the default, leaves the window its
default title, `GuiAdapter.default_title`. While a frame is held at a limit
the title ends with " — limit reached: <name>" either way
([Limit reached](limit-reached.md)). After each client pump the native loop
asks `GuiAdapter.windowTitle`,
which renders the template with `pane_title.focusedTitle`, `workspaceName`,
`tab_label.text`, and the active machine's label (or the local hostname) as
`{hostname}`. `WindowTitleState.sync` hands the text to the platform only when
it differs from the last one sent.

Bar callbacks receive `context.pane_title` for the focused pane of the active
tab.

## Validation

- `src/backend/runtime/tests/pane_title_test.zig` proves capture, sanitizing,
  clearing, delivery and revision bookkeeping through a real attachment.
- `src/core/schema_contract_test.zig` pins the `pane_title` bytes.
- `src/model/state/tests/observations.zig` proves per-pane storage,
  no-op repeats and the focused-pane accessor.
- `src/client/presentation/window_title.zig` proves send-on-change, retry
  after failure and bounded Unicode truncation.
