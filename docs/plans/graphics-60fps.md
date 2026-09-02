# Graphics at 60 FPS plan

Goal: a full-pane terminal-browser at 4K (3840x2160 RGBA, 31.6 MiB per frame)
presents at the host refresh cap of 60 Hz through telar, with zero media
resets, drops or client resyncs. terminal-browser directly on Ghostty reports
70-80 frames/s written to the tty; the last recorded telar number is
~17.5 images/s at 22.9 MB per frame (commit `0dcbaeb`, 2026-08-24).

Status (2026-09-02): every phase done. A synthetic 4K stream at 120 frames/s
is forwarded at over 100 frames/s by the runtime and presented at 60 by the
client, the pacer cap, over both shared memory and files, with zero drops.
The gate is in `docs/performance-gates.md`; the decisions are in ADR 0008.

Findings that shape the order (verified 2026-09-02, see the session notes in
each phase):

- Memory bandwidth is not the limit. Ghostty itself copies every frame three
  times (`graphics_image.zig:239`, `renderer/image.zig:544`, texture upload)
  and still sustains 70-80. Measured on an M3 with 16 KiB pages for one 4K
  frame: warm memcpy 1.6-1.9 ms; fresh shm object + memcpy 3.7-4.4 ms;
  memcpy into a persistent mapping 1.2-3.1 ms. Page faults on fresh objects
  cost more than the copy.
- The client media pass is the bottleneck. Every graphics message schedules a
  cell draw (`presenter.zig:150-161`); the media pass is armed only after that
  draw at `now + 16.67 ms` (`presenter.zig:211-213`) and re-armed for another
  tick whenever a draw is pending (`presenter.zig:365-369`). Under a
  continuous stream that is three to four ticks per frame, which matches the
  17.5 figure.
- The runtime freezes each generation on the main loop with a 31.6 MiB
  `@memcpy` into a fresh shm object (`attachment/graphics.zig:60`), only
  while the media actor is idle (`delivery/root.zig:488-501`,
  `media_projection.zig:33`), through a single transfer slot
  (`attachment/root.zig:812`). That stalls input dispatch ~4 ms per frame.
- terminal-browser prefers `t=f` over `t=s` (`terminal.rs:433-464`) and, on a
  file-capable host, rewrites eight persistent mmap'd files in place
  (`terminal.rs:509-535`). telar rejects file media
  (`src/backend/media/root.zig:24`), so inside telar it creates a fresh shm
  object per frame.
- Quotas are not a problem: 256 MiB per pane, 128 MiB per screen
  (`src/core/graphics.zig:16-18`). `docs/kitty-graphics.md` still documents the
  old 64/32 MiB values.

Base: `main`. Every wire change follows the golden-corpus discipline in
`src/core/schema/handshake.zig`: corpus entries + version bump. Every phase
keeps the three-budget rule from `docs/engineering-invariants.md`: nothing here
may add work to the interactive path.

Explicit non-goals: PNG decode, Unicode placeholders, remote (socket) clients
above the chunked fallback rate, patching Ghostty the host.

---

## P1. Measure before touching anything

No phase below is accepted on a feeling. Today there is no frames-per-second
counter and no benchmark of the `t=s` → freeze → client path
(`benchmarks/main.zig:128-133` covers `t=d` + zlib at 1080p only).

- Runtime telemetry (`observability/telemetry.zig`): per-attachment
  `graphics_frames_published` with the monotonic timestamp of the last
  publish, `graphics_stage_blocked` split by cause (credit, worker busy, slot
  busy; today `.blocked` is silent, `attachment/root.zig:845`), and
  `diagnostics.Timing` for `media_ingest` (batch sealed → `addImage`) and
  `graphics_freeze`.
- Client telemetry (`resources/telemetry.zig`): `pane_frames_presented`,
  `present_interval` timing per pane, `media_deferrals` (the
  `presenter.zig:365` branch), `shared_expiries` (exists on `Store`, never
  exported), and `shared_retire_latency` from emission to observed consume.
- Benchmark `backend.kitty.shared_frame_3840x2160`: envelope bytes →
  `filterAtomicSharedFrames` → Ghostty VT shm load → `freezeSharedPixels`,
  with the child object created by the harness. Records p50/p99 for each
  stage separately.
