# Clipboard image preview

This flow starts when the focused child receives an unmodified `Ctrl+V`. Telar
then tries to mirror a local clipboard image for an attachment-capable agent.
The preview is disposable client media paired by prompt order with the
`[Image #N]` marker owned by Codex or Claude. The child remains responsible for
accepting or rejecting the paste.

## End-to-end path

```text
Ctrl+V
  |
InputHandler.key
  |
key_routing adapter -> KeyRoutingHandler
  |
pane_inputs.send -> client outbox
  |
clipboard_images.start
  |
StartClipboardImageHandler
  |
ClientModel.beginClipboardCapture { id, target }
  |
ClientEvent.clipboard_image media worker
  |
clipboard_images.complete
  |
CompleteClipboardImageHandler
  |
finish exact id -> validate returned target -> validate current target
  |
attachments.Store.adopt -> Store.ingressVersion
  |
optional pane resize
  |
DeliverClipboardImageCompletionHandler
  |
quiet result or bounded failure notification
  |
presentation_lifecycle.observe -> Presenter -> paced cell and media passes
```

`InputHandler.key` delegates the semantic key without recognizing `Ctrl+V`.
`KeyRoutingHandler` completes its pane effect before it asks for a preview, and
the adapter maps those effects to `pane_inputs.send` followed by
`clipboard_images.start`. The runtime drains the outbox to the PTY
independently. A missing target, unsupported platform, busy worker or
scheduling failure can drop the preview, but none can retract or delay an
already accepted pane input transaction. See [Key routing](key-routing.md).

## Prompt coupling

The attachment store scopes previews to one exact pane generation and applies
the provider's marker identity, chosen by `attachment_prompt.markerPolicy`:

- Codex (`ordered`) treats each `[Image #N]` marker as one atomic editor
  element and renumbers the remaining markers after deletion, so its previews
  follow prompt order.
- Claude (`stable_number`) keeps increasing marker numbers after deletion, so
  Telar learns and retains the actual number rendered for each preview.
- Pi (`pasted_path`) has no placeholder. Its `Ctrl+V` writes the image to
  `<tmpdir>/pi-clipboard-<uuid>.<ext>` and inserts that path as plain text.
  Telar learns the UUID from committed frames and treats the whole path as
  the marker. `attachments/path_marker.zig` reads Pi's editor conventions: a
  word longer than the row is broken at grapheme granularity into rows of
  `width - 1` cells, the path starts at the first `/` of its word so a word
  soft-wrapped before it is never included, and the hidden hardware cursor is
  replaced by Pi's isolated inverse-video cell.

Closing a preview produces a bounded synthetic key sequence for its pane. The
sequence moves to the corresponding marker, deletes it and restores the prior
cursor position. An atomic placeholder costs one deletion key; a Pi path costs
one per grapheme, and the cursor must share a row with the path's end or
start. The whole sequence is bounded by `attachments.max_removal_keys`, which
the pane-input boundary can encode as one transaction.
`PaneInputHandler.executeKeys` encodes the sequence against the pane's current
keyboard modes and enqueues it as one input transaction. Telar retires the
local image only after that transaction is accepted.

For input in the other direction, a plain `Backspace` or `Delete` next to a
known marker retires its preview. Providers that learn marker identities also
arm a bounded deletion watch: after a key that may remove a marker (Backspace
and Delete for every learning policy; Pi's word and line deletion bindings as
well), the next `deletion_watch_frames` committed frames retire previews whose
learned marker is no longer on screen. This covers deletion paths that happen
inside Claude's attachment navigation context and Pi's `Ctrl+W`, `Ctrl+U`,
`Ctrl+K`, `Alt+D` and `Alt+Backspace`. A plain `Enter` delivered to the owning
pane retires every preview for that prompt. It also cancels an exact clipboard
capture still in flight, so a late worker completion cannot recreate previews
for a prompt that was already sent. Retiring image buffers remains deferred to
the media path.

## State and worker ownership

