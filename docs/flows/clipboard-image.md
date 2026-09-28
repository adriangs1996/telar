# Clipboard image preview

This flow starts when the focused child receives an unmodified `Ctrl+V`. On
macOS the window then mirrors a clipboard image for an attachment-capable
agent: a card on a shelf below the agent's pane, paired by prompt order with
the marker the agent's editor shows (`[Image #N]` for Codex and Claude, a
pasted path for Pi). A card opens the image in a modal. The child remains
responsible for accepting or rejecting the paste; the agent reads the image
from the clipboard itself.

The shelf belongs to the window's own client. Clients of other machines the
window holds, and the headless client, bind no shelf: their `Ctrl+V` still
reaches the child, and nothing is captured.

## End-to-end path

```text
Ctrl+V (window key event)
  |
router.routeEvent -> key_routing.routeKeyInput -> key_routing.routeCurrentKey
  |
key_routing.routePaneKey -> pane_input.sendPaneInput -> model.to_runtime
  |
key_routing.requestsClipboardPreview -> clipboard_capture.startClipboardCapture
  |
model.clipboard.reserve { id, target } -> model.to_host .capture
  |
GuiAdapter.deliverRequests -> clipboard_image.start -> inbox worker
  |                                      (reads the pasteboard as a bounded PNG,
  |                                       decodes the thumbnail and modal copy)
gui_event .clipboard_image -> clipboard_image.finish
  |
clipboard_capture.completeClipboardCapture
  |
finish exact id -> validate returned target -> validate current target
  |
AttachmentShelf.adopt (ImagePreviews) -> catalog slot owns the decoded pixels
  |
pane_resize.resizeAttachedPanes -> model.pane_bottom_reservation
  |
clipboard_capture.reportClipboardCapture: quiet result or bounded notice
  |
GuiAdapter.observation (attachment_ingress) -> prepare -> ImagePreviews.beginFrame
  |
Composition: ImagePreviewShelf in the layout's reserved rows, ImagePreviewModal
```

`key_routing.routeCurrentKey` sends the pane input through
`key_routing.routePaneKey` first. Only when that input was delivered and
`key_routing.requestsClipboardPreview` matches does it call
`clipboard_capture.startClipboardCapture`. The runtime send worker drains
`model.to_runtime` to the PTY independently. A missing target, unsupported
platform, busy worker or scheduling failure can drop the preview, but none can
retract or delay an already accepted pane input transaction. See
[Key routing](key-routing.md).

## Prompt coupling

The catalog scopes previews to one exact pane generation and applies the
marker scheme the agent's manifest declares (`attachments` in
`config.runtime.agents`, carried on the snapshot entry and mapped by
`attachment_prompt.markerPolicy`; `none` hides the shelf):

- Codex (`ordered`) treats each `[Image #N]` marker as one atomic editor
  element and renumbers the remaining markers after deletion, so its previews
  follow prompt order.
- Claude (`stable_number`) keeps increasing marker numbers after deletion, so
  the catalog learns and retains the actual number rendered for each preview.
- Both editors word-wrap the placeholder at its inner space when it lands on
  a row boundary. Marker scanning accepts that shape, so a wrapped marker
  still counts as present, can be paired and can be dismissed.
- Pi (`pasted_path`) has no placeholder. Its `Ctrl+V` writes the image to
  `<tmpdir>/pi-clipboard-<uuid>.<ext>` and inserts that path as plain text.
  `src/model/attachments/path_marker.zig` reads Pi's editor conventions to
  find that path on screen.

A card's `×` sends `.attachment_dismiss`. `agent_attachments.dismissAttachment`
plans a bounded synthetic key sequence (at most
`attachment_types.max_removal_keys` keys) that moves to the marker, deletes it
and restores the cursor, sends it through `pane_input.sendPaneKeys` as one
input transaction, and retires the preview only after that transaction is
accepted.

For input in the other direction, a plain `Backspace` or `Delete` next to a
known marker retires its preview. Providers that learn marker identities also
arm a bounded deletion watch: after a key that may remove a marker, the next
`deletion_watch_frames` committed frames retire previews whose learned marker
is no longer on screen. A plain `Enter` delivered to the owning pane retires
every preview for that prompt and cancels an exact capture still in flight,
so a late completion cannot recreate previews for a prompt already sent.
Claude and Pi turn an `Enter` after a trailing backslash into a newline;
`markers.promptContinuesAtCursor` reads that backslash from the committed
frame, so that `Enter` leaves previews and the capture alone.

## State and worker ownership

`ClientModel` owns one optional `ClipboardCapture` in `model.clipboard`
(`ClipboardCaptureState`): a monotonically increasing identity and the exact
pane generation selected at start. This is lifecycle state, not render state.

`GuiAdapter.init` sets `model.host.clipboard_capture` on macOS and binds
`ImagePreviews.port()` as the window client's `Client.attachments`.
`startClipboardCapture` resolves the focused target, commits the reservation
and queues a `.capture` request in the same function. It returns
`unsupported`, `no_target`, `busy` or the started reservation directly.