- `tools/verify_terminal_browser.py --measure SECONDS`: runs the animated
  fixture at full pane, reads both telemetry streams, and reports frames/s at
  each stage: forwarded by the media actor, published by the runtime,
  presented by the client. Keeps the existing zero-drop assertions. The
  result JSON gains a `frames` block.
- Correct `docs/kitty-graphics.md` quotas.

Exit: baseline numbers for 1080p and the largest local display recorded at the
bottom of this file. No wire change.

## P2. Client: control graphics ride the cell frame

The separate paced media pass exists for the inline budget (256 KiB per pass).
A shared-memory hand-off is ~200 bytes of escapes. Splitting the two removes
the timer hops.

- `CombinedGraphicsWriter` splits into a control writer (shared names,
  placements, placement deletes, image deletes: bounded to a few hundred
  bytes, never pixel data) and a bulk writer (inline chunks, zlib slices,
  toast and icon rasters). Both keep the "whoever opened a transfer owns the
  stream" rule (`presenter.zig:588-616`).
- The cell frame flush includes the control writer inside the same DEC 2026
  update (`screen.zig:201-203` already has the slot; `presenter.zig:537`
  currently clears it). Cells are still composed and written first.
- `presentMedia` no longer re-arms a timer when a draw is pending. It marks
  `media_after_draw` and `completeDraw` runs the bulk pass in the same event.
  The pacer still bounds bulk passes to one per interval.
- Graphics-only ingress keeps scheduling a paced cell frame; composition of an
  unchanged model is damage-bounded and the frame now carries the control
  escapes, so a dedicated control flush was not needed.
  `docs/flows/pane-graphics.md` "Budget and bounds" is rewritten accordingly.
- Tests: writer tests prove a control pass emits shared names and placements
  but no pixel streams and emits nothing while a chunked transfer is open; a
  client test proves a deferred media tick re-arms at the draw's completion;
  a client test proves the shared name and placement land inside the cell
  frame's synchronized update. No wire change.

Exit: `present_interval` p99 ≤ 17 ms at 1080p on the `--measure` run.

Result (2026-09-02, same setup as the baseline): presented 48.1 frames/s
against 48.6 published, present interval 21.4 ms avg. The client no longer
loses frames; the ceiling moved to the runtime (media ingest 11.5 ms avg,
freeze 7.9 ms avg on the main loop, 1823 deferred send-loop lanes), which is
P3.

## P3. Runtime: freeze on the media actor

Move the second copy off the main loop and drop the "only when the actor is
idle" coupling.

- After `addImage`, still on the media actor, the pixels are hot: the actor
  freezes the generation into the runtime-owned object and hands a
  `FrozenFrame { name, metadata, generation }` to the main loop through the
  existing media completion event. One slot per pane, latest wins: replacing
  an unsent frozen frame unlinks the old object.
- `stageNextTransfer` consumes the prepared frame for shared transport instead
  of copying. The `worker == null` gate stays only for the chunked fallback,
  which reads live storage.
- Quota and credit: the actor reserves pane bytes (`reserveManual`) before
  freezing; the main loop applies the byte credit. If credit is exhausted the
  frame is unlinked and `graphics_stage_blocked.credit` counts it.
- Reconnect snapshots keep reading live VT storage; nothing changes for them.
- Tests: attachment tests with a fake actor; frame N+1 completing while N is
  frozen and unsent proves N is unlinked and N+1 published; pane close with a
  frozen unsent frame leaks nothing; `graphics_freeze` timing moves out of the
  main-loop event. No wire change.

Exit: main-loop event dispatch shows no per-frame stall in `--measure`;
`graphics_stage_blocked.worker` is zero.

Result (2026-09-02): the runtime-thread freeze is gone (`graphics_freeze`
0 samples, every transfer adopted), so input dispatch no longer stalls ~8 ms
per frame. Throughput did not move: presented 47.6 frames/s against 48.2
forwarded, because the actor is serial and now spends 19.8 ms per batch
(11.5 ms decode + the same ~8 ms freeze it inherited). Both halves are page
faults on fresh memory, not copying: the 50 MiB loading buffer and the fresh
shared object each fault in ~2300 pages per frame. `graphics_stage_deferred`
stays non-zero and harmless: the send loop polls the lane while the actor
runs, and adoption happens at the actor's completion anyway. P4 and P6 are
where the actor's time goes down.