`ClientModel` owns one optional `ClipboardCapture`. It contains a monotonically
increasing identity and the exact pane generation selected at start. This is
lifecycle state, not render state, so reserving or finishing it does not
advance `ClientModel.Version`.

`StartClipboardImageHandler` commits that reservation before scheduling the
media worker. The adapter supplies only the physical platform-support fact;
the handler owns `unsupported`, resolves the focused target from `ClientModel`,
owns `no_target` and `busy`, and returns the complete start outcome. A
scheduling error removes only the matching reservation. A second `Ctrl+V`
still reaches the child, but its preview is skipped while the first capture
remains active.

The platform worker receives copied IDs and values. It owns clipboard access,
PNG allocation and format checks. `CaptureResources` retains only the result
pointer needed to close the cancellation race. Client shutdown cancels select
tasks before it frees that pointer. No worker retains `ClientModel` or `View`.
Its only borrowed client memory is the heap-stable orphan result slot.

## Completion policy

`ClientEvent.clipboard_image` carries the capture identity even when clipboard
access failed. `CompleteClipboardImageHandler` first finishes only that exact
identity. An unrelated completion cannot clear newer work.

A successful worker result must repeat the same identity and target. The model
then resolves the focused attachment target again. A removed agent, changed
pane generation, focus change or workspace change makes the image stale. The
adapter securely frees its PNG without changing the shelf.

For a current result, the application handler orders resource adoption before
geometry effects. `attachments.Store` validates the image again, owns the PNG
and reports whether the shelf changed pane geometry. The adapter delegates
active-tab selection to `OfferActivePaneGeometryHandler` and offers new pane
sizes to the runtime only for that layout transition. The completion handler
then delegates its classified outcome through an explicit delivery boundary.

`DeliverClipboardImageCompletionHandler` keeps applied, stale, ignored and
clipboard-empty results quiet. It maps oversized, worker and adoption failures
to bounded notification inputs; the adapter only publishes them. An adoption
failure consumes the capture and frees its buffer. A resize delivery failure
happens before outcome delivery, after adoption, and remains an explicit client
error matching other committed geometry effects.

## Presentation and bounds

The PNG does not enter `ClientModel`. `attachments.Store` owns the physical
preview bytes and advances `ingressVersion` after each accepted image.
`presentation_lifecycle.observe` publishes that revision beside model and pane-graphics
revisions. The presenter compares it with the revision last painted and
schedules the paced frame. Clipboard completion never calls
`Presenter.requestDraw`.

The media path has fixed limits:

- one capture worker per client;
- 32 MiB of source clipboard data;
- 16 MiB per encoded PNG;
- 16 million decoded pixels;
- four retained previews;
- 32 MiB of retained preview bytes.

Captured buffers are zeroed before release. Eviction keeps the newest bounded
items. Dismissal defers large buffer cleanup to the media path so an input
event does not wipe megabytes synchronously.

## Proof

- `src/frontend/client/model.zig` proves single-flight capture identity, exact
  completion, target ownership, validation and identifier exhaustion.
- `src/frontend/client/application/clipboard_image.zig` proves commit before
  scheduling, complete start classification, exact consumption, stale
  suppression, adoption before resize and failure classification before exact
  delivery.
- `src/frontend/client/application/clipboard_image_delivery.zig` proves quiet
  outcomes, notification mapping and publication failure propagation.
- `src/frontend/client/application/input/attachment_prompt.zig` proves child
  marker deletion precedes local retirement, prompt submission cancels an
  in-flight capture, and which keys arm a deletion watch per policy.
- `src/frontend/attachments/root.zig` proves cancellation ownership, image
  bounds, retained-byte limits, target scoping, marker planning, the bounded
  deletion watch and ingress revision.
- `src/frontend/attachments/path_marker.zig` proves Pi path parsing across
  forced wraps, extent limits, screen-order collection and cursor resolution.
- `src/frontend/client/client_test.zig` proves pane delivery without a target,
  successful resource observation, stale target cleanup, quiet clipboard-empty
  behavior and notification failures without direct presentation.
