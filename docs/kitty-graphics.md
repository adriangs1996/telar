# Kitty graphics support

Telar terminates Kitty Graphics Protocol commands at each pane PTY. Child APCs
never pass through to the host. The runtime interprets them into virtual
images and placements and sends them to each client as separate graphics
messages. The window keeps a bounded replica of them
([pane graphics](flows/pane-graphics.md)) and draws them with Metal or Vulkan
([pane images](flows/pane-images.md)). The terminal client re-emitted them as
KGP to its host terminal; that path left with it.

## Ownership

The runtime owns decoded child images, child image and placement IDs,
generations, placements, quotas, incomplete uploads, and replies written back
to the PTY. This state survives client disconnection. A reconnecting client
requests an incremental graphics snapshot.

The client's graphics resources own the retained replica: image identities,
placements, per-pane and global quotas, and the byte credit returned to the
runtime. The window reports images and exact pointer pixels as supported; its
cell pixel size comes from its font metrics.

`telar-core` contains only bounded wire values, formats, rectangles, clipping,
and schema messages. It contains no parser, allocator, PTY, or terminal writer.

`lib/kitty_protocol` is a dependency-free library that encodes Kitty image
transmissions, placements, and deletions into a caller-owned writer. It owns no
resources or pacing policy. The runtime media path and `core.Image` use its
format values.

## Implemented child subset

- RGB (`f=24`), RGBA (`f=32`), and PNG (`f=100`). PNG is decoded to
  straight-alpha RGBA on the media actor through Ghostty's `sys.decode_png`
  callback, using the Wuffs dependency pinned by Ghostty. Decoder state,
  workspace, and pixels all use the pane/global quota allocator.
- Direct transmission (`t=d`) with independently base64-encoded chunks.
- POSIX shared-memory transmission (`t=s`) for local RGB and RGBA frames. A
  complete frame is copied once by the media actor into the runtime-owned
  object that serves as both emulator storage and the local client's transfer;
  any other shared command goes through the emulator, which copies the mapped
  bytes into quota-accounted storage. Either way the child's segment is
  unlinked after reading.
- Regular file transmission (`t=f`) for complete frames and capability
  queries, validated by the pane as described below.
- Zlib compression (`o=z`) with exact decompressed-length validation.
- Transmit, transmit-and-display, put, query, and delete.
- Child image IDs, placement IDs, runtime generations, and anonymous virtual
  placement IDs.
- Source rectangles, output columns and rows, pixel offsets, z-index, and
  `C=1` cursor policy.
- Cursor movement after a placement in the interactive terminal too, which
  ignores graphics APCs: `KittyCursor` reads each command's control data (and
  a direct PNG's IHDR) as `vtscan.KittyCommandScanner` finds it end, and moves
  the cursor past `a=T`/`a=p` placements the way Ghostty does, unless `C=1`,
  `U=1` or `P` keeps it. Sizes for `a=p` come from a bounded table of the
  pane's transmissions.
- PTY replies through a bounded, serialized response queue.
- Cell and pixel dimensions in Ghostty VT and PTY `winsize`, including
  `xpixel` and `ypixel`.
- SGR cell and SGR-pixel mouse modes. When the client reports exact pointer
  pixels, as the window does, Telar preserves them relative to the pane.
  Otherwise it falls back to the measured center of the reported cell.

Regular file media (`t=f`) is accepted for complete frames and for the
`a=q` capability query, on the pane's validation rather than the emulator's:
an absolute path with no symlink at the leaf, a regular file owned by the
runtime's user, at least as long as the declared pixels, and within the screen
cap. The file is mapped read-only for one copy and never written, kept open or
deleted; anything else is answered `EBADF` or dropped as unavailable.
Temporary file media (`t=t`) stays rejected. PNG uses the emulator's bounded
loading path, including direct base64 chunks; the complete-file fast path
still accepts only raw RGB/RGBA. Unicode virtual placements are not emitted
because the pinned Ghostty VT does not
expose them with enough information to preserve pane clipping and lifecycle.

## Runtime-client flow control

Graphics do not ride in `pane_frame`. Metadata, pixel chunks, placements,
deletes, and snapshot boundaries are separate ordered messages. IPC pixel
chunks are capped at 1 MiB. The runtime freezes at most one generation per
attachment while it crosses the socket, folds newer generations, and keeps the
previous placement until the replacement image and placement are complete. A
complete terminal-browser frame (`a=T`, `t=s`, `C=1`, `q=2`, no crop or offset
keys) crosses the runtime with one copy: the media actor
maps the child's object, copies it into a fresh runtime-owned object, unlinks
the child's name, and keeps its own object mapped read-only as the image's
pixels. The emulator stores a one-byte placeholder for that image; it never
reads pixels in the runtime, and freeing the placeholder (replacement, delete,
pane close) unmaps the object and releases its reservation. The envelope's
prefix, a synthesized `a=p` placement and the suffix still go through the
emulator, so cursor policy and synchronized output are what the child asked
for. The same object is parked on the pane as the local client's transfer
(at most four per pane, no second reservation). For images the emulator
decoded itself the actor freezes the generation into a runtime-owned object
right after decoding, while the pixels are hot. The runtime thread adopts the
parked object when it stages the transfer, so no pixel copy runs on the thread
that dispatches input; a generation nobody can adopt is released at the next
synchronization, and a newer generation of the same image replaces an
unadopted one. The runtime-thread copy remains only as the fallback for a
generation the actor did not freeze. Moving a placement never retransmits pixels. Each client grants
an explicit byte credit. The runtime cannot freeze another image until the
client has retired enough image storage and returned that credit.

