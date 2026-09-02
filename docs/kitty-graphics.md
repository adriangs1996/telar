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

`ClientModel` owns exterior capability state and resolved pixel geometry. The
client's graphics resources own exterior IDs, physical placements, layout
clipping, pending exterior deletes, and the hybrid sidebar framebuffers. Pane
exterior IDs use the low range below `0x40000000`.
Telar UI images use the high range beginning at `0x80000001`; child z-indices
are clamped to `[-1000, 1000]`, while sidebar layers use `-10` through `-8`.

`telar-core` contains only bounded wire values, formats, rectangles, clipping,
and schema messages. It contains no parser, allocator, PTY, or terminal writer.

## Capability detection

On client startup Telar sends direct-data KGP probes for raw image support and
zlib support using image IDs 31 and 32. It also sends the window-pixel query
(`CSI 14 t`), the cell-pixel query (`CSI 16 t`), the mode 1016 query and primary
device attributes. APC and CSI replies are consumed by the client input parser
and never reach the focused pane. Each support state is `unknown`, `supported`
or `unsupported`; `unknown` expires after 250 ms without blocking input. Pixel
queries are repeated after resize.

The [host capability flow](flows/host-capabilities.md) records response
translation, model ownership, expiry and resource fallback. The
[host resize flow](flows/host-resize.md) records geometry effects, placement
invalidation and query-rearm order.

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
are complete. For local clients the pane's media actor freezes each decoded
generation into the runtime-owned shared object right after the emulator
stored it, while the pixels are still hot, and parks it on the pane (at most
four per pane, every byte reserved against the pane quota). The runtime thread
adopts the parked object when it stages the transfer, so no pixel copy runs on
the thread that dispatches input; a generation nobody can adopt is released at
the next synchronization, and a newer generation of the same image replaces
an unadopted one. The runtime-thread copy remains only as the fallback for a
generation the actor did not freeze. Moving a placement never retransmits pixels. Each client grants
an explicit byte credit. The runtime cannot freeze another image until the
client has retired enough image storage and returned that credit.

The default decoded-memory limits are:

- 64 images and 256 placements per pane.
- 256 MiB per pane and 512 MiB per runtime.
- 128 MiB per VT screen with the default pane quota
  (`min(128 MiB, pane quota / 2)`), so one 6016x3384 RGBA frame fits and
  three fit the pane.
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
the same pane and global quotas. When several complete terminal-browser frames
arrive in one batch, the actor keeps the newest available shared-memory frame
for each placement. It does not parse or rewrite other child output.

A client that shares the runtime's machine declares it with an explicit
`configure_graphics` message before opening panes; nothing is assumed. For such
clients the runtime freezes each generation into a runtime-owned POSIX
shared-memory object and sends only its validated name (`graphics_shared_image`)
instead of pixel chunks; the pixels never cross the socket. The client maps the
object read-only, without copying, and that one mapping serves both the compact
`t=s` hand-off to a local Ghostty host and the inline fallback. Names are
unguessable, unique for the life of the process, at most 31 bytes (Darwin's
PSHMNAMLEN), and objects are created `0600` with `O_EXCL`.

The host that consumes a `t=s` name unlinks the object; the client unlinks
whatever it discards, and unlinking twice is harmless because names are never
reused. A host that has not consumed a name after about three seconds of drawn
frames loses it: the client unlinks the object, retransmits the pixels inline
from its mapping, and after two such expiries stops offering names for the rest
of the session. This keeps one dropped `t=s` command, silent under `q=2`, from
pinning pane memory credit forever. A client crash can strand at most the
in-flight objects its credit allowed; macOS offers no way to enumerate and
sweep them, so that bounded leak is accepted and cleared on reboot.

Only when Ghostty unlinks a consumed name, or the deadline reclaims it, does
the client retire the image and return the exact byte credit to the runtime.
Hosts without Kitty graphics shared-memory support and remote sessions retain
the bounded direct-data fallback, which base64-encodes at most 256 KiB per
media pass. Shared names, placements and deletes ride inside the cell frame's
synchronized update, after the cells and before the cursor, so a local frame
costs no media tick. Cell composition and its terminal flush complete first;
a pending cell frame defers the separately paced bulk media pass to its own
completion, and terminal writes remain serialized so KGP chunks cannot
interleave with cell escape sequences.

