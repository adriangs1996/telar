# Pane images

The window draws the Kitty graphics images a pane's child placed: at their
cell, clipped to the pane, in their z-index layer, moving with the text when
the pane scrolls back. The runtime owns the images and placements
([pane graphics](pane-graphics.md)); this flow starts where the window's
retained replica ends.

## End-to-end path

```text
runtime graphics messages -> pane_graphics.applyPaneGraphics
  -> retained_graphics.Store (one per machine slot, GuiAdapter.graphics_stores)
     shared image: mmap of the runtime's object; chunk: 1 MiB copy
  |
GuiAdapter.prepare
  -> pane_images.place     resolve the presented machine's placements when the
                           store, textures or cell size changed: box, layer,
                           sort; release textures nothing uses
  -> pane_images.start     at most 4 uploads in flight: lease the pixels,
                           reserve GPU bytes, name a handle
  -> Scene -> TerminalRenderer.drawPane
                           below-background layer, cell backgrounds,
                           below-text layer, block cursor, glyphs, above-text
                           layer, other cursors; each image quad records an
                           image draw
  -> pane_images.noteDrawn
  |
window_callbacks.render -> pane_images.handOff (uploads and releases into the frame)
  |
native: acceptImages (Metal) / telar_renderer_accept_images (Vulkan)
  releases, then uploads queued to the backend's upload thread
  |
upload thread: texture, row bands through fixed scratch (RGB -> RGBA)
  -> image_ready(handle) on the window thread
  -> GuiAdapter.imageReady -> pane_images.finish (lease returned; the store
     may free the pixels and return runtime credit)
  -> observation changes -> next prepare draws the texture
```

## Ownership and bounds

- The runtime decides what the images are; the window decides only which
  texture a handle holds. Nothing here parses child bytes.
- `PaneImages` is window state: the `GpuImages` table (512 rows, one per
  native handle), the resolved placements (at most 512), and the handoff
  arrays. It allocates nothing after `GuiAdapter.init`.
- GPU bytes are charged against `core.max_image_bytes_global`. A new upload
  that does not fit evicts the least recently drawn texture the last frame
  did not draw; if none can go, the upload waits and the placement draws
  nothing. Text is never affected.
- An upload holds a `retained_graphics` lease: the store keeps the pixels
  mapped and charged until `image_ready`. The window closes the renderer,
  which joins its upload thread, before `pane_images.abandon` returns every
  outstanding lease and the stores are freed.
- A generation replaced by a newer one keeps drawing until the newer
  texture is ready, so a streaming pane never flashes empty.

## Budget

`place` and `start` run on the window thread inside `prepare`, which is the
interactive path. Both read metadata only: `place` rebuilds only when the
presented store's ingress revision, the texture revision, the machine or the
cell size changed; `start` leases and hands off pointers. The pixel copy,
RGB expansion and texture creation happen on the backend's upload thread,
which the frame never waits for. `GuiAdapter.observation` folds the store's
ingress and the texture revision into the presentation, so a ready texture or
a new generation schedules one paced frame.

## Geometry

`kitty_protocol.displayBox` resolves the drawn size the way kitty and Ghostty
draw classic placements: natural size without `c`/`r`, stretched with both,
aspect ratio from the source with one; offsets clamped inside the cell.
`kitty_protocol.displayLayer` splits the z-index at `INT32_MIN/2` and zero.
Placements sort by `(z, image id, placement)`. A placement's row is relative
to the top of the active screen; `drawPane` adds the rows the pane scrolled
back, so an image moves with its text and is clipped with
`QuadList.pushClipped`, texture coordinates included.

## Backends

Both backends draw the quad list in instanced runs and bind one image per
image quad (texture selector 10): Metal through its argument table, Vulkan
through a descriptor set at set 1. The shader samples straight alpha
linearly, clamp to edge, as Ghostty does.

- Metal: shared-storage `RGBA8Unorm` textures written with `replaceRegion`
  on a serial dispatch queue; `shutdown` waits for it.
- Vulkan: device-local images written from a 4 MiB staging buffer by the
  upload thread's own command pool and fence; `queue_lock` serializes queue
  submission with the frame worker.

## Verification

`src/gui/tests/pane_images.zig` covers resolution, uploads, the in-flight
bound, stand-in generations, deletion, leases across a pane clear, failed
uploads, hidden panes, and the three layers with scroll and clipping.
`src/gui/tests/macos_images.m` (`zig build test-gui-window`) uploads RGB and
RGBA images, renders one frame offscreen and reads its pixels back: two
images in one frame, quad order across them, straight alpha, and release
and reuse of a handle. `lib/kitty_protocol/display.zig` covers every sizing
rule. `tools/gui_capture.m` captures the real window's presented pixels
without the screen recording permission, for checks with `chafa -f kitty`.