`clipboard_image.start` runs one inbox worker at a time. A capture requested
while a cancelled one still reads the pasteboard waits in
`ImagePreviews.queued`; a later request replaces it and the replaced one
finishes as cancelled. The worker receives copied values and two heap-stable
slots: `model.clipboard.orphan` for the `Capture` it publishes and
`ImagePreviews.landing` for the decoded preview. It reads at most 32 MiB of
pasteboard data into a PNG of at most 16 MiB and 16 million pixels, then
decodes it (`imaging.png`) and box-filters it into a premultiplied thumbnail
that fits 256 × 256 pixels and a modal copy of at most 2048 pixels a side and
2 Mi pixels (`image/preview_decode.zig`). `clipboard_image.finish` completes
the capture in the window's own client, whichever machine is shown, frees a
decoded preview adoption did not take, and starts the queued capture.

## Completion policy

`completeClipboardCapture` first finishes only the exact identity it was
given; an unrelated completion cannot clear newer work. A successful result
must repeat the same identity and target, and the model then resolves the
focused attachment target again. A removed agent, changed pane generation,
focus change or workspace change makes the image stale and it is freed.

A current result is adopted by `ImagePreviews`: the catalog validates the
image again, owns the PNG, and the new slot takes the decoded preview whose
sequence matches the capture. When adoption changes the shelf's pane,
`pane_resize.resizeAttachedPanes` records the shelf's reservation in
`model.pane_bottom_reservation`, which every `tab_layout.snapshot` applies:
the pane sizes offered to the runtime, the drawn panes and pointer targeting
all see the same shortened pane, and the snapshot's `reserved` rectangle is
where the shelf draws.

Applied, stale, ignored and clipboard-empty results stay quiet. Oversized,
worker, decoding and adoption failures map to bounded notifications.

## Presentation and bounds

The previews take the last two of the frame's eight diagram texture slots,
so the diagram store keeps six (`diagrams/Store.zig`). Slot 6 is a sheet of
four 256 × 256 cells, one per catalog slot, holding the thumbnails; slot 7 is
the open preview's modal copy. The frame's texture budget
(`TELAR_GUI_DIAGRAM_FRAME_PIXELS`, `DiagramTexture.max_frame_pixels`) adds the
sheet and one modal copy to the diagrams' 8 Mi pixels.

Pixels change only in `ImagePreviews.beginFrame`, which `prepare` calls while
no frame is in flight: it zeroes and frees the pixels retired since the last
frame, reaps retired catalog slots and copies new thumbnails into their sheet
cells. A retired preview's pixels wait in a bounded list for that step, so the
key press that retires one never wipes megabytes, and the modal copy the last
frame sampled is never freed under it. Every change advances
`ImagePreviews.revision`, which the window reports as `attachment_ingress`,
so the presenter schedules the paced frame.

`ImagePreviewShelf` draws one card per visible preview, the thumbnail fitted
in it and a `×` control. A card opens the modal; `ImagePreviewModal` dims the
window, draws the image fitted in a bordered panel and closes on a press
outside it, on its `×`, or on Esc, which `key_routing` routes to the shelf
while the modal owns the keyboard.

Limits:

- one capture worker per window;
- 32 MiB of source clipboard data, 16 MiB per PNG, 16 million pixels;
- four retained previews and 32 MiB of retained PNG bytes;
- per preview, a 256 × 256 thumbnail and a modal copy of 2 Mi pixels.

Captured PNGs and decoded pixels are zeroed before release.

## Validation

- `src/model/state/tests/configuration_and_host.zig` and
  `src/model/state/ClipboardCaptureState.zig` prove single-flight capture
  identity, exact completion, target ownership, identifier exhaustion and
  orphan cleanup.
- `src/model/state/tests/tabs.zig` proves the layout snapshot applies the
  pane bottom reservation and rebuilds when it changes.
- `src/client/input/attachment_prompt.zig` proves marker policies per provider
  and which keys arm a deletion watch.
- `src/model/attachments/path_marker.zig` proves Pi path parsing.
- `src/client/attachments/catalog_tests.zig` proves sensitive-byte ownership,
  the four-item eviction bound and initialization failures.
- The clipboard and marker tests in `src/client_tests/configuration.zig`,
  `input.zig` and `input_operations.zig`, run against a test shelf, prove the
  shared client's capture, adoption, marker deletion and prompt submission.
- `src/gui/image/preview_decode.zig` proves the preview sizes and
  premultiplied decoding.
- `src/gui/tests/image_previews.zig` proves sheet cells per slot, that a
  borrowed modal copy outlives its retirement until the next frame, that a
  preview decoded for another capture is not adopted, and, through the
  window, that a completed capture reserves rows below the pane, draws its
  thumbnail from the sheet, opens the modal from its card and closes it with
  Esc.
