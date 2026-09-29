# Kitty graphics render plan

Goal: an application that speaks the Kitty graphics protocol inside a telar
pane (`chafa -f kitty`, `kitten icat`, `timg -pk`, Yazi, agent previews) shows
the real image in the window, drawn as Kitty and Ghostty draw it, on Metal and
Vulkan, without making a keystroke or a cell frame wait.

Base: `main` at `ace4fe2f`. Out of scope: sidebar project icons (another
session owns them).

Status (2026-09-29): phases 1-7 done on macOS and Linux. Found on the way
and fixed with Adrian's approval: the runtime dropped any direct image larger
than the media queue (now the pane holds its PTY read while a Kitty command
is queued), and the interactive terminal did not move its cursor past a
placement (now `KittyCursor` does). The gate compares the image stream with a
text-redraw control, not idle (Adrian, 2026-09-29). Open: the window turns a
4K 120 Hz stream into 35 textures a second, under the 58 floor; drawing a
window-sized image is the measured cost ([performance gates](../performance-gates.md)).

## What exists (verified 2026-09-29)

Runtime side, already complete for classic placements:

- The media terminal (`pane.media.terminal`) parses every PTY byte; its
  viewport is never scrolled, so `core.Placement.y` is the row relative to the
  top of the active screen (`media.placementValue`, `src/backend/media/media.zig:457`).
- Ghostty marks `kitty_images.dirty` on index, scroll, insert/delete lines,
  reflow and screen switch, so scrolling text re-walks the attachment and
  resends the moved placement (`Pane.observeGraphicsDamage`,
  `attachment_namespace.encodeNextGraphics`). A placement whose pin went into
  scrollback is sent with a negative `y`.
- `columns`, `rows`, `offset_x`, `offset_y`, the source rectangle and `z_index`
  reach the client unresolved. No code resolves `columns = rows = 0`.

Client side:

- Each machine slot has its own `graphics_delivery.Store`
  (`GuiAdapter.graphics_stores`, `host_ports.graphicsRetention`); every
  delivery hook is a no-op.
- The window declares `images = .unsupported` (`GuiAdapter.start`,
  `GuiAdapter.resize`) and bootstraps with `graphics_shared = false`, so a 4K
  RGBA generation arrives as 32 1-MiB chunks, each `@memcpy`ed on the window's
  main thread, which is the thread that routes keys.
- `pane_frame` hides a pane's graphics unless it is scrolled to the bottom
  (`src/model/panes/pane_frame.zig:64`).
- The cell fallback flag (`Pane.graphics_placeholder`) changes nothing on
  screen; nothing in `src/gui` reads it.

Window renderer:

- One flat quad list, one instanced draw per frame, no GPU scissor (clipping
  is `QuadList.pushClipped` on the CPU). Paint order is list order; inside a
  pane: cell backgrounds, block cursor, glyph ink, bar/underline cursors
  (`TerminalRenderer.drawPane`).
- Textures ride the frame as borrowed pointers with a version: atlas (R8),
  sprite page, and 8 RGBA slots already taken by diagrams (6) and previews
  (2). A new version re-uploads the whole texture on the render thread; on
  macOS that is the main thread (`TelarMetalRenderer.uploadDiagrams`,
  synchronous `replaceRegion`). No slot and no pixel budget is free.
- Textures are premultiplied `RGBA8Unorm`; the shader divides alpha back out.
  Diagrams and sprites sample linear, clamp to edge.
- `ImagePreviews.beginFrame` zeroes and frees retired copies (up to 8 MiB) and
  copies 256 KiB per new thumbnail inside `prepare`. This plan does not copy
  that shape; fixing previews themselves is a separate change.

## What the protocol asks of a renderer

Checked against `docs/graphics-protocol.rst` on kitty master, kitty's
`graphics.c`, and Ghostty's `renderer/image.zig`, `graphics_storage.zig` and
`generic.zig`.

| Feature | Behaviour | This plan |
| --- | --- | --- |
| Source rect `x,y,w,h` | intersection with the image; 0 means to the edge | draw (runtime already resolves it) |
| `X,Y` offsets | pixel origin inside the first cell, not added to `c,r` | draw |
| Neither `c` nor `r` | natural pixel size of the source rect | draw |
| Only `c` or only `r` | the other side follows the source aspect ratio | draw |
| Both `c` and `r` | kitty and Ghostty stretch to `c*cw - X` by `r*ch - Y`; the spec text added 2026-08-23 says letterbox | **decision 1** |
| `z < INT32_MIN/2` | under non-default cell backgrounds | draw |
| `INT32_MIN/2 <= z < 0` | over backgrounds, under text | draw |
| `z >= 0` | over text | draw |
| Ties | lower image id below; same id undefined | sort by `(z, image_id, virtual_id)` |
| Scroll with text | placements move with their row, into scrollback | draw (runtime resends `y`) |
| Clear, reset, alt screen | images cleared | runtime already deletes |
| Clipping | truncated at the pane edge | CPU clip, UVs clipped with geometry |
| Filtering | not specified; both use linear, clamp to edge | linear |
| Unicode placeholders (`U=1`, U+10EEEE) | image drawn through placeholder cells | **not in this plan** (below) |
| Animation (`a=f,a=a,a=c`) | frames with gaps, loop counts | **not in this plan** (below) |

