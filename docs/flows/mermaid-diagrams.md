# Mermaid diagrams in agent messages

The GUI renders a completed `mermaid` fence as a themed diagram. Runtime-owned
messages retain their original Markdown, so copying a response and reconnecting
preserve the source. Rendering is disposable client state.

## Flow and ownership

1. `MessageBlocks` recognizes the fence and records whether its closing delimiter
   has arrived. Streaming code remains visible until the fence closes.
2. `MessageText` measures a cached image or the original code fallback. Only a
   visible fallback asks `diagrams.Store` to retain an owned request. Measurement
   never starts work or pins images outside the viewport.
3. After scene preparation, `diagrams.Service` admits pending requests, replaces
   unpinned cache slots and starts at most one inbox worker. In-frame measurement
   and painting see the same images and dimensions.
4. `diagrams.worker` runs the installed `telar-diagram-renderer` executable with
   JSON on stdin and an empty environment. The helper parses Mermaid and returns
   a fixed header plus premultiplied pixels. The worker validates dimensions
   before allocating the payload, reads its exact length and requires EOF.
5. The service owns the result before publishing a void `diagram_ready` inbox
   notification. It also owns cleanup if shutdown drops that notification.
6. `GuiClient.prepare` adopts a notified result only after the previous native
   flight completes. `MermaidBlock` draws it through `Canvas.diagramAt`; the frame
   carries borrowed image descriptors to Metal or Vulkan. Visible slots are pinned
   until delivery completes. A new texture version triggers an upload.

The cache compares exact source bytes, theme and scale, plus the pane,
attachment, runtime generation, item identity and fence offset. Unrelated
streaming revisions do not invalidate an unchanged closed fence. A changed
source or a replacement pane cannot display an earlier result. Window width
changes reuse the same image and preserve its full aspect ratio.

Only the GUI owns the helper and pixels. Closing it cancels and joins the inbox
tasks, terminates and reaps the helper, then releases retained pixels. The runtime
and its Codex session continue independently. Reconnection renders the retained
source again.

## Bounds and failure

There are eight cache slots, eight replaceable wanted requests and one active
helper per GUI. Each source is at most 48 KiB. Cached pixels total at most 8 Mpx
or 32 MiB; each image is at most 4 Mpx with sides no larger than 4096 pixels.
One active or notified result can retain another 16 MiB before adoption. GPU
textures contain only visible images, within the same 32 MiB limit; Vulkan
staging can require another 32 MiB, excluding driver alignment and bookkeeping.

The helper has a 512 MiB Rust heap quota, a five-second CPU limit and an
eight-second parent deadline covering stdin, stdout and process exit. Source
does not reach shell arguments. Fonts are embedded; external SVG resources and
source callbacks are disabled. See the helper's [protocol and build contract](../../tools/diagram-renderer/README.md)
for exact input limits, supported syntax and licenses.

Syntax errors, unsupported features, unavailable helpers, timeouts and exhausted
quotas leave the original code visible with a short status. A failed request is
cached instead of retried every frame. Idle and hidden diagrams schedule no
polling or animation.

## Verification

`zig build test-gui test-diagram-renderer` covers streaming fence boundaries,
frame consistency, source replacement, stale results, pinning, pixel quotas,
allocation failure, source retention, worker timeouts and shutdown. Native
backend tests cover texture versions, clipping, replacement, deletion and both
end slots on Metal and Vulkan.

The macOS conversation fixture uses simulated Codex messages and the real
diagram helper and GPU path:

```sh
python3 tools/gui_agent_messages.py zig-out/bin/telar /tmp/telar-diagrams-check \
  --response-file tools/fixtures/mermaid-messages.md --diagrams
```

It checks a delivered diagram texture, copying the complete source and
reconnecting to the same provider. The fixture includes the reported flowchart
and a sequence diagram. Optional `--resize WIDTH HEIGHT` also captures a narrow
layout when the window manager permits resizing.

Validated on macOS with Zig 0.16.0 and Rust 1.93.1:

- `zig build test-gui codestyle`: 478 tests passed.
- `zig build test check check-client-boundaries codestyle`: 3,499 tests passed,
  two skipped; all 164 build steps succeeded.
- `zig build test-diagram-renderer`: five tests passed.
- Native Metal and Vulkan texture checks passed, including version changes,
  replacement and invalid descriptor cleanup.
- The installed-binary fixture delivered the capture flowchart at 528 × 1,434
  pixels and a sequence diagram at 450 × 304 pixels. Clipboard content matched
  the full original Markdown, resizing preserved the diagram, and reconnecting
  reused the existing provider. This fixture simulates Codex messages; it makes
  no model request.
