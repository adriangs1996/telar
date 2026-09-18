# Clipboard images in native agent panes

On macOS, Cmd+V or the native Paste action in an agent composer requests an
image with text fallback. This follows T3 Code's attachment paste behavior:
claim image data, bind asynchronous work to the original draft, and keep it
as an attachment until submission. Reference inspected at
[`1ab2dfb`](https://github.com/pingdotgg/t3code/blob/1ab2dfb5a7bd2996f79407b5d02cae6132a7626c/apps/web/src/components/chat/ChatComposer.tsx).

## Ownership and path

```text
Cmd+V / Paste
  -> TelarTextInputView -> native semantic key
  -> widgets/interaction/routing.beginClipboardRead
  -> host.Services.readImage { request, widget, attachment generation }
  -> TelarHostServices -> one native media job
  -> shared host/macos/clipboard_image.h -> private PNG cache
  -> native clipboard completion { image path or text }
  -> routing.finishPaste validates owner, focus and draft revision
  -> agent_threads.attachImage -> AgentThreadHandler -> Model -> Pane
  -> composer image controls / Send
  -> AgentPrompt -> owned client outbox -> AgentThreadController
  -> runtime AgentThreadHandler -> Session observation queue
  -> Codex turn/start with localImage inputs
  -> request_completed clears only the acknowledged draft revision
```

The GUI owns the pending read, source conversion and cached PNG. Its media
worker retains a pasteboard object and copied identities, never a borrowed
client pointer. The main RunLoop delivers the result. Stopping host services
prevents delivery; a clipboard change invalidates the capture. Ordinary text
continues through the existing selection-aware paste path.

`Pane` owns the ordered draft references. Image storage is allocated only for
a pane receiving its first image, then reused until pane destruction. The
wire message borrows bounded paths; the outbox copies them into its existing
byte slots. The runtime's observation queue copies accepted references before
acknowledging submission. Image bytes never enter the input queue or IPC.

This is a **same-machine transport**: the native client and runtime share the
host filesystem. A future remote native connection needs an explicit image
upload protocol before it can advertise this capability. Linux retains its
existing text clipboard behavior. TUI Ctrl+V preview semantics are unchanged;
both macOS adapters share source validation and PNG conversion.

## Draft behavior and recovery

- Up to four image thumbnails appear above the composer text. Clicking a
  thumbnail opens a window-sized preview; its separate close button removes
  that attachment and preserves the order of the others.
- Escape, the preview close button or a click on its backdrop closes the viewer.
  The viewer consumes editor input and rejects stale draft or pane identities.
- Empty text with images is a valid submission. Images accompany text as
  separate provider inputs. A slash-prefixed message with images stays a turn.
- Send waits while a clipboard read is outstanding; repeated reads for the
  same composer share that pending operation.
- Changing the draft, attachment generation, focus or modal before completion
  discards stale data. A stale remove control cannot remove a replacement image.
- Failed admission preserves the draft. A runtime acknowledgement clears only
  the exact submitted content revision, including its images; later edits remain.
- Conversation text displays numbered image labels without exposing cache paths
  or inline image data, including before the provider echoes the user message.

## Preview delivery

The GUI reuses the bounded diagram texture store and its single worker. Requests
carry a distinct local-image kind and own their path before leaving preparation.
Their cache identity includes the pane attachment generation and full path;
text edits, theme changes and resize reuse decoded pixels. No file I/O or image
decoding happens in the composer paint or input handlers.

The worker checks file type, ownership, source length and the final component's
symlink status through its opened descriptor. On macOS, ImageIO converts the
bounded source into premultiplied sRGB pixels, preserving orientation and aspect
ratio. Each preview uses at most one megapixel and 2048 pixels per side, so four
attachments fit within the shared eight-megapixel texture budget. The original
PNG path is still submitted to the agent. Missing or invalid previews retain
the numbered attachment and removal action; the viewer reports unavailability.

Completion adoption, eviction and shutdown use the existing store's frame
lifetime rules. A worker cannot replace pixels while the GPU borrows them.

## Bounds and storage

Capture accepts PNG, TIFF, JPEG and owner-held regular image files. It checks
source size and dimensions before encoding. File reads use a checked descriptor
with no symlink traversal, then an owned snapshot. Image conversion, hashing,
cache I/O and cleanup run on the media worker, outside keyboard routing.

Limits are 32 MiB source bytes, 16 MiB encoded PNG, 16 million pixels, four
paths per message, 1,024 UTF-8 bytes per absolute PNG path, and the existing
8 KiB outbox payload budget for text plus paths. Admission checks the complete
payload before reserving a queue slot.

The macOS cache is `~/Library/Caches/telar-agent-images`, mode 0700. Content
hashes name immutable PNG files, mode 0600. Writers serialize with a directory
lock and publish a flushed temporary file by atomic rename. The cache rejects
new content above 256 MiB or a bounded 1,024-entry scan. A capture reuses identical
content and refreshes its timestamp; new writes prune files older than 30 days.
Missing or expired files remain an explicit provider failure.

Removal, pane departure and GUI shutdown release draft references but leave
cached files available to accepted runtime turns. Client death therefore does
not remove an image while the provider is opening it. Cache retention also
covers rejected and cancelled captures, bounded by the same byte quota.

## Proof

- `AgentImages`, schema and outbox tests check ownership, invalid references,
  image-only messages, wire round trips, overflow and atomic rejection.
- Client agent-thread tests cover image limits and stale acknowledgements.
- GUI interaction tests exercise Cmd+V, text fallback, pending-send suppression,
  image-only submission, removal and stale paste results.
- Native macOS host tests capture a real PNG from a named pasteboard, check
  dimensions and permissions, exercise fallback, and verify that the image
  survives host-service shutdown.
- Codex adapter tests verify ordered `localImage` inputs, mixed messages and
  conversation labels that omit paths and encoded image content.
