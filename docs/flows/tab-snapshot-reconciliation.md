# Tab snapshot reconciliation

The runtime owns pane membership. The client preserves layout, buffers, focus
and disposable resources for identities that remain canonical.

```text
bootstrap / selection / recovery -> AttachedClient.requestTabSnapshot
  -> runtime encodes current descriptors for the requested stable location
  -> entrypoints/AttachedClient.handleServerMessage(.tab_snapshot)
  -> operations/tabs/tab_snapshots.apply
     -> consume exact correlation and decode bounded pane identities
     -> Model.reconcileTab
     -> ignore removed-pane requests and pane_resources.release
     -> AttachedClient.synchronizeActivePane
     -> AttachedClient.resizeAttachedPanes
     -> AttachedClient.attachVisiblePanes for visible detached panes
  -> adapter observes presentation revisions
```

The runtime queues stable query identity, not borrowed pane descriptors, and
encodes its latest membership at delivery. The client consumes correlation once,
requires the exact location and ignores a continuation already retired by
canonical lifecycle. Unknown or incompatible replies are protocol errors.

The model rejects unknown tabs, duplicate/cross-tab identities and malformed
membership before resource effects. Retained panes keep buffers, attachment
flags and layout nodes; new panes start detached. Active membership/layout
changes advance the pane revision. Inactive reconciliation and exact repeats
advance no visible revision.

A saved split tree is restored only when its pane set still matches runtime
membership. Otherwise deterministic display order supplies the layout. When
the old focus disappears, a survivor is selected before restoration. Membership
does not depend on geometry: a pane with no usable content still belongs to the
layout and can attach after geometry becomes available.

After the model commits, the same operation retires removed resources, then
synchronizes active resources, offers attached sizes and requests missing
attachments. Pending requests are deduplicated; panes without content are
skipped. Geometry/focus operations resolve their target tab once and call
`AttachedClient.attachVisiblePanes` only after its canonical snapshot has loaded.
Exact repeated snapshots can repair operational resources without inventing a
model revision.

`tab_snapshots.recover` owns singleton repair coalescence. Attachment rejection,
tab closure and failed workspace departure decide whether they need repair,
then call it with the exact location. A pending snapshot is reused; otherwise
one correlated request is queued.

Model rejection performs no resource cleanup. Post-commit resource failure
keeps canonical membership and completed effects. A later snapshot or reconnect
repairs disposable state. Decoding/retirement lists use fixed pane bounds.

Source: `src/client/operations/tabs/tab_snapshots.zig` and
`src/client/model/Model.zig`.
Tests: `src/frontend/client/tests/synchronization.zig`, `pane_lifecycle.zig`,
`src/client/model/tests/tabs.zig`, workspace layout tests, and bounded request
tracker/outbox tests.
