---
status: accepted
---

# Graphics frames cross the runtime once

A full-pane terminal-browser at 4K produces a 31.6 MiB RGBA frame at the
host's refresh rate. Telar sits between the child and the host terminal, so
every copy, allocation and timer hop on that path is paid per frame. The
first measured pipeline presented 20 frames per second while the runtime
published 50, and each frame moved through five copies and two fresh
shared objects.

## Decision

Pane graphics control escapes ride the cell frame. Shared names, placements
and deletes are a few hundred bytes, so the presenter emits them inside the
cell frame's synchronized update, after the cells and before the cursor. The
separate byte-bounded media pass exists for pixel streams and UI rasters
only, and a media pass that yields to a pending cell frame runs at that
frame's completion rather than a pacer interval later.

A complete shared frame crosses the runtime with one copy. The media actor
recognizes the atomic terminal-browser envelope, maps the child's object or
validated file, copies it once into a fresh runtime-owned POSIX shared object,
unlinks the child's name, and keeps its own object mapped as the image's
pixels. The emulator stores a one-byte placeholder for such images; it never
reads pixels in the runtime, and freeing the placeholder unmaps the object and
releases its reservation. The same object is parked on the pane as the local
client's transfer, and the runtime thread adopts it without copying. Images
the emulator decoded itself are frozen by the media actor right after decode;
the runtime thread copies only as a fallback.

The host's reply is the consume signal. The shared transmission asks for a
reply, the client retires the image on `OK` and returns the exact credit, and
an error reply reclaims the name and retransmits inline. The name probe and
the pass-counter deadline remain as the safety net.

The runtime never opens a child path through the emulator. File frames and
file capability queries are handled by the pane against one validation:
absolute path, no symlink at the leaf, a regular file owned by the runtime's
user, at least the declared length, under the screen cap. The file is mapped
read-only for one copy and never written, kept open or deleted.

## Considered options

- Keeping graphics on their own paced media tick cost two to four pacer
  intervals per frame under a continuous stream; the byte budget it protects
  is irrelevant to a 200-byte hand-off.
- A persistent file ring handed to the host with `t=f` was measured before
  it was built: rewriting eight 4K slots at 60 Hz on macOS cost 8 ms per
  frame and the kernel wrote the dirty pages back to disk at hundreds of
  megabytes per second. Fresh shared objects are cheaper and leave no disk
  traffic.
- Letting the emulator keep the mapping as ordinary image data would have
  `std.mem.Allocator`'s safety-checked builds scribble over an object the
  host may still be reading; macOS refuses a copy-on-write mapping of a
  shared object, so the placeholder indirection is the honest way to keep
  the emulator's ownership model intact.
- Enabling the emulator's own file loading would have let a child point the
  long-lived runtime at any readable path through a parser Telar does not
  own; validating in the pane keeps the invariant explicit.

## Consequences

- Synthetic 3840x2160 RGBA at 120 frames per second: the runtime forwards
  over 100 frames per second and the client presents 60, the pacer cap, with
  zero drops, resets or resyncs, on the reference M3 with Ghostty 1.3.1.
- The runtime thread no longer copies pixels inside event dispatch.
- Diagnostics counters are available in optimized builds through
  `-Ddiagnostics`, and `telar-frame-source` makes the throughput gate
  independent of Chromium.
- The emulator's per-screen byte limit no longer sees direct frames; the
  pane quota bounds them instead.
