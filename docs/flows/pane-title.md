# Pane title

A child's OSC 0/2 window title is free evidence the emulator already parses.
The runtime keeps a sanitized bounded copy per pane, every client mirrors it,
and the host terminal's own window title can follow the focused pane.

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
runtime_messages -> pane_metadata.applyTitle
        |
ClientModel.updatePaneMetadata(.title) -> multiplexer.Model.setPaneTitle
        |
Version.pane_metadata
        |
Presenter.syncWindowTitle -> OSC 0 to the host (only when the rendered
                             `client.window_title` template changes)
        +-> Lua bar context `pane_title`
        +-> agent snapshot `session_title` fallback (source `terminal`)
```

## Runtime

`TitleState.observe` runs on the interactive path after each ingest: one
bounded compare, no allocation. It drops C0/DEL bytes and invalid UTF-8
sequences and cuts at `schema.max_pane_title_bytes` on a code point boundary,
so the stored value is safe in a wire frame and in a host escape sequence.

Attachments start at the empty-title revision. A fresh attachment therefore
receives a `pane_title` only for a title a child actually set; a cleared title
is delivered as an empty string so clients forget it.

Agent snapshot enrichment substitutes the pane title for the placeholder
session title while no generated, manual or agent title exists and marks the source
`terminal`. The history store never persists that source.

## Client

The client pane stores the title as an owned slice allocated on change, like
the working directory, because pane storage is inline in every tab and a
fixed buffer per pane would cost megabytes per client model.

`client.window_title` is a template with `{hostname}`, `{workspace}`, `{tab}`
and `{pane_title}`. An empty template, the default, never touches the host
title. The presenter renders it on every presentation and writes OSC 0 only
when the rendered text differs from the last one sent; the bytes ride the
frame flush already in progress.

Bar callbacks receive `context.pane_title` for the focused pane of the active
tab.

## Proof

- `src/backend/runtime/tests/pane_title_test.zig` proves capture, sanitizing,
  clearing, delivery and revision bookkeeping through a real attachment.
- `src/core/schema_contract_test.zig` pins the `pane_title` bytes.
- `src/frontend/client/model/tests/observations.zig` proves per-pane storage,
  no-op repeats and the focused-pane accessor.
- `src/frontend/presentation/window_title.zig` proves token rendering and
  send-on-change.