Placeholders need the runtime to send virtual placements and the client to
read row/column diacritics and the image id from placeholder cells; the pinned
Ghostty VT drops them before telar sees them (`media.zig:460`). Animation needs
the runtime to compose frames; Ghostty's VT does not implement `a=f`. Both are
wire and runtime work that this renderer then consumes; they get their own
plan once this one lands.

## Design

Three paths, three owners:

```text
runtime ─graphics msgs─> client store (main thread: metadata, shm map, no pixel copy)
                              │ upload request (bounded, latest-wins)
                              ▼
                  native upload thread (media path) ── texture ready ──> wake
                              │
prepare (interactive) ── placement quads + image draws ──> renderer (one draw per image run)
```

### 1. Pixels reach the window without a copy on the main thread

The local machine's client declares `graphics_shared = true`. The window
already shares the runtime's machine for the local slot, and the shared path
is implemented, tested and falls back to chunks on any mapping failure
(`pane_graphics.applyPaneGraphics`, `.shared_mapping_failed`). A 4K
generation then costs the main thread one `shm_open` and one `mmap`. Remote
machine slots keep chunks; moving chunk ingestion off the main thread stays
open (it is the "separate scheduling change" `pane-graphics.md` already
names).

### 2. GPU images are a table the adapter owns

`graphics_delivery.zig` stops being a no-op. Per slot store:

- `ImageState` gains a lease count (the `retained.zig` pattern: pixels stay
  charged and mapped until the upload that reads them finishes) and the
  handle of its GPU texture once one exists.
- A fixed-capacity `GpuImages` table in `GuiAdapter` (one for the window, rows
  carry the slot): handle, image identity, byte size, state
  (`queued`/`uploading`/`ready`), last frame drawn. Capacity 512 rows, the
  per-pane placement bound times the realistic visible pane count; a full
  table skips uploads, it never grows.
- GPU bytes are charged against `core.max_image_bytes_global` (512 MiB). An
  RGB image costs `w*h*4` on the GPU. Over budget, textures not drawn in the
  last frame (hidden panes, other tabs, other machines) are released first;
  if that is not enough the upload waits and the placement draws nothing.
  Text is never affected.
- A texture is released when its image entry is deleted, when its pane is
  cleared, and when it has not been drawn for N frames while its pane is
  hidden. Releasing is a native call that frees after the in-flight frame
  completes, the same rule `DiagramTexture` follows today.

### 3. Uploads run on a native upload thread

New ABI in `telar_gui.h`, implemented by both renderers:

```c
bool telar_gui_image_upload(void *renderer, const struct telar_gui_image_upload *request);
size_t telar_gui_image_take_ready(void *renderer, uint32_t *handles, size_t capacity);
void telar_gui_image_release(void *renderer, uint32_t handle);
```

- `upload` enqueues into a bounded ring (4 in flight) and returns false when
  it is full; the adapter retries on a later frame. It never blocks.
- The upload thread creates the texture and writes it in row bands through a
  fixed 1 MiB scratch buffer: RGB is expanded to RGBA there, RGBA is copied
  as is. No allocation proportional to the image beyond the texture itself.
- Completion goes into a ready ring and wakes the window loop through the
  existing wake pipe; `take_ready` drains it during `prepare` and the adapter
  returns the upload lease.
- Latest-wins: when a newer generation of the same image id is requested
  while an older one is queued and not started, the older request is
  replaced. A generation already uploading finishes; the next frame draws the
  newest ready one.
- The previous generation keeps drawing until the next one is ready, so a
  streaming pane never flashes empty. A placement remembers the last texture
  it drew and holds it until its new image is ready.
- Metal: `MTLStorageModeShared` textures on unified-memory devices,
  `replaceRegion` per band on a serial dispatch queue; `Managed` plus a blit
  on discrete GPUs. Vulkan: a thread with its own command pool and a
  persistent staging buffer; queue submission shares a mutex with the frame
  worker unless the device offers a separate transfer queue family.
- KGP pixels are straight alpha. The image quad sets a shader flag that skips
  the premultiply division, and the shader premultiplies after sampling, as
  Ghostty's image shader does. The CPU never premultiplies.

### 4. Placement quads in `prepare`

