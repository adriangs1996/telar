# Mermaid diagrams

`lib/mermaid` turns a Mermaid source into a themed, premultiplied RGBA image.
The GUI keeps a small texture cache over it, so a widget can show a diagram
beside terminal content. No widget requests diagrams today. This page describes
the path the next one will use.

## Library

`mermaid.render(io, allocator, request, executables)` spawns the first helper
in `executables` that exists, writes one JSON request on its stdin and reads a
fixed header plus pixels from its stdout. The environment is empty and the
source never reaches shell arguments. The library checks the header before
allocating the payload, reads the exact length and requires EOF. One deadline
covers writing, reading and process exit. On timeout or cancellation it sends
`KILL` and reaps the child, so a helper that ignores `TERM` still goes away.

The helper exit code carries the failure class: 3 is an unsupported diagram,
4 is a limit, anything else is invalid output. `mermaid.Image` owns the pixels
until the caller calls `deinit`.

The library knows nothing about telar. The caller chooses the helper path and
the colors (`mermaid.Theme`).

## GUI integration

1. A widget calls `diagrams.Store.request` while measuring, with an opaque
   `owner` key it chooses, the source, `diagram_theme.resolve(canvas.theme)`
   and the scale. The store copies the source into a replaceable slot. It does
   no I/O and never pins images outside the viewport.
2. After scene preparation, `diagrams.Service` admits pending requests,
   replaces unpinned cache slots and starts at most one inbox worker.
3. `diagrams.worker` resolves `telar-diagram-renderer` beside the executable.
   Builds running from `.zig-cache` also try the helper the build produced.
   Then it calls `mermaid.render`.
4. The service owns the result before publishing a void `diagram_ready` inbox
   notification. It also owns cleanup if shutdown drops that notification.
5. `GuiAdapter.prepare` adopts a notified result only after the previous native
   flight completes. A widget draws it through `Canvas.diagramAt`. The frame
   carries borrowed image descriptors to Metal or Vulkan. Visible slots stay
   pinned until delivery completes, and a new texture version triggers an upload.

The cache key is the owner, the exact source bytes, the theme and the scale.
A changed source or owner cannot display an earlier result.

Only the GUI owns the helper and pixels. Closing it cancels and joins the inbox
tasks, the library kills and reaps the helper, and the store releases retained
pixels.

## Bounds and failure

There are eight cache slots, eight replaceable wanted requests and one active
helper per GUI. Each source is at most 48 KiB. Cached pixels total at most 8 Mpx
or 32 MiB; each image is at most 4 Mpx with sides no larger than 4096 pixels.
One active or notified result can retain another 16 MiB before adoption. GPU
textures contain only visible images, within the same 32 MiB limit; Vulkan
staging can require another 32 MiB, excluding driver alignment and bookkeeping.

The helper has a 512 MiB Rust heap quota, a five-second CPU limit and an
eight-second parent deadline. Fonts are embedded; external SVG resources and
source callbacks are disabled. See the helper's [protocol and build contract](../../tools/diagram-renderer/README.md)
for exact input limits, supported syntax and licenses.

A failed request is cached instead of retried every frame. Idle and hidden
diagrams schedule no polling or animation.

## Verification

- `zig build test-libraries` runs the `lib/mermaid` protocol tests and the
  render tests against shell helpers: exact pixels, stdin that is never read,
  missing output, excess output, deadline after EOF, cancellation, a helper that
  ignores `TERM`, and the exit-code classification.
- `zig build test-gui` covers the store and service: pinning, pixel quotas,
  allocation failure, stale results, source retention and shutdown.
- `zig build test-diagram-renderer` checks the helper itself.
- Native backend tests cover texture versions, clipping, replacement, deletion
  and both end slots on Metal and Vulkan.