The window charges its textures against the global limit and releases the
least recently drawn ones first when a new upload would exceed it.

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
a pane frees VT images, transfer snapshots, client pixels and placements.

PTY output is copied into two fixed 64 KiB batches and parsed by at most one
media actor per pane. PTY reads resume after the independent text ingest, so
base64, zlib, allocation, and Ghostty graphics parsing cannot stall cells or
input. When the actor is busy, the next 16 KiB read would not fit the open
batch and a Kitty command is queued or in progress (`Pipeline.holdsRead`),
the pane holds its next read until the actor finishes instead of dropping the
batch: only the child sending graphics waits, as it would in Kitty or
Ghostty. Plain output keeps the drop-and-reset policy. `media_held_reads`
counts held reads. A placement whose row leaves the media terminal's history
(10,000 bytes of scrollback) is deleted on the client. Applications that negotiate shared memory keep bulk pixels out of those
batches; mapping, copying, and decoding still happen on the media actor under
the same pane and global quotas. When several complete terminal-browser frames
arrive in one batch, the actor keeps the newest available shared-memory frame
for each placement. It does not parse or rewrite other child output.

A client that shares the runtime's machine declares it with an explicit
`configure_graphics` message before opening panes; nothing is assumed. For such
clients the runtime freezes each generation into a runtime-owned POSIX
shared-memory object and sends only its validated name (`graphics_shared_image`)
instead of pixel chunks; the pixels never cross the socket. The client maps the
object read-only, without copying, and unlinks any name it does not adopt.
Names are unguessable, unique for the life of the process, at most 31 bytes
(Darwin's PSHMNAMLEN), and objects are created `0600` with `O_EXCL`. The window
and the headless client bootstrap with shared graphics off, so today every
client receives bounded pixel chunks. A shared client that crashes can strand
at most the in-flight objects its credit allowed; macOS offers no way to
enumerate and sweep them, so that bounded leak is accepted and cleared on
reboot. The client returns the exact byte credit to the runtime when it
retires an image.

Debug telemetry exposes `input_write_*` and `ingest_*` timings. The benchmark
`backend.kitty.ingest_zlib_rgba_1920x1080` covers the actual APC → base64 →
zlib → Ghostty path; the transport integration suite holds the ingest actor at
a deterministic gate and proves input reaches the child before it is released.

## Sidebar and icons

The terminal client's Kitty sidebar renderers, its provider-mark and Nerd Font
icon atlases and its top-bar mark raster left with it. The window draws the
sidebar, icons and marks itself; see [`sidebar.md`](sidebar.md).

## Verification

`zig build test-png` exercises PNG decoding, allocation-failure cleanup,
malformed input, oversized dimensions, screen quotas, RGB/grayscale conversion,
alpha preservation, every PTY split, Pi-style 4096-character chunks, quiet
errors, replacement and deletion. `zig build test-transport` also sends PNG
through a real child PTY and checks the decoded pixels before and after a
runtime graphics snapshot.

The runtime suite covers exact query encoding, APC parsing at every input
split, RGB/RGBA chunking, zlib success and invalid sizes, unsupported media
replies, overflow and quota checks, image and placement deletes, resize
reconstruction, generation replacement, history isolation and runtime
reconnect snapshots. Runtime integration tests use real PTYs in raw mode,
verify that the child receives `Gi=31;OK`, exercise KGP and history in the
same pane, and prove input remains live while the ingest actor is occupied.
Client resource-store tests cover quotas, stale revisions and credits.

The terminal-browser verifier (`zig build verify-terminal-browser`) and the
graphics throughput gate measured the terminal client inside Ghostty and were
retired with it; [`performance-gates.md`](performance-gates.md) records what
replaces them.

## Remaining limitations

- No temporary-file or Unicode-placeholder transport. File transport
  covers complete frames and queries only; chunked or cropped file commands
  are refused.
- Unicode placeholders (`U=1`) and animation (`a=f`, `a=a`, `a=c`) are not
  drawn: the pinned Ghostty VT drops virtual placements and does not
  implement animation.
- An image that scrolls past the media terminal's 10,000 bytes of history
  disappears from the scrollback.
- The window's own client declares shared graphics; other machines' clients
  and the headless client receive decoded pixels in 1 MiB chunks, copied on
  the thread that routes keys.
- A 4K stream reaches the window's textures at about 35 generations a second
  on an M3, under the gate's 58 floor ([performance gates](performance-gates.md)).
- Only the local socket transport has been exercised with graphical load.