Debug telemetry exposes `input_write_*` and `ingest_*` timings. The benchmark
`backend.kitty.ingest_zlib_rgba_1920x1080` covers the actual APC → base64 →
zlib → Ghostty path; the transport integration suite holds the ingest actor at
a deterministic gate and proves input reaches the child before it is released.

## Sidebar renderers

The cell widget draws the complete semantic sidebar into `ui.Buffer`.
`KittySidebarRenderer` owns two reusable RGBA assets: one rounded selection
card and the provider-mark atlas. The card raster is capped at 64 KiB, while
the checked-in atlas's 256 px source slots are downsampled with
premultiplied-alpha bilinear filtering into slots that preserve the terminal
cell aspect ratio. Text, cursor, selection marker, hover, and hit targets
remain cells. Hover does not enter the KGP preparation contract and therefore
cannot dirty graphical pixels or placements. Both renderers consume the same
semantic frame, so hit testing does not depend on KGP.

The cell widget renders the immutable bounded snapshot supplied by the
presenter. Agent storage, local pane-index projection and adapter ownership are
recorded in [`sidebar.md`](sidebar.md).

`kitty-full` is an experimental alias of the hybrid backend. It intentionally
does not rasterize text yet.

The optional `nerd-font` icon theme is separate from the sidebar renderer.
Widgets keep a one-cell fallback and publish a bounded icon plan. During the
media pass, the client rasterizes the required glyph/color tuples from the
embedded Nerd Fonts subset into one opaque atlas whose slots preserve the host
cell aspect ratio. Glyph size is constrained by the shorter side, so circular
icons remain circular in tall terminal cells. Working-status frames share one
atlas, so animation changes placements without retransmitting pixels. Missing
KGP support or non-RGB colors use the Unicode theme directly. Allocation or
rasterization failure triggers the same fallback on the next cell frame.

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

`--measure SECONDS` keeps the animated fixture running that long, builds
Telar as `-Doptimize=ReleaseFast -Ddiagnostics=true` so the counters exist
without Debug overhead, and adds a `frames` block: frames per second forwarded
by the media actor, published by the runtime and presented by the client, with
the ingest, freeze, deferral and retire-latency figures behind them.

It writes its machine-readable result to
`zig-out/terminal-browser-verification.json`. On 2026-08-23 it passed against:

- Ghostty 1.3.1 on macOS: exterior KGP and mode 1016 were accepted, the fixture
  page loaded, terminal-browser produced an image and placement, Telar emitted
  pane and hybrid-sidebar graphics, and response drops were zero.
- Silent and responding simulated exteriors in the parser/client tests: timeout
  commits the cell fallback; APC, pixel-size and mode-1016 replies update the
  client model before presenter observation.

The real run also uses Ghostty's scripting API to send keyboard and pixel-mouse
input to the exact verification terminal; the page preload records the
resulting Chromium key and pointer events. Its isolated SQLite database contains
zero command rows from KGP or injected input. A human pass is still required
for subjective interaction quality, pixel-perfect clipping, font metrics, DPI
scaling, and sidebar artwork.

On 2026-08-24 the full-size animated fixture ran for 75 seconds after crossing
the old 64-generation failure point. Runtime and client telemetry recorded zero
media resets, media failures, dropped media bytes, client resyncs, stale client
messages, and outbox saturation. Two screenshots three seconds apart changed
inside the browser image, confirming that the visible frame had not frozen.

## Remaining limitations

- No PNG, file, temporary-file, or Unicode-placeholder transport.
- Pixel mouse precision is limited to cell centers when the exterior terminal
  does not report pixel mouse coordinates.
- Only the local socket transport has been exercised with graphical load.
- `kitty-full` does not rasterize text.
- The reproducible terminal-browser check covers one real graphical pane. ID
  isolation across panes, tab visibility, delete, resize, and layout rebuilds
  are deterministic Store/writer tests rather than an automated GUI pass.
- Runtime-to-client IPC still copies decoded pixels in 1 MiB chunks. Local
  Ghostty output avoids the second bulk copy and base64 expansion; other hosts
  use the direct-data fallback.
