# Pane metadata

The runtime publishes CWD and observed foreground process independently of
cell frames. The client owns only bounded replicas used by pane borders, tab
labels and navigation.

```text
runtime metadata cursors -> pane_cwd / pane_foreground
  -> entrypoints/server_messages.handleServerMessage
  -> operations/panes/pane_metadata.applyCwd / applyForeground
  -> Model.updatePaneMetadata
  -> multiplexer metadata storage
  -> adapter observes pane_metadata / pane_foreground revisions
```

The operation translates both wire variants to the same model transaction.
Retired panes and exact repeats are no-ops. CWD replacement allocates its bounded
owned copy before releasing the old path, so failure preserves the previous
value and revisions. A different exact path with the same display basename
updates state without publishing a display revision.

Foreground names use fixed storage. A changed attached-pane name advances both
metadata and foreground revisions; the latter identifies changes affecting pane
composition. No metadata operation requests a draw or reaches into host caches.
The presenter observes revisions and composes current model state.

Workspace snapshots carry bounded foreground names for inactive tabs without
requiring attachments. The model retains the relevant focused pane identity
and fallback name until terminal models exist. Global runtime metadata cursors
coalesce updates keyed by slot, identity, generation and revision. The model
accepts an unattached foreground update only for a matching retained identity
in the current workspace. Manual tab labels remain authoritative over automatic
names. Both adapters use `Tab.labelSlice()` and `Tab.labelIcon()`.

Each new runtime attachment also has its own metadata cursor. It receives
bootstrap metadata even if a global update arrived before the local pane was
constructed. Retirement frees owned CWD storage; reconnect receives current
runtime facts through fresh cursors.

Source: `src/client/operations/panes/pane_metadata.zig`,
`src/client/model/Model.zig`, and `src/client/workspace/`.
Tests: `src/client/model/tests/panes.zig`, `tabs.zig`,
`src/frontend/client/tests/pane_updates.zig`, and runtime workspace-snapshot /
runtime-state tests.
