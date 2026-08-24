# Kitty graphics support

Telar terminates Kitty Graphics Protocol commands at each pane PTY. Child APCs
never pass through to the exterior terminal. The runtime interprets them into
virtual images and placements; the client assigns exterior IDs, clips them to
the visible pane, and emits fresh KGP commands inside the same synchronized
DEC 2026 update as the cell diff.

## Ownership

The runtime owns decoded child images, child image and placement IDs,
generations, placements, quotas, incomplete uploads, and replies written back
to the PTY. This state survives client disconnection. A reconnecting client
requests an incremental graphics snapshot.

The client owns exterior capability detection, pixel geometry, exterior IDs,
physical placements, layout clipping, pending exterior deletes, and the hybrid
sidebar framebuffers. Pane exterior IDs use the low range below `0x40000000`.
Telar UI images use the high range beginning at `0x80000001`; child z-indices
are clamped to `[-1000, 1000]`, while sidebar layers use `-10` and `-9`.

`telar-core` contains only bounded wire values, formats, rectangles, clipping,
and schema messages. It contains no parser, allocator, PTY, or terminal writer.

## Capability detection

On client startup Telar sends the direct-data KGP query for image ID 31, the
window-pixel query (`CSI 14 t`), the cell-pixel query (`CSI 16 t`), and primary
device attributes. APC and CSI replies are consumed by the client input parser
and never reach the focused pane. The KGP state is `unknown`, `supported`, or
`unsupported`; `unknown` expires after 250 ms without blocking input. Pixel
queries are repeated after resize.

`automatic` renders cells while support is unknown, selects `kitty-hybrid` on
success, and stays on cells on rejection or timeout. Explicit `kitty-hybrid`
and `kitty-full` return `KittyGraphicsUnsupported` when the probe fails.

## Implemented child subset

- RGB (`f=24`) and RGBA (`f=32`).
- Direct transmission (`t=d`) with independently base64-encoded chunks.
- POSIX shared-memory transmission (`t=s`) for local RGB and RGBA frames. The
  media actor copies the mapped bytes into quota-accounted runtime storage and
  unlinks the segment after reading it.
- Zlib compression (`o=z`) with exact decompressed-length validation.
- Transmit, transmit-and-display, put, query, and delete.
- Child image IDs, placement IDs, runtime generations, and anonymous virtual
  placement IDs.
- Source rectangles, output columns and rows, pixel offsets, z-index, and
  `C=1` cursor policy.
- PTY replies through a bounded, serialized response queue.
- Cell and pixel dimensions in Ghostty VT and PTY `winsize`, including
  `xpixel` and `ypixel`.
- SGR cell and SGR-pixel mouse modes. When the exterior reports mode 1016,
  Telar preserves its exact pixel coordinates relative to the pane. Otherwise
  it falls back to the measured center of the reported cell.

Regular and temporary file media (`t=f`, `t=t`) are rejected as unsupported;
the runtime never opens a child-selected path. PNG is not decoded. Unicode
virtual placements are not emitted because the pinned Ghostty VT does not
expose them with enough information to preserve pane clipping and lifecycle.

## Runtime-client flow control

Graphics do not ride in `pane_frame`. Metadata, pixel chunks, placements,
deletes, and snapshot boundaries are separate ordered messages. IPC pixel
chunks are capped at 1 MiB. The runtime freezes at most one generation per
attachment while it crosses the socket, folds newer generations, and keeps the
previous exterior placement visible until the replacement image and placement
are complete. Moving a placement never retransmits pixels.

The default decoded-memory limits are:

- 64 images and 256 placements per pane.
- 64 MiB per pane and 256 MiB per runtime.
- About 21.3 MiB per VT screen with the default pane quota
  (`min(32 MiB, pane quota / 3)`).
- 64 KiB per child APC payload and 4096 chunks per image.
- 64 queued PTY replies, each at most 1024 bytes.

