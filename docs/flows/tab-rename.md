# Tab rename

The runtime owns the canonical label. The client prompt edits a candidate and
closes only after a locally accepted request; it does not rename the replica.

```text
name_prompt.inputPrompt -> name_prompt.submitPrompt(.rename_tab)
  -> tab_rename.requestTabRename
     -> pending-operation gate, label_validation.validate, resolve exact target
     -> tab_rename.sendTabRenameRequest -> owned rename_tab
  -> runtime canonical rename -> tab_renamed
  -> runtime_messages.handleServerMessage
  -> tab_rename.completeTabRename
     -> consume and verify exact rename continuation
     -> ClientModel.renameTab -> tab_rename.rename
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
displayed automatic text. Reconciliation compares `model.tabs.canonicalLabel(slot)`;
presentation uses `tab_label.text(model, slot)`.

The runtime commits its owned label before replying and marks other observing
clients for resync. The requesting client accepts the reply's label, which can
differ from the submitted candidate. The model copies it before wire storage
is released. A real change advances only the tab revision; an identical
canonical label advances nothing and preserves active identity.

Unknown correlation, wrong continuation/location and rejected canonical payloads
cannot rename a tab. Known correlation is consumed before these checks, so
replay cannot apply later. A correlated runtime failure preserves the old label
and publishes the runtime notice. Reconnect rebuilds labels from snapshots.

Source: `src/client/workspace/tab_rename.zig`, `src/model/state/ClientModel.zig`
and `src/model/workspace/tab_rename.zig`.
Tests: `src/frontend/client/tests/renaming_and_telemetry.zig`,
`tab_lifecycle.zig`, `src/model/state/tests/tabs.zig`, and
`src/model/connection/outbox_support.zig` cover prompt lifetime, owned bytes,
correlation, canonical no-ops and presentation boundaries.
