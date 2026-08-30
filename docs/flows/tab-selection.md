# Tab selection

The active tab is disposable client state. The runtime keeps canonical tab and
pane membership, but it does not choose which tab one client is viewing.

Selection runs on the interactive path. Its work is bounded by
`schema.max_tabs_per_workspace`, `schema.max_panes_per_tab`, the fixed client
outbox and the fixed continuation tracker. Only one tab snapshot may be pending.

## Client transition

```text
select_tab / select_tab_offset / mouse identity
        |
InputHandler.selectTab
        |
SelectTab { target }
        |
SelectTabHandler
        |
ClientModel.selectTab
        |
tab_selections.applySelection
        |
detach previous panes -> request selected tab snapshot
        |
Client.observeModel -> Presenter
```

`InputHandler` translates each source into a `Target`. Numeric bindings provide
a zero-based position, next and previous bindings provide a signed offset, and
mouse, sidebar and notification interactions provide a stable tab identity.
The input handler does not inspect the workspace slot array or calculate the
next index.

`SelectTabHandler` rejects selection while a tab snapshot is pending. It then
delegates target resolution and the semantic commit to `ClientModel`. A missing
identity, invalid position, repeated position, zero offset, complete wrapped
turn or workspace with fewer than two tabs is a no-op. No-op selections run no
resource effects and advance no version.

Offset resolution reduces the offset modulo the bounded tab count before it
adds the active index. This supports negative offsets and avoids signed integer
overflow for the full `isize` input range.

## Resource effects and presentation

A committed selection advances only `ClientModel.Version.active_tab`. The
selection adapter then clears reported focus, sends `detach_pane` for every
attached or in-flight pane in the previous tab, hides its graphics and marks
those panes detached. It makes the selected tab's graphics visible,
synchronizes pane focus and enqueues one `request_tab_snapshot` for the exact
selected location.

The runtime dispatches `detach_pane` through `detach_pane.Controller` and
`DetachPaneHandler`. It dispatches `request_tab_snapshot` through
`tab_snapshot.Controller` and the tab snapshot query. The returned
`tab_snapshot` enters the separate
[tab snapshot reconciliation](tab-snapshot-reconciliation.md) flow, which
repairs pane membership and attachments from runtime state.

Neither the selection handler nor its adapter requests a frame. The client loop
calls `Client.observeModel`, and `Presenter` schedules a paced frame only after
it observes the changed active-tab revision.

## Failure and recovery

The model commits before resource effects. A resource error therefore preserves
the selected identity and propagates to the client loop. The client process
exits on that error. Runtime tabs and PTYs remain valid, and reconnect rebuilds
the disposable client model from canonical snapshots. Any `detach_pane` message
already delivered remains valid because attachments also belong to one client
session.

## Proof

- `src/frontend/workspace/tabs.zig` proves bounded positive and negative wrap,
  complete-turn no-ops and overflow-safe offset reduction.
- `src/frontend/client/model.zig` proves identity, position and offset
  resolution plus exact version changes.
- `src/frontend/client/application/select_tab.zig` proves snapshot gating,
  commit ordering, no-op behavior and post-commit effect failure.
- `src/frontend/client/client_test.zig` proves native position and offset
  entrypoints, attachment order, snapshot delivery and presenter observation.
- `src/backend/runtime/controllers/detach_pane.zig` and
  `src/backend/runtime/controllers/tab_snapshot.zig` prove the two runtime
  protocol entrypoints used after selection.