One reservation system accounts before allocation for primary and alternate
screen storage, incomplete parser/base64/zlib state, decoded pixels, and frozen
client-transfer generations. It enforces both the pane and runtime totals; the
per-screen cap is an additional bound, not a partition that can hide copied
transfers. Every `width * height * bytes_per_pixel` calculation is checked.
Incomplete loads are cancelled on chunk, payload, or quota violations. Closing
a pane frees VT images, transfer snapshots, client pixels, placements, and
exterior IDs.

PTY output is copied into two fixed 64 KiB batches and parsed by at most one
media actor per pane. PTY reads resume after the independent text ingest, so
base64, zlib, allocation, and Ghostty graphics parsing cannot stall cells or
input. Applications that negotiate shared memory keep bulk pixels out of those
batches; mapping, copying, and decoding still happen on the media actor under
the same pane and global quotas.
Debug telemetry exposes `input_write_*` and `ingest_*` timings. The benchmark
`backend.kitty.ingest_zlib_rgba_1920x1080` covers the actual APC → base64 →
zlib → Ghostty path; the transport integration suite holds the ingest actor at
a deterministic gate and proves input reaches the child before it is released.

## Sidebar renderers

`CellSidebarRenderer` draws the portable semantic sidebar into `ui.Buffer`.
`KittySidebarRenderer` owns reusable RGBA layers for the rounded panel,
selection, and graphical activity indicator. Text, editable fields, cursor,
and hit targets remain cells. Hover changes do not dirty either graphical
layer. Both renderers use the same semantic row model, so hit testing does not
depend on KGP.

`kitty-full` is an experimental alias of the hybrid backend. It intentionally
does not rasterize text yet.

## Verification

The automated suite covers exact query and command encoding, APC parsing at
every input split, RGB/RGBA chunking, zlib success and invalid sizes, unsupported
media replies, overflow and quota checks, exterior ID isolation, clipping at
all four pane edges, image and placement deletes, resize reconstruction,
generation replacement, renderer selection and fallback, idle zero-work,
semantic hit testing, history isolation, exact mode-1016 coordinates, mouse
encoding, tab hide/show deletion, and runtime reconnect snapshots. Runtime
integration tests use real PTYs in raw mode, verify that the child receives
`Gi=31;OK`, exercise KGP and history in the same pane, and prove input remains
live while the ingest actor is occupied.

The reproducible exterior check builds the pinned terminal-browser revision
`cce10b6131d15bf46a3e4b8dc827e0544ff7fc65` without changes and runs it inside
Telar. It rejects media resets or dropped PTY bytes, so a silent fallback to an
overloaded inline transport cannot pass:

```sh
zig build verify-terminal-browser
# Reuse an already-built checkout:
zig build verify-terminal-browser -- \
  --terminal-browser-repo /path/to/terminal-browser --skip-build
```

It writes its machine-readable result to
`zig-out/terminal-browser-verification.json`. On 2026-08-23 it passed against:

- Ghostty 1.3.1 on macOS: exterior KGP and mode 1016 were accepted, the fixture
  page loaded, terminal-browser produced an image and placement, Telar emitted
  pane and hybrid-sidebar graphics, and response drops were zero.
- Silent and responding simulated exteriors in the parser/client tests: timeout
  selects cells; APC, pixel-size, and mode-1016 replies select KGP and update
  client capabilities.

The real run also uses Ghostty's scripting API to send keyboard and pixel-mouse
input to the exact verification terminal; the page preload records the
resulting Chromium key and pointer events. Its isolated SQLite database contains
zero command rows from KGP or injected input. A human pass is still required
for subjective interaction quality, pixel-perfect clipping, font metrics, DPI
scaling, and sidebar artwork.

## Remaining limitations

- No PNG, file, temporary-file, or Unicode-placeholder transport.
- Pixel mouse precision is limited to cell centers when the exterior terminal
  does not report pixel mouse coordinates.
- Only the local socket transport has been exercised with graphical load.
- `kitty-full` does not rasterize text.
- The reproducible terminal-browser check covers one real graphical pane. ID
  isolation across panes, tab visibility, delete, resize, and layout rebuilds
  are deterministic Store/writer tests rather than an automated GUI pass.
- The current writer base64-encodes decoded pixels for the exterior terminal;
  a future local transport may avoid that copy where the security model permits.