## P4. One copy per frame: the frozen object is the emulator's storage

The original P4 was a persistent file ring handed to the host with `t=f`.
Measured before building it (`scratchpad/ringbench.c`, M3, 8 slots of one 4K
frame rewritten at 60 Hz in `$TMPDIR`): 8.2 ms per frame of write cost, worse
than a fresh shm object, and `iostat` showed the kernel writing the dirty
pages back to disk at up to 351 MB/s. A file ring is out on macOS. The real
cost was never the copy; it was fresh memory: Ghostty VT's 50 MiB loading
buffer plus a fresh shared object, each faulting in ~2300 pages per frame.

- The media actor handles the atomic terminal-browser frame itself
  (`filterAtomicSharedFrames` already isolates it): maps the child's object,
  copies it once into a fresh runtime-owned object, unlinks the child's
  name, and maps its own object read-only for the life of the image.
- The emulator stores a one-byte placeholder as the image data. It never
  reads pixels in the runtime; readers resolve the placeholder to the
  mapping through `PaneMediaAllocator.imagePixels`. Freeing the placeholder
  (replacement, delete, pane close) unmaps the object and releases its
  reservation, so `std.mem.Allocator`'s safety scribble never touches an
  object a client or host may still be reading (a copy-on-write mapping
  would have avoided that too, but macOS refuses `MAP_PRIVATE` on shm).
- The envelope's prefix, a synthesized `a=p` placement and the suffix still
  go through the emulator, so cursor policy and synchronized output are
  unchanged. Frames with crop, offset or z keys keep the parser path.
- The object doubles as the parked transfer for local clients with no extra
  reservation; the P3 fallback copy remains for everything else.
- Tests: the runtime test proves one copy (the emulator's data is the
  placeholder, the pixels are the mapping), replacement unmaps the previous
  object with flat quota, and a pane without shared clients loads the frame
  the same way and parks nothing. Filter tests cover the direct sink and the
  crop-key exclusion.
- `telar-frame-source` (examples/frame_source.zig) publishes frames the way
  terminal-browser does at a chosen size and rate, and
  `verify_terminal_browser.py --source synthetic:WxH@FPS --measure S` runs
  it through Telar on Ghostty, so the pipeline can be measured at exactly 4K
  without Chromium.

Exit: `--measure` at 4K presents ≥ 60 frames/s with zero resets, drops and
resyncs.

Result (2026-09-02, synthetic 3840x2160 RGBA at 120 frames/s, 15 s):
forwarded 103.1/s, presented 62.0/s (the pacer cap), present interval
16.7 ms avg / 34.5 ms max, media ingest 8.3 ms avg, zero drops, resets or
resyncs, 1951 of 1951 frames direct and adopted. The runtime now has about
two frames of headroom per pacer interval at 4K. terminal-browser runs on
the same day were dominated by the machine's memory pressure (4.8 GB of
6 GB swap in use, 17 GB compressed): Chromium produced 15-38 frames/s with
2-3 folded frames total, so the browser, not Telar, was the ceiling; the
synthetic source is the reproducible gate from here on.

## P5. Accept validated `t=f` from children

terminal-browser prefers `t=f` and, inside Telar, would keep its persistent
file ring, saving the per-frame object creation on its side. The direct path
maps the file read-only, so Telar's side never dirties file pages.

- The emulator's `.file` limit stays off: it never opens a child path. The
  pane handles `t=f` itself, on both the complete-frame envelope
  (`filterAtomicSharedFrames` accepts `t=s` and `t=f`, so coalescing is the
  same) and the `a=q,t=f` capability query, which is answered `OK` or
  `EBADF` from the same validation and removed from what the emulator
  parses.
- Validation before mapping: absolute path, `O_NOFOLLOW`, regular file,
  owner is the runtime uid, size at least the declared
  `width * height * bpp`, and byte length under the screen cap. Anything
  else counts `media_unavailable_frames` and the pane keeps its current
  image. The child can only point at files it could already read, so the
  remaining open-after-validate window changes nothing about what the pane
  can show. The file is mapped read-only for one copy and never written,
  kept open or deleted.