- The frame gains `image_draws`: `{ quad_index, handle }` pairs in quad
  order. Each renderer draws the quad list in runs and binds one image
  texture for each image quad (texture selector 10). Draw calls grow by at
  most two per drawn image. A frame draws at most 512 image quads; beyond
  that they are skipped and counted.
- When a pane's placements change (store damage, per-pane revision), the
  adapter rebuilds that pane's placement list: resolved destination size in
  pixels (table above), sorted by `(z, image_id, virtual_id)`, split into
  the three layers. That work is O(placements of the pane) into a fixed
  array and runs only on change, not per frame.
- Per frame, `drawPane` pushes each ready placement at
  `content.origin + (x * cw + offset_x, row * ch + offset_y)` with
  `row = y + max_scroll_offset - scroll.offset`, clipped to the pane with
  `QuadList.pushClipped` (UVs follow). Below-background layer before the cell
  backgrounds, below-text layer after them, above-text layer after the glyph
  ink and before the bar and underline cursors.
- `frame_budget.quads` grows by the image quad cap.

### 5. Semantics that change

- The window declares `images = .supported` once its renderer reports the
  upload thread started; `pane_graphics.syncFallbacks` then clears every
  pane's fallback flag. A renderer that fails to start uploads keeps
  `.unsupported`.
- `pane_frame` stops hiding graphics while scrolled back; a scrolled pane
  draws its images at their shifted rows. Hidden tabs and other machines
  still hide.
- The runtime sends a placement delete when a known placement's pin becomes
  garbage (history pruned). Today it keeps the stale placement on the client
  until Ghostty removes it from storage.

## Decisions (Adrian, 2026-09-29)

1. **`c` and `r` together stretch.** Kitty and Ghostty stretch the image to
   fill the cells; the spec sentence added on 2026-08-23 (kitty commit
   `05444e9e61`) says letterbox, but kitty's own renderer still stretches
   classic placements and letterboxes only placeholders. Telar looks like the
   two terminals applications are tested against.
2. **Images that leave the media terminal's history are deleted.** The media
   terminal keeps 10,000 bytes of scrollback (`Pipeline.zig:50`) against
   10 MB for the main terminal, so an image that scrolls a few screens up
   loses its pin. The runtime sends the delete; giving the media terminal the
   main terminal's bound (which duplicates text scrollback memory per pane in
   the worst case) is measured later if history images matter.
3. **The performance gate below is accepted as designed.**
4. **Linux** is built here and run on a Linux machine Adrian provides.

## Replacement for the graphics performance gate

`tools/gui_graphics_gate.py`, macOS first, built on `gui_latency.py`'s
isolated runtime and injected keys:

- One pane streams a synthetic 3840x2160 RGBA source over `t=s` at 120
  generations per second; a second pane runs `cat` for keystroke echo.
- Measures: image generations presented per second, upload latency
  (request → ready) p50/p95/p99, `prepare` time p50/p95/p99, keystroke →
  Metal completion p50/p95/p99 with and without the stream, media drops,
  graphics resyncs, GPU bytes resident.
- Pass: presented ≥ 58/s at the 60 Hz pacer (the old gate's floor), zero
  resyncs and drops, and keystroke latency within the regression bounds of
  `performance-gates.md` (5% p50, 8% p95, 10% p99) against the same run
  without the stream.
- `zig build bench` gains `gui.kitty.prepare_placements` (256 placements
  across 4 panes, prepare with no allocation) so the frame cost is gated in
  CI without a window.

## Phases

1. **Shared pixels for the local slot.** Flip `graphics_shared` for the
   local client; tests prove chunk fallback still works.
2. **Placement geometry.** Resolve destination size, layer split and sort in
   a pure function with tests for every row of the table, scroll offsets,
   clipping at every edge, negative `y`.
3. **Native image ABI.** Upload thread, ready ring, release, on Metal then
   Vulkan; ABI size tests; macOS pixel readback test of an uploaded RGB and
   RGBA image.
4. **Delivery and frame.** Leases, `GpuImages`, budget and eviction,
   `image_draws`, `drawPane` layers, `images = .supported`, scrolled panes
   draw images. Zig tests on quads and draws; a macOS test that renders a
   frame offscreen and reads back pixels under and over text.
5. **Runtime delete for garbage pins.**
6. **Gate and measurements.** The tool above, the bench, a capture of
   `chafa -f kitty` in the real window.
7. **Docs.** `kitty-graphics.md`, `pane-graphics.md`, `performance-gates.md`,
   a flow doc for the upload path, README quotas (the README still says
   64/256 MiB; the code says 256/512).

## Verification

`zig build codestyle`, `check`, `test`, `test-gui`, `test-gui-window`,
`test-client-integration`, `test-headless`, `test-integrations`, `bench` and
`verify-release`, from this worktree. Real-window checks with `chafa -f kitty`
on a small image, a 4K image, 50 small images, scroll, resize, split panes,
fullscreen, tab switch and machine switch.
