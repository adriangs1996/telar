# Clipboard image preview

The preview shelf that showed a clipboard image below an agent's pane existed
only in the terminal client and left with it. The window never bound a shelf,
and neither does the headless client. An unmodified `Ctrl+V` still reaches the
focused child, and the agent reads the image from the clipboard itself; Telar
shows no preview.

What remains is the shared capture lifecycle and the marker logic behind the
`AttachmentShelf` port. Both run only when an adapter binds a shelf in
`Client.attachments`, which today only the client integration tests do.

## Path today

```text
Ctrl+V (window key event or headless `key` line)
  |
router.routeEvent -> key_routing.routeKeyInput -> key_routing.routeCurrentKey
  |
key_routing.routePaneKey -> pane_input.sendPaneInput -> model.to_runtime
  |
key_routing.requestsClipboardPreview -> clipboard_capture.startClipboardCapture
  |
model.host.clipboard_capture is false -> .unsupported
```

`key_routing.routeCurrentKey` sends the pane input through
`key_routing.routePaneKey` first. Only when that input was delivered and
`key_routing.requestsClipboardPreview` matches does it call
`clipboard_capture.startClipboardCapture`. That function reads platform
support from `model.host.clipboard_capture`, which defaults to `false` and
which neither adapter sets. It therefore returns `unsupported` before it
reserves a capture or queues a host request, and publishes nothing. The
runtime send worker drains `model.to_runtime` to the PTY independently; the
capture outcome can never retract or delay an accepted pane input
transaction. See [Key routing](key-routing.md).

If a `.capture` host request does reach an adapter, both `GuiAdapter` and
`HeadlessClient` answer it at once through
`clipboard_capture.completeClipboardCapture` with
`error.NativeServiceUnavailable`. That finishes the exact capture identity
and publishes the bounded "Image preview failed" notice. No worker reads the
clipboard.

## Shared capture lifecycle

`ClientModel` owns one optional `ClipboardCapture` in `model.clipboard`
(`ClipboardCaptureState`). It contains a monotonically increasing identity and
the exact pane generation selected at start. This is lifecycle state, not
render state, so reserving or finishing it does not advance
`ClientModel.Version`.

With support enabled, `startClipboardCapture` resolves the focused attachment
target, commits the model reservation and queues a `.capture` request on
`model.to_host` in the same function. It returns `unsupported`, `no_target`,
`busy` or the started reservation directly. A failed push removes only the
matching reservation. A second `Ctrl+V` still reaches the child, but no
second capture starts while the first remains active.

`clipboard_capture.completeClipboardCapture` first finishes only the exact
identity it was given; an unrelated completion cannot clear newer work. A
successful result must repeat the same identity and target, and the model then
resolves the focused attachment target again. A removed agent, changed pane
generation, focus change or workspace change makes the image stale, and the
owned capture is freed. A current result is adopted by the bound shelf
through `AttachmentShelf.adopt`; with no shelf, adoption fails with
`AttachmentsUnsupported`. When adoption changes pane geometry, the operation
calls `pane_resize.resizeAttachedPanes` before reporting.

Applied, stale, ignored and clipboard-empty results stay quiet. Oversized,
worker and adoption failures map to bounded notifications. `model.clipboard`
keeps only the orphan result slot needed to close the cancellation race.

## Prompt coupling

The marker policy comes from the agent's manifest (`attachments` in
`config.runtime.agents`, carried on the snapshot entry and mapped by
`attachment_prompt.markerPolicy`):

- Codex (`ordered`) treats each `[Image #N]` marker as one atomic editor
  element and renumbers the remaining markers after deletion.
- Claude (`stable_number`) keeps increasing marker numbers after deletion, so
  a shelf learns and retains the actual number rendered for each preview.
- Pi (`pasted_path`) has no placeholder. Its `Ctrl+V` writes the image to
  `<tmpdir>/pi-clipboard-<uuid>.<ext>` and inserts that path as plain text.
  `src/model/attachments/path_marker.zig` reads Pi's editor conventions to
  find that path on screen.

The key-routing hooks in `agent_attachments` (`observeAttachmentInput`,
`expectMarkerDeletion`, `reconcileAttachmentFrame`, `dismissAttachment`)
return at once without a bound shelf. With a shelf, closing a preview sends a
bounded synthetic key sequence (at most `attachment_types.max_removal_keys`
keys) that deletes the marker through `pane_input.sendPaneKeys`; `Backspace`,
`Delete` and a watch over the next `deletion_watch_frames` committed frames
retire previews whose marker is gone; and a plain `Enter` that submits the
prompt retires its previews and cancels an exact capture still in flight.

The capture limits in `src/model/attachments/types.zig` still bound any
shelf: 32 MiB of source clipboard data, 16 MiB per encoded PNG, 16 million
decoded pixels, four retained previews and 32 MiB of retained preview bytes.

## Validation

- `src/model/state/tests/configuration_and_host.zig` and
  `src/model/state/ClipboardCaptureState.zig` prove single-flight capture
  identity, exact completion, target ownership, validation, identifier
  exhaustion and orphan cleanup.
- `src/client/input/clipboard_image.zig` holds the start and completion
  outcome types and failure classification.
- `src/client/input/attachment_prompt.zig` proves marker policies per
  provider and which keys arm a deletion watch per policy.
- `src/model/attachments/path_marker.zig` proves Pi path parsing across
  forced wraps, extent limits, screen-order collection and cursor resolution.
- `src/client/attachments/catalog_tests.zig` proves sensitive-byte ownership,
  the four-item eviction bound and initialization failures.
- `control-v reaches the pane when no clipboard preview target exists` and the
  clipboard image completion tests in `src/client_tests/configuration.zig`,
  run against a test shelf, prove pane delivery without a target, resource
  observation, stale target cleanup and failures without direct presentation.
- `obsolete clipboard completion frees its image without consuming a newer
  capture` in `src/client_tests/input_operations.zig` proves exact completion.
- The marker tests in `src/client_tests/input.zig` prove that child marker
  deletion precedes local retirement and that prompt submission retires
  paired previews.