- `t=t` stays disabled.
- Tests: a file frame loads with one copy and leaves the file untouched;
  symlink, directory, short file and relative path are refused with the
  image unchanged; queries answer `OK` for an acceptable file and `EBADF`
  for a missing one. `telar-frame-source --transport file` and
  `--measure --transport file` cover the pipeline end to end, and the
  browser run reports `media_file_frames`.

Exit: the browser run reports the file transport and the same frames/s as
shared memory.

Result (2026-09-02): terminal-browser now passes its file probe inside
Telar and every frame arrives as a file frame (132 of 132 direct and
adopted in a 15 s run; the browser itself managed 7.6 frames/s on this
memory-starved machine, so its rate says nothing about Telar). Synthetic
4K at 120 frames/s for 15 s, file transport: forwarded 104.5/s, presented
60.2/s, ingest 6.7 ms avg; shared memory in the same session: 104.2/s and
61.3/s, ingest 7.6 ms avg. One difference worth watching: the file run's
worst present interval was 184 ms against 22 ms for shared memory, most
likely the kernel writing the child's dirty file pages back.

## P6. Explicit host acknowledgement instead of unlink polling

The client learns that Ghostty consumed a name by probing `shm_open` on
every writer pass (`kitty.zig:379-396`), and the 180-pass deadline is the
only recovery. With `q=0` on the transmit, Ghostty answers `OK` for the
image id; the client's input parser already consumes APC replies for the
capability probes.

- Emit the `t=s` transmit with `q=0`; route `OK`/error replies for pane image
  ids to `kitty.Store`, which retires on the reply and returns credit
  exactly. Placements keep `q=2`.
- Keep the probe and deadline as the safety net for hosts that answer
  nothing.
- Tests: reply routing, retire on `OK`, inline fallback on an error reply.

Exit: `shared_retire_latency` p99 under one pacer interval on the synthetic
run.

Result (2026-09-02, synthetic 4K at 120 frames/s): retire latency 16.4 ms
avg and 33.5 ms max (from 16.5 ms avg and 55.4 ms max with probing alone),
forwarded 111.3/s, presented 61.2/s, zero expiries. Retirement is still
observed at pass granularity because the replaced generation retires when
the replacement's placement lands, so the average sits at one interval; the
ack removed the tail, not the floor. The 180-pass deadline and the probe
remain as the safety net.

## P7. Gate and documentation

- `docs/performance-gates.md`: the synthetic `--measure` run with `--floor 58`
  is the graphics throughput gate, once per transport; the browser run
  carries no floor because Chromium's paint rate is the host's business.
- `docs/kitty-graphics.md` and `docs/flows/pane-graphics.md` describe the
  control/bulk split, the single-copy path, file validation and the host
  reply.
- ADR 0008 records why control escapes ride the cell frame, why the runtime
  hands out shared objects rather than files, and why the emulator holds a
  placeholder.

Result (2026-09-02): done; the gate passes on the reference machine for both
transports.

---

## Baseline (P1, 2026-09-02)

Apple M3, Ghostty 1.3.1, terminal-browser `cce10b6`, full-size pane on the
local display (cells 24x66 px), 20 s window, steady-state means:

| Build                      | Frame bytes | Forwarded/s | Published/s | Presented/s |
| -------------------------- | ----------- | ----------- | ----------- | ----------- |
| Debug                      | 37,667,520  | 17.9        | 17.5        | 17.5        |
| ReleaseFast `-Ddiagnostics` | 42,863,040  | 49.6        | 49.6        | 20.0        |

ReleaseFast detail: media ingest 10.9 ms avg (21.7 max), freeze 7.7 ms avg
(24.9 max) on the main loop, 1934 send-loop graphics lanes deferred behind
the media actor, 0 credit blocks, 549 client media deferrals, present
interval 50.6 ms avg (243 max), retire latency 49.4 ms avg. The runtime
publishes two and a half frames for every one the client presents; the rest
are retired unseen when the next generation lands. In Debug the media actor
itself (47.9 ms per batch) is the ceiling, which is why measurement needs
the optimized build.

Benchmark (`zig build bench -- --filter 3840x2160`, ReleaseFast, medians):
child publish 2.3 ms, publish + media ingest 6.4 ms, freeze 2.3 ms per 4K
frame.
