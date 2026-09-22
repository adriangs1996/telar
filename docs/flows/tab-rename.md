# Tab rename

The runtime owns the canonical label. The client prompt edits a candidate and
closes only after a locally accepted request; it does not rename the replica.

```text
AttachedClient.inputPrompt
  -> AttachedClient.requestTabRename
     -> pending-operation gate, validate label, resolve exact target
     -> AttachedClient.sendTabRenameRequest -> owned rename_tab
  -> runtime canonical rename -> tab_renamed
  -> AttachedClient.handleServerMessage
  -> AttachedClient.completeTabRename
     -> consume and verify exact rename continuation
     -> Model.renameTab
  -> adapter observes presentation revisions
```

Names require valid UTF-8, no control bytes and one through
`schema.max_tab_label_bytes` bytes. The target may be inactive. The outbox copies
the borrowed candidate before prompt closure and retains only stable correlation.
A busy lifecycle or vanished target leaves the prompt open; invalid text and
local enqueue errors also preserve it. Failed delivery removes provisional
correlation and changes no canonical tab state.

An empty canonical label selects automatic naming. Manual rename supplies a
nonempty label and disables it, even if that label equals the currently
displayed automatic text. Reconciliation compares `canonicalLabel()`;
presentation uses `labelSlice()`.

The runtime commits its owned label before replying and marks other observing
clients for resync. The requesting client accepts the reply's label, which can
differ from the submitted candidate. The model copies it before wire storage
is released. A real change advances only the tab revision; an identical
canonical label advances nothing and preserves active identity.

Unknown correlation, wrong continuation/location and rejected canonical payloads
cannot rename a tab. Known correlation is consumed before these checks, so
replay cannot apply later. A correlated runtime failure preserves the old label
and publishes the runtime notice. Reconnect rebuilds labels from snapshots.

Source: `src/client/AttachedClient.zig` and
`AttachedClient.inputPrompt`.
Tests: `src/frontend/client/tests/renaming_and_telemetry.zig`,
`tab_lifecycle.zig`, `src/client/model/tests/tabs.zig`, and
`src/client/connection/outbox_support.zig` cover prompt lifetime, owned bytes,
correlation, canonical no-ops and presentation boundaries.
